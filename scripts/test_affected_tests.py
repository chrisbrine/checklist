"""Affected-test planning without Swift builds or live application access."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('affected_tests', Path(__file__).resolve().parents[1] / 'script/affected_tests.py')
selector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selector)


def target(name, dependencies=(), kind='library', path=None):
    return {'name': name, 'type': kind, 'path': path or ('Tests/' if kind == 'test' else 'Sources/') + name,
            'target_dependencies': list(dependencies)}


GRAPH = {'targets': [
    target('ChecklistProviders'), target('ChecklistCore', ['ChecklistProviders']), target('ChecklistIPC'),
    target('ChecklistApp', ['ChecklistCore', 'ChecklistIPC']),
    target('ChecklistBridges', ['ChecklistCore', 'ChecklistIPC']),
    target('ChecklistMCPServer', ['ChecklistBridges']), target('ChecklistCLI', ['ChecklistMCPServer']),
    target('ChecklistService', ['ChecklistBridges']),
    target('ChecklistProducts', ['ChecklistApp', 'ChecklistService', 'ChecklistCLI']),
    target('StorageCrashProbe', ['ChecklistCore', 'StorageReleasedCoreFixture'], path='Tests/StorageCrashProbe'),
    target('StorageReleasedCoreFixture', path='Tests/StorageCrashProbe/ReleasedCore'),
] + [target(name + 'Tests', dependencies, 'test') for name, dependencies in [
    ('ChecklistApp', ['ChecklistApp', 'ChecklistCore']), ('ChecklistCore', ['ChecklistCore']),
    ('ChecklistIPC', ['ChecklistIPC', 'ChecklistCore']), ('ChecklistBridges', ['ChecklistBridges']),
    ('ChecklistMCPServer', ['ChecklistMCPServer']), ('ChecklistCLI', ['ChecklistCLI']),
    ('ChecklistProviders', ['ChecklistProviders']),
]]}


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'scripts').mkdir()
        for name in ['test_affected_tests.py', 'test_test_instances.py', 'test_prepare_public_source.py']:
            (self.root / 'scripts' / name).touch()

    def plan(self, *paths, full=False):
        return selector.select(self.root, GRAPH, paths, self.root / '.build', full)

    def test_app_only(self):
        plan = self.plan('Sources/ChecklistApp/ContentView.swift')
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests'])
        self.assertIn('ChecklistProducts', plan['affected_targets'])
        self.assertEqual(plan['commands'][-1], selector.VALIDATE)
        self.assertIn('^ChecklistAppTests\\.', plan['swift_commands'][0])
        self.assertEqual(plan['swift_commands'][0][:2], ['swift', 'test'])

    def test_core_includes_transitive_dependents(self):
        self.assertEqual(self.plan('Sources/ChecklistCore/Domain.swift')['test_targets'],
                         ['ChecklistAppTests', 'ChecklistBridgesTests', 'ChecklistCLITests',
                          'ChecklistCoreTests', 'ChecklistIPCTests', 'ChecklistMCPServerTests'])

    def test_test_target_does_not_select_its_dependencies(self):
        self.assertEqual(self.plan('Tests/ChecklistCoreTests/NewTests.swift')['test_targets'], ['ChecklistCoreTests'])

    def test_nested_custom_target_uses_longest_path(self):
        plan = self.plan('Tests/StorageCrashProbe/ReleasedCore/Fixture.swift')
        self.assertEqual(plan['affected_targets'], ['ChecklistCoreTests', 'StorageCrashProbe', 'StorageReleasedCoreFixture'])
        self.assertEqual(plan['test_targets'], ['ChecklistCoreTests'])

    def test_python_only_selects_own_test(self):
        for path, expected in [('script/test_instances.py', 'scripts/test_test_instances.py'),
                               ('script/affected_tests.py', 'scripts/test_affected_tests.py'),
                               ('scripts/test_affected_tests.py', 'scripts/test_affected_tests.py'),
                               ('scripts/prepare-public-source.py', 'scripts/test_prepare_public_source.py'),
                               ('scripts/public_source_privacy.py', 'scripts/test_prepare_public_source.py'),
                               ('script/verify_install.py', 'scripts/test_test_instances.py')]:
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual(plan['python_tests'], [expected])
                self.assertFalse(plan['swift_commands'])

    def test_validator_selects_its_own_checks_only(self):
        self.assertEqual(self.plan('scripts/validate-plan.py')['commands'], [selector.VALIDATE])

    def test_docs_planning_examples_only_validate(self):
        plan = self.plan('README.md', 'docs/guide.md', 'planning/build.yaml', 'examples/input.json',
                         'skills/checklist/references/coordinate.md')
        self.assertEqual(plan['commands'], [selector.VALIDATE])

    def test_package_build_and_unknown_paths_select_everything(self):
        expected = sorted(t['name'] for t in GRAPH['targets'] if t['type'] == 'test')
        for path in ['Package.swift', 'Package.resolved', 'script/build_and_run.sh', 'script/build_support.py',
                     'scripts/compile-component.sh', 'scripts/test_build_and_run.py', 'mystery.txt',
                     'Sources/NewTarget/File.swift', 'scripts/unowned.py', '../outside.swift']:
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual(plan['test_targets'], expected)
                self.assertEqual(len(plan['python_tests']), 3)
                self.assertEqual(plan['fallback_paths'], [path])

    def test_heavy_skip_matches_real_swift_test_identifiers(self):
        command = self.plan('Sources/ChecklistCore/Domain.swift')['swift_commands'][0]
        patterns = [command[i + 1] for i, arg in enumerate(command) if arg == '--skip']
        identifiers = [selector.HEAVY_TESTS[0], selector.HEAVY_TESTS[1] + '/testFrozen',
                       selector.HEAVY_TESTS[2] + '/testDecision']
        for identifier in identifiers:
            self.assertTrue(any(re.search(pattern, identifier) for pattern in patterns), identifier)
        self.assertFalse(any(re.search(pattern, 'ChecklistCoreTests.StorageSnapshotCapacityTests/testSmall')
                             for pattern in patterns))

    def test_storage_snapshot_and_media_sources_enable_heavy_cases(self):
        for path in ['Sources/ChecklistCore/StorageSnapshot.swift', 'Sources/ChecklistCore/StorageRecovery.swift',
                     'Sources/ChecklistCore/SnapshotReadProjection.swift', 'Sources/ChecklistCore/PolicySnapshots.swift',
                     'Sources/ChecklistCore/MediaDecisions.swift', 'Sources/ChecklistApp/Media/MediaReviewModel.swift',
                     'Sources/ChecklistCore/Store.swift', 'Sources/ChecklistCore/SchemaMigrations.swift',
                     'Sources/ChecklistCore/ManagedPaths.swift', 'Sources/ChecklistCore/FileDurability.swift']:
            with self.subTest(path=path):
                self.assertEqual(self.plan(path)['skip'], [])
        self.assertEqual(self.plan('Tests/ChecklistCoreTests/MediaDecisionTests.swift')['skip'], list(selector.HEAVY_TESTS))

    def test_full_has_no_filters_or_skips(self):
        plan = self.plan('Sources/ChecklistApp/ContentView.swift', full=True)
        self.assertEqual(plan['swift_commands'], [['env', 'CHECKLIST_STORAGE_PROBE=' + str(self.root / '.build/out/Products/Debug/StorageCrashProbe'),
                                                   'swift', 'test', '--scratch-path', str(self.root / '.build')]])
        self.assertEqual(plan['skip'], [])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(len(plan['python_tests']), 3)

    def test_mixed_paths_union_and_empty_paths(self):
        plan = self.plan('./Sources/ChecklistApp/A.swift', 'Sources/ChecklistApp/A.swift', 'script/test_instances.py')
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests'])
        self.assertEqual(plan['python_tests'], ['scripts/test_test_instances.py'])
        self.assertEqual(len(plan['paths']), 2)
        self.assertEqual(self.plan()['commands'], [selector.VALIDATE])

    def test_graph_cache_is_keyed_by_manifest_hash(self):
        manifest = self.root / 'Package.swift'
        manifest.write_text('first')
        with patch.object(selector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(GRAPH))) as run:
            for _ in range(2):
                self.assertEqual(selector.package_graph(self.root, self.root / '.build'), GRAPH)
            self.assertEqual(run.call_count, 1)
            manifest.write_text('second')
            selector.package_graph(self.root, self.root / '.build')
            self.assertEqual(run.call_count, 2)

    def test_base_diff_includes_staged_unstaged_deleted_renamed_and_untracked(self):
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.root)
        git('init', '-q')
        git('config', 'user.name', 'Synthetic Test')
        git('config', 'user.email', 'test@example.invalid')
        for name in ['staged', 'unstaged', 'deleted', 'old']:
            (self.root / name).write_text('base')
        git('add', '.')
        git('commit', '-qm', 'fixture')
        (self.root / 'staged').write_text('change')
        git('add', 'staged')
        (self.root / 'unstaged').write_text('change')
        (self.root / 'deleted').unlink()
        git('mv', 'old', 'new')
        (self.root / 'untracked').touch()
        self.assertEqual(selector.changed_paths(self.root, 'HEAD'), ['deleted', 'new', 'old', 'staged', 'unstaged', 'untracked'])

    def test_cli_json_path_list_and_stdin(self):
        import contextlib
        import io
        for args in [['--paths', 'Sources/ChecklistApp/A.swift'], ['--paths-file', '-']]:
            output = io.StringIO()
            with patch.object(selector, 'package_graph', return_value=GRAPH), \
                 patch.object(selector.sys, 'stdin', io.StringIO('Sources/ChecklistApp/A.swift\n')), \
                 contextlib.redirect_stdout(output):
                selector.main(['--root', str(self.root), '--json', *args])
            self.assertEqual(json.loads(output.getvalue())['test_targets'], ['ChecklistAppTests'])


if __name__ == '__main__':
    unittest.main()
