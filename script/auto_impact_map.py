#!/usr/bin/env python3
"""Restore local selection caches; stale inputs can refresh a warm compiler index.

Compiler-index maps are conservative static reachability, never measured coverage.
A warm build permits an incremental index build, optionally through a configured
build-cap wrapper; test methods never execute. An unavailable refresh leaves
module fallback intact.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import os
import re
import subprocess
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_inputs(root):
    paths = {root / 'Package.swift', root / 'Package.resolved'}
    paths.update((root / 'Packages').rglob('Package.swift'))
    paths.update((root / 'Packages').rglob('Package.resolved'))
    return {path.relative_to(root).as_posix(): digest(path) for path in sorted(paths) if path.is_file()}


def generator_inputs(root):
    return {path: digest(root / path) for path in ('script/auto_impact_map.py',
            'script/shared_test_impact.py', 'script/index_store.py', 'script/test_impact_map.py',
            'script/affected_tests.py')
            if (root / path).is_file()}


def require_generator_inputs(root, expected, phase):
    if generator_inputs(root) != expected:
        raise ValueError('generator inputs changed during ' + phase + '; rerun with stable tooling')

def source_inventory(root):
    # Package manifests are Swift programs, but they are not target index inputs.
    # Keep a source actually named Package.swift inside Sources/Tests observable.
    return {path.relative_to(root).as_posix() for folder in ('Sources', 'Tests', 'Packages')
            for path in (root / folder).rglob('*') if path.is_file()
            and path.suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp')
            and not (folder == 'Packages' and path.name == 'Package.swift'
                     and not {'Sources', 'Tests'}.intersection(path.relative_to(root).parts[2:]))}


def root_index_inventory(root):
    # A root --build-tests compiles dependency Sources, not dependency Tests.
    # Those tests retain their source fingerprints and separate package commands.
    return {path for path in source_inventory(root) if not re.match(r'Packages/[^/]+/Tests/', path)}


def validate_inputs(root, data, changed=()):
    """Only selected test edits may differ; stale production needs module fallback."""
    from index_store import repository_path
    changed = {path for path in changed if path.startswith('Tests/')
               or re.match(r'Packages/[^/]+/Tests/', path)}
    hashes = data.get('source_hashes')
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError('index export needs source hashes')
    if not data.get('build_inputs') or data['build_inputs'] != build_inputs(root):
        raise ValueError('index build manifest inputs are missing or changed')
    missing = root_index_inventory(root) - set(hashes)
    # New test inputs use explicit direct/fixture fallback. Production additions
    # require a current export too: extensions can change unchanged consumers.
    missing -= set(changed)
    if missing:
        raise ValueError('index export missing current source: ' + sorted(missing)[0])
    for path, value in hashes.items():
        if (not isinstance(path, str) or repository_path(path, root) != path
                or not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)):
            raise ValueError('invalid index source hash: ' + str(path))
        if path not in changed and (not (root / path).is_file() or digest(root / path) != value):
            raise ValueError('index export source inputs differ: ' + path)


def executable_test_targets(graph, path):
    """Physical target/runtime closure; reading another test's source is separate."""
    from affected_tests import RUNTIME_TEST_CONSUMERS
    targets = {item['name']: item for item in graph['targets']}
    owner = next((item for item in sorted(targets.values(), key=lambda item: len(item['path']), reverse=True)
                  if path.startswith(item['path'] + '/')), None)
    if owner is None:
        return {name for name, item in targets.items() if item['type'] == 'test'}
    reached = {owner['name']}
    while True:
        added = {name for name, item in targets.items()
                 if reached.intersection(item.get('target_dependencies', []))}
        for producer, consumers in RUNTIME_TEST_CONSUMERS.items():
            if producer in reached:
                added.update(name for name in consumers if name in targets)
        if added <= reached:
            return {name for name in reached if targets[name]['type'] == 'test'}
        reached.update(added)


