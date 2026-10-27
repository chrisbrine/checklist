#!/usr/bin/env python3
"""Generate an execution-derived source/test impact map (local, never committed).

One instrumented build is followed by a separate xctest process per class and
qualification case. Each process owns its raw profiles, including child processes.
A failed/incomplete refresh is retained as incomplete, never a closed-world map.
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


def build_map(root, observations, commit, generated_at, generation_seconds, inventory=None):
    """Union observations; inventory includes instrumented files with zero hits.

    Each observation has sources and either class or qualification_case. The
    caller sets complete only after every discovered class and case has coverage;
    assertion failures are reported separately from missing coverage.
    """
    root = Path(root)
    paths = set(inventory or ())
    for observation in observations:
        paths.update(observation['sources'])
    sources = {path: {'classes': set(), 'qualification_cases': set()} for path in sorted(paths)}
    classes, cases = set(), set()
    unmeasurable = {}
    for observation in observations:
        group, case = observation.get('class'), observation.get('qualification_case')
        if group and observation.get('skipped'):
            unmeasurable[group] = {
                'reason': observation.get('unmeasurable_reason', 'All native methods skipped; see generation logs'),
                'sources': sorted(static_references(root, group))}
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
    return (['Unmeasured class: ' + value for value in sorted(missing_classes)] +
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


def _swift_code(text):
    """Remove comments and string contents before deriving symbol references."""
    return re.sub(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def static_references(root, identifier):
    """Unmeasurable classes use declared type/function names in their own files.

    Include extension files; never expand these edges to the module closure.
    This is a lexical dependency approximation, separate from measured coverage.
    """
    target, owner = identifier.split('/')[0].split('.', 1)
    test_codes = []
    for test in sorted((root / 'Tests' / target).rglob('*.swift')):
        code = _swift_code(test.read_text())
        if re.search(r'\b(?:class|extension|struct)\s+' + re.escape(owner) + r'\b', code):
            test_codes.append(code)
    code = '\n'.join(test_codes)
    names = set(re.findall(r'\b[A-Za-z_]\w*\b', code))
    calls = set(re.findall(r'\b([A-Za-z_]\w*)\s*(?:<[^\n<>]*>)?\s*\(', code))
    references = inspection_references(root, identifier)
    sources = [path for folder in ('Sources', 'Tests', 'Packages')
               for path in (root / folder).rglob('*') if path.is_file()
               and _source_path(str(path), root)]
    for source in sorted(sources):
        declared = _swift_code(source.read_text())
        # A member named `record` is not the unrelated router.record call.
        # Top-level functions stand alone; members need their owning type.
        types, functions = set(), set()
        depth = 0
        for token in re.finditer(r'[{}]|\b(class|struct|enum|protocol|typealias|actor|extension|func)\s+([A-Za-z_]\w*)', declared):
            if token[0] == '{':
                depth += 1
            elif token[0] == '}':
                depth -= 1
            elif depth == 0:
                if token[1] != 'extension':
                    (functions if token[1] == 'func' else types).add(token[2])
        if source.suffix != '.swift':
            depth = 0
            # C/Objective-C fixture functions also have direct Swift callers.
            for token in re.finditer(r'[{}]|\b([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?=[{;])', declared):
                if token[0] == '{':
                    depth += 1
                elif token[0] == '}':
                    depth -= 1
                elif depth == 0:
                    functions.add(token[1])
        extension_owners = set(re.findall(r'\bextension\s+([A-Za-z_]\w*)', declared))
        members = set(re.findall(r'\bfunc\s+([A-Za-z_]\w*)', declared))
        if types & names or functions & calls or (extension_owners & names and members & calls):
            references.add(source.relative_to(root).as_posix())
    return references


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
    parser.add_argument('--runner-wrapper', type=Path, default=os.environ.get('CHECKLIST_SWIFT_RUNNER'),
                        help='shared build-cap shell wrapper; every swift test runs through it')
    parser.add_argument('--output', type=Path, default=Path('.local/build/test-impact-map.json'))
    parser.add_argument('--test-timeout', type=float, default=1800, help='maximum seconds for one test process')
    parser.add_argument('--resume', type=Path, help='resume a generation log directory at the same source/test hashes')
    parser.add_argument('--reexport', action='store_true', help='with --resume, re-export existing profiles without rerunning completed tests; permit only generator hash changes')
    parser.add_argument('--classes', nargs='+', help='bounded diagnostic subset; result stays incomplete')
    parser.add_argument('--qualification-cases', nargs='+', help='bounded diagnostic subset')
    args = parser.parse_args(argv)
    if args.reexport and not args.resume:
        parser.error('--reexport requires --resume')
    load_start = _load()
    root, scratch = args.root.resolve(), args.scratch_path.resolve()
    output = args.output if args.output.is_absolute() else root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
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
    for relative in ('Package.swift', 'Package.resolved', 'script/test_impact_map.py'):
        path = root / relative
        if path.is_file():
            input_hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = work / 'inputs.json'
    previous_hashes = json.loads(manifest.read_text()) if manifest.is_file() else None
    compared_previous = dict(previous_hashes or {})
    compared_current = dict(input_hashes)
    if args.reexport:
        compared_previous.pop('script/test_impact_map.py', None)
        compared_current.pop('script/test_impact_map.py', None)
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
    try:
        prefix = ['bash', str(args.runner_wrapper.resolve())] if args.runner_wrapper else []
        common = prefix + ['env', 'LLVM_PROFILE_FILE=' + str(work / 'build-%m-%p.profraw'), 'swift', 'test',
                  '--cache-path', str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                  '--enable-dependency-cache', '--scratch-path', str(scratch)]
        # Swift 6 forwards --list-tests into the list subcommand, which rejects
        # --enable-code-coverage. Build instrumented tests with an empty filter
        # first; discovery reuses that build and never runs test methods.
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
        _run(common + ['--skip', 'HumanClaimsKeychainTests', '--filter', '^$'],
             root, work / 'restore-default-build.log')
    except (RuntimeError, OSError, ValueError) as error:
        errors.append('restore default build: ' + str(error))
    profile_caveats.extend('Preserved build/discovery profile: ' + path for path in
                           collect_default_profiles(root, work / 'phase-fallback-profiles'))
    result = build_map(root, observations, commit, datetime.now(timezone.utc).isoformat(),
                       round(time.monotonic() - started, 3), inventory)
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
