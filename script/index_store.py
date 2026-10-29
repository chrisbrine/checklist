#!/usr/bin/env python3
"""Export repository occurrences through the toolchain's public IndexStore C API.

No compiler or product dependency is added. Declarations below follow
https://github.com/swiftlang/llvm-project/blob/next/clang/include/indexstore/indexstore.h.
Only records referenced by current units are read, never orphaned record files.
"""
import argparse
import ctypes as C
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time

DEFAULT_LIBRARY = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/'
                       'XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib')
DECLARATION, DEFINITION, REFERENCE, CALL = 1, 2, 4, 32
CHILDOF, CALLEDBY, CONTAINEDBY = 1 << 9, 1 << 13, 1 << 16
EXTENDEDBY = 1 << 14
DYNAMIC, OVERRIDEOF, ACCESSOROF, SPECIALIZATIONOF = 1 << 6, 1 << 11, 1 << 15, 1 << 18
CALLABLE_KINDS = {12, 16, 17, 18, 22, 23, 24}


def dispatch_edges(rows):
    """Forward requirement/receiver -> witness, override, accessor implementation."""
    dispatch = {item['usr'] for _, item in rows if item['roles'] & (DECLARATION | DEFINITION)
                and (item['roles'] & DYNAMIC or any(relation['roles'] & OVERRIDEOF
                     for relation in item.get('relations', [])))}
    for _, item in rows:
        if not item['roles'] & (DECLARATION | DEFINITION):
            continue
        for relation in item.get('relations', []):
            if (relation['roles'] & (OVERRIDEOF | ACCESSOROF | SPECIALIZATIONOF)
                    or item['usr'] in dispatch and relation['roles'] & CHILDOF):
                yield relation['usr'], item['usr']


class StringRef(C.Structure):
    _fields_ = [('data', C.c_void_p), ('length', C.c_size_t)]


def _string(value):
    return C.string_at(value.data, value.length).decode('utf-8') if value.length else ''


def repository_path(filename, root):
    """Exclude external/generated files and paths escaping the repository."""
    path = Path(filename)
    if '..' in path.parts:
        return None
    path = path if path.is_absolute() else root / path
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        return None
    parts = relative.parts
    tree = parts and (parts[0] in ('Sources', 'Tests') or
                      (parts[0] == 'Packages' and len(parts) > 2 and parts[2] in ('Sources', 'Tests')))
    return relative.as_posix() if tree and path.suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp') else None


