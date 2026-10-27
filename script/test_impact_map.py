#!/usr/bin/env python3
"""Generate an execution-derived source/test impact map (local, never committed).

One instrumented build is followed by a separate xctest process per class and
qualification case. Each process owns its raw profiles, including child processes.
A failed/incomplete refresh is retained as incomplete, never a closed-world map.
Skipped classes use compiler-index declaration reachability, never lexical names.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from index_store import (read_index_store, repository_path, DECLARATION, DEFINITION,
                         REFERENCE, CALL, CHILDOF, CALLEDBY, CONTAINEDBY,
                         EXTENDEDBY, CALLABLE_KINDS)

SCHEMA_VERSION = 1


def _source_path(filename, root):
    path = Path(filename)
    if not path.is_absolute():
        path = root / path
    try:
        relative = path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None
    parts = Path(relative).parts
    repository_tree = parts and (parts[0] in ('Sources', 'Tests') or
                                  (parts[0] == 'Packages' and len(parts) > 2 and parts[2] in ('Sources', 'Tests')))
    return relative if (repository_tree and path.suffix in
                        ('.swift', '.c', '.h', '.m', '.mm', '.cpp')) else None


def parse_coverage_export(payload, root):
    """Return repository source files with executed regions in llvm-cov JSON."""
    if isinstance(payload, str):
        payload = json.loads(payload)
    covered = set()
    for datum in payload.get('data', []):
        for entry in datum.get('files', []):
            path = _source_path(entry['filename'], Path(root))
            # segments: line, column, count, hasCount, isRegionEntry[, isGap].
            executed = any(len(segment) >= 5 and segment[2] > 0 and segment[3]
                           and (len(segment) < 6 or not segment[5])
                           for segment in entry.get('segments', []))
            summary = entry.get('summary', {})
            executed = executed or any(summary.get(kind, {}).get('covered', 0) > 0
                                       for kind in ('regions', 'lines', 'functions'))
            if path and executed:
                covered.add(path)
        # Function regions also cover exports made with skip-expansions/segments.
        for function in datum.get('functions', []):
            filenames = function.get('filenames', [])
            for region in function.get('regions', []):
                if len(region) >= 6 and region[4] > 0 and 0 <= region[5] < len(filenames):
                    path = _source_path(filenames[region[5]], Path(root))
                    if path:
                        covered.add(path)
    return covered


def build_map(root, observations, commit, generated_at, generation_seconds, inventory=None,
              index_export=None):
    """Union observations; inventory includes instrumented files with zero hits.

    Each observation has sources and either class or qualification_case. The
    caller sets complete only after every discovered class and case has coverage;
    assertion failures are reported separately from missing coverage.
    """
    root = Path(root)
    paths = set(inventory or ())
    for observation in observations:
        paths.update(observation['sources'])
    index_edges, index_walks = {}, {}
    for item in observations:
        if item.get('class') and item.get('skipped'):
            group = item['class']
            index_walks[group] = {}
            index_edges[group] = (index_references(root, group, index_export, index_walks[group])
                                  if index_export is not None else set())
    for edges in index_edges.values():
        paths.update(edges)
    sources = {path: {'classes': set(), 'qualification_cases': set()} for path in sorted(paths)}
    classes, cases = set(), set()
    unmeasurable = {}
    for observation in observations:
        group, case = observation.get('class'), observation.get('qualification_case')
        if group and observation.get('skipped'):
            unmeasurable[group] = {
                'reason': observation.get('unmeasurable_reason', 'All native methods skipped; see generation logs'),
                'sources': sorted(index_edges[group]), 'source': 'index-store', 'walk': index_walks[group]}
        if group and not observation.get('skipped'):
            classes.add(group)
        if case and not observation.get('skipped'):
            cases.add(case)
        for path in observation['sources']:
            if group:
                sources[path]['classes'].add(group)
            if case:
                sources[path]['qualification_cases'].add(case)
    return {'schema_version': SCHEMA_VERSION, 'commit': commit,
            'generated_at': generated_at, 'generation_seconds': generation_seconds,
            'complete': False, 'measured_classes': sorted(classes),
            'measured_qualification_cases': sorted(cases),
            'coverage_unmeasurable_classes': unmeasurable,
            'sources': {path: {key: sorted(values) for key, values in entry.items()}
                        for path, entry in sources.items()},
            'source_hashes': {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                              for path in sources if (root / path).is_file()}}


def coverage_gaps(result, classes, cases):
    """A finished attempt is closed only with coverage or an explicit exception."""
    missing_classes = set(classes) - set(result['measured_classes']) - set(result['coverage_unmeasurable_classes'])
    missing_cases = set(cases) - set(result['measured_qualification_cases'])
    missing_index = [group for group, entry in result['coverage_unmeasurable_classes'].items()
                     if entry.get('source') != 'index-store' or not entry.get('sources')
                     or entry.get('walk', {}).get('complete') is not True]
    return (['Missing index-store dependencies: ' + value for value in sorted(missing_index)] +
            ['Unmeasured class: ' + value for value in sorted(missing_classes)] +
            ['Unmeasured qualification case: ' + value for value in sorted(missing_cases)])


def inspection_references(root, identifier, executed_sources=()):
    """Derive literal file/tree readers conservatively from the test class files.

    Literal directories expand to their current source files. These edges are
    separate from execution coverage; generated names cannot establish an edge.
    """
    target, owner = identifier.split('/')[0].split('.', 1)
    references = set()
    executed_tests = {root / path for path in executed_sources if path.startswith('Tests/')}
    files = set((root / 'Tests' / target).rglob('*.swift')) | executed_tests
    for test in sorted(files):
        text = test.read_text()
        if test not in executed_tests and not re.search(r'\b(?:class|extension|struct)\s+' + re.escape(owner) + r'\b', text):
            continue
        for literal in re.findall(r'"((?:Packages/[^"\n]*/)?(?:Sources|Tests)/[^"\n]+)"', text):
            candidate = root / literal
            paths = candidate.rglob('*') if candidate.is_dir() else [candidate]
            references.update(path for item in paths if item.is_file()
                              if (path := _source_path(str(item), root)))
    return references


def index_references(root, identifier, export, walk_stats=None):
    """Resolve test-file references by USR, then traverse recorded declaration edges.

    Follow the finite graph to a fixed point, visiting each USR once. Types do
    not expand to all their members; only callable-local declarations are entered.
    This is conservative static reachability, not execution/branch coverage.
    """
    started = time.monotonic()
    if walk_stats is not None:
        walk_stats.update(complete=False, nodes=0, edges=0, seconds=0.0)
    if not isinstance(export, dict) or export.get('schema_version') != 1 or not isinstance(export.get('occurrences'), list):
        raise ValueError('invalid index export')
    root = Path(root)
    target, owner = identifier.split('/')[0].split('.', 1)
    rows, locations, kinds, edges = [], {}, {}, {}
    paths = {}
    for item in export['occurrences']:
        if (not isinstance(item, dict) or not isinstance(item.get('file'), str)
                or not isinstance(item.get('usr'), str) or not isinstance(item.get('name'), str)
                or not isinstance(item.get('roles'), int) or not isinstance(item.get('kind'), int)
                or not isinstance(item.get('relations', []), list)):
            raise ValueError('invalid index occurrence')
        for relation in item.get('relations', []):
            if (not isinstance(relation, dict) or not isinstance(relation.get('usr'), str)
                    or not isinstance(relation.get('roles'), int)):
                raise ValueError('invalid index relation')
        filename = item['file']
        if filename not in paths:
            path = repository_path(filename, root)
            paths[filename] = path if path and (root / path).is_file() else None
        path = paths[filename]
        if not path or not item['usr']:
            continue
        rows.append((path, item))
        kinds[item['usr']] = item['kind']
        if item['roles'] & (DECLARATION | DEFINITION):
            locations.setdefault(item['usr'], set()).add(path)
    class_usrs = {item['usr'] for path, item in rows
                  if path.startswith('Tests/' + target + '/') and item['kind'] == 7
                  and item['name'] == owner and item['roles'] & (DECLARATION | DEFINITION)}
    files = {path for path, item in rows if item['usr'] in class_usrs
             and item['roles'] & (DECLARATION | DEFINITION | EXTENDEDBY)}
    seeds = set()
    for path, item in rows:
        usr, roles = item['usr'], item['roles']
        if path in files and roles & (REFERENCE | CALL | DECLARATION | DEFINITION):
            seeds.add(usr)
        for relation in item.get('relations', []):
            parent = relation['usr']
            if (roles & (REFERENCE | CALL) and relation['roles'] & (CALLEDBY | CONTAINEDBY)
                    or roles & (DECLARATION | DEFINITION) and relation['roles'] & CHILDOF
                    and kinds.get(parent) in CALLABLE_KINDS):
                edges.setdefault(parent, set()).add(usr)
    references, visited, frontier = set(files), set(), seeds
    edge_count = 0
    while frontier:
        frontier -= visited
        if not frontier:
            break
        for usr in frontier:
            references.update(locations.get(usr, ()))
        visited.update(frontier)
        edge_count += sum(len(edges.get(usr, ())) for usr in frontier)
        frontier = {callee for usr in frontier for callee in edges.get(usr, ())}
    if walk_stats is not None:
        walk_stats.update(complete=True, nodes=len(visited), edges=edge_count,
                          seconds=round(time.monotonic() - started, 6))
    return references


def validate_index_sources(root, export, require_hashes=True):
    """A saved export may be reused only with its original indexed source bytes."""
    if (not isinstance(export, dict) or export.get('schema_version') != 1
            or not isinstance(export.get('occurrences'), list)):
        raise ValueError('invalid index export')
    hashes = export.get('source_hashes', {})
    if not isinstance(hashes, dict) or (require_hashes and not hashes):
        raise ValueError('index export needs source hashes')
    root = Path(root)
    for path, digest in hashes.items():
        if (not isinstance(path, str) or repository_path(path, root) != path
                or not (root / path).is_file()
                or hashlib.sha256((root / path).read_bytes()).hexdigest() != digest):
            raise ValueError('index export source inputs differ: ' + str(path))
    if require_hashes:
        for item in export.get('occurrences', []):
            if not isinstance(item, dict) or item.get('file') not in hashes:
                raise ValueError('index export occurrence has no source hash')


def refresh_index_map(root, data, export):
    """Replace skipped-class edges while preserving the original native evidence.

    This bounded refresh does not run skipped tests, renew coverage timestamps or
    forgive coverage errors. All original source/test/build inputs must still
    match; only the two index/generator implementation files may have changed.
    """
    root = Path(root)
    if data.get('schema_version') != SCHEMA_VERSION or data.get('complete') is not True:
        raise ValueError('index refresh requires a complete coverage map')
    inputs = data.get('input_hashes', {})
    if not inputs:
        raise ValueError('index refresh requires original input hashes')
    allowed = {'script/test_impact_map.py', 'script/index_store.py'}
    current = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
               for folder in ('Sources', 'Tests', 'Packages') for path in (root / folder).rglob('*')
               if path.is_file() and (path.suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp')
                                      or path.name in ('Package.swift', 'Package.resolved'))}
    for path in ('Package.swift', 'Package.resolved'):
        if (root / path).is_file():
            current[path] = hashlib.sha256((root / path).read_bytes()).hexdigest()
    if current != {path: digest for path, digest in inputs.items() if path not in allowed}:
        raise ValueError('index refresh source/test/manifest inputs differ from native coverage')
    validate_index_sources(root, export, require_hashes=False)
    result = json.loads(json.dumps(data))
    for group, observation in result.get('coverage_unmeasurable_classes', {}).items():
        walk = {}
        references = index_references(root, group, export, walk)
        observation.pop('max_depth', None)
        observation.update(source='index-store', sources=sorted(references), walk=walk)
        for path in references:
            result['sources'].setdefault(path, {'classes': [], 'qualification_cases': []})
            result['source_hashes'][path] = current[path]
    result['input_hashes'] = dict(inputs)
    for path in allowed:
        if (root / path).is_file():
            result['input_hashes'][path] = hashlib.sha256((root / path).read_bytes()).hexdigest()
    result['index_store'] = {key: value for key, value in export.items()
                             if key not in ('occurrences', 'source_hashes')}
    result['index_store']['traversal'] = 'fixed-point'
    errors = coverage_gaps(result, result.get('class_inventory', []),
                           result.get('qualification_case_inventory', []))
    result['errors'] = list(data.get('errors', [])) + errors
    result['complete'] = not result['errors']
    return result


def collect_default_profiles(root, destination):
    """Preserve profiles from children that replace LLVM_PROFILE_FILE."""
    candidates = [root / 'default.profraw']
    for tree in ('Sources', 'Tests', 'Packages'):
        candidates.extend((root / tree).rglob('default.profraw'))
    moved = []
    for source in candidates:
        if not source.is_file():
            continue
        target = destination / source.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            target = target.with_name(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f') + '-' + target.name)
        source.replace(target)
        moved.append(str(target))
    return moved


def _run(command, root, log, env=None):
    with log.open('w') as output, log.with_suffix(log.suffix + '.stderr').open('w') as errors:
        result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=errors)
    if result.returncode:
        raise RuntimeError(f'command exited {result.returncode}; see {log}')
    return log.read_text()


def completed_tests(text):
    """Native XCTest terminal records, independent of assertion verdict."""
    finished = set()
    for target, method in re.findall(r"Test Case '-\[([\w.]+) (\w+)\]' (?:passed|failed|skipped)\b", text):
        finished.add(target + '/' + method)
    finished.update(re.findall(r"Test Case '([\w.]+/\w+)' (?:passed|failed|skipped)\b", text))
    return finished


def coverage_objects(scratch):
    """Find actual instrumented executable products, including child probes."""
    products = []
    for path in sorted((scratch / 'debug').iterdir()):
        if not path.is_file() or not os.access(path, os.X_OK):
            continue
        kind = subprocess.check_output(['file', '-b', str(path)], text=True)
        if 'Mach-O' not in kind or 'executable' not in kind:
            continue
        sections = subprocess.check_output(['otool', '-l', str(path)], text=True)
        if '__llvm_covmap' in sections:
            products.append(path)
    return products


def _load():
    return {'at': datetime.now(timezone.utc).isoformat(), 'averages': list(os.getloadavg())}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--scratch-path', type=Path, required=True)
    parser.add_argument('--index-scratch-path', type=Path,
                        help='dedicated index build scratch (default: sibling <scratch>-idx)')
    index_input = parser.add_mutually_exclusive_group()
    index_input.add_argument('--index-store-path', type=Path, help='read an already built index store')
    index_input.add_argument('--index-export', type=Path, help='read a saved semantic index export')
    parser.add_argument('--additional-index-store', type=Path, action='append', default=[],
                        help='additional same-build store, such as SwiftPM Clang records')
    parser.add_argument('--refresh-index-map', type=Path,
                        help='replace skipped-class edges in this complete map, retaining native observations')
    parser.add_argument('--runner-wrapper', type=Path, default=os.environ.get('CHECKLIST_SWIFT_RUNNER'),
                        help='shared build-cap shell wrapper; every swift test runs through it')
    parser.add_argument('--output', type=Path, default=Path('.local/build/test-impact-map.json'))
    parser.add_argument('--test-timeout', type=float, default=1800, help='maximum seconds for one test process')
    parser.add_argument('--resume', type=Path, help='resume a generation log directory at the same source/test hashes')
    parser.add_argument('--reexport', action='store_true', help='with --resume, re-export existing profiles without rerunning completed tests; permit only generator/index-reader hash changes')
    parser.add_argument('--classes', nargs='+', help='bounded diagnostic subset; result stays incomplete')
    parser.add_argument('--qualification-cases', nargs='+', help='bounded diagnostic subset')
    args = parser.parse_args(argv)
    if args.additional_index_store and not args.index_store_path:
        parser.error('--additional-index-store requires --index-store-path')
    if args.reexport and not args.resume:
        parser.error('--reexport requires --resume')
    load_start = _load()
    root, scratch = args.root.resolve(), args.scratch_path.resolve()
    output = args.output if args.output.is_absolute() else root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    if args.refresh_index_map:
        if not (args.index_store_path or args.index_export):
            parser.error('--refresh-index-map requires --index-store-path or --index-export')
        if args.resume or args.classes or args.qualification_cases:
            parser.error('--refresh-index-map cannot resume or select native executions')
        original_bytes = args.refresh_index_map.read_bytes()
        exported = (json.loads(args.index_export.read_text()) if args.index_export else
                    read_index_store(args.index_store_path, root, additional_stores=args.additional_index_store))
        validate_index_sources(root, exported)
        result = refresh_index_map(root, json.loads(original_bytes), exported)
        result['index_refresh'] = {'at': datetime.now(timezone.utc).isoformat(),
            'seconds': round(time.monotonic() - started, 3),
            'input_map': str(args.refresh_index_map.resolve()),
            'input_map_sha256': hashlib.sha256(original_bytes).hexdigest(),
            'coverage_generated_at': result['generated_at'], 'native_executions_reused': True}
        temporary = output.with_suffix('.tmp')
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.replace(output)
        print(json.dumps({'output': str(output), 'complete': result['complete'],
                          'index_refresh': result['index_refresh'], 'errors': result['errors']}, indent=2))
        return 0 if result['complete'] else 1
    work = args.resume or output.parent / ('test-impact-profiles-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f'))
    work = work.resolve()
    work.mkdir(exist_ok=bool(args.resume))
    # Import only the case inventory, never the obsolete source declarations.
    sys.path.insert(0, str(root / 'script'))
    from affected_tests import QUALIFICATION_CASES
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    observations, inventory, errors = [], set(), []
    test_failures, test_skips = [], []
    profile_caveats = []
    inspection_edges = {}
    input_hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for folder in ('Sources', 'Tests', 'Packages') for path in sorted((root / folder).rglob('*'))
                    if path.is_file() and (path.suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp')
                                           or path.name in ('Package.swift', 'Package.resolved'))}
    for relative in ('Package.swift', 'Package.resolved', 'script/test_impact_map.py', 'script/index_store.py'):
        path = root / relative
        if path.is_file():
            input_hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = work / 'inputs.json'
    previous_hashes = json.loads(manifest.read_text()) if manifest.is_file() else None
    compared_previous = dict(previous_hashes or {})
    compared_current = dict(input_hashes)
    if args.reexport:
        for relative in ('script/test_impact_map.py', 'script/index_store.py'):
            compared_previous.pop(relative, None)
            compared_current.pop(relative, None)
    if args.resume and (previous_hashes is None or compared_previous != compared_current):
        parser.error('resume source/test/manifest inputs differ; start a new generation')
    # Preserve the original fingerprint; a re-export records its own fingerprint
    # in the output, while subsequent resumes still validate the original inputs.
    if not args.resume:
        manifest.write_text(json.dumps(input_hashes, sort_keys=True) + '\n')
    origin_path = work / 'generation-origin.json'
    if origin_path.is_file():
        origin = json.loads(origin_path.read_text())
    else:
        origin = {'started_at': datetime.fromtimestamp(work.stat().st_birthtime, timezone.utc).isoformat(),
                  'load_start': None if args.resume else load_start}
        origin_path.write_text(json.dumps(origin) + '\n')
    profile_caveats.extend('Preserved unattributed profile: ' + path for path in
                           collect_default_profiles(root, work / 'unattributed-profiles'))
    coverage_build_started = False
    prefix = ['bash', str(args.runner_wrapper.resolve())] if args.runner_wrapper else []
    common = prefix + ['env', 'LLVM_PROFILE_FILE=' + str(work / 'build-%m-%p.profraw'), 'swift', 'test',
              '--cache-path', str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
              '--enable-dependency-cache', '--scratch-path', str(scratch)]
    try:
        if args.index_export:
            exported_index = json.loads(args.index_export.read_text())
        elif args.index_store_path:
            exported_index = read_index_store(args.index_store_path, root, additional_stores=args.additional_index_store)
        else:
            index_scratch = (args.index_scratch_path or scratch.with_name(scratch.name + '-idx')).resolve()
            if index_scratch == scratch:
                raise ValueError('index scratch must be separate from the warm coverage scratch')
            index_path = index_scratch / 'index-store'
            # The Xcode SwiftPM backend can ignore -Xswiftc index flags. The
            # native backend honors the explicit path; never change warm scratch.
            _run(prefix + ['swift', 'build', '--build-tests', '--build-system', 'native',
                '--enable-index-store', '--cache-path', str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                '--enable-dependency-cache', '--scratch-path', str(index_scratch),
                '-Xswiftc', '-index-store-path', '-Xswiftc', str(index_path)],
                root, work / 'index-build.log')
            exported_index = read_index_store(index_path, root,
                additional_stores=[index_scratch / 'debug/index/store'])
        validate_index_sources(root, exported_index)
        (work / 'index-export.json').write_text(json.dumps(exported_index, separators=(',', ':')) + '\n')
        # Swift 6 forwards --list-tests into the list subcommand, which rejects
        # --enable-code-coverage. Build instrumented tests with an empty filter
        # first; discovery reuses that build and never runs test methods.
        coverage_build_started = True
        _run(common + ['--enable-code-coverage', '--skip', 'HumanClaimsKeychainTests',
                       '--filter', '^$'], root, work / 'build.log')
        # Listing does not execute methods; Swift's list subcommand rejects --skip.
        # Exclude the forbidden class from safe/discovered execution IDs below.
        discovery = _run(common + ['--skip-build', '--list-tests'],
                         root, work / 'discovery.log')
        discovered = sorted(set(re.findall(r'^([A-Za-z_]\w*\.[A-Za-z_]\w*/[A-Za-z_]\w*)\s*$', discovery, re.M)))
        if not discovered:
            raise RuntimeError('no XCTest cases discovered')
        safe = [case for case in discovered if '.HumanClaimsKeychainTests/' not in case]
        all_classes = sorted({case.split('/')[0] for case in discovered})
        classes = sorted({case.split('/')[0] for case in safe})
        for group in sorted(set(all_classes) - set(classes)):
            observations.append({'class': group, 'sources': [], 'skipped': True,
                'unmeasurable_reason': 'Owner no-keychain rule: HumanClaimsKeychainTests must never execute'})
        requested_classes = args.classes or classes
        requested_cases = (args.qualification_cases if args.qualification_cases is not None else
                           [] if args.classes else list(QUALIFICATION_CASES))
        unknown = set(requested_classes) - set(classes) | (set(requested_cases) - set(safe))
        if unknown:
            raise RuntimeError('unknown or excluded tests: ' + ', '.join(sorted(unknown)))
        child_objects = coverage_objects(scratch)
        jobs = [('class', group, [case for case in safe if case.startswith(group + '/')
                                  and case not in QUALIFICATION_CASES]) for group in requested_classes]
        jobs += [('qualification_case', case, [case]) for case in requested_cases]
        for number, (kind, identifier, selected) in enumerate(jobs):
            if not selected:
                # A qualification-only class has no ordinary execution to measure.
                observations.append({'class': identifier, 'sources': []})
                continue
            directory = work / str(number)
            directory.mkdir(exist_ok=bool(args.resume))
            checkpoint = directory / 'observation.json'
            if args.resume and not args.reexport and checkpoint.is_file():
                saved = json.loads(checkpoint.read_text())
                if saved.get(kind) == identifier:
                    cached_log = directory / 'test.log'
                    text = cached_log.read_text() if cached_log.is_file() else ''
                    if completed_tests(text) != set(selected) or not re.search(
                            r"Test Suite 'Selected tests' (?:passed|failed) at", text):
                        errors.append(identifier + ': cached native execution is incomplete; use --reexport to inspect')
                        continue
                    if any(failure.get('exit_code', 0) < 0 for failure in saved.get('test_failures', [])):
                        errors.append(identifier + ': cached test process terminated by signal')
                        continue
                    inventory.update(saved.pop('inventory', []))
                    test_failures.extend(saved.pop('test_failures', []))
                    test_skips.extend(saved.pop('test_skips', []))
                    references = saved.pop('inspection_references', [])
                    if references:
                        inspection_edges[identifier] = references
                    observations.append(saved)
                    continue
            env = dict(os.environ, LLVM_PROFILE_FILE=str(directory / '%m-%p.profraw'),
                       CHECKLIST_QUALIFICATION='1' if kind == 'qualification_case' else '0',
                       CHECKLIST_TEST_TEMPLATE_ROOT=str(scratch / 'test-store-templates'),
                       CHECKLIST_STORAGE_PROBE=str(scratch / 'out/Products/Debug/StorageCrashProbe'))
            target = identifier.split('.')[0]
            bundle = scratch / 'debug' / (target + '.xctest')
            binary = bundle / 'Contents/MacOS' / target
            print(f'[{number + 1}/{len(jobs)}] {identifier}', flush=True)
            try:
                test_log = directory / 'test.log'
                reuse_execution = bool(args.reexport and test_log.is_file())
                prior_failures = []
                if reuse_execution:
                    if checkpoint.is_file():
                        prior_failures = json.loads(checkpoint.read_text()).get('test_failures', [])
                    test_output = test_log.read_text()
                    test_failures.extend(prior_failures)
                else:
                    with test_log.open('w') as log:
                        execution = subprocess.run(['xcrun', 'xctest', '-XCTest', ','.join(selected), str(bundle)],
                                                   cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=args.test_timeout)
                    test_output = test_log.read_text()
                    profile_caveats.extend(identifier + ': captured child fallback profile: ' + path
                        for path in collect_default_profiles(root, directory / 'fallback-profiles'))
                    if execution.returncode:
                        test_failures.append({'test': identifier, 'exit_code': execution.returncode,
                                              'log': str(test_log)})
                    if execution.returncode < 0:
                        raise RuntimeError(f'test process terminated by signal {-execution.returncode}')
                if any(failure.get('exit_code', 0) < 0 for failure in prior_failures) or re.search(
                        r'(?:Program crashed:|Abort trap:|Segmentation fault:|terminated by signal)', test_output):
                    raise RuntimeError('native test log records a crash or abort')
                finished = completed_tests(test_output)
                if finished != set(selected):
                    raise RuntimeError('incomplete native execution: missing=' + repr(sorted(set(selected) - finished)) +
                                       ', unexpected=' + repr(sorted(finished - set(selected))))
                if not re.search(r"Test Suite 'Selected tests' (?:passed|failed) at", test_output):
                    raise RuntimeError('native test process did not finish its selected suite')
                # Existing assertion failures are recoverable from terminal logs
                # even when an earlier interrupted run never wrote a checkpoint.
                if reuse_execution and not prior_failures and re.search(r"Test Case .* failed ", test_output):
                    test_failures.append({'test': identifier, 'exit_code': 1, 'log': str(test_log),
                                          'recovered_from_native_log': True})
                test_skips.extend(line for line in test_output.splitlines() if ' skipped ' in line or ' skipped:' in line)
                profiles = sorted(directory.rglob('*.profraw'))
                if not profiles:
                    raise RuntimeError('instrumented test produced no raw profile')
                merged = directory / 'coverage.profdata'
                _run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles), '-o', str(merged)],
                     root, directory / 'merge.log')
                objects = [arg for product in child_objects for arg in ('-object', str(product))]
                exported = _run(['xcrun', 'llvm-cov', 'export', str(binary), *objects, '-summary-only',
                                 '-skip-functions', '-skip-expansions', '-instr-profile=' + str(merged)],
                                root, directory / 'coverage.json')
                diagnostics = (directory / 'coverage.json.stderr').read_text()
                if re.search(r'mismatched|profile data may be out of date|hash mismatch', diagnostics, re.I):
                    raise RuntimeError('llvm-cov reports incompatible profile counters; see coverage.json.stderr')
                payload = json.loads(exported)
                if not payload.get('data'):
                    raise RuntimeError('llvm-cov export contains no coverage data')
                for datum in payload.get('data', []):
                    inventory.update(path for entry in datum.get('files', [])
                                     if (path := _source_path(entry['filename'], root)))
                executed_sources = parse_coverage_export(payload, root)
                references = inspection_references(root, identifier, executed_sources) if kind == 'class' else set()
                if references:
                    inspection_edges[identifier] = sorted(references)
                skipped_count = len(re.findall(r"Test Case .* skipped ", test_output))
                all_skipped = skipped_count >= len(selected)
                observation = {kind: identifier, 'sources': [] if all_skipped else
                               sorted(executed_sources | references)}
                if all_skipped:
                    observation['skipped'] = True
                    reasons = [line.strip() for line in test_output.splitlines() if 'skipped:' in line or 'Test skipped' in line]
                    observation['unmeasurable_reason'] = '; '.join(dict.fromkeys(reasons)) or 'All native methods skipped; see ' + str(test_log)
                observations.append(observation)
                checkpoint.write_text(json.dumps(dict(observation, inventory=sorted(inventory),
                    test_failures=[failure for failure in test_failures if failure['test'] == identifier],
                    test_skips=[line for line in test_output.splitlines() if ' skipped ' in line or ' skipped:' in line],
                    inspection_references=sorted(references))) + '\n')
            except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                profile_caveats.extend(identifier + ': preserved child profile after incomplete execution: ' + path
                    for path in collect_default_profiles(root, directory / 'fallback-profiles'))
                errors.append(f'{identifier}: {error}')
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        errors.append(str(error))
    # Coverage is a final-round refresh cost. Leave the assigned warm scratch
    # ready for ordinary uninstrumented affected tests and production builds.
    try:
        if coverage_build_started:
            _run(common + ['--skip', 'HumanClaimsKeychainTests', '--filter', '^$'],
                 root, work / 'restore-default-build.log')
    except (RuntimeError, OSError, ValueError) as error:
        errors.append('restore default build: ' + str(error))
    profile_caveats.extend('Preserved build/discovery profile: ' + path for path in
                           collect_default_profiles(root, work / 'phase-fallback-profiles'))
    result = build_map(root, observations, commit, datetime.now(timezone.utc).isoformat(),
                       round(time.monotonic() - started, 3), inventory,
                       index_export=exported_index if 'exported_index' in locals() else None)
    result['index_store'] = {key: value for key, value in locals().get('exported_index', {}).items()
                             if key not in ('occurrences', 'source_hashes')}
    result['index_store']['traversal'] = 'fixed-point'
    result['invocation_seconds'] = result['generation_seconds']
    result['generation_seconds'] = round((datetime.now(timezone.utc) -
        datetime.fromisoformat(origin['started_at'])).total_seconds(), 3)
    if not args.classes and args.qualification_cases is None:
        errors.extend(coverage_gaps(result, all_classes if 'all_classes' in locals() else [], QUALIFICATION_CASES))
    result['complete'] = not errors and not args.classes and args.qualification_cases is None
    result['errors'] = errors
    result['coverage_errors'] = errors
    result['test_failures'] = test_failures
    result['test_skips'] = test_skips
    result['profile_caveats'] = profile_caveats
    result['inspection_references'] = inspection_edges
    result['input_hashes'] = input_hashes
    result['class_inventory'] = all_classes if 'all_classes' in locals() else []
    result['qualification_case_inventory'] = list(QUALIFICATION_CASES)
    result['generation_logs'] = str(work)
    result['load_start'] = load_start
    result['load_end'] = _load()
    result['generation_origin'] = origin
    result['resume'] = {'from': str(args.resume.resolve()) if args.resume else None,
                        'reexport': args.reexport, 'started_at': load_start['at'],
                        'seconds': result['invocation_seconds']}
    result['coverage_objects'] = list(map(str, child_objects)) if 'child_objects' in locals() else []
    temporary = output.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, indent=2) + '\n')
    temporary.replace(output)
    print(json.dumps({'output': str(output), 'complete': result['complete'],
                      'generation_seconds': result['generation_seconds'], 'errors': errors}, indent=2))
    return 1 if errors or test_failures else 0


if __name__ == '__main__':
    sys.exit(main())
