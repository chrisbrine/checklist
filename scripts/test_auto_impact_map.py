#!/usr/bin/env python3
"""Automatic local impact-map recovery uses synthetic index data; no Swift runs."""
from contextlib import redirect_stdout
import io
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import auto_impact_map as auto
import affected_tests as selector


class AutoImpactMapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scratch = self.root / '.build'
        self.output = self.root / '.local/build/test-impact-map.json'
        self.index = self.scratch / 'affected-tests/index-export.json'
        self.case = 'ChecklistCoreTests.CoreTests/testValue'
        self.cases = (self.case,)
        self.write('Package.swift', '// synthetic package')
        self.write('Sources/ChecklistCore/Value.swift', 'struct Value {}')
        self.write('Sources/ChecklistApp/View.swift', 'struct View {}')
        self.write('Tests/ChecklistCoreTests/CoreTests.swift',
                   'final class CoreTests: XCTestCase { func testValue() { Value() } }')
        self.write('Tests/ChecklistAppTests/ViewTests.swift',
                   'final class ViewTests: XCTestCase { func testValue() { View() } }')
        self.rows = [self.row('Sources/ChecklistCore/Value.swift', 'value', 'Value'),
                     self.row('Sources/ChecklistApp/View.swift', 'view', 'View')]
        for target, cls, usr in [('ChecklistCoreTests', 'CoreTests', 'value'),
                                 ('ChecklistAppTests', 'ViewTests', 'view')]:
            path = f'Tests/{target}/{cls}.swift'
            self.rows += [self.row(path, cls, cls, kind=7), self.row(path, usr, usr, roles=36)]
        self.export = {'schema_version': 1, 'source': 'index-store', 'occurrences': self.rows,
                       'source_hashes': {path: auto.digest(self.root / path) for path in auto.source_inventory(self.root)},
                       'build_inputs': auto.build_inputs(self.root)}
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Synthetic', '-c', 'user.email=test@example.invalid',
                        'add', '.'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Synthetic', '-c', 'user.email=test@example.invalid',
                        'commit', '-qm', 'baseline'], cwd=self.root, check=True)

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def row(self, file, usr, name, kind=6, roles=2, relations=()):
        return dict(file=file, usr=usr, name=name, kind=kind, roles=roles, relations=list(relations))

    def save_index(self):
        auto.atomic_json(self.index, self.export)

    def test_missing_map_is_regenerated_into_class_groups_without_execution_claims(self):
        self.save_index()
        result = auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.assertEqual(result['state'], 'regenerated')
        data = json.loads(self.output.read_text())
        self.assertEqual(data['schema_version'], 2)
        self.assertEqual(data['selection_source'], 'index-store')
        self.assertEqual(data['measured_classes'], [])
        self.assertEqual(data['measured_qualification_cases'], [])
        self.assertEqual(data['sources']['Sources/ChecklistCore/Value.swift'],
                         {'classes': ['ChecklistCoreTests.CoreTests'], 'qualification_cases': [self.case]})
        self.assertEqual(data['sources']['Sources/ChecklistApp/View.swift']['classes'], ['ChecklistAppTests.ViewTests'])
        with patch.object(selector, 'QUALIFICATION_CASES', self.cases):
            loaded, status = selector.load_impact_map(self.root, self.output)
        self.assertIsNotNone(loaded, status)
        self.assertEqual(status['source'], 'index-store')
        self.assertEqual(json.loads((self.scratch / 'affected-tests/test-impact-map.json').read_text()), data)

    def test_cli_automatically_regenerates_and_selects_classes_for_three_change_types(self):
        self.save_index()
        graph = {'targets': [
            {'name': 'ChecklistCore', 'type': 'library', 'path': 'Sources/ChecklistCore'},
            {'name': 'ChecklistApp', 'type': 'executable', 'path': 'Sources/ChecklistApp'},
            {'name': 'ChecklistCoreTests', 'type': 'test', 'path': 'Tests/ChecklistCoreTests',
             'target_dependencies': ['ChecklistCore']},
            {'name': 'ChecklistAppTests', 'type': 'test', 'path': 'Tests/ChecklistAppTests',
             'target_dependencies': ['ChecklistApp']}]}
        for path, target, cls in [('Sources/ChecklistCore/Value.swift', 'ChecklistCoreTests', 'CoreTests'),
                                  ('Sources/ChecklistApp/View.swift', 'ChecklistAppTests', 'ViewTests'),
                                  ('Tests/ChecklistCoreTests/CoreTests.swift', 'ChecklistCoreTests', 'CoreTests')]:
            with self.subTest(path=path):
                output = io.StringIO()
                with patch.object(selector, 'QUALIFICATION_CASES', self.cases), \
                     patch.object(selector, 'package_graph', return_value=graph), redirect_stdout(output):
                    selector.main(['--root', str(self.root), '--scratch-path', str(self.scratch),
                                   '--paths', path, '--json'])
                plan = json.loads(output.getvalue())
                self.assertEqual(plan['test_groups'], {target: [cls]})
                self.assertEqual(plan['group_fallback_paths'], [])
                self.assertEqual(plan['fallback_paths'], [])
                self.assertEqual(plan['impact_map_status']['source'], 'index-store')

    def test_package_manifests_and_separate_package_tests_are_not_root_index_records(self):
        manifest = 'Packages/ChecklistShared/Package.swift'
        source = 'Packages/ChecklistShared/Sources/ChecklistDomain/Package.swift'
        test = 'Packages/ChecklistShared/Tests/ChecklistSharedTests/BoundaryTests.swift'
        self.write(manifest, '// actual nested package manifest layout')
        self.write(source, 'struct DomainValue {}')
        self.write(test, 'final class BoundaryTests: XCTestCase {}')
        inventory = auto.source_inventory(self.root)
        self.assertNotIn(manifest, inventory)
        self.assertIn(source, inventory)
        self.assertIn(test, inventory)
        self.assertIn(source, auto.root_index_inventory(self.root))
        self.assertNotIn(test, auto.root_index_inventory(self.root))
        self.assertIn(manifest, auto.build_inputs(self.root))
        self.assertIn(test, auto.compiler_inputs(self.root))
        export = dict(self.export,
                      source_hashes=dict(self.export['source_hashes'], **{source: auto.digest(self.root / source)}),
                      build_inputs=auto.build_inputs(self.root),
                      occurrences=self.rows + [self.row(source, 'domain', 'DomainValue')])
        data = auto.build_index_map(self.root, export, self.cases)
        self.assertTrue(data['complete'])
        self.assertEqual(data['selection_source'], 'index-store')
        self.write(manifest, '// changed nested manifest')
        with self.assertRaisesRegex(ValueError, 'manifest inputs'):
            auto.validate_inputs(self.root, export)
        self.write(manifest, '// actual nested package manifest layout')
        # Real shared Sources remain mandatory; only the manifest/test distinction
        # is relaxed, never unknown target source files.
        self.write('Packages/ChecklistShared/Sources/ChecklistDomain/Missing.swift', 'struct Missing {}')
        with self.assertRaisesRegex(ValueError, 'index export missing current source'):
            auto.build_index_map(self.root, export, self.cases)

    def test_complete_retained_map_restores_missing_checkout_copy(self):
        self.save_index()
        auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.output.unlink()
        self.index.unlink()
        with patch.object(selector, 'QUALIFICATION_CASES', self.cases):
            result = auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.assertEqual(result['state'], 'restored')
        self.assertTrue(self.output.is_file())

    def test_stale_map_is_rebuilt_from_index_without_renewing_coverage(self):
        self.save_index()
        auto.regenerate(self.root, self.scratch, self.output, self.cases)
        for file in [self.output, self.scratch / 'affected-tests/test-impact-map.json']:
            data = json.loads(file.read_text())
            data['generated_at'] = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
            auto.atomic_json(file, data)
        result = auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.assertEqual(result['state'], 'regenerated')
        self.assertEqual(json.loads(self.output.read_text())['measured_classes'], [])

    def test_unrelated_source_drift_refuses_regeneration_and_preserves_existing_map(self):
        self.save_index()
        self.write('Sources/ChecklistCore/Value.swift', 'changed')
        self.write('.local/build/test-impact-map.json', 'existing incompatible receipt')
        result = auto.regenerate(self.root, self.scratch, self.output, self.cases,
                                 ['Sources/ChecklistApp/View.swift'])
        self.assertEqual(result['state'], 'unavailable')
        self.assertIn('source inputs differ', result['reason'])
        self.assertEqual(self.output.read_text(), 'existing incompatible receipt')

    def test_selected_existing_production_shape_change_refuses_static_edges(self):
        self.save_index()
        auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.write('Sources/ChecklistCore/Value.swift',
                   'struct Value {}\nextension View: CustomStringConvertible { var description: String { "changed" } }')
        with self.assertRaisesRegex(ValueError, 'source inputs differ'):
            auto.build_index_map(self.root, self.export, self.cases, ['Sources/ChecklistCore/Value.swift'])
        with patch.object(selector, 'QUALIFICATION_CASES', self.cases):
            data, status = selector.load_impact_map(self.root, self.output,
                                                   selected_paths=['Sources/ChecklistCore/Value.swift'])
        self.assertIsNone(data)
        self.assertIn('source inputs differ', status['reason'])

    def test_changed_manifest_and_legacy_export_without_manifest_receipt_are_refused(self):
        for edit in ('missing', 'changed'):
            with self.subTest(edit=edit):
                export = dict(self.export)
                if edit == 'missing':
                    del export['build_inputs']
                else:
                    self.write('Package.swift', 'changed manifest')
                with self.assertRaisesRegex(ValueError, 'manifest inputs'):
                    auto.build_index_map(self.root, export, self.cases)

    def test_missing_current_class_or_occurrence_hash_cannot_close_inventory(self):
        for edit in ('class', 'hash'):
            with self.subTest(edit=edit):
                export = json.loads(json.dumps(self.export))
                if edit == 'class':
                    export['occurrences'] = [row for row in self.rows if row['name'] != 'CoreTests']
                else:
                    del export['source_hashes']['Tests/ChecklistCoreTests/CoreTests.swift']
                with self.assertRaises(ValueError):
                    auto.build_index_map(self.root, export, self.cases)

    def test_raw_index_recovery_retains_original_hashes_and_requires_unchanged_store(self):
        store = self.root / 'raw-index'
        store.mkdir()
        (store / 'unit').write_text('compiled index')
        exported = dict(self.export, store=str(store), library='synthetic-library')
        self.index.parent.mkdir(parents=True, exist_ok=True)
        auto.save_index_receipt(self.index, exported)
        receipt = self.index.with_name('index-inputs.json')
        self.write('Tests/ChecklistCoreTests/CoreTests.swift', 'requested changed test source')
        reread = dict(self.export, source_hashes={'incorrect': 'read-time hashes'})
        with patch('index_store.read_index_store', return_value=reread) as reader:
            recovered = auto.recover_raw_index(self.root, receipt, ['Tests/ChecklistCoreTests/CoreTests.swift'])
        reader.assert_called_once()
        self.assertEqual(recovered['source_hashes'], self.export['source_hashes'])
        (store / 'unit').write_text('replacement index')
        with patch('index_store.read_index_store') as reader, self.assertRaisesRegex(ValueError, 'raw index changed'):
            auto.recover_raw_index(self.root, receipt, ['Tests/ChecklistCoreTests/CoreTests.swift'])
        reader.assert_not_called()

    def test_missing_portable_export_recovers_raw_receipt_before_regenerating(self):
        store = self.root / 'raw-index'
        store.mkdir()
        (store / 'unit').write_text('compiled index')
        self.index.parent.mkdir(parents=True, exist_ok=True)
        exported = dict(self.export, store=str(store), library='synthetic-library')
        auto.save_index_receipt(self.index, exported)
        with patch('index_store.read_index_store', return_value=self.export):
            result = auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.assertEqual(result['state'], 'regenerated')
        self.assertTrue(self.index.is_file())
        self.assertTrue(self.output.is_file())

    def test_static_loader_refuses_unselected_test_drift_and_invalidates_changed_generator(self):
        self.save_index()
        auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.write('Tests/ChecklistCoreTests/CoreTests.swift',
                   'final class CoreTests: XCTestCase { func testValue() { View() } }')
        with patch.object(selector, 'QUALIFICATION_CASES', self.cases):
            data, status = selector.load_impact_map(self.root, self.output,
                                                   selected_paths=['Sources/ChecklistApp/View.swift'])
            self.assertIsNone(data)
            self.assertIn('source inputs differ', status['reason'])
            data, status = selector.load_impact_map(self.root, self.output,
                                                   selected_paths=['Tests/ChecklistCoreTests/CoreTests.swift'])
            self.assertIsNotNone(data, status)
            self.write('script/auto_impact_map.py', '# changed generator')
            data, status = selector.load_impact_map(self.root, self.output,
                                                   selected_paths=['Tests/ChecklistCoreTests/CoreTests.swift'])
            self.assertIsNone(data)
            self.assertIn('invalid static index selection map', status['reason'])

    def test_changed_shared_helper_selects_whole_owner_when_static_consumers_are_stale(self):
        path = self.write('Tests/ChecklistCoreTests/Fixture.swift', 'func makeValue() {}')
        key = path.relative_to(self.root).as_posix()
        data = auto.build_index_map(self.root, dict(self.export,
            source_hashes=dict(self.export['source_hashes'], **{key: auto.digest(path)})), self.cases)
        data['sources'][key] = {'classes': ['ChecklistCoreTests.CoreTests'], 'qualification_cases': []}
        path.write_text('func makeValue() { View() }')
        owner = {'name': 'ChecklistCoreTests', 'type': 'test', 'path': 'Tests/ChecklistCoreTests'}
        result = selector.test_file_selection(self.root, {'ChecklistCoreTests': owner}, owner, key, data, {})
        self.assertEqual(result, {'fallback': 'changed shared test helper has no current indexed consumers'})

    def warm_native_fixture(self):
        self.write('.build/build.db', 'warm native metadata')
        (self.scratch / 'arm64-apple-macosx/debug/Modules').mkdir(parents=True)
        store = self.scratch / 'index-store'
        store.mkdir()
        (store / 'record').write_text('same-build record')
        wrapper = self.write('build-cap.sh', '# synthetic wrapper; never executed')
        exported = dict(self.export, store=str(store), library='synthetic-library')
        return wrapper, exported

    def test_missing_or_stale_export_refreshes_warm_index_through_build_cap_without_tests(self):
        wrapper, exported = self.warm_native_fixture()
        self.save_index()
        self.write('Sources/ChecklistCore/Value.swift', 'struct Value { var changed: Int }')
        exported['source_hashes'] = {path: auto.digest(self.root / path) for path in auto.source_inventory(self.root)}
        with patch.object(auto.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as runner, \
             patch.object(auto.subprocess, 'check_output', return_value='synthetic-commit'), \
             patch('index_store.read_index_store', return_value=exported) as reader:
            result = auto.regenerate(self.root, self.scratch, self.output, self.cases,
                                    ['Sources/ChecklistCore/Value.swift'], runner_wrapper=wrapper)
        self.assertEqual(result['state'], 'regenerated')
        self.assertTrue(result['native_index_refreshed'])
        command = runner.call_args.args[0]
        self.assertEqual(command[:4], ['bash', str(wrapper.resolve()), 'swift', 'build'])
        for flag in ('--skip-update', '--build-tests', '--enable-dependency-cache', '--enable-index-store'):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index('--scratch-path') + 1], str(self.scratch))
        self.assertNotIn('test', command)
        reader.assert_called_once()
        self.assertTrue(self.output.is_file())
        self.assertTrue(self.index.with_name('index-inputs.json').is_file())

    def test_failed_native_refresh_is_loud_and_does_not_retry_unchanged_inputs(self):
        wrapper, _ = self.warm_native_fixture()
        with patch.object(auto.subprocess, 'run', return_value=SimpleNamespace(returncode=8)) as runner:
            first = auto.regenerate(self.root, self.scratch, self.output, self.cases, runner_wrapper=wrapper)
            second = auto.regenerate(self.root, self.scratch, self.output, self.cases, runner_wrapper=wrapper)
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(first['state'], 'unavailable')
        self.assertIn('exit 8', first['reason'])
        self.assertIn('already failed', second['reason'])
        self.assertFalse(self.output.exists())

    def test_repaired_wrapper_can_retry_same_sources_after_recorded_failure(self):
        wrapper, _ = self.warm_native_fixture()
        with patch.object(auto.subprocess, 'run', return_value=SimpleNamespace(returncode=8)) as runner:
            auto.regenerate(self.root, self.scratch, self.output, self.cases, runner_wrapper=wrapper)
            wrapper.write_text('# different repaired build wrapper')
            auto.regenerate(self.root, self.scratch, self.output, self.cases, runner_wrapper=wrapper)
        self.assertEqual(runner.call_count, 2)

    def test_source_change_during_native_export_cannot_publish_current_hashes_on_old_index(self):
        wrapper, exported = self.warm_native_fixture()
        def export_while_editing(*args, **kwargs):
            self.write('Sources/ChecklistCore/Value.swift', 'struct Value { var changed: Int }')
            exported['source_hashes'] = {path: auto.digest(self.root / path)
                                         for path in auto.source_inventory(self.root)}
            return exported
        with patch.object(auto.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), \
             patch('index_store.read_index_store', side_effect=export_while_editing):
            with self.assertRaisesRegex(ValueError, 'changed during native index export'):
                auto.refresh_native_index(self.root, self.scratch, wrapper)
        self.assertFalse(self.index.exists())
        self.assertFalse(self.index.with_name('index-inputs.json').exists())
        self.assertTrue(json.loads(self.index.with_name('index-refresh-status.json').read_text())['failed'])

    def test_cold_native_cache_never_builds(self):
        wrapper = self.write('build-cap.sh', '# never executed')
        with patch.object(auto.subprocess, 'run') as runner:
            with self.assertRaisesRegex(ValueError, 'warm native build cache'):
                auto.refresh_native_index(self.root, self.scratch, wrapper)
        runner.assert_not_called()

    def test_runtime_name_lookup_classes_are_conservative_readers_of_every_source(self):
        self.write('Tests/ChecklistAppTests/ViewTests.swift',
                   'final class ViewTests: XCTestCase { func testValue() { NSSelectorFromString("run") } }')
        export = dict(self.export, source_hashes={path: auto.digest(self.root / path)
                                                for path in auto.source_inventory(self.root)})
        data = auto.build_index_map(self.root, export, self.cases)
        self.assertEqual(data['dynamic_lookup_classes'], ['ChecklistAppTests.ViewTests'])
        self.assertEqual(data['sources']['Sources/ChecklistCore/Value.swift']['classes'],
                         ['ChecklistAppTests.ViewTests', 'ChecklistCoreTests.CoreTests'])
        self.assertEqual(data['measured_classes'], [])

    def test_dynamic_callers_are_precise_and_bounded_by_target_runtime_links(self):
        app = 'Sources/ChecklistApp/View.swift'
        app_test = 'Tests/ChecklistAppTests/ViewTests.swift'
        core_test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        helper = 'Tests/ChecklistAppTests/RuntimeFixture.swift'
        self.write(app, 'struct View { func lookup() { NSSelectorFromString("run") } }')
        self.write(helper, '@objc class RuntimeFixture: NSObject {}')
        rows = self.rows + [
            self.row(app, 'lookup', 'lookup()', kind=16),
            self.row(app, 'NSSelectorFromString', 'NSSelectorFromString(_:)', kind=12, roles=36,
                     relations=[{'usr': 'lookup', 'roles': 73728}]),
            self.row(app, 'equal', '==', kind=16,
                     relations=[{'usr': 'Equatable.equal', 'roles': 2048}]),
            self.row(core_test, 'Equatable.equal', '==', kind=16, roles=36),
            self.row(app_test, 'lookup', 'lookup()', kind=16, roles=36),
            self.row(helper, 'runtime-fixture', 'RuntimeFixture', kind=7)]
        graph = {'targets': [
            {'name': 'ChecklistCore', 'type': 'library', 'path': 'Sources/ChecklistCore'},
            {'name': 'ChecklistApp', 'type': 'executable', 'path': 'Sources/ChecklistApp',
             'target_dependencies': ['ChecklistCore']},
            {'name': 'ChecklistCoreTests', 'type': 'test', 'path': 'Tests/ChecklistCoreTests',
             'target_dependencies': ['ChecklistCore']},
            {'name': 'ChecklistAppTests', 'type': 'test', 'path': 'Tests/ChecklistAppTests',
             'target_dependencies': ['ChecklistApp']}]}
        export = dict(self.export, occurrences=rows,
                      source_hashes={path: auto.digest(self.root / path) for path in auto.source_inventory(self.root)})
        data = auto.build_index_map(self.root, export, self.cases, graph=graph)
        self.assertEqual(data['dynamic_lookup_classes'], ['ChecklistAppTests.ViewTests'])
        self.assertEqual(data['dynamic_scope'], 'target-runtime-links')
        # App runtime lookup cannot load the independent CoreTests bundle.
        self.assertEqual(data['sources'][core_test]['classes'], ['ChecklistCoreTests.CoreTests'])
        # App links Core production and can resolve a same-bundle ObjC fixture.
        self.assertEqual(data['sources']['Sources/ChecklistCore/Value.swift']['classes'],
                         ['ChecklistAppTests.ViewTests', 'ChecklistCoreTests.CoreTests'])
        self.assertEqual(data['sources'][helper]['classes'], ['ChecklistAppTests.ViewTests'])

    def test_lookup_missing_containing_relation_keeps_helper_file_consumers(self):
        helper = 'Tests/ChecklistAppTests/RuntimeHelper.swift'
        self.write(helper, 'func lookupHelper() { NSSelectorFromString("run") }')
        rows = self.rows + [self.row(helper, 'lookup-helper', 'lookupHelper()', kind=12),
                           self.row(helper, 'NSSelectorFromString', 'NSSelectorFromString(_:)', kind=12, roles=36),
                           self.row('Tests/ChecklistAppTests/ViewTests.swift', 'lookup-helper',
                                    'lookupHelper()', kind=12, roles=36)]
        export = dict(self.export, occurrences=rows,
                      source_hashes={path: auto.digest(self.root / path) for path in auto.source_inventory(self.root)})
        data = auto.build_index_map(self.root, export, self.cases)
        self.assertEqual(data['dynamic_lookup_classes'], ['ChecklistAppTests.ViewTests'])
        self.assertIn('ChecklistAppTests.ViewTests', data['sources']['Sources/ChecklistCore/Value.swift']['classes'])
        # One precise occurrence must not erase another opaque lookup in the file.
        rows[-2]['relations'] = [{'usr': '', 'roles': 73728}]
        rows.append(self.row(helper, 'dlsym', 'dlsym(_:_:)', kind=12, roles=36,
                             relations=[{'usr': 'unreachable-helper', 'roles': 73728}]))
        data = auto.build_index_map(self.root, export, self.cases)
        self.assertEqual(data['dynamic_lookup_classes'], ['ChecklistAppTests.ViewTests'])

    def test_malformed_lookup_occurrences_are_rejected_by_index_validation(self):
        for bad in [None, {'name': None}, {'name': 'dlsym', 'roles': 'bad'},
                    {'name': 'dlsym', 'roles': 36, 'relations': [None]}]:
            export = dict(self.export, occurrences=self.rows + [bad])
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                auto.build_index_map(self.root, export, self.cases)

    def test_no_evidence_names_refresh_and_leaves_module_fallback(self):
        result = auto.regenerate(self.root, self.scratch, self.output, self.cases)
        self.assertEqual(result['state'], 'unavailable')
        self.assertIn('script/index_store.py', result['refresh'])
        self.assertFalse(self.output.exists())

    def test_unsafe_hash_paths_and_invalid_digests_are_refused(self):
        for path, value in [('../escape.swift', '0' * 64), ('Sources/ChecklistCore/Value.swift', 'bad')]:
            with self.subTest(path=path):
                export = dict(self.export, source_hashes=dict(self.export['source_hashes']))
                export['source_hashes'][path] = value
                with self.assertRaisesRegex(ValueError, 'invalid index source hash'):
                    auto.build_index_map(self.root, export, self.cases)


if __name__ == '__main__':
    unittest.main()