class IndexStore:
    """Small synchronous ctypes binding; reader-owned strings are copied eagerly."""
    ObjectCallback = C.CFUNCTYPE(C.c_bool, C.c_void_p, C.c_void_p)
    UnitCallback = C.CFUNCTYPE(C.c_bool, C.c_void_p, StringRef)

    def __init__(self, library):
        self.lib = C.CDLL(str(library))
        pointer = C.c_void_p
        signatures = {
            'error_get_description': (C.c_char_p, [pointer]),
            'error_dispose': (None, [pointer]),
            'store_create': (pointer, [C.c_char_p, C.POINTER(pointer)]),
            'store_dispose': (None, [pointer]),
            'store_units_apply_f': (C.c_bool, [pointer, C.c_uint, pointer, self.UnitCallback]),
            'unit_reader_create': (pointer, [pointer, C.c_char_p, C.POINTER(pointer)]),
            'unit_reader_dispose': (None, [pointer]),
            'unit_reader_is_system_unit': (C.c_bool, [pointer]),
            'unit_reader_dependencies_apply_f': (C.c_bool, [pointer, pointer, self.ObjectCallback]),
            'unit_dependency_get_kind': (C.c_int, [pointer]),
            'unit_dependency_get_name': (StringRef, [pointer]),
            'unit_dependency_get_filepath': (StringRef, [pointer]),
            'unit_dependency_is_system': (C.c_bool, [pointer]),
            'record_reader_create': (pointer, [pointer, C.c_char_p, C.POINTER(pointer)]),
            'record_reader_dispose': (None, [pointer]),
            'record_reader_occurrences_apply_f': (C.c_bool, [pointer, pointer, self.ObjectCallback]),
            'occurrence_get_symbol': (pointer, [pointer]),
            'occurrence_get_roles': (C.c_uint64, [pointer]),
            'occurrence_get_line_col': (None, [pointer, C.POINTER(C.c_uint), C.POINTER(C.c_uint)]),
            'occurrence_relations_apply_f': (C.c_bool, [pointer, pointer, self.ObjectCallback]),
            'symbol_get_usr': (StringRef, [pointer]),
            'symbol_get_name': (StringRef, [pointer]),
            'symbol_get_kind': (C.c_int, [pointer]),
            'symbol_relation_get_roles': (C.c_uint64, [pointer]),
            'symbol_relation_get_symbol': (pointer, [pointer]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.lib, 'indexstore_' + name)
            function.restype, function.argtypes = result, arguments
            setattr(self, name, function)

    def create(self, function, *arguments):
        error = C.c_void_p()
        result = function(*arguments, C.byref(error))
        if error:
            try:
                description = self.error_get_description(error).decode('utf-8')
            finally:
                self.error_dispose(error)
            raise RuntimeError(description)
        if not result:
            raise RuntimeError('IndexStore reader creation failed')
        return result

    def apply(self, function, reader, callback, units=False, allow_empty=False):
        errors = []
        visited = []

        def visit(context, value):
            try:
                visited.append(True)
                callback(value)
                return True
            except Exception as error:
                # ctypes otherwise suppresses callback exceptions.
                errors.append(error)
                return False

        wrapped = (self.UnitCallback if units else self.ObjectCallback)(visit)
        arguments = (reader, 1, None, wrapped) if units else (reader, None, wrapped)
        complete = function(*arguments)
        if errors:
            raise errors[0]
        # Empty compiler records (e.g. a comments-only build aggregation file)
        # have no occurrence block: libIndexStore returns false without calling
        # the visitor. A stopped nonempty walk must still fail closed.
        if not complete and not (allow_empty and not visited):
            raise RuntimeError('IndexStore enumeration did not finish')


def read_index_store(store_path, root, library=DEFAULT_LIBRARY, additional_stores=()):
    """Return a portable semantic export; no test method or database is opened."""
    root, store_path = Path(root).resolve(), Path(store_path).resolve()
    started = time.monotonic()
    api = IndexStore(library)
    store = api.create(api.store_create, str(store_path).encode())
    records, units, occurrences = set(), [], []
    try:
        api.apply(api.store_units_apply_f, store, lambda name: units.append(_string(name)), units=True)
        for name in units:
            unit = api.create(api.unit_reader_create, store, name.encode())
            try:
                if api.unit_reader_is_system_unit(unit):
                    continue

                def dependency(value):
                    if api.unit_dependency_get_kind(value) != 2 or api.unit_dependency_is_system(value):
                        return
                    path = repository_path(_string(api.unit_dependency_get_filepath(value)), root)
                    if path:
                        records.add((_string(api.unit_dependency_get_name(value)), path))

                api.apply(api.unit_reader_dependencies_apply_f, unit, dependency)
            finally:
                api.unit_reader_dispose(unit)
        for name, path in sorted(records):
            record = api.create(api.record_reader_create, store, name.encode())
            try:
                def occurrence(value):
                    symbol = api.occurrence_get_symbol(value)
                    relations = []

                    def relation(item):
                        related = api.symbol_relation_get_symbol(item)
                        relations.append({'usr': _string(api.symbol_get_usr(related)),
                                          'roles': api.symbol_relation_get_roles(item)})

                    api.apply(api.occurrence_relations_apply_f, value, relation)
                    line, column = C.c_uint(), C.c_uint()
                    api.occurrence_get_line_col(value, C.byref(line), C.byref(column))
                    occurrences.append({'file': path, 'usr': _string(api.symbol_get_usr(symbol)),
                        'name': _string(api.symbol_get_name(symbol)), 'kind': api.symbol_get_kind(symbol),
                        'roles': api.occurrence_get_roles(value), 'line': line.value, 'column': column.value,
                        'relations': relations})

                try:
                    api.apply(api.record_reader_occurrences_apply_f, record, occurrence, allow_empty=True)
                except RuntimeError as error:
                    raise RuntimeError(f'{path} ({name}): {error}') from error
            finally:
                api.record_reader_dispose(record)
    finally:
        api.store_dispose(store)
    if not records or not occurrences:
        raise ValueError('index store contains no repository records')
    from auto_impact_map import build_inputs
    result = {'schema_version': 1, 'source': 'index-store', 'store': str(store_path),
            'build_inputs': build_inputs(root), 'library': str(library), 'generated_at': datetime.now(timezone.utc).isoformat(),
            'generation_seconds': round(time.monotonic() - started, 3),
            'unit_count': len(units), 'record_count': len(records), 'occurrences': occurrences,
            'source_hashes': {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                              for path in sorted({path for _, path in records})}}
    # SwiftPM's Clang targets write to its standard store even when -Xswiftc
    # selects a separate Swift store. Read both from the same completed build.
    for additional in additional_stores:
        if Path(additional).resolve() == store_path:
            continue
        other = read_index_store(additional, root, library)
        for path, digest in other['source_hashes'].items():
            if path in result['source_hashes'] and result['source_hashes'][path] != digest:
                raise ValueError('source changed between index stores: ' + path)
        result['occurrences'].extend(other['occurrences'])
        result['source_hashes'].update(other['source_hashes'])
        result.setdefault('additional_stores', []).append({key: value for key, value in other.items()
            if key not in ('occurrences', 'source_hashes')})
    result['generation_seconds'] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--additional-store', type=Path, action='append', default=[],
                        help='additional store from the same build, e.g. SwiftPM Clang records')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--library', type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = read_index_store(args.store, args.root, args.library, args.additional_store)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(',', ':')) + '\n')
    from auto_impact_map import save_index_receipt
    save_index_receipt(args.output, result)
    print(json.dumps({key: value for key, value in result.items()
                      if key not in ('occurrences', 'source_hashes')}))


if __name__ == '__main__':
    main()