def build_index_map(root, export, cases, changed=(), graph=None):
    """Use CL-294's USR graph and current class audit; do not label it as execution."""
    from shared_test_impact import shared_source_classes, _test_classes
    from index_store import DECLARATION, DEFINITION, REFERENCE, CALL, CALLEDBY, CONTAINEDBY
    validate_inputs(root, export, changed)
    definitions = sorted({item['file'] for item in export.get('occurrences', [])
                          if isinstance(item, dict) and isinstance(item.get('roles'), int)
                          and item['roles'] & (DECLARATION | DEFINITION)
                          and isinstance(item.get('file'), str) and (root / item['file']).is_file()})
    # The shared walker validates all indexed class declarations and source
    # inventory. Hash drift was checked above with only caller-selected exemptions.
    # Start dynamic readers at each actual call's containing declaration, not
    # every definition in a file that also happens to contain a lookup.
    runtime_name = re.compile(r'^(?:NSClassFromString|NSSelectorFromString|dlsym)(?:\(|$)')
    lookup_roots, opaque_lookups = {}, set()
    for item in export.get('occurrences', []):
        if (isinstance(item, dict) and isinstance(item.get('name'), str)
                and runtime_name.match(item['name']) and type(item.get('roles')) is int
                and item['roles'] & (REFERENCE | CALL) and isinstance(item.get('file'), str)
                and isinstance(item.get('usr'), str) and isinstance(item.get('relations', []), list)):
            roots = {relation['usr'] for relation in item.get('relations', [])
                     if isinstance(relation, dict) and isinstance(relation.get('usr'), str) and relation['usr']
                     and type(relation.get('roles')) is int
                     and relation['roles'] & (CALLEDBY | CONTAINEDBY)}
            lookup_roots.setdefault(item['file'], set()).update(roots)
            if not roots:
                opaque_lookups.add(item['file'])
    lookup_users = {usr: [] for roots in lookup_roots.values() for usr in roots}
    consumers = shared_source_classes(root, export, definitions, include_dispatch=True, usr_results=lookup_users)
    sources = {path: {'classes': groups, 'qualification_cases': sorted(
        case for case in cases if case.split('/')[0] in groups)} for path, groups in consumers.items()}
    from test_impact_map import inspection_references
    inspections = {}
    for group in _test_classes(root):
        test_inputs = [path for path, groups in consumers.items() if group in groups and path.startswith('Tests/')]
        references = inspection_references(root, group, test_inputs)
        if references:
            inspections[group] = sorted(references)
        for path in references:
            entry = sources.setdefault(path, {'classes': [], 'qualification_cases': []})
            entry['classes'] = sorted(set(entry['classes']) | {group})
    # Lookup destinations have no USR edge. Keep their real callers conservative,
    # bounded by the binaries that can load each target; test source readers are
    # already recorded separately above.
    runtime = re.compile(r'\b(?:NSClassFromString|NSSelectorFromString|dlsym)\s*\(|@_dynamicReplacement\b')
    class_files = _test_classes(root)
    dynamic_classes, dynamic_sources = set(), []
    for path in source_inventory(root):
        if not runtime.search((root / path).read_text(errors='replace')):
            continue
        roots = lookup_roots.get(path, ())
        readers = (set().union(*(set(lookup_users[usr]) for usr in roots)) if roots
                   else set(consumers.get(path, ())))
        # A snippet or call missing its containing declaration cannot be narrowed
        # to the external lookup USR: retain every consumer of its helper file.
        if not roots or path in opaque_lookups:
            readers.update(consumers.get(path, ()))
            readers.update(group for group, files in class_files.items() if path in files)
        if graph is not None:
            allowed = executable_test_targets(graph, path)
            readers = {group for group in readers if group.split('.')[0] in allowed}
        dynamic_classes.update(readers)
        if not path.startswith('Tests/') and not re.match(r'Packages/[^/]+/Tests/', path):
            dynamic_sources.append(path)
    if dynamic_classes:
        for path, entry in sources.items():
            readers = dynamic_classes
            if graph is not None:
                allowed = executable_test_targets(graph, path)
                readers = {group for group in readers if group.split('.')[0] in allowed}
            entry['classes'] = sorted(set(entry['classes']) | readers)
            entry['qualification_cases'] = sorted(set(entry['qualification_cases']) | {
                case for case in cases if case.split('/')[0] in readers})
    return {'schema_version': 2, 'selection_source': 'index-store', 'complete': True,
            'generated_at': datetime.now(timezone.utc).isoformat(),
            'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            'sources': sources, 'source_hashes': dict(export['source_hashes']),
            'build_inputs': dict(export['build_inputs']), 'generator_inputs': generator_inputs(root),
            'inspection_references': inspections,
            'class_inventory': sorted(_test_classes(root)), 'qualification_case_inventory': list(cases),
            'measured_classes': [], 'measured_qualification_cases': [],
            'indexed_classes': sorted(class_files), 'indexed_qualification_cases': list(cases),
            'dynamic_lookup_classes': sorted(dynamic_classes), 'static_fallback_sources': sorted(dynamic_sources),
            'dynamic_scope': 'target-runtime-links' if graph is not None else 'conservative-all-targets',
            'index_store': {key: value for key, value in export.items()
                            if key not in ('occurrences', 'source_hashes', 'build_inputs')}}


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        json.dump(data, stream, separators=(',', ':'))
        stream.write('\n')
        temporary = Path(stream.name)
    temporary.replace(path)


