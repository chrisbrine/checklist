"""Affected-test planning without Swift builds or live application access."""
import ast
from contextlib import redirect_stdout
import io
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
    target('ChecklistCLIInputProbe', ['ChecklistIPC'], kind='executable', path='Tests/ChecklistCLIInputProbe'),
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
        core = self.root / 'Sources/ChecklistCore'; core.mkdir(parents=True)
        (core / 'NativeOutcomeRecorder.swift').write_text('NativeOutcomeRecorder')
        service = self.root / 'Sources/ChecklistService'; service.mkdir(parents=True)
        (service / 'main.swift').write_text('NativeOutcomeRecorder')
        for name in ['test_affected_tests.py', 'test_test_instances.py', 'test_prepare_public_source.py']:
            (self.root / 'scripts' / name).touch()

    def plan(self, *paths, full=False, qualification=False, last_round=False):
        return selector.select(self.root, GRAPH, paths, self.root / '.build', full, qualification, last_round)

    def test_app_only(self):
        plan = self.plan('Sources/ChecklistApp/ContentView.swift')
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests', 'ChecklistProvidersTests'])
        self.assertIn('ChecklistProducts', plan['affected_targets'])
        self.assertEqual(plan['commands'][-1], selector.VALIDATE)
        self.assertIn('^ChecklistAppTests\\.', plan['swift_commands'][0])
        self.assertIn('--parallel', plan['swift_commands'][0])
        command = plan['swift_commands'][0]
        self.assertEqual(command[command.index('--num-workers') + 1], '10')
        self.assertIn('--enable-dependency-cache', plan['swift_commands'][0])

    def test_core_includes_transitive_dependents(self):
        self.assertEqual(self.plan('Sources/ChecklistCore/Domain.swift')['test_targets'],
                         ['ChecklistAppTests', 'ChecklistBridgesTests', 'ChecklistCLITests',
                          'ChecklistCoreTests', 'ChecklistIPCTests', 'ChecklistMCPServerTests', 'ChecklistProvidersTests'])

    def test_test_target_does_not_select_its_dependencies(self):
        self.assertEqual(self.plan('Tests/ChecklistBridgesTests/NewTests.swift')['test_targets'], ['ChecklistBridgesTests'])

    def test_source_inspection_consumers_are_selected(self):
        for path in ['Sources/ChecklistService/main.swift', 'Sources/ChecklistCLI/main.swift',
                     'Sources/ChecklistBridges/Bridge.swift', 'Tests/ChecklistCoreTests/NewTests.swift']:
            with self.subTest(path=path):
                self.assertIn('ChecklistAppTests', self.plan(path)['test_targets'])

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

    def test_round_and_full_use_the_same_pinned_python(self):
        prefix = ['uv', 'run', '--no-project', '--python', '3.12',
                  '--with', 'jsonschema', '--with', 'pyyaml', 'python']
        for full in [False, True]:
            with self.subTest(full=full):
                plan = self.plan('scripts/test_test_instances.py', full=full)
                commands = [command for command in plan['commands'] if command not in plan['swift_commands']]
                self.assertEqual(len(commands), len(plan['python_tests']) + 1)
                for command in commands:
                    self.assertEqual(command[:-1], prefix)
                self.assertIn(prefix + ['scripts/test_test_instances.py'], commands)
                self.assertEqual(commands[-1], prefix + ['scripts/validate-plan.py'])

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
        command = self.plan('Sources/ChecklistApp/ContentView.swift')['swift_commands'][0]
        patterns = [command[i + 1] for i, arg in enumerate(command) if arg == '--skip']
        identifiers = list(selector.QUALIFICATION_CASES)
        for identifier in identifiers:
            self.assertTrue(any(re.search(pattern, identifier) for pattern in patterns), identifier)
        self.assertFalse(any(re.search(pattern, 'ChecklistCoreTests.StorageSnapshotCapacityTests/testSmall')
                             for pattern in patterns))

    def test_qualification_table_selects_only_declared_inputs_with_reasons(self):
        case = 'ChecklistCoreTests.MediaDecisionTests/test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal'
        path = 'Sources/ChecklistCore/MediaDecisions.swift'
        plan = self.plan(path)
        self.assertIn(case, plan['qualification_tests'])
        self.assertEqual(plan['qualification_reasons'][case], [path])
        self.assertNotIn(selector.REAL_SIZE_TESTS[0], plan['qualification_tests'])
        self.assertEqual(plan['qualification_mode'], 'affected')
        self.assertLess(len(plan['qualification_tests']), len(selector.QUALIFICATION_CASES))
        self.assertEqual(self.plan('Sources/ChecklistCore/NewHelper.swift')['qualification_tests'], [])
        self.assertEqual(self.plan('Sources/ChecklistApp/Views/NewView.swift')['qualification_tests'], [])

    def test_ordinary_note_parser_selects_all_six_writer_qualification_cases(self):
        path = 'Sources/ChecklistCore/OrdinaryMentionTokens.swift'
        plan = self.plan(path)
        expected = [
            'ChecklistCoreTests.TicketLifecycleCleanupTests/testPreparationProgressUnderConstantUnrelatedWritesAndBoundsMemory',
            'ChecklistCoreTests.TicketLifecycleCleanupTests/testSustainedWritersBoundRSSCPUAndBackoff',
            'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeAutomaticFirstPassKeepsConcurrentReadAndWriteUnderTwoSeconds',
            'ChecklistCoreTests.EvidenceAuthorityTests/testLargeSubmitBlocksOtherCommandsOnlyBriefly',
            'ChecklistCoreTests.EvidenceAuthorityTests/testLargeReferenceImportBlocksOtherCommandsOnlyBriefly',
            'ChecklistCoreTests.EvidenceAuthorityTests/testReviewClaimValidatesTheCapturedTargetBeforeTheWriter',
        ]
        self.assertEqual(plan['qualification_tests'], expected)
        self.assertEqual(plan['group_fallback_paths'], [path])
        self.assertEqual(plan['test_groups'], {})
        self.assertEqual(len(plan['test_targets']), 7)
        for case in expected:
            self.assertEqual(plan['qualification_reasons'][case], [path])

    def test_shared_qualification_inputs_select_their_declared_cases(self):
        plan = self.plan('Sources/ChecklistCore/Store.swift')
        self.assertIn('ChecklistCoreTests', plan['test_targets'])
        self.assertNotIn(selector.REAL_SIZE_TESTS[0], plan['qualification_tests'])
        self.assertIn('CHECKLIST_QUALIFICATION=1', plan['qualification_commands'][0])
        self.assertEqual(self.plan('Sources/ChecklistProviders/NewHelper.swift')['qualification_tests'], [])

    def test_unknown_inputs_keep_unit_fallback_without_implicit_full_qualification(self):
        for path in ['Package.swift', 'mystery.txt', 'docs/new-fixture.bin']:
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual(plan['fallback_paths'], [path])
                self.assertEqual(plan['skip'], list(selector.QUALIFICATION_CASES))
                self.assertEqual(len(plan['test_targets']), 7)
                self.assertEqual(plan['qualification_tests'], [])

    def test_runtime_file_inputs_select_consumers(self):
        for path, consumers in selector.FILE_TEST_CONSUMERS.items():
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual(plan['test_targets'], list(consumers))
                self.assertEqual(plan['fallback_paths'], [])
                self.assertEqual(plan['commands'][-1], selector.VALIDATE)

    def test_shared_fixture_selects_swift_and_python_consumers(self):
        plan = self.plan('Tests/Fixtures/path-overlap-vectors.json')
        self.assertEqual(plan['test_targets'], ['ChecklistIPCTests'])
        self.assertEqual(plan['python_tests'], ['scripts/test_test_instances.py'])
        self.assertEqual(plan['fallback_paths'], [])
        self.assertIn(['uv', 'run', '--no-project', '--python', '3.12', '--with', 'jsonschema', '--with', 'pyyaml',
                       'python', 'scripts/test_test_instances.py'], plan['commands'])

    def test_unavailable_mapped_consumer_falls_back(self):
        (self.root / 'scripts/test_test_instances.py').unlink()
        plan = self.plan('Tests/Fixtures/path-overlap-vectors.json')
        self.assertEqual(plan['fallback_paths'], ['Tests/Fixtures/path-overlap-vectors.json'])
        self.assertNotIn('scripts/test_test_instances.py', plan['python_tests'])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(plan['skip'], list(selector.QUALIFICATION_CASES))

    def test_unavailable_swift_consumer_falls_back(self):
        with patch.dict(selector.FILE_TEST_CONSUMERS, {'docs/integrations.md': ('MissingTests',)}):
            plan = self.plan('docs/integrations.md')
        self.assertEqual(plan['fallback_paths'], ['docs/integrations.md'])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(len(plan['python_tests']), 3)
        self.assertEqual(plan['skip'], list(selector.QUALIFICATION_CASES))

    def test_python_resource_reader_precedes_validation_only(self):
        with patch.dict(selector.FILE_PYTHON_TEST_CONSUMERS,
                        {'docs/python-input.md': ('scripts/test_test_instances.py',)}):
            plan = self.plan('docs/python-input.md')
        self.assertEqual(plan['test_targets'], [])
        self.assertEqual(plan['python_tests'], ['scripts/test_test_instances.py'])
        self.assertEqual(plan['fallback_paths'], [])

    def test_mapped_readers_supplement_package_resource_consumers(self):
        graph = {'targets': [target('Assets', path='Tests/Fixtures'),
                             target('AssetsTests', ['Assets'], 'test'),
                             target('ChecklistIPC'), target('ChecklistIPCTests', ['ChecklistIPC'], 'test')]}
        graph['targets'][0]['resources'] = [{'path': 'Tests/Fixtures/path-overlap-vectors.json'}]
        plan = selector.select(self.root, graph, ['Tests/Fixtures/path-overlap-vectors.json'], self.root / '.build')
        self.assertEqual(plan['test_targets'], ['AssetsTests', 'ChecklistIPCTests'])
        self.assertEqual(plan['python_tests'], ['scripts/test_test_instances.py'])
        self.assertEqual(plan['fallback_paths'], [])

    def test_cli_input_probe_selects_mcp_runtime_consumers(self):
        plan = self.plan('Tests/ChecklistCLIInputProbe/main.swift')
        self.assertEqual(plan['test_targets'], ['ChecklistMCPServerTests'])
        self.assertIn('^ChecklistMCPServerTests\\.', plan['swift_commands'][0])

    def test_package_resources_follow_target_consumers(self):
        # SwiftPM resources live under their target path, including custom paths.
        graph = {'targets': [target('Assets', path='fixtures/assets'),
                             target('AssetsTests', ['Assets'], 'test')]}
        graph['targets'][0]['resources'] = [{'path': 'fixtures/assets/catalog.json', 'rule': 'copy'}]
        plan = selector.select(self.root, graph, ['fixtures/assets/catalog.json'], self.root / '.build')
        self.assertEqual(plan['test_targets'], ['AssetsTests'])

    def test_full_default_and_qualification_are_distinct(self):
        plan = self.plan(full=True)
        command = plan['swift_commands'][0]
        self.assertIn('--parallel', command)
        self.assertNotIn('--filter', command)
        self.assertEqual(plan['skip'], list(selector.QUALIFICATION_CASES))
        self.assertIn('CHECKLIST_QUALIFICATION=0', command)
        qualified = selector.select(self.root, GRAPH, [], self.root / '.build', full=True, qualification=True)
        self.assertEqual(qualified['skip'], [])
        self.assertEqual(qualified['isolated_test_groups'], list(selector.ISOLATED_TEST_GROUPS))
        self.assertIn('CHECKLIST_QUALIFICATION=1', qualified['qualification_commands'][0])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(len(plan['python_tests']), 3)

    def test_template_store_changes_select_only_declared_qualification_consumers(self):
        plan = self.plan('Tests/ChecklistTestSupport/TestStore.swift')
        self.assertNotIn(selector.REAL_SIZE_TESTS[0], plan['qualification_tests'])
        self.assertIn(selector.QUALIFICATION_TESTS[1], plan['qualification_tests'])
        self.assertEqual(plan['qualification_reasons'][selector.QUALIFICATION_TESTS[1]],
                         ['Tests/ChecklistTestSupport/TestStore.swift'])

    def test_changed_qualification_fixture_selects_its_case(self):
        path = self.root / 'Tests/ChecklistCoreTests/MediaDecisionTests.swift'
        path.parent.mkdir(parents=True)
        method = 'test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal'
        path.write_text('func ' + method + '() throws {\n try QualificationSuite.requireEnabled()\n}')
        plan = self.plan(path.relative_to(self.root).as_posix())
        self.assertEqual(plan['qualification_tests'], ['ChecklistCoreTests.MediaDecisionTests/' + method])
        self.assertTrue(plan['qualification_commands'])
        helper = self.plan('Tests/ChecklistTestSupport/TestStore.swift')
        self.assertEqual(helper['qualification_tests'], list(selector.QUALIFICATION_TESTS))

    def test_full_default_overrides_manifest_auto_qualification(self):
        plan = self.plan('Package.swift', full=True)
        self.assertFalse(plan['qualification'])
        self.assertEqual(plan['qualification_commands'], [])

    def test_qualification_is_a_separate_single_worker_suite(self):
        plan = self.plan('Sources/ChecklistCore/Store.swift', qualification=True)
        self.assertIn('CHECKLIST_QUALIFICATION=0', plan['swift_commands'][0])
        self.assertEqual(len(plan['qualification_commands']), 1)
        command = plan['qualification_commands'][0]
        self.assertIn('CHECKLIST_QUALIFICATION=1', command)
        self.assertEqual(command[command.index('--num-workers') + 1], '1')
        patterns = [command[i + 1] for i, arg in enumerate(command) if arg == '--filter']
        for case in selector.QUALIFICATION_CASES:
            self.assertTrue(any(re.search(pattern, case) for pattern in patterns), case)
        self.assertFalse(any(re.search(pattern, 'ChecklistCoreTests.CoreTests/testSmall') for pattern in patterns))

    def test_closed_core_helper_selects_its_groups_and_mapped_dependents(self):
        plan = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift')
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests', 'ChecklistCoreTests'])
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['NativeOutcomeRecorderTests'],
                                               'ChecklistAppTests': ['GlossaryTests']})
        self.assertFalse(plan['qualification'])
        self.assertEqual(plan['qualification_tests'], [])
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assertEqual(len(plan['default_swift_commands']), 1)
        self.assertEqual(plan['isolated_test_groups'], [])
        self.assertIn('^ChecklistCoreTests\\.(?:NativeOutcomeRecorderTests)(?:/|$)', plan['swift_commands'][0])

    def test_new_symbol_reader_invalidates_closed_group(self):
        (self.root / 'Sources/ChecklistCore/Another.swift').write_text('NativeOutcomeRecorder()')
        plan = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift')
        self.assertNotIn('ChecklistCoreTests', plan['test_groups'])
        self.assertFalse(plan['qualification'])
        self.assertEqual(plan['group_fallback_paths'], ['Sources/ChecklistCore/NativeOutcomeRecorder.swift'])

    def test_unmapped_core_input_overrides_narrow_group(self):
        plan = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift', 'Sources/ChecklistCore/Store.swift')
        self.assertNotIn('ChecklistCoreTests', plan['test_groups'])
        self.assertTrue(plan['qualification'])
        self.assertTrue(plan['isolated_test_groups'])
        docs = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift', 'README.md')
        self.assertIn('ChecklistCoreTests', docs['test_groups'])
        self.assertFalse(docs['qualification'])
        resource = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift', 'docs/integrations.md')
        self.assertNotIn('ChecklistCoreTests', resource['test_groups'])

    def test_independent_test_files_select_classes_but_shared_helpers_do_not(self):
        directory = self.root / 'Tests/ChecklistCoreTests'; directory.mkdir(parents=True)
        source = directory / 'SmallTests.swift'
        source.write_text('import XCTest\nfinal class SmallTests: XCTestCase { func testOne() {} }\n')
        path = source.relative_to(self.root).as_posix()
        self.assertEqual(self.plan(path)['test_groups']['ChecklistCoreTests'], ['SmallTests'])
        sibling = directory / 'Other.swift'
        sibling.write_text('extension SmallTests { func testTwo() {} }')
        self.assertNotIn('ChecklistCoreTests', self.plan(path)['test_groups'])
        sibling.unlink()
        source.write_text('final class SmallTests: XCTestCase { func setupFixture() {} func testOne() {} }')
        self.assertNotIn('ChecklistCoreTests', self.plan(path)['test_groups'])
        source.write_text('struct Shared {}\nfinal class SmallTests: XCTestCase { func testOne() {} }')
        self.assertNotIn('ChecklistCoreTests', self.plan(path)['test_groups'])
        source.unlink()
        self.assertNotIn('ChecklistCoreTests', self.plan(path)['test_groups'])

    def test_independent_class_groups_union(self):
        directory = self.root / 'Tests/ChecklistCoreTests'; directory.mkdir(parents=True)
        paths = []
        for name in ['FirstTests', 'SecondTests']:
            p = directory / (name + '.swift')
            p.write_text('final class ' + name + ': XCTestCase { func testOne() {} }')
            paths.append(p.relative_to(self.root).as_posix())
        self.assertEqual(self.plan(*paths)['test_groups']['ChecklistCoreTests'], ['FirstTests', 'SecondTests'])

    def test_native_git_class_is_isolated_without_omitting_it(self):
        plan = self.plan(full=True)
        self.assertEqual(len(plan['swift_commands']), 3)
        parallel, isolated, signed_child = plan['swift_commands']
        self.assertEqual(plan['timing_commands'], [])
        self.assertTrue(plan['timing_deferred'])
        timing = self.plan(full=True, qualification=True)['timing_commands'][0]
        self.assertEqual(timing[timing.index('--num-workers') + 1], '1')
        self.assertIn('^ChecklistCoreTests\\.SourceGitConfinementTests(?:/|$)', parallel)
        self.assertIn('xcrun', isolated)
        self.assertIn('xctest', isolated)
        self.assertEqual(isolated[isolated.index('-XCTest') + 1], 'ChecklistCoreTests.SourceGitConfinementTests')
        self.assertTrue(isolated[-1].endswith('/debug/ChecklistCoreTests.xctest'))
        self.assertNotIn('--parallel', isolated)
        self.assertNotIn('--num-workers', isolated)
        self.assertNotIn('--skip', isolated)
        self.assertIn('^ChecklistMCPServerTests\\.DelegateChildBindingTests(?:/|$)', parallel)
        self.assertEqual(signed_child[signed_child.index('-XCTest') + 1], 'ChecklistMCPServerTests.DelegateChildBindingTests')
        self.assertTrue(signed_child[-1].endswith('/debug/ChecklistMCPServerTests.xctest'))

    def test_signed_native_group_is_selected_without_core_target(self):
        plan = self.plan('Tests/ChecklistMCPServerTests/DelegateChildBindingTests.swift')
        self.assertEqual(plan['test_targets'], ['ChecklistMCPServerTests'])
        self.assertEqual(plan['isolated_test_groups'], ['ChecklistMCPServerTests.DelegateChildBindingTests'])
        self.assertEqual(len(plan['default_swift_commands']), 2)
        self.assertIn('^ChecklistMCPServerTests\\.DelegateChildBindingTests(?:/|$)', plan['default_swift_commands'][0])
        self.assertTrue(plan['default_swift_commands'][1][-1].endswith('/debug/ChecklistMCPServerTests.xctest'))

    def test_view_outside_declared_defaults_inputs_selects_no_qualification(self):
        plan = self.plan('Sources/ChecklistApp/ContentView.swift')
        self.assertEqual(plan['qualification_tests'], [])
        self.assertEqual(plan['qualification_commands'], [])
        self.assertEqual(plan['qualification_mode'], 'affected')
        path = 'Sources/ChecklistApp/Stores/ChecklistStore.swift'
        selected = self.plan(path)
        case = 'ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit'
        self.assertEqual(selected['qualification_tests'], [case])
        self.assertEqual(selected['qualification_reasons'], {case: [path]})

    def test_ipc_timing_qualification_follows_ipc_source(self):
        plan = self.plan('Sources/ChecklistIPC/ChecklistClient.swift')
        self.assertIn('ChecklistIPCTests.LongCommandTests/testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient', plan['qualification_tests'])
        self.assertTrue(plan['qualification_commands'])

    def test_changed_app_timing_fixture_selects_its_case(self):
        path = self.root / 'Tests/ChecklistAppTests/IsolatedDefaultsTests.swift'
        path.parent.mkdir(parents=True)
        method = 'testPreferencesRemainAbsentAfterChildProcessExit'
        path.write_text('func ' + method + '() throws {\n try QualificationSuite.requireEnabled()\n}')
        plan = self.plan(str(path.relative_to(self.root)))
        self.assertEqual(plan['qualification_tests'], ['ChecklistAppTests.IsolatedDefaultsTests/' + method])

    def test_timing_group_is_a_separate_single_worker_invocation(self):
        default = self.plan('Sources/ChecklistApp/ContentView.swift')
        expected = [case for case in selector.ISOLATED_TESTS if case.startswith('ChecklistAppTests.')]
        self.assertIn('ChecklistAppTests.ScreenTimingTests/testCachedCleanupNativeFrame', expected)
        # An ordinary affected run lists the budgets but defers them (CL-266 item 2).
        self.assertEqual(default['timing_tests'], expected)
        self.assertEqual(default['timing_commands'], [])
        self.assertTrue(default['timing_deferred'])
        plan = self.plan('Sources/ChecklistApp/ContentView.swift', qualification=True)
        self.assertEqual(plan['timing_tests'], expected)
        self.assertFalse(plan['timing_deferred'])
        self.assertEqual(len(plan['timing_commands']), 1)
        command = plan['timing_commands'][0]
        self.assertNotIn(command, plan['default_swift_commands'])
        self.assertNotIn(command, plan['qualification_commands'])
        self.assertIn(command, plan['swift_commands'])
        self.assertIn('CHECKLIST_QUALIFICATION=0', command)
        self.assertEqual(command[command.index('--num-workers') + 1], '1')
        self.assertEqual([command[i + 1] for i, arg in enumerate(command) if arg == '--filter'],
                         ['^' + re.escape(case) + '$' for case in expected])
        parallel = plan['swift_commands'][0]
        for case in selector.ISOLATED_TESTS:
            self.assertIn('^' + re.escape(case) + '(?:/|$)', parallel)
            self.assertNotIn(case, plan['skip'])
        other = self.root / 'Tests/ChecklistAppTests/OtherTests.swift'
        other.parent.mkdir(parents=True)
        other.write_text('final class OtherTests: XCTestCase { func testOne() {} }')
        narrowed = self.plan('Tests/ChecklistAppTests/OtherTests.swift')
        self.assertEqual(narrowed['test_groups']['ChecklistAppTests'], ['OtherTests'])
        self.assertEqual(narrowed['timing_tests'], [])
        self.assertEqual(narrowed['timing_commands'], [])

    def assert_case_runs(self, plan, case, commands_key='qualification_commands'):
        for command in plan[commands_key]:
            filters = [command[i + 1] for i, arg in enumerate(command) if arg == '--filter']
            skips = [command[i + 1] for i, arg in enumerate(command) if arg == '--skip']
            if any(re.search(pattern, case) for pattern in filters) and not any(
                    re.search(pattern, case) for pattern in skips):
                self.assertIn(command, plan['commands'])
                return
        self.fail(f'{case} has no runnable command in {commands_key}')

    def test_real_size_manifest_fixture_keeps_coverage_in_qualification(self):
        case, = selector.REAL_SIZE_TESTS
        default = self.plan(full=True)
        self.assertIn('^' + re.escape(case) + '(?:/|$)', default['default_swift_commands'][0])
        self.assertIn(case, default['skip'])
        self.assertNotIn(case, default['timing_tests'])
        self.assertEqual(default['qualification_commands'], [])
        qualified = self.plan(full=True, qualification=True)
        self.assert_case_runs(qualified, case)
        # This ungated real-size fixture also runs when its own source changes.
        path = self.root / 'Tests/ChecklistCoreTests/StorageCompactManifestTests.swift'
        path.parent.mkdir(parents=True)
        path.write_text('final class StorageCompactManifestTests: XCTestCase { func ' + case.split('/')[1] + '() throws {} }')
        self.assert_case_runs(self.plan(path.relative_to(self.root).as_posix()), case)
        self.assertEqual(len(set(selector.ISOLATED_TESTS)), len(selector.ISOLATED_TESTS))
        self.assertFalse(set(selector.ISOLATED_TESTS) & set(selector.QUALIFICATION_CASES))

    def test_screen_query_plans_are_qualification_only_and_follow_their_source(self):
        case = 'ChecklistCoreTests.ScreenReadQueryPlanTests/testRealSizeScreenReadQueryPlans'
        default = self.plan(full=True)
        self.assertIn(case, default['skip'])
        self.assertEqual(default['qualification_commands'], [])
        self.assert_case_runs(self.plan(full=True, qualification=True), case)
        path = self.root / 'Tests/ChecklistCoreTests/ScreenReadQueryPlanTests.swift'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('final class ScreenReadQueryPlanTests: XCTestCase { func testRealSizeScreenReadQueryPlans() throws {} }')
        self.assert_case_runs(self.plan(path.relative_to(self.root).as_posix()), case)
        self.assert_case_runs(self.plan('Sources/ChecklistCore/WorkspacePageRead.swift'), case)

    def test_manifest_production_change_runs_real_size_qualification(self):
        case, = selector.REAL_SIZE_TESTS
        plan = self.plan('Sources/ChecklistCore/StorageCompactManifest.swift')
        self.assertTrue(plan['qualification'])
        self.assertIn(case, plan['qualification_tests'])
        self.assertNotIn(case, plan['skip'])
        self.assert_case_runs(plan, case)
        self.assertIn('^' + re.escape(case) + '(?:/|$)', plan['default_swift_commands'][0])
        self.assertTrue(plan['timing_deferred'])
        self.assertEqual(plan['timing_commands'], [])

    def test_app_only_change_still_defers_timing_and_load_sensitive_budgets(self):
        plan = self.plan('Sources/ChecklistApp/Support/Canceled.swift')
        self.assertTrue(plan['timing_deferred'])
        self.assertEqual(plan['timing_commands'], [])
        expected = [case for case in selector.TIMING_TESTS + selector.LOAD_SENSITIVE_TESTS
                    if case.startswith('ChecklistAppTests.')]
        self.assertEqual(plan['timing_tests'], expected)
        for case in expected:
            self.assertIn('^' + re.escape(case) + '(?:/|$)', plan['default_swift_commands'][0])
            self.assertNotIn(case, plan['qualification_tests'])
        for path in ['Tests/ChecklistAppTests/ScreenTimingTests.swift',
                     'Tests/ChecklistAppTests/PreviewAvailabilityTests.swift']:
            changed = self.plan(path)
            self.assertFalse(changed['timing_deferred'])
            for case in expected:
                self.assert_case_runs(changed, case, 'timing_commands')

    def test_full_qualification_mode_is_explicit_or_last_round_and_not_target_limited(self):
        for options, mode in [({'qualification': True}, 'requested-full'),
                              ({'last_round': True}, 'pass-final-round')]:
            plan = self.plan('README.md', **options)
            self.assertEqual(plan['qualification_mode'], mode)
            self.assertEqual(plan['qualification_tests'], list(selector.QUALIFICATION_CASES))
            self.assertEqual(plan['default_swift_commands'], [])
            for case in selector.QUALIFICATION_CASES:
                self.assert_case_runs(plan, case)
        self.assertEqual(self.plan(full=True)['qualification_mode'], 'full-default')

    def test_deleted_extension_fixture_still_selects_its_registered_methods(self):
        path = 'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift'
        self.assertFalse((self.root / path).exists())
        plan = self.plan(path)
        self.assertIn('ChecklistCoreTests.TicketLifecycleCleanupTests/testSustainedWritersBoundRSSCPUAndBackoff',
                      plan['qualification_tests'])
        self.assertNotIn(selector.REAL_SIZE_TESTS[0], plan['qualification_tests'])

    def test_unmapped_source_falls_back_to_module_closure_and_reports_path(self):
        path = 'Sources/ChecklistCore/NewHelper.swift'
        plan = self.plan(path)
        self.assertEqual(plan['group_fallback_paths'], [path])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(plan['test_groups'], {})

    def test_unrelated_source_input_does_not_broaden_mapped_core_groups(self):
        plan = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift', 'Sources/ChecklistApp/NewView.swift')
        self.assertEqual(plan['test_groups'].get('ChecklistCoreTests'), ['NativeOutcomeRecorderTests'])
        self.assertNotIn('ChecklistAppTests', plan['test_groups'])

    def test_full_qualification_cli_needs_no_changed_paths(self):
        for switch, mode in [('--qualification', 'requested-full'), ('--last-round', 'pass-final-round')]:
            output = io.StringIO()
            with patch.object(selector, 'package_graph', return_value=GRAPH), redirect_stdout(output):
                selector.main(['--root', str(self.root), '--json', switch])
            plan = json.loads(output.getvalue())
            self.assertEqual(plan['qualification_mode'], mode)
            self.assertEqual(plan['qualification_tests'], list(selector.QUALIFICATION_CASES))
            self.assertEqual(plan['qualification_test_targets'], ['ChecklistAppTests', 'ChecklistCoreTests', 'ChecklistIPCTests'])
            self.assertEqual(plan['default_swift_commands'], [])

    def test_selected_cases_and_changed_inputs_are_printed(self):
        path = 'Sources/ChecklistCore/MediaDecisions.swift'
        output = io.StringIO()
        with patch.object(selector, 'package_graph', return_value=GRAPH), redirect_stdout(output):
            selector.main(['--root', str(self.root), '--paths', path])
        printed = output.getvalue()
        self.assertIn('Qualification mode: affected', printed)
        self.assertIn('Qualification case: ChecklistCoreTests.MediaDecisionTests/', printed)
        self.assertIn(' <- ' + path, printed)
        self.assertIn('Module group fallback for: ' + path, printed)

    def test_wall_clock_budget_scanner_follows_helpers_and_all_sizes(self):
        directory = self.root / 'Tests/ChecklistAppTests'
        directory.mkdir(parents=True)
        (directory / 'BudgetTests.swift').write_text('''final class BudgetTests: XCTestCase {
    private final class Fixture { func ignored() {} }
    private func measure() {
        let start = ProcessInfo.processInfo.systemUptime
        let spent = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(spent, 0.3)
    }
    func testViaHelper() { measure() }
    func testMilliseconds() { XCTAssertLessThan(milliseconds, cached ? 300 : 1_000) }
    func testAtFloor() { XCTAssertLessThan(ContinuousClock.now - start, .seconds(5)) }
    func testEightSeconds() { XCTAssertLessThan(Date().timeIntervalSince(started), 8) }
    func testLargeDuration() { XCTAssertLessThanOrEqual(ContinuousClock.now - start, .seconds(120)) }
    func testTrueSamples() {
        var samples: [Double] = []
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
        XCTAssertTrue(samples.allSatisfy { $0 < 300 })
    }
    func testDuration() { XCTAssertTrue(ContinuousClock.now - start < Duration.seconds(8)) }
    func testRelative() { XCTAssertLessThan(elapsed, total * 0.5) }
    func testReversed() { XCTAssertTrue(.seconds(90) >= ContinuousClock.now - start) }
    func testLowerBound() { XCTAssertTrue(elapsed > 0) }
    func testCount() { XCTAssertLessThan(pages, 3) }
    func testGated() throws {
        try QualificationSuite.requireEnabled()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
''')
        cases = selector.wall_clock_budget_cases(self.root)
        self.assertEqual(sorted(cases), ['ChecklistAppTests.BudgetTests/' + name for name in
                                         ['testAtFloor', 'testDuration', 'testEightSeconds', 'testGated', 'testLargeDuration',
                                          'testMilliseconds', 'testRelative', 'testReversed', 'testTrueSamples', 'testViaHelper']])
        self.assertTrue(cases['ChecklistAppTests.BudgetTests/testGated'][1])
        self.assertFalse(cases['ChecklistAppTests.BudgetTests/testViaHelper'][1])

    def test_default_suite_wall_clock_budgets_are_in_timing_group(self):
        # Guard (CL-275): every elapsed-time budget, regardless of size or
        # assertion form, must leave the parallel default pass.
        root = Path(__file__).resolve().parents[1]
        cases = selector.wall_clock_budget_cases(root)
        unregistered = sorted(case for case, (_, gated) in cases.items()
                              if not gated and case not in selector.TIMING_TESTS and case not in selector.QUALIFICATION_TESTS)
        self.assertEqual(unregistered, [], 'register these in TIMING_TESTS (docs/test-selection.md)')
        self.assertEqual(sorted(case for case in selector.TIMING_TESTS if case not in cases), [], 'stale TIMING_TESTS entries')
        self.assertEqual(len(set(selector.TIMING_TESTS)), len(selector.TIMING_TESTS))
        self.assertFalse(set(selector.LOAD_SENSITIVE_TESTS) & set(selector.TIMING_TESTS))
        self.assertFalse(set(selector.TIMING_TESTS) & set(selector.QUALIFICATION_TESTS))

    def test_qualification_registry_matches_gated_methods(self):
        root = Path(__file__).resolve().parents[1]
        gated = []
        for source in (root / 'Tests').rglob('*.swift'):
            gated.extend(re.findall(r'func (test\w+)\(\) throws \{\s+try QualificationSuite.requireEnabled\(\)', source.read_text()))
        registered = [name.split('/')[1] for name in selector.QUALIFICATION_TESTS]
        self.assertCountEqual(gated, registered)
        self.assertEqual(len(set(registered)), len(registered))

    def test_mixed_paths_union_and_empty_paths(self):
        plan = self.plan('./Sources/ChecklistApp/A.swift', 'Sources/ChecklistApp/A.swift', 'script/test_instances.py')
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests', 'ChecklistProvidersTests'])
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
            self.assertEqual(json.loads(output.getvalue())['test_targets'], ['ChecklistAppTests', 'ChecklistProvidersTests'])


