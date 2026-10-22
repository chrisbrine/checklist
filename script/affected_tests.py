#!/usr/bin/env python3
"""Plan affected checks; never build, test or install. See docs/test-selection.md."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys

HEAVY_TESTS = (
    'ChecklistCoreTests.StorageSnapshotCapacityTests/testMoreThanThirtyThousandObjectsAndEightMiBManifestRoundTripWithoutPruning',
    'ChecklistCoreTests.MediaFrozenIntakeTests',
    'ChecklistCoreTests.MediaDecisionTests',
)
# Prefixes match file stems as well as directories in today's flat Core layout.
HEAVY_SOURCE_PREFIXES = (
    'Sources/ChecklistCore/Storage', 'Sources/ChecklistCore/Snapshot',
    'Sources/ChecklistCore/PolicySnapshots', 'Sources/ChecklistCore/Media',
    'Sources/ChecklistApp/Media/',
    'Sources/ChecklistCore/Store.swift', 'Sources/ChecklistCore/SchemaMigrations.swift',
    'Sources/ChecklistCore/ManagedPaths.swift', 'Sources/ChecklistCore/ManagedPathConsumers.swift',
    'Sources/ChecklistCore/FileDurability.swift', 'Sources/ChecklistCore/SafeFileRead.swift',
    'Sources/ChecklistCore/GRDBRecordEnvelopeAdapter.swift', 'Sources/ChecklistCore/RecordEnvelope.swift',
    'Sources/ChecklistCore/LegacyStoredValue.swift',
)
BUILD_SCRIPTS = ('script/build_', 'script/build_and_run.sh', 'scripts/compile-component.sh',
                 'scripts/test_build_and_run.py')
PYTHON_TEST_OWNERS = {
    'scripts/validate-plan.py': [],  # Its own shape/reference checks run in VALIDATE.
    'script/verify_install.py': ['scripts/test_test_instances.py'],
    'scripts/public_source_privacy.py': ['scripts/test_prepare_public_source.py'],
}
# Core's crash tests launch this executable through CHECKLIST_STORAGE_PROBE,
# a runtime dependency that SwiftPM's target graph cannot express.
RUNTIME_TEST_CONSUMERS = {'StorageCrashProbe': ('ChecklistCoreTests',)}
VALIDATE = ['uv', 'run', '--no-project', '--with', 'jsonschema', '--with', 'pyyaml',
            'python', 'scripts/validate-plan.py']


def package_graph(root, scratch):
    """Cache only the graph (not the changed paths), keyed by manifest bytes."""
    digest = hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest()
    cache = scratch / 'affected-tests' / (digest + '.json')
    if cache.exists():
        try:
            return json.loads(cache.read_text())
        except (ValueError, OSError):
            pass
    result = subprocess.run(['swift', 'package', '--scratch-path', str(scratch),
                             'describe', '--type', 'json'], cwd=root, check=True,
                            text=True, capture_output=True)
    graph = json.loads(result.stdout)
    cache.parent.mkdir(parents=True, exist_ok=True)
    # Separate processes may plan checks in the same slot; publish atomically.
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', dir=cache.parent, delete=False) as output:
        output.write(json.dumps(graph))
        temporary = Path(output.name)
    temporary.replace(cache)
    return graph


def changed_paths(root, base):
    # Include both rename endpoints, deleted paths, staged/unstaged and untracked files.
    tracked = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', base, '--'], cwd=root)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=root)
    return sorted(set(p.decode() for p in (tracked + untracked).split(b'\0') if p))


def python_tests(root, path):
    if path in PYTHON_TEST_OWNERS:
        return PYTHON_TEST_OWNERS[path]
    name = PurePosixPath(path).name
    if path.startswith('scripts/') and name.startswith('test_'):
        return [path]
    candidate = 'scripts/test_' + PurePosixPath(path).stem.replace('-', '_') + '.py'
    return [candidate] if (root / candidate).is_file() else None


def select(root, graph, paths, scratch, full=False):
    targets = {target['name']: target for target in graph['targets']}
    all_tests = {name for name, target in targets.items() if target['type'] == 'test'}
    affected, python, unknown = set(), set(), []
    # Longest target path wins (e.g. StorageCrashProbe/ReleasedCore).
    owners = sorted(targets.values(), key=lambda target: len(target['path']), reverse=True)
    normalized = sorted(set(PurePosixPath(path.removeprefix('./')).as_posix() for path in paths))
    for path in normalized:
        parts = PurePosixPath(path).parts
        if PurePosixPath(path).is_absolute() or '..' in parts:
            unknown.append(path)
        elif path == 'Package.swift' or path == 'Package.resolved' or path.startswith(BUILD_SCRIPTS):
            unknown.append(path)
        elif path.startswith(('Sources/', 'Tests/')):
            owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
            if owner:
                affected.add(owner['name'])
            else:
                unknown.append(path)
        elif path.endswith('.py') and path.startswith(('script/', 'scripts/')):
            own_tests = python_tests(root, path)
            if own_tests is not None:
                python.update(own_tests)
            else:
                unknown.append(path)
        elif path.endswith('.md') or path.startswith(('docs/', 'planning/', 'plans/', 'examples/', 'contracts/')):
            pass
        else:
            unknown.append(path)
    # Reverse dependency closure includes executable modules and their consumers.
    while True:
        dependents = {name for name, target in targets.items()
                      if affected.intersection(target.get('target_dependencies', []))}
        for producer, consumers in RUNTIME_TEST_CONSUMERS.items():
            if producer in affected:
                dependents.update(name for name in consumers if name in targets)
        added = dependents - affected
        if not added:
            break
        affected.update(added)
    if unknown or full:
        affected.update(targets)
        python.update(str(path.relative_to(root)) for path in (root / 'scripts').glob('test_*.py'))
    tests = sorted(all_tests.intersection(affected))
    skip = list(HEAVY_TESTS) if tests and not full and not any(
        path.startswith(HEAVY_SOURCE_PREFIXES) for path in normalized) else []
    swift = []
    if tests or full:
        command = ['swift', 'test', '--scratch-path', str(scratch)]
        if not full:
            for target in tests:
                command.extend(['--filter', '^' + re.escape(target) + r'\.'])
            for case in skip:
                command.extend(['--skip', '^' + re.escape(case) + r'(?:/|$)'])
        if 'ChecklistCoreTests' in tests:
            command = ['env', 'CHECKLIST_STORAGE_PROBE=' + str(scratch / 'out/Products/Debug/StorageCrashProbe')] + command
        swift.append(command)
    # uv supplies the dependencies needed by the exporter/validator tests too.
    python_commands = [['uv', 'run', '--no-project', '--with', 'jsonschema', '--with', 'pyyaml',
                        'python', path] for path in sorted(python)]
    return {'paths': normalized, 'affected_targets': sorted(affected), 'test_targets': tests,
            'python_tests': sorted(python), 'fallback_paths': unknown, 'skip': skip, 'full': full,
            'swift_commands': swift, 'commands': swift + python_commands + [VALIDATE]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--base', help='diff commit against the working tree, including untracked files')
    source.add_argument('--paths', nargs='+', help='repository-relative changed paths')
    source.add_argument('--paths-file', type=Path, help='newline-delimited paths, or - for stdin')
    parser.add_argument('--full', action='store_true', help='full Swift suite without filters/skips and all Python tests')
    parser.add_argument('--json', action='store_true', help='emit the plan as JSON argv arrays')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--scratch-path', type=Path, default=Path('.build'))
    args = parser.parse_args(argv)
    if not any((args.base, args.paths, args.paths_file, args.full)):
        parser.error('supply --base, --paths, --paths-file or --full')
    root = args.root.resolve()
    scratch = args.scratch_path.resolve()
    try:
        paths = args.paths or []
        if args.base:
            paths = changed_paths(root, args.base)
        elif args.paths_file:
            contents = sys.stdin.read() if str(args.paths_file) == '-' else args.paths_file.read_text()
            paths = contents.splitlines()
        plan = select(root, package_graph(root, scratch), paths, scratch, args.full)
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print('Test targets: ' + (', '.join(plan['test_targets']) or '(none)'))
            if plan['fallback_paths']:
                print('Full selection for: ' + ', '.join(plan['fallback_paths']))
            if plan['skip']:
                print('Heavy cases skipped: ' + ', '.join(plan['skip']))
            for command in plan['commands']:
                print(shlex.join(command))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'affected_tests: {error}\n')


if __name__ == '__main__':
    main()
