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

    def plan(self, *paths, full=False, qualification=False, last_round=False, impact_map=None):
        return selector.select(self.root, GRAPH, paths, self.root / '.build', full, qualification, last_round, impact_map)

    def measured_map(self, sources, complete=True):
        return {'schema_version': 1, 'commit': 'synthetic-commit', 'complete': complete,
                'generated_at': '2026-10-26T00:00:00Z', 'generation_seconds': 1.25,
                'measured_classes': sorted({item for entry in sources.values() for item in entry['classes']}),
                'measured_qualification_cases': sorted({item for entry in sources.values()
                                                       for item in entry['qualification_cases']}),
                'source_hashes': {}, 'sources': sources}

    def shared_graph(self):
        graph = json.loads(json.dumps(GRAPH))
        package = 'Packages/ChecklistShared'
        graph['targets'].extend([
            dict(target('ChecklistDomain'), path=package + '/Sources/ChecklistDomain', package_path=package),
            dict(target('ChecklistContracts', ['ChecklistDomain']),
                 path=package + '/Sources/ChecklistContracts', package_path=package),
            dict(target('ChecklistSharedTests', ['ChecklistContracts'], 'test'),
                 path=package + '/Tests/ChecklistSharedTests', package_path=package),
        ])
        graph['targets'][1]['target_dependencies'].append('ChecklistContracts')
        return graph

    def shared_plan(self, *paths, impact_map=None, full=False):
        return selector.select(self.root, self.shared_graph(), paths, self.root / '.build', full=full,
                               impact_map=impact_map or {'complete': False})

    def test_static_runtime_lookup_fallback_survives_shared_index_merge(self):
        import hashlib
        path = 'Packages/ChecklistShared/Sources/ChecklistContracts/CommandMethods.swift'
        test = 'Tests/ChecklistCoreTests/LeafTests.swift'
        for name, text in [(path, 'public func read() {}'),
                           (test, 'final class LeafTests: XCTestCase {}')]:
            source = self.root / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(text)
        export = {'schema_version': 1,
                  'source_hashes': {name: hashlib.sha256((self.root / name).read_bytes()).hexdigest()
                                    for name in [path, test, 'Sources/ChecklistCore/NativeOutcomeRecorder.swift',
                                                 'Sources/ChecklistService/main.swift']},
                  'occurrences': [
                      {'file': path, 'usr': 'read', 'name': 'read', 'kind': 12, 'roles': 2},
                      {'file': test, 'usr': 'class', 'name': 'LeafTests', 'kind': 7, 'roles': 2},
                      {'file': test, 'usr': 'read', 'name': 'read', 'kind': 12, 'roles': 4}]}
        measured = self.measured_map({path: {'classes': ['ChecklistCoreTests.LeafTests'],
                                             'qualification_cases': []}})
        measured.update(selection_source='index-store', static_fallback_sources=[path])
        plan = selector.select(self.root, self.shared_graph(), [path], self.root / '.build',
                               impact_map=measured, shared_index=export)
        self.assertEqual(plan['shared_index_selections'], {path: ['ChecklistCoreTests.LeafTests']})
        self.assertIn(path, plan['group_fallback_paths'])
        self.assertNotIn('ChecklistCoreTests', plan['test_groups'])
        self.assertIn('runtime-name lookup', plan['fallback_reasons'][path])

    def test_shared_source_uses_module_consumers_and_own_package_command(self):
        path = 'Packages/ChecklistShared/Sources/ChecklistContracts/CommandMethods.swift'
        plan = self.shared_plan(path)
        self.assertEqual(plan['fallback_paths'], [])
        self.assertIn('ChecklistSharedTests', plan['test_targets'])
        self.assertIn('ChecklistCoreTests', plan['test_targets'])
        self.assertIn('module closure', plan['fallback_reasons'][path])
        shared, = plan['shared_package_commands']
        self.assertEqual(shared[shared.index('--package-path') + 1], str(self.root / 'Packages/ChecklistShared'))
        self.assertEqual(shared[shared.index('--scratch-path') + 1], str(self.root / '.build/packages/ChecklistShared'))
        self.assertIn('--enable-dependency-cache', shared)
        self.assertIn('HumanClaimsKeychainTests', shared)
        self.assertTrue(any(command[-len(shared):] == shared for command in plan['commands']))
        self.assertNotIn('^ChecklistSharedTests\\.', plan['swift_commands'][0])

    def test_shared_measured_source_keeps_own_tests_and_narrows_root_classes(self):
        path = 'Packages/ChecklistShared/Sources/ChecklistContracts/CommandMethods.swift'
        measured = self.measured_map({path: {'classes': ['ChecklistIPCTests.CommandReplyTests'],
                                             'qualification_cases': []}})
        plan = self.shared_plan(path, impact_map=measured)
        self.assertEqual(plan['test_targets'], ['ChecklistIPCTests', 'ChecklistSharedTests'])
        self.assertEqual(plan['test_groups'], {'ChecklistIPCTests': ['CommandReplyTests']})
        self.assertEqual(plan['fallback_paths'], [])
        self.assertEqual(plan['group_fallback_paths'], [])

    def test_empty_shared_coverage_does_not_drop_root_consumers(self):
        path = 'Packages/ChecklistShared/Sources/ChecklistContracts/CommandMethods.swift'
        plan = self.shared_plan(path, impact_map=self.measured_map({
            path: {'classes': [], 'qualification_cases': []}}))
        self.assertIn('ChecklistCoreTests', plan['test_targets'])
        self.assertIn('ChecklistSharedTests', plan['test_targets'])
        self.assertIn(path, plan['group_fallback_paths'])

    def test_shared_test_change_runs_only_its_package_and_class(self):
        path = 'Packages/ChecklistShared/Tests/ChecklistSharedTests/CommandMethodsTests.swift'
        source = self.root / path
        source.parent.mkdir(parents=True)
        source.write_text('import XCTest\nfinal class CommandMethodsTests: XCTestCase {\n func testRead() {}\n}\n')
        plan = self.shared_plan(path)
        self.assertEqual(plan['test_targets'], ['ChecklistSharedTests'])
        self.assertEqual(plan['test_groups'], {'ChecklistSharedTests': ['CommandMethodsTests']})
        self.assertEqual(plan['fallback_paths'], [])
        self.assertEqual(plan['swift_commands'], plan['shared_package_commands'])
        self.assertIn('^ChecklistSharedTests\\.(?:CommandMethodsTests)(?:/|$)', plan['swift_commands'][0])

    def test_shared_manifest_lockfile_and_unknown_input_name_full_fallback(self):
        for path, reason in [
            ('Packages/ChecklistShared/Package.swift', 'nested package manifest or lockfile'),
            ('Packages/ChecklistShared/Package.resolved', 'nested package manifest or lockfile'),
            ('Packages/ChecklistShared/unknown.bin', 'unknown path; its consumers cannot be determined'),
        ]:
            with self.subTest(path=path):
                plan = self.shared_plan(path)
                self.assertEqual(plan['fallback_paths'], [path])
                self.assertEqual(plan['fallback_reasons'][path], reason)
                self.assertEqual(len(plan['test_targets']), 8)
                self.assertEqual(len(plan['shared_package_commands']), 1)
                self.assertIn('scripts/test_affected_tests.py', plan['python_tests'])

    def test_shared_index_selects_root_classes_without_execution_coverage(self):
        import hashlib
        shared = 'Packages/ChecklistShared/Sources/ChecklistContracts/CommandMethods.swift'
        test = 'Tests/ChecklistIPCTests/CommandReplyTests.swift'
        for path, text in [(shared, 'public func read() {}'),
                           (test, 'final class CommandReplyTests: XCTestCase {}')]:
            source = self.root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(text)
        export = {'schema_version': 1,
                  'source_hashes': {path: hashlib.sha256((self.root / path).read_bytes()).hexdigest()
                                    for path in [shared, test, 'Sources/ChecklistCore/NativeOutcomeRecorder.swift',
                                                 'Sources/ChecklistService/main.swift']},
                  'occurrences': [
                      {'file': shared, 'usr': 'read', 'name': 'read', 'kind': 12, 'roles': 2},
                      {'file': test, 'usr': 'class', 'name': 'CommandReplyTests', 'kind': 7, 'roles': 2},
                      {'file': test, 'usr': 'read', 'name': 'read', 'kind': 12, 'roles': 4}]}
        plan = selector.select(self.root, self.shared_graph(), [shared], self.root / '.build',
                               impact_map={'complete': False}, shared_index=export)
        self.assertEqual(plan['test_targets'], ['ChecklistIPCTests', 'ChecklistSharedTests'])
        self.assertEqual(plan['test_groups'], {'ChecklistIPCTests': ['CommandReplyTests']})
        self.assertEqual(plan['shared_index_selections'], {shared: ['ChecklistIPCTests.CommandReplyTests']})
        self.assertEqual(plan['fallback_reasons'], {})
        index_path = self.root / 'index.json'
        index_path.write_text(json.dumps(export))
        output = io.StringIO()
        with patch.object(selector, 'package_graph', return_value=self.shared_graph()), \
             patch.object(selector, 'load_impact_map', return_value=(None, {'state': 'missing'})), \
             redirect_stdout(output):
            selector.main(['--root', str(self.root), '--paths', './' + shared, '--json',
                           '--scratch-path', str(self.root / '.build'), '--shared-index', str(index_path)])
        cli_plan = json.loads(output.getvalue())
        for key in ('test_targets', 'test_groups', 'shared_index_selections'):
            self.assertEqual(cli_plan[key], plan[key])
        export['source_hashes'][test] = '0' * 64
        stale = selector.select(self.root, self.shared_graph(), [shared], self.root / '.build',
                                impact_map={'complete': False}, shared_index=export)
        self.assertIn('source inputs differ', stale['fallback_reasons'][shared])
        self.assertEqual(stale['fallback_paths'], [])
        self.assertIn('ChecklistCoreTests', stale['test_targets'])

    def test_shared_full_includes_separate_package_command(self):
        plan = self.shared_plan(full=True)
        self.assertEqual(len(plan['test_targets']), 8)
        self.assertEqual(len(plan['shared_package_commands']), 1)
        self.assertNotIn('--package-path', plan['swift_commands'][0])

    def test_synthetic_llvm_exports_feed_selection_without_source_declarations(self):
        spec = importlib.util.spec_from_file_location('test_impact_map',
                    Path(__file__).resolve().parents[1] / 'script/test_impact_map.py')
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        path = 'Sources/ChecklistCore/NativeOutcomeRecorder.swift'
        case = selector.REAL_SIZE_TESTS[0]
        export = {'data': [{'files': [{'filename': str(self.root / path),
                                      'segments': [[1, 1, 2, True, True, False]]}]}]}
        covered = generator.parse_coverage_export(export, self.root)
        measured = generator.build_map(self.root, [
            {'class': 'ChecklistCoreTests.NativeOutcomeRecorderTests', 'sources': covered},
            {'qualification_case': case, 'sources': covered}],
            'synthetic-commit', '2026-10-26T00:00:00Z', 0.5)
        measured['complete'] = True
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['NativeOutcomeRecorderTests']})
        self.assertEqual(plan['qualification_tests'], [case])
        self.assertEqual(plan['group_fallback_paths'], [])

    def test_generated_map_selects_only_executing_classes_and_cases(self):
        path = 'Sources/ChecklistCore/MediaDecisions.swift'
        case = 'ChecklistCoreTests.MediaDecisionTests/test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal'
        measured = self.measured_map({path: {'classes': ['ChecklistCoreTests.MediaDecisionTests',
                                                       'ChecklistAppTests.GlossaryTests'],
                                           'qualification_cases': [case]}})
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(plan['test_targets'], ['ChecklistAppTests', 'ChecklistCoreTests'])
        self.assertEqual(plan['test_groups'], {'ChecklistAppTests': ['GlossaryTests'],
                                               'ChecklistCoreTests': ['MediaDecisionTests']})
        self.assertEqual(plan['qualification_tests'], [case])
        self.assertEqual(plan['qualification_reasons'][case], [path])
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assert_case_deferred(plan, case)

    def test_mapped_source_never_adds_unmeasured_module_consumers(self):
        path = 'Sources/ChecklistCore/Leaf.swift'
        private = selector.QUALIFICATION_CASES[0]
        measured = self.measured_map({path: {'classes': ['ChecklistCoreTests.LeafTests'], 'qualification_cases': []}})
        measured.update(class_inventory=['ChecklistCoreTests.LeafTests', 'ChecklistCoreTests.PrivateTests'],
                        qualification_case_inventory=[private])
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['LeafTests']})
        self.assertEqual(plan['qualification_tests'], [])
        self.assertEqual(plan['qualification_fallback_cases'], {})
        self.assertEqual(plan['coverage_fallback_classes'], {})
        self.assertEqual(plan['group_fallback_paths'], [])
        unmapped = self.plan('Sources/ChecklistApp/View.swift', impact_map=measured)
        self.assertEqual(unmapped['group_fallback_paths'], ['Sources/ChecklistApp/View.swift'])
        self.assertEqual(unmapped['qualification_tests'],
                         ['ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit'])

    def test_unmeasurable_classes_select_only_index_reference_sources(self):
        referenced = 'Sources/ChecklistCore/HumanClaims.swift'
        unrelated = 'Sources/ChecklistCore/Leaf.swift'
        measured = self.measured_map({path: {'classes': [], 'qualification_cases': []}
                                      for path in (referenced, unrelated)})
        group = 'ChecklistAppTests.HumanClaimsKeychainTests'
        measured['class_inventory'] = [group]
        measured['coverage_unmeasurable_classes'] = {
            group: {'reason': 'owner prohibits keychain access', 'sources': [referenced],
                    'source': 'index-store', 'walk': {'complete': True, 'nodes': 1, 'edges': 0, 'seconds': 0.0}}}
        plan = self.plan(referenced, impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistAppTests': ['HumanClaimsKeychainTests']})
        self.assertEqual(plan['coverage_unmeasurable_classes'], {group: [referenced]})
        self.assertEqual(plan['test_group_sources'],
                         {group: {'source': 'index-store', 'paths': [referenced]}})
        self.assertEqual(plan['group_fallback_paths'], [])
        plan = self.plan(unrelated, impact_map=measured)
        self.assertEqual(plan['test_targets'], [])
        self.assertEqual(plan['coverage_unmeasurable_classes'], {})
        output = io.StringIO()
        with patch.object(selector, 'package_graph', return_value=GRAPH), \
             patch.object(selector, 'load_impact_map', return_value=(measured, {'state': 'current'})), \
             redirect_stdout(output):
            selector.main(['--root', str(self.root), '--paths', referenced])
        self.assertIn('Compiler-index class references: ' + group + ' <- ' + referenced,
                      output.getvalue())

    def test_synthetic_index_export_selects_store_copy_classes_and_indirect_receipt(self):
        spec = importlib.util.spec_from_file_location('test_impact_map',
                    Path(__file__).resolve().parents[1] / 'script/test_impact_map.py')
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        names = ['ArchivePreviewStoreCopyTests', 'GroupKeyStoreCopyTests',
                 'ImportStoreCopyQualificationTests', 'TicketCleanupReceiptMeasurementTests']
        used = ['ArchivePreview.swift', 'GroupKeys.swift', 'Import.swift', 'Router.swift']
        occurrences, observations = [], []
        def occurrence(file, usr, roles, relations=(), kind=12):
            occurrences.append({'file': file, 'usr': usr, 'name': usr, 'kind': kind,
                                'roles': roles, 'relations': list(relations)})
        for name, filename in zip(names, used):
            test = 'Tests/ChecklistCoreTests/' + name + '.swift'
            (self.root / test).parent.mkdir(parents=True, exist_ok=True)
            (self.root / test).write_text('final class ' + name + ': XCTestCase {}')
            source = 'Sources/ChecklistCore/' + filename
            (self.root / source).write_text('// synthetic declaration locations\n')
            occurrence(test, name, 2, kind=7)
            occurrence(test, name + '.test', 2, [{'usr': name, 'roles': 512}], kind=16)
            occurrence(test, filename, 4 | 32, [{'usr': name + '.test', 'roles': 8192}])
            occurrence(source, filename, 2)
            observations.append({'class': 'ChecklistCoreTests.' + name,
                                 'sources': [], 'skipped': True})
        cleanup = 'Sources/ChecklistCore/TicketLifecycleCleanup.swift'
        unrelated = 'Sources/ChecklistCore/Unrelated.swift'
        (self.root / cleanup).write_text('// synthetic declaration locations\n')
        (self.root / unrelated).write_text('// unrelated declaration location\n')
        # The receipt dependency lies beyond five recorded edges. Each helper
        # lives in its own source file so a truncated traversal cannot hide it.
        parent, parent_file = 'Router.swift', 'Sources/ChecklistCore/Router.swift'
        for level in range(6):
            usr = 'helper%d' % level
            file = 'Sources/ChecklistCore/Helper%d.swift' % level
            (self.root / file).write_text('// synthetic declaration location\n')
            occurrence(parent_file, usr, 4 | 32, [{'usr': parent, 'roles': 8192}])
            occurrence(file, usr, 2)
            parent, parent_file = usr, file
        occurrence(parent_file, 'ticketCleanupRead', 4 | 32,
                   [{'usr': parent, 'roles': 8192}])
        occurrence(cleanup, 'ticketCleanupRead', 2)
        occurrence(cleanup, 'ticketCleanupPassProjection', 4 | 32,
                   [{'usr': 'ticketCleanupRead', 'roles': 8192}])
        occurrence(cleanup, 'ticketCleanupPassProjection', 2)
        occurrence(unrelated, 'unrelated', 2)
        # An unrelated function in a reached file must not open its call graph.
        occurrence('Sources/ChecklistCore/Router.swift', 'unrelated', 4 | 32,
                   [{'usr': 'unrelatedRouterFunction', 'roles': 8192}])
        inventory = ['Sources/ChecklistCore/' + filename for filename in used] + [cleanup, unrelated]
        measured = generator.build_map(self.root, observations, 'synthetic-commit',
                    '2026-10-26T00:00:00Z', 0.5, inventory=inventory,
                    index_export={'schema_version': 1, 'occurrences': occurrences})
        measured['complete'] = True
        self.assertEqual(measured['measured_classes'], [])
        for name, filename in zip(names, used):
            path = cleanup if name == names[-1] else 'Sources/ChecklistCore/' + filename
            with self.subTest(group=name):
                plan = self.plan(path, impact_map=measured)
                group = 'ChecklistCoreTests.' + name
                self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': [name]})
                self.assertEqual(plan['coverage_unmeasurable_classes'], {group: [path]})
                self.assertEqual(plan['test_group_sources'],
                                 {group: {'source': 'index-store', 'paths': [path]}})
                self.assertEqual(plan['group_fallback_paths'], [])
                self.assertIs(measured['coverage_unmeasurable_classes'][group]['walk']['complete'], True)
        plan = self.plan(unrelated, impact_map=measured)
        self.assertEqual(plan['test_targets'], [])
        self.assertEqual(plan['test_group_sources'], {})

    def test_generated_map_unions_measured_consumers_and_reasons(self):
        paths = ['Sources/ChecklistCore/First.swift', 'Sources/ChecklistCore/Second.swift']
        case = selector.REAL_SIZE_TESTS[0]
        measured = self.measured_map({path: {'classes': ['ChecklistCoreTests.SharedTests',
                                                         'ChecklistCoreTests.' + name],
                                             'qualification_cases': [case]}
                                      for path, name in zip(paths, ['FirstTests', 'SecondTests'])})
        plan = self.plan(*paths, impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['FirstTests', 'SecondTests', 'SharedTests']})
        self.assertEqual(plan['qualification_tests'], [case])
        self.assertEqual(plan['qualification_reasons'][case], paths)

    def test_generated_empty_coverage_entry_needs_no_swift_execution(self):
        path = 'Sources/ChecklistApp/Unused.swift'
        measured = self.measured_map({path: {'classes': [], 'qualification_cases': []}})
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(plan['test_targets'], [])
        self.assertEqual(plan['qualification_tests'], [])
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assertEqual(plan['commands'], [selector.VALIDATE])

    def test_mapped_probe_source_uses_measured_coverage_without_module_fallback(self):
        for path in ('Tests/StorageCrashProbe/ReleasedCore/Old.swift',
                     'Tests/ChecklistCLIInputProbe/main.swift'):
            with self.subTest(path=path):
                measured = self.measured_map({path: {'classes': [], 'qualification_cases': []}})
                plan = self.plan(path, impact_map=measured)
                self.assertEqual(plan['test_targets'], [])
                self.assertEqual(plan['group_fallback_paths'], [])

    def test_new_source_uses_module_closure_even_with_other_mapped_inputs(self):
        mapped = 'Sources/ChecklistCore/Existing.swift'
        new = 'Sources/ChecklistCore/NewHelper.swift'
        measured = self.measured_map({mapped: {'classes': ['ChecklistCoreTests.ExistingTests'],
                                               'qualification_cases': []}})
        plan = self.plan(mapped, new, impact_map=measured)
        self.assertEqual(plan['group_fallback_paths'], [new])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(plan['test_groups'], {})
        self.assertTrue(plan['qualification_tests'])

    def test_unrelated_module_fallback_keeps_mapped_core_class(self):
        mapped = 'Sources/ChecklistCore/Existing.swift'
        new = 'Sources/ChecklistApp/NewView.swift'
        measured = self.measured_map({mapped: {'classes': ['ChecklistCoreTests.ExistingTests'],
                                               'qualification_cases': []}})
        plan = self.plan(mapped, new, impact_map=measured)
        self.assertEqual(plan['test_groups'].get('ChecklistCoreTests'), ['ExistingTests'])
        self.assertNotIn('ChecklistAppTests', plan['test_groups'])
        self.assertEqual(plan['group_fallback_paths'], [new])

    def test_incomplete_map_cannot_narrow_module_closure(self):
        path = 'Sources/ChecklistCore/Existing.swift'
        measured = self.measured_map({path: {'classes': ['ChecklistCoreTests.ExistingTests'],
                                             'qualification_cases': []}}, complete=False)
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(plan['test_groups'], {})
        self.assertEqual(plan['group_fallback_paths'], [path])
        self.assertTrue(plan['qualification_tests'])

    def test_map_freshness_rejects_missing_old_incomplete_and_test_drift(self):
        from datetime import datetime, timedelta, timezone
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()
        git('init', '-q')
        git('config', 'user.name', 'Synthetic Test')
        git('config', 'user.email', 'test@example.invalid')
        fixture = self.root / 'Tests/ChecklistCoreTests/Fixture.swift'
        fixture.parent.mkdir(parents=True)
        fixture.write_text('fixture')
        git('add', '.')
        git('commit', '-qm', 'map base')
        map_path = self.root / 'coverage.json'
        self.assertEqual(selector.load_impact_map(self.root, map_path)[1]['state'], 'missing')
        measured = self.measured_map({})
        measured.update(commit=git('rev-parse', 'HEAD'),
                        generated_at=datetime.now(timezone.utc).isoformat(),
                        measured_qualification_cases=list(selector.QUALIFICATION_CASES))
        map_path.write_text(json.dumps(measured))
        accepted, status = selector.load_impact_map(self.root, map_path)
        self.assertIsNotNone(accepted)
        self.assertEqual(status['state'], 'current')
        # Production changes are expected; the recorded map still selects their consumers.
        (self.root / 'Sources/ChecklistCore/NativeOutcomeRecorder.swift').write_text('changed')
        self.assertIsNotNone(selector.load_impact_map(self.root, map_path)[0])
        # CL-299: changed test code keeps the measured map; the planner selects it directly.
        fixture.write_text('changed fixture')
        accepted, status = selector.load_impact_map(self.root, map_path)
        self.assertIsNotNone(accepted)
        self.assertEqual(status['changed_test_inputs'], ['Tests/ChecklistCoreTests/Fixture.swift'])
        fixture.write_text('fixture')
        data = self.root / 'Tests/ChecklistCoreTests/data.json'
        data.write_text('{}')
        self.assertIn('test/build inputs changed: Tests/ChecklistCoreTests/data.json',
                      selector.load_impact_map(self.root, map_path)[1]['reason'])
        data.unlink()
        measured['generated_at'] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        map_path.write_text(json.dumps(measured))
        self.assertIn('old', selector.load_impact_map(self.root, map_path)[1]['reason'])
        measured['generated_at'] = datetime.now(timezone.utc).isoformat()
        measured['complete'] = False
        map_path.write_text(json.dumps(measured))
        self.assertIsNone(selector.load_impact_map(self.root, map_path)[0])
        measured['complete'] = True
        measured['commit'] = '0000000000000000000000000000000000000000'
        map_path.write_text(json.dumps(measured))
        self.assertIsNone(selector.load_impact_map(self.root, map_path)[0])

    def write(self, path, text):
        source = self.root / path
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(text)
        return path

    def direct_map(self, extra=None):
        """A current map with one mapped Core source and declared test classes."""
        self.write('Tests/ChecklistCoreTests/ExistingTests.swift', 'final class ExistingTests: XCTestCase { func testOne() {} }')
        self.write('Tests/ChecklistIPCTests/UserTests.swift', 'final class UserTests: XCTestCase { func testOne() {} }')
        sources = {'Sources/ChecklistCore/Existing.swift': {'classes': ['ChecklistCoreTests.ExistingTests'],
                                                            'qualification_cases': []}}
        sources.update(extra or {})
        return self.measured_map(sources)

    def test_new_test_file_selects_own_classes_and_keeps_source_coverage(self):
        measured = self.direct_map()
        new = self.write('Tests/ChecklistCoreTests/NewTests.swift',
                         '@MainActor final class NewTests: XCTestCase {\n    private struct Fixture {}\n'
                         '    func helper() {}\n    func testOne() {}\n}\n@MainActor private final class Fake {}\n')
        plan = self.plan('Sources/ChecklistCore/Existing.swift', new, impact_map=measured)
        self.assertEqual(plan['test_groups']['ChecklistCoreTests'], ['ExistingTests', 'NewTests'])
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assertEqual(plan['qualification_tests'], [])
        selection = plan['direct_test_selections'][new]
        self.assertIn('new test file', selection['reason'])
        self.assertEqual(selection['classes'], ['ChecklistCoreTests.NewTests'])
        # Core test sources are read as text by App inspection tests; without
        # recorded readers that target stays whole, with the reason named.
        self.assertEqual(selection['whole_targets'], ['ChecklistAppTests'])
        self.assertIn('ChecklistAppTests', plan['test_targets'])
        self.assertNotIn('ChecklistAppTests', plan['test_groups'])
        self.write('Tests/ChecklistAppTests/GlossaryTests.swift', 'final class GlossaryTests: XCTestCase {}')
        measured['inspection_references'] = {'ChecklistAppTests.GlossaryTests': ['Tests/ChecklistCoreTests/ExistingTests.swift']}
        plan = self.plan('Sources/ChecklistCore/Existing.swift', new, impact_map=measured)
        self.assertEqual(plan['test_groups']['ChecklistAppTests'], ['GlossaryTests'])
        self.assertEqual(len(plan['test_targets']), 2)

    def test_changed_test_file_keeps_measured_consumers_and_adds_new_classes(self):
        changed = 'Tests/ChecklistIPCTests/ChangedTests.swift'
        measured = self.direct_map({changed: {'classes': ['ChecklistIPCTests.ChangedTests', 'ChecklistIPCTests.UserTests'],
                                              'qualification_cases': []}})
        # Measured consumers make even a shared top-level helper selectable.
        self.write(changed, 'func sharedHelper() {}\nfinal class ChangedTests: XCTestCase { func testOne() {} }\n'
                            'final class AddedTests: XCTestCase { func testTwo() {} }\n')
        plan = self.plan(changed, 'Sources/ChecklistCore/Existing.swift', impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['ExistingTests'],
                                               'ChecklistIPCTests': ['AddedTests', 'ChangedTests', 'UserTests']})
        self.assertIn('changed test file', plan['direct_test_selections'][changed]['reason'])
        self.assertEqual(plan['group_fallback_paths'], [])

    def test_deleted_test_file_selects_remaining_measured_consumers_or_falls_back(self):
        gone = 'Tests/ChecklistIPCTests/GoneTests.swift'
        measured = self.direct_map({gone: {'classes': ['ChecklistIPCTests.GoneTests', 'ChecklistIPCTests.UserTests'],
                                           'qualification_cases': []}})
        plan = self.plan(gone, impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistIPCTests': ['UserTests']})
        self.assertIn('deleted test file', plan['direct_test_selections'][gone]['reason'])
        unknown = 'Tests/ChecklistIPCTests/UnmappedTests.swift'
        plan = self.plan(unknown, impact_map=measured)
        self.assertEqual(plan['group_fallback_paths'], [unknown])
        self.assertIn('deleted test file is not in the coverage map', plan['fallback_reasons'][unknown])
        self.assertEqual(plan['test_targets'], ['ChecklistIPCTests'])
        self.assertNotIn('ChecklistIPCTests', plan['test_groups'])

    def test_shared_test_helper_without_measured_consumers_falls_back(self):
        measured = self.direct_map()
        helper = self.write('Tests/ChecklistCoreTests/SharedFixture.swift',
                            'struct SharedFixture {}\nfinal class HelperTests: XCTestCase { func testOne() {} }\n')
        plan = self.plan(helper, 'Sources/ChecklistCore/Existing.swift', impact_map=measured)
        self.assertEqual(plan['group_fallback_paths'], [helper])
        self.assertIn('shared test helpers (struct SharedFixture)', plan['fallback_reasons'][helper])
        self.write(helper, 'nonisolated func sharedHelper() {}\nfinal class HelperTests: XCTestCase { func testOne() {} }\n')
        self.assertIn('unrecognized nonisolated func', self.plan(helper, impact_map=measured)['fallback_reasons'][helper])
        self.assertNotIn('ChecklistCoreTests', plan['test_groups'])
        self.assertTrue(all(case.startswith(('ChecklistCoreTests.', 'ChecklistAppTests.'))
                            for case in plan['qualification_tests']))
        self.assertIn('ChecklistCoreTests.MediaDecisionTests/test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal',
                      plan['qualification_tests'])
        # A new class another test file uses is a shared helper too.
        self.write(helper, 'final class HelperTests: XCTestCase { func testOne() {} }\n')
        self.write('Tests/ChecklistCoreTests/UserOfHelper.swift', 'final class UserOfHelper: HelperTests {}')
        plan = self.plan(helper, impact_map=measured)
        self.assertIn('used by Tests/ChecklistCoreTests/UserOfHelper.swift', plan['fallback_reasons'][helper])

    def test_qualification_test_file_selects_only_its_own_cases(self):
        measured = self.direct_map()
        method = 'test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal'
        path = self.write('Tests/ChecklistCoreTests/MediaDecisionTests.swift',
                          'final class MediaDecisionTests: XCTestCase {\n    func ' + method +
                          '() throws { try QualificationSuite.requireEnabled() }\n    func testSmall() {}\n}\n')
        plan = self.plan(path, impact_map=measured)
        self.assertEqual(plan['qualification_tests'], ['ChecklistCoreTests.MediaDecisionTests/' + method])
        self.assertEqual(plan['qualification_reasons'], {'ChecklistCoreTests.MediaDecisionTests/' + method: [path]})
        self.assertEqual(plan['test_groups']['ChecklistCoreTests'], ['MediaDecisionTests'])
        self.assertEqual(plan['direct_test_selections'][path]['qualification_cases'],
                         ['ChecklistCoreTests.MediaDecisionTests/' + method])

    def test_runtime_input_selects_reading_test_classes(self):
        measured = self.direct_map()
        self.write('Tests/ChecklistCoreTests/ReaderTests.swift',
                   'final class ReaderTests: XCTestCase { func testRead() { _ = "docs/integrations.md" } }')
        plan = self.plan('docs/integrations.md', impact_map=measured)
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['ReaderTests']})
        self.assertIn('ReaderTests.swift', plan['direct_test_selections']['docs/integrations.md']['reason'])
        (self.root / 'Tests/ChecklistCoreTests/ReaderTests.swift').unlink()
        plan = self.plan('docs/integrations.md', impact_map=measured)
        self.assertEqual(plan['test_targets'], ['ChecklistCoreTests'])
        self.assertNotIn('ChecklistCoreTests', plan['test_groups'])

    def test_new_source_reached_only_through_changed_files(self):
        measured = self.direct_map()
        mapped = self.write('Sources/ChecklistCore/Existing.swift', 'let value = NewFeature().run()')
        new = self.write('Sources/ChecklistCore/NewFeature.swift',
                         'public struct NewFeature { public func run() {} }\n'
                         'extension NewFeature: Equatable {}\n'
                         'extension NativeOutcomeRecorder { func newFeatureName() {} }\n')
        plan = self.plan(mapped, new, impact_map=measured)
        self.assertEqual(plan['group_fallback_paths'], [])
        self.assertEqual(plan['new_source_reachability'][new]['referenced_by'], [mapped])
        self.assertEqual(plan['test_groups'], {'ChecklistCoreTests': ['ExistingTests']})
        cases = {
            'extension NativeOutcomeRecorder: CustomStringConvertible { var description: String { "" } }': 'conformance',
            'public struct NativeOutcomeRecorder2 {}\nextension NativeOutcomeRecorder { init(x: Int) {} }': 'initializer',
            'public struct Unreferenced {}': 'not reached',
            'public struct NewFeature {}\n@objc class Bridge: NSObject {}': 'runtime lookup',
            'public struct NewFeature {}\nnonisolated func newFeatureHelper() {}': 'unrecognized top-level',
        }
        for text, reason in cases.items():
            with self.subTest(reason=reason):
                self.write(new, text)
                plan = self.plan(mapped, new, impact_map=measured)
                self.assertEqual(plan['group_fallback_paths'], [new])
                self.assertIn(reason, plan['fallback_reasons'][new])
                self.assertEqual(len(plan['test_targets']), 7)
        # A name an unchanged file already uses may be an overload or a move.
        self.write(new, 'public struct NewFeature {}')
        self.write('Sources/ChecklistCore/Unchanged.swift', 'let other = NewFeature()')
        plan = self.plan(mapped, new, impact_map=measured)
        self.assertIn('reuses names in unchanged files: NewFeature', plan['fallback_reasons'][new])

    def test_every_fallback_names_its_reason(self):
        plan = self.plan('Package.swift', 'script/build_app.sh', 'unknown.bin', '../outside', 'Sources/ChecklistCore/Store.swift')
        self.assertEqual(set(plan['fallback_reasons']), set(plan['fallback_paths'] + plan['group_fallback_paths']))
        self.assertEqual(plan['fallback_reasons']['Package.swift'], 'package manifest or lockfile')
        self.assertEqual(plan['fallback_reasons']['script/build_app.sh'], 'build script')
        self.assertIn('no current coverage map', plan['fallback_reasons']['Sources/ChecklistCore/Store.swift'])

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
        self.assertIn('HumanClaimsKeychainTests', plan['swift_commands'][0])

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
        (self.root / 'scripts/test_test_impact_map.py').touch()
        for path, expected in [('script/test_instances.py', 'scripts/test_test_instances.py'),
                               ('script/affected_tests.py', 'scripts/test_affected_tests.py'),
                               ('scripts/test_affected_tests.py', 'scripts/test_affected_tests.py'),
                               ('scripts/prepare-public-source.py', 'scripts/test_prepare_public_source.py'),
                               ('scripts/public_source_privacy.py', 'scripts/test_prepare_public_source.py'),
                               ('script/verify_install.py', 'scripts/test_test_instances.py'),
                               ('script/index_store.py', 'scripts/test_test_impact_map.py')]:
            with self.subTest(path=path):
                plan = self.plan(path)
                self.assertEqual(plan['python_tests'], sorted([expected] + (
                    ['scripts/test_shared_test_impact.py', 'scripts/test_auto_impact_map.py'] if path == 'script/index_store.py' else [])))
                self.assertFalse(plan['swift_commands'])

    def test_executable_defaults_have_timing_guard_but_qualification_keeps_its_budget(self):
        plan = self.plan('Sources/ChecklistCore/NativeOutcomeRecorder.swift')
        defaults = plan['default_swift_commands']
        guarded = plan['guarded_default_commands']
        self.assertEqual(len(defaults), len(guarded))
        for raw, command in zip(defaults, guarded):
            self.assertEqual(command[:3], ['python3', 'script/check_test_timings.py', 'run'])
            self.assertEqual(command[-len(raw):], raw)
            self.assertIn(command, plan['commands'])
            self.assertNotIn(raw, plan['commands'])
        for command in plan['qualification_commands'] + plan['timing_commands']:
            self.assertIn(command, plan['commands'])
            self.assertNotIn('script/check_test_timings.py', command)
        for command in plan['swift_commands']:
            if 'swift' in command:
                self.assertIn('--skip-update', command)

    def test_round_and_full_use_the_same_pinned_python(self):
        prefix = ['uv', 'run', '--no-project', '--python', '3.12',
                  '--with', 'jsonschema', '--with', 'pyyaml', 'python']
        for full in [False, True]:
            with self.subTest(full=full):
                plan = self.plan('scripts/test_test_instances.py', full=full)
                commands = [command for command in plan['commands'] if command not in plan['swift_commands'] and command not in plan['guarded_default_commands']]
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

    def test_changed_qualification_fixture_selects_its_case(self):
        path = self.root / 'Tests/ChecklistCoreTests/MediaDecisionTests.swift'
        path.parent.mkdir(parents=True)
        method = 'test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal'
        path.write_text('func ' + method + '() throws {\n try QualificationSuite.requireEnabled()\n}')
        plan = self.plan(path.relative_to(self.root).as_posix())
        self.assertIn('ChecklistCoreTests.MediaDecisionTests/' + method, plan['qualification_tests'])
        self.assertTrue(plan['qualification_deferred'])
        self.assertEqual(plan['qualification_commands'], [])

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

    def test_ipc_timing_qualification_follows_ipc_source(self):
        plan = self.plan('Sources/ChecklistIPC/ChecklistClient.swift')
        self.assertIn('ChecklistIPCTests.LongCommandTests/testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient', plan['qualification_tests'])
        self.assertTrue(plan['qualification_deferred'])
        self.assertEqual(plan['qualification_commands'], [])

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

    def assert_case_deferred(self, plan, case):
        self.assertIn(case, plan['qualification_tests'])
        self.assertTrue(plan['qualification_deferred'])
        self.assertEqual(plan['qualification_execution_tests'], [])
        self.assertEqual(plan['qualification_commands'], [])
        self.assertFalse(plan['qualification'])
        self.assertIn(case, plan['skip'])

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
        # Its changed source retains candidates but cannot opt itself in.
        path = self.root / 'Tests/ChecklistCoreTests/StorageCompactManifestTests.swift'
        path.parent.mkdir(parents=True)
        path.write_text('final class StorageCompactManifestTests: XCTestCase { func ' + case.split('/')[1] + '() throws {} }')
        self.assert_case_deferred(self.plan(path.relative_to(self.root).as_posix()), case)
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
        self.assert_case_deferred(self.plan(path.relative_to(self.root).as_posix()), case)
        self.assert_case_deferred(self.plan('Sources/ChecklistCore/WorkspacePageRead.swift'), case)

    def test_manifest_production_change_defers_real_size_qualification(self):
        case, = selector.REAL_SIZE_TESTS
        plan = self.plan('Sources/ChecklistCore/StorageCompactManifest.swift')
        self.assertFalse(plan['qualification'])
        self.assertIn(case, plan['qualification_tests'])
        self.assertIn(case, plan['skip'])
        self.assert_case_deferred(plan, case)
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
            self.assertTrue(changed['timing_deferred'])
            self.assertEqual(changed['timing_commands'], [])
            qualified = self.plan(path, qualification=True)
            for case in expected:
                if '.HumanClaimsKeychainTests/' not in case:
                    self.assert_case_runs(qualified, case, 'timing_commands')

    def test_full_qualification_mode_is_explicit_or_last_round_and_not_target_limited(self):
        for options, mode in [({'qualification': True}, 'requested-full'),
                              ({'last_round': True}, 'pass-final-round')]:
            plan = self.plan('README.md', **options)
            self.assertEqual(plan['qualification_mode'], mode)
            self.assertEqual(plan['qualification_tests'], list(selector.QUALIFICATION_CASES))
            self.assertEqual(plan['default_swift_commands'], [])
            if options.get('last_round'):
                self.assertEqual(plan['swift_commands'], [])
                self.assertEqual(plan['qualification_commands'], [])
                self.assertEqual(len(plan['coverage_refresh_commands']), 1)
                self.assertIn('script/test_impact_map.py', plan['coverage_refresh_commands'][0])
                self.assertIn(plan['coverage_refresh_commands'][0], plan['commands'])
            else:
                self.assertEqual(plan['coverage_refresh_commands'], [])
                for case in selector.QUALIFICATION_CASES:
                    self.assert_case_runs(plan, case)
        self.assertEqual(self.plan(full=True)['qualification_mode'], 'full-default')

    def test_unmapped_source_falls_back_to_module_closure_and_reports_path(self):
        path = 'Sources/ChecklistCore/NewHelper.swift'
        plan = self.plan(path)
        self.assertEqual(plan['group_fallback_paths'], [path])
        self.assertEqual(len(plan['test_targets']), 7)
        self.assertEqual(plan['test_groups'], {})

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

    def test_wall_clock_scanner_tracks_local_tuple_timers_and_sample_aggregates(self):
        directory = self.root / 'Tests/ChecklistCoreTests'
        directory.mkdir(parents=True)
        (directory / 'BudgetTests.swift').write_text('''final class BudgetTests: XCTestCase {
    private let json = #"} } }"#
    // } } fake closing braces in a comment
    /* } } /* nested { */ } */
    func testTupleSamples() throws {
        func time<T>(_ work: () throws -> T) rethrows -> (T, Double) {
            let start = Date()
            let value = try work()
            return (value, Date().timeIntervalSince(start))
        }
        var samples: [Double] = []
        for _ in 0..<5 {
            let (value, sample) = try time { 17 }
            XCTAssertEqual(value, 17)
            samples.append(sample)
        }
        let peak = samples.max() ?? 0
        XCTAssertLessThan(peak, 1.0)
    }
    func testScalarTimerAndReduce() {
        func measure() -> Double {
            let begin = ProcessInfo.processInfo.systemUptime
            return ProcessInfo.processInfo.systemUptime - begin
        }
        let samples = [measure(), measure()]
        let peak = samples.reduce(0, max)
        XCTAssertTrue(peak <= 1)
    }
    func testTupleProjection() {
        func sample() -> (Int, Double) { return (17, Date().timeIntervalSince(start)) }
        let observation = sample()
        XCTAssertLessThan(observation.1, 2)
    }
    private func reading() -> Double {
        let begin = ProcessInfo.processInfo.systemUptime
        let end = ProcessInfo.processInfo.systemUptime
        return end - begin
    }
    func testSameFileTimer() {
        let readings = [reading(), reading()]
        XCTAssertLessThan(readings.max() ?? 0, 3)
    }
    func testTupleResultCountIsNotTiming() {
        func time<T>(_ work: () -> T) -> (T, Double) {
            return (work(), Date().timeIntervalSince(start))
        }
        let (count, sample) = time { 17 }
        XCTAssertLessThan(count, 20)
    }
}
''')
        cases = selector.wall_clock_budget_cases(self.root)
        self.assertEqual(sorted(cases), ['ChecklistCoreTests.BudgetTests/' + name for name in
                                        ['testSameFileTimer', 'testScalarTimerAndReduce', 'testTupleProjection', 'testTupleSamples']])

    def test_wall_clock_scanner_tracks_multiple_bindings_without_tainting_counts(self):
        directory = self.root / 'Tests/ChecklistCoreTests'
        directory.mkdir(parents=True)
        (directory / 'BindingBudgetTests.swift').write_text('''final class BindingBudgetTests: XCTestCase {
    func testCommaClockAlias() {
        let end = ProcessInfo.processInfo.systemUptime, after = end - scanEnd
        XCTAssertLessThan(after, before)
    }
    func testCommaChainAliases() {
        let mark = DispatchTime.now().uptimeNanoseconds, delta = mark - start, peak = delta
        XCTAssertTrue(peak < 300)
    }
    func testTypedContinuedBindingsAndSamples() {
        let mark: Double = ProcessInfo.processInfo.systemUptime,
            span: Double = mark - start
        let samples: [Double] = [span], high = samples.max() ?? 0
        XCTAssertLessThan(high, 2)
    }
    func testTupleAndCommaBindings() {
        func time() -> (Int, Double) { return (3, Date().timeIntervalSince(start)) }
        let (value, tick) = time(), cap = tick * 2, count = value + 1
        XCTAssertLessThan(cap, 3)
    }
    func testCountsStayUntimed() {
        let pages = 2, after = pages + 1, before = 5
        XCTAssertLessThan(after, before)
    }
    func testClockAndCountStaySeparate() {
        let mark = ProcessInfo.processInfo.systemUptime, count = 3, next = count + 1
        XCTAssertLessThan(next, 5)
    }
    func testArgumentStringTupleAndGenericCommasStayUntimed() {
        let text = "bad, alias = ProcessInfo.processInfo.systemUptime", pair = (2, 3), next = pair.0 + 1
        let count = min(2, 3), last = count + 1
        let counts: Dictionary<String, Int> = ["page": 2], total = counts["page"]! + 1
        XCTAssertLessThan(next, 5)
        XCTAssertLessThan(last, 5)
        XCTAssertLessThan(total, 5)
    }
    func testTupleResultCountStaysUntimed() {
        func time() -> (Int, Double) { return (3, Date().timeIntervalSince(start)) }
        let (value, tick) = time(), count = value + 1
        XCTAssertLessThan(count, 5)
    }
}
''')
        self.assertEqual(sorted(selector.wall_clock_budget_cases(self.root)),
                         ['ChecklistCoreTests.BindingBudgetTests/' + name for name in
                          ['testCommaChainAliases', 'testCommaClockAlias', 'testTupleAndCommaBindings',
                           'testTypedContinuedBindingsAndSamples']])

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
        registered = [name.split('/')[1] for name in selector.QUALIFICATION_CASES]
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

    def test_graph_includes_shared_products_paths_and_cached_descriptions(self):
        (self.root / 'Package.swift').write_text('root')
        manifest = self.root / 'Packages/ChecklistShared/Package.swift'
        manifest.parent.mkdir(parents=True)
        manifest.write_text('shared')
        root = {'targets': [dict(target('ChecklistIPC'), product_dependencies=['PublicContracts'])]}
        shared = {'products': [{'name': 'PublicContracts', 'targets': ['ChecklistContracts']}],
                  'targets': [target('ChecklistContracts'), target('ChecklistSharedTests', ['ChecklistContracts'], 'test')]}
        with patch.object(selector.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, json.dumps(root)),
                subprocess.CompletedProcess([], 0, json.dumps(shared))]) as run:
            graph = selector.package_graph(self.root, self.root / '.build')
            self.assertEqual(graph['targets'][0]['target_dependencies'], ['ChecklistContracts'])
            self.assertEqual(graph['targets'][1]['path'], 'Packages/ChecklistShared/Sources/ChecklistContracts')
            self.assertEqual(graph['targets'][2]['package_path'], 'Packages/ChecklistShared')
            self.assertEqual(selector.package_graph(self.root, self.root / '.build'), graph)
            self.assertEqual(run.call_count, 2)
            command = run.call_args_list[1].args[0]
            self.assertEqual(command[command.index('--package-path') + 1], str(manifest.parent))
            self.assertEqual(command[command.index('--scratch-path') + 1],
                             str(self.root / '.build/packages/ChecklistShared'))

    def test_nested_package_manifest_changes_invalidate_graph_cache(self):
        (self.root / 'Package.swift').write_text('root package')
        manifest = self.root / 'Packages/Nested/Package.swift'
        manifest.parent.mkdir(parents=True)
        manifest.write_text('first nested package')
        with patch.object(selector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(GRAPH))) as run:
            selector.package_graph(self.root, self.root / '.build')
            selector.package_graph(self.root, self.root / '.build')
            self.assertEqual(run.call_count, 1)
            manifest.write_text('second nested package')
            selector.package_graph(self.root, self.root / '.build')
            self.assertEqual(run.call_count, 2)
            manifest.unlink()
            selector.package_graph(self.root, self.root / '.build')
            self.assertEqual(run.call_count, 3)

    def test_loader_requires_nonempty_index_edges_for_skipped_inventory(self):
        from datetime import datetime, timezone
        measured = self.measured_map({'Sources/ChecklistCore/HumanClaims.swift': {
            'classes': [], 'qualification_cases': []}})
        measured.update(generated_at=datetime.now(timezone.utc).isoformat(),
                        measured_qualification_cases=list(selector.QUALIFICATION_CASES),
                        qualification_case_inventory=list(selector.QUALIFICATION_CASES),
                        class_inventory=['ChecklistAppTests.ForbiddenTests'])
        map_path = self.root / 'coverage.json'
        with patch.object(selector, 'changed_paths', return_value=[]), patch.object(selector.subprocess, 'run'):
            map_path.write_text(json.dumps(measured))
            self.assertIsNone(selector.load_impact_map(self.root, map_path)[0])
            measured['coverage_unmeasurable_classes'] = {
                'ChecklistAppTests.ForbiddenTests': {'reason': 'Owner forbids keychain',
                    'sources': ['Sources/ChecklistCore/HumanClaims.swift'],
                    'source': 'index-store', 'walk': {'complete': True, 'nodes': 1, 'edges': 0, 'seconds': 0.0}}}
            map_path.write_text(json.dumps(measured))
            loaded, status = selector.load_impact_map(self.root, map_path)
            self.assertIsNotNone(loaded)
            self.assertEqual(loaded['measured_classes'], [])
            self.assertEqual(status['unmeasured_classes'], ['ChecklistAppTests.ForbiddenTests'])
            observation = measured['coverage_unmeasurable_classes']['ChecklistAppTests.ForbiddenTests']
            # A legacy depth-cut map must fall back even when labeled complete.
            walk = observation.pop('walk')
            observation['max_depth'] = 5
            map_path.write_text(json.dumps(measured))
            loaded, status = selector.load_impact_map(self.root, map_path)
            self.assertIsNone(loaded)
            self.assertEqual(status['state'], 'fallback')
            self.assertIn('complete fixed-point walk', status['reason'])
            del observation['max_depth']
            observation['walk'] = walk
            for field, invalid in [('source', None), ('source', 'static-reference'),
                                   ('source', 'coverage'), ('source', 'index'),
                                   ('walk', None), ('walk', {}), ('walk', {'complete': False}),
                                   ('walk', {'complete': 1}),
                                   ('sources', []), ('sources', None),
                                   ('sources', ['../Sources/Escape.swift']),
                                   ('sources', ['/Sources/Absolute.swift']),
                                   ('sources', ['Sources/../Escape.swift']),
                                   ('sources', ['Sources/./Unnormalized.swift']),
                                   ('sources', ['Sources\\Escape.swift']),
                                   ('sources', ['Sources/ChecklistCore/AbsentFromInventory.swift']),
                                   ('sources', ['']), ('sources', ['docs/file.md'])]:
                with self.subTest(field=field, invalid=invalid):
                    original = observation[field]
                    observation[field] = invalid
                    map_path.write_text(json.dumps(measured))
                    self.assertIsNone(selector.load_impact_map(self.root, map_path)[0])
                    observation[field] = original
            measured['measured_qualification_cases'].pop()
            map_path.write_text(json.dumps(measured))
            self.assertIsNone(selector.load_impact_map(self.root, map_path)[0])

    def test_runtime_fixture_change_invalidates_observed_coverage(self):
        from datetime import datetime, timezone
        measured = self.measured_map({})
        measured.update(generated_at=datetime.now(timezone.utc).isoformat(),
                        measured_qualification_cases=list(selector.QUALIFICATION_CASES))
        map_path = self.root / 'coverage.json'
        map_path.write_text(json.dumps(measured))
        for path in ['Sources/ChecklistApp/Assets/catalog.json', 'Tests/Fixtures/unnamed.json']:
            with self.subTest(path=path), patch.object(selector, 'changed_paths', return_value=[path]), \
                    patch.object(selector.subprocess, 'run'):
                mapping, status = selector.load_impact_map(self.root, map_path)
                self.assertIsNone(mapping)
                self.assertIn(path, status['reason'])
        # A runtime input with named readers keeps the map; its readers are selected directly.
        with patch.object(selector, 'changed_paths', return_value=['examples/media-intake.json']), \
                patch.object(selector.subprocess, 'run'):
            mapping, status = selector.load_impact_map(self.root, map_path)
            self.assertIsNotNone(mapping)
            self.assertEqual(status['changed_test_inputs'], ['examples/media-intake.json'])

    def test_nested_package_build_and_test_inputs_invalidate_coverage(self):
        from datetime import datetime, timezone
        measured = self.measured_map({})
        measured.update(generated_at=datetime.now(timezone.utc).isoformat(),
                        measured_qualification_cases=list(selector.QUALIFICATION_CASES))
        map_path = self.root / 'coverage.json'
        map_path.write_text(json.dumps(measured))
        for path in ['Packages/Runtime/Package.swift', 'Packages/Runtime/Package.resolved',
                     'Packages/Runtime/Tests/RuntimeTests/Fixture.swift']:
            with self.subTest(path=path), patch.object(selector, 'changed_paths', return_value=[path]), \
                 patch.object(selector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
                loaded, status = selector.load_impact_map(self.root, map_path)
                self.assertIsNone(loaded)
                self.assertIn(path, status['reason'])
        with patch.object(selector, 'changed_paths', return_value=['Packages/Runtime/Sources/Runtime/File.swift']), \
             patch.object(selector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            self.assertIsNotNone(selector.load_impact_map(self.root, map_path)[0])

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
        # These audit package/resource fallback, independently of an ignored
        # machine-local coverage cache. Generated-map tests use synthetic exports.
        cls.coverage_patch = patch.object(selector, 'load_impact_map',
            return_value=(None, {'state': 'graph-audit-fixture'}))
        cls.coverage_patch.start()
        cls.addClassCleanup(cls.coverage_patch.stop)
        # Reuse the assigned persistent slot when present. This describes the
        # actual package; it never builds Swift or runs the application.
        cls.scratch = cls.root.parent / '.build'
        if not cls.scratch.is_dir():
            cls.scratch = cls.root / '.build'
        cls.graph = selector.package_graph(cls.root, cls.scratch)
        cls.targets = sorted(cls.graph['targets'], key=lambda t: len(t['path']), reverse=True)

    def owner(self, path):
        return next(t for t in self.targets if path.startswith(t['path'] + '/'))

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