# These tests create a different script in an owned workspace, or reject the
# requested execution before a read. Neither reads our repository's validator.
SYNTHETIC_FILE_REFERENCES = {
    ('Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift', 'scripts/validate-plan.py'),
    ('Tests/ChecklistCoreTests/AgentReviewAssessmentTests.swift', 'scripts/validate-plan.py'),
}
# ChecklistInstanceTests passes these names to its URL parser, not to exec.
SYNTHETIC_EXECUTABLE_REFERENCES = {
    ('Tests/ChecklistIPCTests/ChecklistInstanceTests.swift', 'ChecklistApp'),
    ('Tests/ChecklistIPCTests/ChecklistInstanceTests.swift', 'ChecklistService'),
}


def repository_references(root):
    """Audit path literals, including directory enumerations, in Swift inputs.

    This deliberately over-approximates reads: a repository path in a string
    must have an owner even if it is only used on one conditional test route.
    Generated store/workspace fixtures and installed-bundle resources aren't
    repository inputs. Split/dynamic paths need an explicit audit when added.
    """
    directories = {p.name for p in root.iterdir() if p.is_dir() and not p.name.startswith('.')}
    references = []
    for tree in ('Tests', 'Sources'):
        for source in sorted((root / tree).rglob('*.swift')):
            for literal in re.findall(r'"((?:\\.|[^"\\])*)"', source.read_text()):
                path = Path(literal)
                if (source.relative_to(root).as_posix(), literal) in SYNTHETIC_FILE_REFERENCES:
                    continue
                if '/' not in literal or not path.parts or path.parts[0] not in directories or '\\' in literal:
                    continue
                candidate = root / path
                inputs = sorted(candidate.rglob('*')) if candidate.is_dir() else [candidate]
                for item in inputs:
                    if item.is_file():
                        references.append((source.relative_to(root).as_posix(), item.relative_to(root).as_posix()))
    return references


