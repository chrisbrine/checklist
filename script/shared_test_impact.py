#!/usr/bin/env python3
"""Conservative root XCTest consumers of shared source declarations by compiler USR."""
import hashlib
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from index_store import (repository_path, DECLARATION, DEFINITION, REFERENCE, CALL,
                         CHILDOF, CALLEDBY, CONTAINEDBY, EXTENDEDBY, CALLABLE_KINDS)


def _test_classes(root):
    """Current root XCTest declarations; strings/comments cannot invent classes."""
    classes = {}
    # Test fixtures contain Swift snippets. Remove them before collecting actual
    # declarations (including raw and multiline Swift strings).
    literals = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|#+"""[\s\S]*?"""#+|'
                          r'"""[\s\S]*?"""|#+"[^\n]*?"#+|"(?:\\.|[^"\\])*"')
    declaration = re.compile(r'\bclass\s+(\w+)\s*:\s*(?:\w+\.)?XCTestCase\b')
    for source in sorted((root / 'Tests').rglob('*.swift')):
        path = source.relative_to(root).as_posix()
        parts = Path(path).parts
        if len(parts) < 3:
            continue
        text = literals.sub(lambda match: '\n' * match.group().count('\n'), source.read_text())
        for name in declaration.findall(text):
            classes.setdefault(parts[1] + '.' + name, set()).add(path)
    return classes


def shared_source_classes(root, export, paths):
    """Return root Target.Class consumers, or reject an incomplete/stale export.

    This is index_references' finite declaration graph in reverse, built once
    for all requested paths. Like that walk, every reference in a test class's
    files is a conservative seed; type references never expand all type members.
    A requested source may differ from its indexed bytes because the caller is
    planning its edit. All other indexed source inputs must still match.
    """
    root, paths = Path(root).resolve(), set(paths)
    if (not isinstance(export, dict) or export.get('schema_version') != 1
            or not isinstance(export.get('occurrences'), list)):
        raise ValueError('invalid index export')
    hashes = export.get('source_hashes')
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError('index export needs source hashes')
    for path in paths:
        if (not isinstance(path, str) or repository_path(path, root) != path
                or not (root / path).is_file()):
            raise ValueError('unknown shared source: ' + str(path))
    for path, digest in hashes.items():
        if (not isinstance(path, str) or repository_path(path, root) != path
                or not (root / path).is_file() or not isinstance(digest, str)
                or not re.fullmatch(r'[0-9a-f]{64}', digest)):
            raise ValueError('invalid index source hash: ' + str(path))
        if path not in paths and hashlib.sha256((root / path).read_bytes()).hexdigest() != digest:
            raise ValueError('index export source inputs differ: ' + path)

    rows, kinds, definitions, source_paths = [], {}, {}, {}
    for item in export['occurrences']:
        if (not isinstance(item, dict) or not isinstance(item.get('file'), str)
                or not isinstance(item.get('usr'), str) or not isinstance(item.get('name'), str)
                or type(item.get('roles')) is not int or type(item.get('kind')) is not int
                or not isinstance(item.get('relations', []), list)):
            raise ValueError('invalid index occurrence')
        for relation in item.get('relations', []):
            if (not isinstance(relation, dict) or not isinstance(relation.get('usr'), str)
                    or type(relation.get('roles')) is not int):
                raise ValueError('invalid index relation')
        if item['file'] not in source_paths:
            source_paths[item['file']] = repository_path(item['file'], root)
        path = source_paths[item['file']]
        if path is None or path not in hashes:
            raise ValueError('index export occurrence has no source hash: ' + item['file'])
        if not item['usr']:
            continue
        rows.append((path, item))
        kinds[item['usr']] = item['kind']
        if item['roles'] & (DECLARATION | DEFINITION):
            definitions.setdefault(path, set()).add(item['usr'])
    for path in paths:
        if not definitions.get(path):
            raise ValueError('shared source has no indexed declarations: ' + path)

    current_sources = {path.relative_to(root).as_posix()
                       for folder in ('Sources', 'Tests', 'Packages/ChecklistShared/Sources')
                       for path in (root / folder).rglob('*.swift')}
    missing_inputs = current_sources - set(hashes)
    missing_sources = sorted(path for path in missing_inputs if not path.startswith('Tests/'))
    missing_tests = sorted(path for path in missing_inputs if path.startswith('Tests/'))
    if missing_sources:
        raise ValueError('index export missing current Swift source: ' + missing_sources[0])
    if missing_tests:
        raise ValueError('index export missing current Swift test input: ' + missing_tests[0])
    classes = _test_classes(root)
    class_usrs, indexed_class_files = {}, {}
    for path, item in rows:
        parts = Path(path).parts
        if (parts[0] == 'Tests' and len(parts) >= 3 and item['kind'] == 7
                and item['roles'] & (DECLARATION | DEFINITION)):
            group = parts[1] + '.' + item['name']
            if path in classes.get(group, ()):
                class_usrs.setdefault(group, set()).add(item['usr'])
                indexed_class_files.setdefault(group, set()).add(path)
    for group, files in classes.items():
        if indexed_class_files.get(group) != files:
            raise ValueError('root test class missing from index export: ' + group)

    files_to_classes = {}
    usr_to_classes = {}
    for group, usrs in class_usrs.items():
        for usr in usrs:
            usr_to_classes.setdefault(usr, set()).add(group)
    for path, item in rows:
        if item['roles'] & (DECLARATION | DEFINITION | EXTENDEDBY):
            files_to_classes.setdefault(path, set()).update(usr_to_classes.get(item['usr'], ()))
    seeds, callers = {}, {}
    for path, item in rows:
        usr, roles = item['usr'], item['roles']
        if roles & (REFERENCE | CALL | DECLARATION | DEFINITION):
            seeds.setdefault(usr, set()).update(files_to_classes.get(path, ()))
        for relation in item.get('relations', []):
            parent = relation['usr']
            if (roles & (REFERENCE | CALL) and relation['roles'] & (CALLEDBY | CONTAINEDBY)
                    or roles & (DECLARATION | DEFINITION) and relation['roles'] & CHILDOF
                    and kinds.get(parent) in CALLABLE_KINDS):
                callers.setdefault(usr, set()).add(parent)

    result = {}
    for path in sorted(paths):
        visited, frontier, consumers = set(), set(definitions[path]), set()
        while frontier:
            usr = frontier.pop()
            if usr in visited:
                continue
            visited.add(usr)
            consumers.update(seeds.get(usr, ()))
            frontier.update(callers.get(usr, set()) - visited)
        result[path] = sorted(consumers)
    return result