def store_signature(paths):
    """Detect raw index replacement since the completed-build export receipt."""
    signature = hashlib.sha256()
    for root in map(Path, paths):
        if not root.is_dir():
            raise ValueError('retained index store is missing: ' + str(root))
        for path in sorted(root.rglob('*')):
            if path.is_file():
                info = path.stat()
                signature.update((str(path) + ':' + str(info.st_size) + ':' + str(info.st_mtime_ns)).encode())
    return signature.hexdigest()


def save_index_receipt(output, export):
    paths = [export['store']] + [item['store'] for item in export.get('additional_stores', [])]
    receipt = {key: export[key] for key in ('source_hashes', 'build_inputs')}
    receipt.update(stores=paths, signature=store_signature(paths), library=export['library'])
    atomic_json(output.with_name('index-inputs.json'), receipt)


def recover_raw_index(root, receipt_path, changed):
    from index_store import read_index_store
    receipt = json.loads(receipt_path.read_text())
    validate_inputs(root, receipt, changed)
    if store_signature(receipt['stores']) != receipt['signature']:
        raise ValueError('raw index changed since completed-build export')
    result = read_index_store(receipt['stores'][0], root, receipt['library'], receipt['stores'][1:])
    if store_signature(receipt['stores']) != receipt['signature']:
        raise ValueError('raw index changed while recovering export')
    # The read occurs after edits may have started. Retain the compiled input
    # hashes certified by the original explicit same-build export, not new bytes.
    result.update(source_hashes=receipt['source_hashes'], build_inputs=receipt['build_inputs'])
    return result


def compiler_inputs(root):
    result = {path: digest(root / path) for path in source_inventory(root)}
    result.update(build_inputs(root))
    return result


def file_identity(path):
    path = Path(path).resolve()
    if not path.is_file():
        return {'path': str(path), 'exists': False}
    info = path.stat()
    return {'path': str(path), 'bytes': info.st_size, 'modified_ns': info.st_mtime_ns}


def refresh_native_index(root, scratch, runner_wrapper=None):
    """Refresh compiler inputs automatically, preserving the warm test backend."""
    from index_store import read_index_store, DEFAULT_LIBRARY
    wrapper = runner_wrapper or os.environ.get('CHECKLIST_SWIFT_RUNNER')
    if wrapper and not Path(wrapper).is_file():
        raise ValueError('configured native index runner wrapper is missing: ' + str(wrapper))
    native = (scratch / 'build.db').is_file() and (
        (scratch / 'debug/Modules').is_dir()
        or any(path.is_dir() for path in scratch.glob('*/debug/Modules')))
    swiftbuild = ((scratch / 'manifest.pif').is_file()
                  and any((scratch / 'out/Products/Debug').glob('*.swiftmodule')))
    if not native and not swiftbuild:
        raise ValueError('native index refresh needs a warm native or swiftbuild build cache')
    # Swift Build may ignore -Xswiftc indexing flags. Retain a native index lane
    # beside its receipts rather than switch/rebuild the assigned warm test lane.
    index_scratch = scratch if native else scratch / 'affected-tests/native-index'
    inputs = compiler_inputs(root)
    generators = generator_inputs(root)
    wrapper_input = [file_identity(wrapper), digest(Path(wrapper))] if wrapper else None
    context = [inputs, generators, wrapper_input, str(index_scratch),
               file_identity(DEFAULT_LIBRARY), file_identity(DEFAULT_LIBRARY.parent.parent / 'bin/swiftc'),
               os.environ.get('DEVELOPER_DIR'), os.environ.get('TOOLCHAINS')]
    stamp = hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()
    directory = scratch / 'affected-tests'
    directory.mkdir(parents=True, exist_ok=True)
    receipt_path = directory / 'index-refresh-status.json'
    if receipt_path.is_file():
        previous = json.loads(receipt_path.read_text())
        if previous.get('inputs') == stamp and previous.get('failed'):
            raise ValueError('native index refresh already failed for these inputs; inspect ' + str(receipt_path))
    index = index_scratch / 'index-store'
    prefix = ['bash', str(Path(wrapper).resolve())] if wrapper else []
    command = prefix + ['swift', 'build', '--skip-update',
               '--build-tests', '--build-system', 'native', '--enable-index-store',
               '--cache-path', str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
               '--enable-dependency-cache', '--scratch-path', str(index_scratch),
               '-Xswiftc', '-index-store-path', '-Xswiftc', str(index)]
    started = time.monotonic()
    receipt = {'inputs': stamp, 'command': command, 'failed': True}
    try:
        with (directory / 'index-refresh.log').open('w') as log:
            process = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
        if process.returncode:
            raise ValueError('native index refresh failed with exit ' + str(process.returncode) + '; see ' + str(directory / 'index-refresh.log'))
        current = compiler_inputs(root)
        if current != inputs:
            raise ValueError('source inputs changed during native index refresh')
        require_generator_inputs(root, generators, 'native index refresh')
        clang_store = index_scratch / 'debug/index/store'
        additional = [clang_store] if clang_store.is_dir() else []
        export = read_index_store(index, root, additional_stores=additional)
        if compiler_inputs(root) != inputs:
            raise ValueError('source inputs changed during native index export')
        if any(path not in inputs or inputs[path] != value
               for path, value in export.get('source_hashes', {}).items()):
            raise ValueError('native index export hashes differ from compiled source snapshot')
        require_generator_inputs(root, generators, 'native index export')
        output = directory / 'index-export.json'
        atomic_json(output, export)
        save_index_receipt(output, export)
        receipt['failed'] = False
        return output
    except Exception as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['wall_seconds'] = round(time.monotonic() - started, 3)
        atomic_json(receipt_path, receipt)