def python_repository_references(root):
    """Audit literal repository paths passed to Python file reads.

    Like the Swift audit, this is conservative, not an interpreter. Paths split
    across variables or computed dynamically require an explicit map and audit.
    """
    directories = {p.name for p in root.iterdir() if p.is_dir() and not p.name.startswith('.')}
    references = set()
    for source in sorted((root / 'scripts').glob('test_*.py')):
        for node in ast.walk(ast.parse(source.read_text())):
            if not isinstance(node, ast.Call):
                continue
            if isinstance(node.func, ast.Attribute) and node.func.attr in ('read_text', 'read_bytes', 'open'):
                expression = node.func.value
            elif isinstance(node.func, ast.Name) and node.func.id == 'open' and node.args:
                expression = node.args[0]
            else:
                continue
            # Path / 'directory' / 'file' and Path / 'directory/file'.
            def literals(expression):
                if isinstance(expression, ast.Constant) and isinstance(expression.value, str):
                    return [expression.value]
                if isinstance(expression, ast.BinOp) and isinstance(expression.op, ast.Div):
                    return literals(expression.left) + literals(expression.right)
                return []
            literal = '/'.join(literals(expression))
            path = Path(literal)
            if '/' not in literal or not path.parts or path.parts[0] not in directories:
                continue
            candidate = root / path
            inputs = sorted(candidate.rglob('*')) if candidate.is_dir() else [candidate]
            for item in inputs:
                if item.is_file():
                    references.add((source.relative_to(root).as_posix(), item.relative_to(root).as_posix()))
    return sorted(references)


class RepositoryDependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[1]
        # Reuse the assigned persistent slot when present. This describes the
        # actual package; it never builds Swift or runs the application.
        cls.scratch = cls.root.parent / '.build'
        if not cls.scratch.is_dir():
            cls.scratch = cls.root / '.build'
        cls.graph = selector.package_graph(cls.root, cls.scratch)
        cls.targets = sorted(cls.graph['targets'], key=lambda t: len(t['path']), reverse=True)

    def owner(self, path):
        return next(t for t in self.targets if path.startswith(t['path'] + '/'))

    def test_actual_graph_qualification_inputs_are_complete_and_runnable(self):
        self.assertEqual(set(selector.QUALIFICATION_SOURCE_PATHS), set(selector.QUALIFICATION_CASES))
        for case, patterns in selector.QUALIFICATION_SOURCE_PATHS.items():
            self.assertTrue(patterns, case)
            fixtures = []
            for pattern in patterns:
                self.assertNotIn(pattern, ['Sources/ChecklistCore/*', 'Sources/ChecklistApp/*', 'Sources/ChecklistIPC/*'])
                matches = list(self.root.glob(pattern))
                self.assertTrue(matches, (case, pattern))
                fixtures.extend(p for p in matches if p.suffix == '.swift' and p.is_file()
                                and p.relative_to(self.root).as_posix().startswith('Tests/'))
            self.assertTrue(any('func ' + case.split('/')[1] + '(' in fixture.read_text()
                                for fixture in fixtures), case)
        for path in ['Sources/ChecklistCore/StorageCompactManifest.swift',
                     'Sources/ChecklistCore/NativeOutcomeRecorder.swift',
                     'Sources/ChecklistIPC/ChecklistClient.swift',
                     'Sources/ChecklistApp/Support/Canceled.swift']:
            plan = selector.select(self.root, self.graph, [path], self.scratch)
            expected = [case for case, patterns in selector.QUALIFICATION_SOURCE_PATHS.items()
                        if any(selector.fnmatchcase(path, pattern) for pattern in patterns)]
            self.assertEqual(plan['qualification_tests'], expected)
            for case in expected:
                self.assertNotIn(case, plan['skip'])
                self.assertEqual(plan['qualification_reasons'][case], [path])
                self.assertTrue(any('^' + re.escape(case) + '$' in command and '--skip' not in command
                                    for command in plan['qualification_commands']))

    def test_actual_graph_mapped_view_selects_only_consumer_groups(self):
        path = 'Sources/ChecklistApp/Views/TicketStatusReason.swift'
        plan = selector.select(self.root, self.graph, [path], self.scratch)
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests'])
        self.assertIn('TicketStatusReasonTests', plan['test_groups']['ChecklistAppTests'])
        self.assertIn('GlossaryTests', plan['test_groups']['ChecklistAppTests'])
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assertEqual(plan['qualification_tests'], [])
        self.assertEqual(plan['timing_commands'], [])
        self.assertTrue(plan['timing_deferred'])
        classes = set()
        for source in (self.root / 'Tests/ChecklistAppTests').glob('*.swift'):
            classes.update(re.findall(r'final class (\w+)\s*:\s*XCTestCase', source.read_text()))
        self.assertTrue(set(plan['test_groups']['ChecklistAppTests']).issubset(classes))

    def test_actual_graph_leaf_maps_cover_unit_and_dependent_consumers(self):
        for path, expected in [
            ('Sources/ChecklistCore/MediaListConfiguration.swift', ['ChecklistAppTests', 'ChecklistCoreTests']),
            ('Sources/ChecklistApp/Models/TicketPurgePreview.swift', ['ChecklistAppTests']),
            ('Sources/ChecklistApp/Support/CodexComposeLink.swift', ['ChecklistAppTests']),
        ]:
            with self.subTest(path=path):
                plan = selector.select(self.root, self.graph, [path], self.scratch)
                self.assertEqual(plan['test_targets'], expected)
                self.assertEqual(plan['group_fallback_paths'], [])
                for name, groups in plan['test_groups'].items():
                    target_path = next(t['path'] for t in self.targets if t['name'] == name)
                    classes = set()
                    for source in (self.root / target_path).rglob('*.swift'):
                        classes.update(re.findall(r'final class (\w+)\s*:\s*XCTestCase', source.read_text()))
                    self.assertTrue(set(groups).issubset(classes), (path, set(groups) - classes))

    def test_repository_input_map_covers_swift_literals(self):
        found = {}
        for source, path in repository_references(self.root):
            if path.endswith('.swift'):
                continue
            owner = self.owner(source)
            consumers = ([owner['name']] if owner['type'] == 'test' else
                         selector.select(self.root, self.graph, [source], self.scratch)['test_targets'])
            found.setdefault(path, set()).update(consumers)
        self.assertEqual(found, {path: set(consumers) for path, consumers in selector.FILE_TEST_CONSUMERS.items()},
                         'Update FILE_TEST_CONSUMERS for added, moved or removed repository input reads')
        for path, consumers in found.items():
            plan = selector.select(self.root, self.graph, [path], self.scratch)
            self.assertTrue(consumers.issubset(plan['test_targets']), (path, plan))

    def test_repository_input_selection_covers_python_reads(self):
        references = python_repository_references(self.root)
        self.assertIn(('scripts/test_test_instances.py', 'Tests/Fixtures/path-overlap-vectors.json'), references)
        for source, path in references:
            with self.subTest(reader=source, input=path):
                plan = selector.select(self.root, self.graph, [path], self.scratch)
                self.assertIn(source, plan['python_tests'],
                              'Add every Python reader to FILE_PYTHON_TEST_CONSUMERS or fall back to the full suite')

    def test_python_input_audit_finds_docs_and_split_fixture_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ['docs/new.md', 'Tests/Fixtures/shared.json', 'scripts/test_new.py']:
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            (root / 'scripts/test_new.py').write_text(
                "(REPO / 'docs/new.md').read_text()\n"
                "with open(REPO / 'Tests' / 'Fixtures' / 'shared.json') as f: pass\n")
            self.assertEqual(python_repository_references(root), [
                ('scripts/test_new.py', 'Tests/Fixtures/shared.json'),
                ('scripts/test_new.py', 'docs/new.md')])

    def test_source_reads_select_the_reading_test_target(self):
        for source, path in repository_references(self.root):
            owner = self.owner(source)
            if owner['type'] == 'test' and path.endswith('.swift'):
                with self.subTest(reader=source, input=path):
                    plan = selector.select(self.root, self.graph, [path], self.scratch)
                    self.assertIn(owner['name'], plan['test_targets'])

    def test_input_audit_finds_new_docs_skills_and_resource_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ['docs/new.md', 'skills/new/input.json', 'examples/new.json',
                         'contracts/new.json', 'Resources/catalog.json']:
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            source = root / 'Tests/NewTests/InputTests.swift'
            source.parent.mkdir(parents=True)
            source.write_text('let inputs = ["docs/new.md", "skills/new/input.json", "examples/new.json", '
                              '"contracts/new.json", "Resources/catalog.json"]')
            self.assertEqual({path for _, path in repository_references(root)},
                             {'docs/new.md', 'skills/new/input.json', 'examples/new.json',
                              'contracts/new.json', 'Resources/catalog.json'})

    def test_actual_package_resources_select_consumers(self):
        for target in self.targets:
            expected = selector.select(self.root, self.graph,
                                       [target['path'] + '/ResourceInput.swift'], self.scratch)['test_targets']
            for resource in target.get('resources', []):
                path = Path(resource['path'])
                if path.is_absolute():
                    path = path.relative_to(self.root)
                plan = selector.select(self.root, self.graph, [path.as_posix()], self.scratch)
                self.assertTrue(set(expected).issubset(plan['test_targets']), (target['name'], resource))

    def test_runtime_executable_map_covers_actual_package_references(self):
        executables = {t['name'] for t in self.targets if t['type'] == 'executable'}
        references = {}
        for source in (self.root / 'Tests').rglob('*.swift'):
            relative = source.relative_to(self.root).as_posix()
            owner = next((t for t in self.targets if relative.startswith(t['path'] + '/')), None)
            if owner is None or owner['type'] != 'test':
                continue
            text = source.read_text()
            for name in executables:
                if (relative, name) in SYNTHETIC_EXECUTABLE_REFERENCES:
                    continue
                # Canonical built binary names, not synthetic app/shim filenames.
                if '"' + name + '"' in text or (name == 'StorageCrashProbe' and '"CHECKLIST_STORAGE_PROBE"' in text):
                    references.setdefault(name, set()).add(owner['name'])
        self.assertEqual(references, {name: set(consumers) for name, consumers in selector.RUNTIME_TEST_CONSUMERS.items()},
                         'Update RUNTIME_TEST_CONSUMERS for executable runtime dependencies')
        for name, consumers in references.items():
            target = next(t for t in self.targets if t['name'] == name)
            plan = selector.select(self.root, self.graph, [target['path'] + '/main.swift'], self.scratch)
            self.assertTrue(consumers.issubset(plan['test_targets']), (name, plan))


if __name__ == '__main__':
    unittest.main()