def regenerate(root, scratch, output, cases, changed=(), index_path=None, max_age_hours=24, runner_wrapper=None, graph=None):
    """Try retained complete coverage first, then a saved semantic index export."""
    from affected_tests import load_impact_map
    started = time.monotonic()
    cache = scratch / 'affected-tests/test-impact-map.json'
    generators = generator_inputs(root)

    def generator_drift():
        try:
            require_generator_inputs(root, generators, 'impact map regeneration')
        except ValueError as error:
            return {'state': 'unavailable', 'reason': str(error),
                    'refresh': 'Rerun script/affected_tests.py after generator edits finish'}
        return None

    candidates = [cache]
    candidates.extend(sorted((root / '.local/build').glob('test-impact-profiles-*/map.json'), reverse=True))
    for candidate in candidates:
        if candidate == output:
            continue
        data, status = load_impact_map(root, candidate, max_age_hours, changed)
        if data is not None:
            if drift := generator_drift():
                return drift
            atomic_json(output, data)
            return {'state': 'restored', 'from': str(candidate), 'source': data.get('selection_source', 'coverage')}
    indices = [index_path] if index_path else [scratch / 'affected-tests/index-export.json',
                                              root / '.local/build/test-impact-index.json']
    indices += sorted((root / '.local/build').glob('test-impact-profiles-*/index-export.json'), reverse=True)
    reasons = []
    receipt = scratch / 'affected-tests/index-inputs.json'
    if not any(candidate.is_file() for candidate in indices) and receipt.is_file():
        try:
            recovered = recover_raw_index(root, receipt, changed)
            recovered_path = scratch / 'affected-tests/index-export.json'
            if drift := generator_drift():
                return drift
            atomic_json(recovered_path, recovered)
            indices.insert(0, recovered_path)
        except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
            reasons.append(str(receipt) + ': ' + str(error))
    for candidate in dict.fromkeys(indices):
        if not candidate.is_file():
            continue
        try:
            data = build_index_map(root, json.loads(candidate.read_text()), cases, changed, graph)
            data['generation_seconds'] = round(time.monotonic() - started, 3)
            data['index_export_sha256'] = digest(candidate)
            if drift := generator_drift():
                return drift
            atomic_json(output, data)
            atomic_json(cache, data)
            return {'state': 'regenerated', 'from': str(candidate), 'source': 'index-store',
                    'seconds': data['generation_seconds']}
        except (OSError, ValueError, KeyError, TypeError) as error:
            reasons.append(str(candidate) + ': ' + str(error))
    if drift := generator_drift():
        return drift
    try:
        refreshed = refresh_native_index(root, scratch, runner_wrapper)
        data = build_index_map(root, json.loads(refreshed.read_text()), cases, changed, graph)
        data['generation_seconds'] = round(time.monotonic() - started, 3)
        data['index_export_sha256'] = digest(refreshed)
        if drift := generator_drift():
            return drift
        atomic_json(output, data)
        atomic_json(cache, data)
        return {'state': 'regenerated', 'from': str(refreshed), 'source': 'index-store',
                'native_index_refreshed': True, 'seconds': data['generation_seconds']}
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        reasons.append(str(error))
    return {'state': 'unavailable', 'reason': '; '.join(reasons) or 'no retained current coverage map or compiler-index export',
            'refresh': 'Generate a same-build index export with script/index_store.py; pass --impact-index or save it at ' + str(indices[0])}
