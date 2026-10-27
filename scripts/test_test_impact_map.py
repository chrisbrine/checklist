"""Coverage mapping tests use synthetic LLVM/index exports, never Swift or live stores."""
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import ANY, patch

SPEC = importlib.util.spec_from_file_location('test_impact_map', Path(__file__).resolve().parents[1] / 'script/test_impact_map.py')
impact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(impact)
import index_store


class CoverageMapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for relative in ['Sources/ChecklistCore/Used.swift', 'Sources/ChecklistCore/Unused.swift',
                         'Sources/ChecklistApp/View.swift', 'Tests/ChecklistCoreTests/CoreTests.swift']:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)

    def export(self, files=(), functions=()):
        return {'type': 'llvm.coverage.json.export', 'version': '2.0.1',
                'data': [{'files': list(files), 'functions': list(functions)}]}

    def test_export_counts_only_executed_repository_source_regions(self):
        payload = self.export(files=[
            {'filename': str(self.root / 'Sources/ChecklistCore/Used.swift'),
             'segments': [[1, 1, 2, True, True, False]]},
            {'filename': 'Sources/ChecklistCore/Unused.swift',
             'segments': [[1, 1, 0, True, True, False]]},
            {'filename': 'Sources/ChecklistApp/View.swift',
             'segments': [[1, 1, 3, True, True, True], [2, 1, 3, False, False, False]]},
            {'filename': str(self.root / 'Tests/ChecklistCoreTests/CoreTests.swift'),
             'segments': [[1, 1, 3, True, True, False]]},
            {'filename': str(self.root.parent / 'Sources/External.swift'),
             'segments': [[1, 1, 3, True, True, False]]},
        ])
        self.assertEqual(impact.parse_coverage_export(json.dumps(payload), self.root),
                         {'Sources/ChecklistCore/Used.swift', 'Tests/ChecklistCoreTests/CoreTests.swift'})

    def test_export_function_regions_support_segment_free_exports(self):
        payload = self.export(functions=[
            {'filenames': ['Sources/ChecklistCore/Used.swift', 'Sources/ChecklistApp/View.swift'],
             'regions': [[1, 1, 2, 1, 0, 0], [2, 1, 3, 1, 4, 1], [3, 1, 4, 1, 4, 9]]}])
        self.assertEqual(impact.parse_coverage_export(payload, self.root), {'Sources/ChecklistApp/View.swift'})

    def test_summary_only_export_and_generated_dependency_exclusion(self):
        payload = self.export(files=[
            {'filename': 'Sources/ChecklistCore/Used.swift', 'summary': {'regions': {'covered': 1}}},
            {'filename': 'Sources/ChecklistCore/Unused.swift', 'summary': {'regions': {'covered': 0}}},
            {'filename': '.build/checkouts/dependency/Sources/File.swift', 'summary': {'lines': {'covered': 5}}},
        ])
        self.assertEqual(impact.parse_coverage_export(payload, self.root), {'Sources/ChecklistCore/Used.swift'})

    def test_build_map_derives_consumers_unions_classes_and_keeps_zero_hits(self):
        used = 'Sources/ChecklistCore/Used.swift'
        view = 'Sources/ChecklistApp/View.swift'
        unused = 'Sources/ChecklistCore/Unused.swift'
        first = impact.parse_coverage_export(self.export(files=[
            {'filename': used, 'segments': [[1, 1, 1, True, True, False]]},
            {'filename': view, 'segments': [[1, 1, 1, True, True, False]]}]), self.root)
        second = impact.parse_coverage_export(self.export(files=[
            {'filename': used, 'segments': [[1, 1, 9, True, True, False]]}]), self.root)
        result = impact.build_map(self.root, [
            {'class': 'ChecklistAppTests.ViewTests', 'sources': first},
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': second},
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': second},
            {'qualification_case': 'ChecklistCoreTests.RealSizeTests/testLarge', 'sources': second},
        ], 'abc123', '2026-10-26T00:00:00+00:00', 1.75, inventory=[used, unused, view])
        self.assertEqual(result['schema_version'], 1)
        self.assertEqual(result['commit'], 'abc123')
        self.assertEqual(result['generated_at'], '2026-10-26T00:00:00+00:00')
        self.assertEqual(result['generation_seconds'], 1.75)
        self.assertFalse(result['complete'], 'only a completed generator run may certify a map')
        self.assertEqual(result['sources'][used], {
            'classes': ['ChecklistAppTests.ViewTests', 'ChecklistCoreTests.CoreTests'],
            'qualification_cases': ['ChecklistCoreTests.RealSizeTests/testLarge']})
        self.assertEqual(result['sources'][unused], {'classes': [], 'qualification_cases': []})
        self.assertEqual(result['sources'][view], {'classes': ['ChecklistAppTests.ViewTests'], 'qualification_cases': []})
        self.assertEqual(result['measured_classes'], ['ChecklistAppTests.ViewTests', 'ChecklistCoreTests.CoreTests'])
        self.assertEqual(result['measured_qualification_cases'], ['ChecklistCoreTests.RealSizeTests/testLarge'])
        self.assertEqual(result['source_hashes'][used], hashlib.sha256((self.root / used).read_bytes()).hexdigest())
        json.dumps(result)  # Persisted maps must remain JSON serializable.

    def test_inspection_references_expand_literal_files_trees_and_extensions(self):
        directory = self.root / 'Tests/ChecklistCoreTests'
        (directory / 'CoreTests.swift').write_text(
            'final class CoreTests: XCTestCase { let input = "Sources/ChecklistCore/Used.swift" }')
        (directory / 'CoreExtension.swift').write_text(
            'extension CoreTests { let tree = "Sources/ChecklistApp" }')
        (directory / 'OtherTests.swift').write_text(
            'final class OtherTests: XCTestCase { let input = "Sources/ChecklistCore/Unused.swift" }')
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.CoreTests'),
                         {'Sources/ChecklistCore/Used.swift', 'Sources/ChecklistApp/View.swift'})
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.CoreTests/testSmall'),
                         {'Sources/ChecklistCore/Used.swift', 'Sources/ChecklistApp/View.swift'})
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.MissingTests'), set())

    def test_inspection_references_do_not_invent_dynamic_or_unrelated_reads(self):
        directory = self.root / 'Tests/ChecklistCoreTests'
        (directory / 'CoreTests.swift').write_text(
            'final class CoreTests: XCTestCase { let input = "Sources/" + module + "/Used.swift" }')
        (directory / 'OtherTests.swift').write_text(
            'final class OtherTests: XCTestCase { let input = "Sources/ChecklistCore/Unused.swift" }')
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.CoreTests'), set())
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.OtherTests'),
                         {'Sources/ChecklistCore/Unused.swift'})


    def index_occurrence(self, file, usr, name, roles=2, kind=12, relations=()):
        return {'file': file, 'usr': usr, 'name': name, 'kind': kind,
                'roles': roles, 'relations': list(relations)}

    def index_export(self, *occurrences):
        return {'schema_version': 1, 'occurrences': list(occurrences)}

    def class_index(self, *occurrences):
        return self.index_export(self.index_occurrence(
            'Tests/ChecklistCoreTests/CoreTests.swift', 'class:CoreTests', 'CoreTests', kind=7),
            *occurrences)

    def test_unmeasurable_class_uses_index_symbols_and_keeps_reason(self):
        used = 'Sources/ChecklistCore/Used.swift'
        unused = 'Sources/ChecklistCore/Unused.swift'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        (self.root / used).write_text('struct UsedType {}\nfunc usedFunction() {}')
        (self.root / unused).write_text('struct OtherType { func usedFunction() {} }\nfunc otherFunction() {}')
        (self.root / test).write_text(
            'final class CoreTests: XCTestCase { func testIt() { _ = UsedType(); usedFunction() } }'
            '// OtherType otherFunction()\nlet label = "OtherType otherFunction()"')
        export = self.class_index(
            self.index_occurrence(used, 'type:UsedType', 'UsedType', kind=6),
            self.index_occurrence(used, 'function:usedFunction', 'usedFunction'),
            self.index_occurrence(unused, 'type:OtherType', 'OtherType', kind=6),
            self.index_occurrence(unused, 'member:usedFunction', 'usedFunction', kind=16),
            self.index_occurrence(unused, 'function:otherFunction', 'otherFunction'),
            self.index_occurrence(test, 'type:UsedType', 'UsedType', roles=4, kind=6),
            self.index_occurrence(test, 'function:usedFunction', 'usedFunction', roles=36))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {used, test})
        result = impact.build_map(self.root, [
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': [], 'skipped': True,
             'unmeasurable_reason': 'Owner forbids keychain access'}
        ], 'abc', 'now', 0, inventory=[used, unused], index_export=export)
        self.assertEqual(result['measured_classes'], [])
        self.assertEqual(result['coverage_unmeasurable_classes'], {
            'ChecklistCoreTests.CoreTests': {'reason': 'Owner forbids keychain access',
                'sources': [used, test], 'source': 'index-store', 'walk': ANY}})
        self.assertEqual(result['sources'][used]['classes'], [])

    def test_index_references_do_not_confuse_unrelated_member_names(self):
        used = 'Sources/ChecklistCore/Used.swift'
        selected = 'Sources/ChecklistCore/Unused.swift'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        (self.root / used).write_text('struct Recorder { func record() {} }')
        (self.root / selected).write_text('extension CommandRouter { func record() {} }')
        (self.root / test).write_text(
            'class CoreTests { func testIt() { let router = CommandRouter(); router.record() } }')
        export = self.class_index(
            self.index_occurrence(used, 'Recorder.record', 'record', kind=16),
            self.index_occurrence(selected, 'CommandRouter.record', 'record', kind=16),
            self.index_occurrence(test, 'CommandRouter.record', 'record', roles=36, kind=16))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {selected, test})

    def test_extension_type_alone_does_not_expand_to_all_its_files(self):
        used = 'Sources/ChecklistCore/Used.swift'
        unused = 'Sources/ChecklistCore/Unused.swift'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        (self.root / used).write_text('extension CommandRouter { func selected() {} }')
        (self.root / unused).write_text('extension CommandRouter { func unrelated() {} }')
        (self.root / test).write_text(
            'class CoreTests { func testIt() { let router = CommandRouter(); router.selected() } }')
        export = self.class_index(
            self.index_occurrence(used, 'CommandRouter', 'CommandRouter', kind=6),
            self.index_occurrence(used, 'CommandRouter.selected', 'selected', kind=16,
                                  relations=[{'usr': 'CommandRouter', 'roles': 512}]),
            self.index_occurrence(unused, 'CommandRouter.unrelated', 'unrelated', kind=16,
                                  relations=[{'usr': 'CommandRouter', 'roles': 512}]),
            self.index_occurrence(test, 'CommandRouter', 'CommandRouter', roles=4, kind=6),
            self.index_occurrence(test, 'CommandRouter.selected', 'selected', roles=36, kind=16))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {used, test})

    def test_index_references_include_class_extensions_and_package_symbols(self):
        package = 'Packages/Domain/Sources/Domain/Thing.swift'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        extension = 'Tests/ChecklistCoreTests/Extra.swift'
        other = 'Tests/ChecklistCoreTests/OtherTests.swift'
        (self.root / package).parent.mkdir(parents=True)
        (self.root / package).write_text('enum PackageThing {}')
        (self.root / test).write_text('class CoreTests {}')
        (self.root / extension).write_text('extension CoreTests { func testMore() { _ = PackageThing() } }')
        (self.root / other).write_text('class OtherTests { func testOther() { _ = CoreTests(); unused() } }')
        export = self.class_index(
            self.index_occurrence(extension, 'class:CoreTests', 'CoreTests', roles=4 | 16384, kind=7,
                                  relations=[{'usr': 'extension:CoreTests', 'roles': 16384}]),
            self.index_occurrence(package, 'PackageThing', 'PackageThing', kind=5),
            self.index_occurrence(extension, 'PackageThing', 'PackageThing', roles=4, kind=5),
            self.index_occurrence(other, 'class:CoreTests', 'CoreTests', roles=4, kind=7),
            self.index_occurrence('Sources/ChecklistCore/Unused.swift', 'unused', 'unused'),
            self.index_occurrence(other, 'unused', 'unused', roles=36))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {package, test, extension})
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.Absent', export), set())

    def test_unmeasurable_class_has_c_function_and_fixture_edges(self):
        production = 'Sources/Legacy/Legacy.c'
        header = 'Sources/Legacy/Legacy.h'
        fixture = 'Tests/KeychainFixture/Fixture.c'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        for file, text in ((production, 'int KeychainRead(void) { return 0; }'),
                           (header, 'int KeychainRead(void);'),
                           (fixture, 'int FixtureCreate(void) { return 1; }')):
            path = self.root / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (self.root / test).write_text('class CoreTests { func testIt() { KeychainRead(); FixtureCreate() } }')
        export = self.class_index(
            self.index_occurrence(production, 'c:KeychainRead', 'KeychainRead'),
            self.index_occurrence(header, 'c:KeychainRead', 'KeychainRead', roles=1),
            self.index_occurrence(fixture, 'c:FixtureCreate', 'FixtureCreate'),
            self.index_occurrence(test, 'c:KeychainRead', 'KeychainRead', roles=36),
            self.index_occurrence(test, 'c:FixtureCreate', 'FixtureCreate', roles=36))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {production, header, fixture, test})

    def test_index_references_follow_cleanup_router_to_indirect_projection(self):
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        router = 'Sources/ChecklistCore/Router.swift'
        cleanup = 'Sources/ChecklistCore/TicketLifecycleCleanup.swift'
        for file in (router, cleanup):
            (self.root / file).write_text('// Synthetic indexed declarations')
        export = self.class_index(
            self.index_occurrence(router, 'router.route', 'route', kind=16),
            self.index_occurrence(cleanup, 'cleanup.read', 'ticketCleanupRead', kind=16),
            self.index_occurrence(cleanup, 'cleanup.projection', 'ticketCleanupPassProjection'),
            self.index_occurrence(test, 'router.route', 'route', roles=36, kind=16),
            self.index_occurrence(router, 'cleanup.read', 'ticketCleanupRead', roles=36, kind=16,
                                  relations=[{'usr': 'router.route', 'roles': 8192}]),
            self.index_occurrence(cleanup, 'cleanup.projection', 'ticketCleanupPassProjection', roles=36,
                                  relations=[{'usr': 'cleanup.read', 'roles': 65536}]))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {test, router, cleanup})
        result = impact.build_map(self.root, [
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': [], 'skipped': True,
             'unmeasurable_reason': 'Store-copy cannot run under coverage'}
        ], 'abc', 'now', 0, index_export=export)
        self.assertIn(cleanup, result['coverage_unmeasurable_classes']['ChecklistCoreTests.CoreTests']['sources'])
        self.assertEqual(result['coverage_unmeasurable_classes']['ChecklistCoreTests.CoreTests']['source'], 'index-store')

    def test_index_call_graph_reaches_beyond_five_edges_and_cycles_terminate(self):
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        paths = ['Sources/ChecklistCore/Level%d.swift' % level for level in range(7)]
        rows = []
        for level, file in enumerate(paths):
            (self.root / file).write_text('func level%d() {}' % level)
            rows.append(self.index_occurrence(file, 'level%d' % level, 'level%d' % level))
            if level:
                rows.append(self.index_occurrence(paths[level - 1], 'level%d' % level, 'level%d' % level,
                    roles=36, relations=[{'usr': 'level%d' % (level - 1), 'roles': 8192}]))
        rows.extend([
            self.index_occurrence(test, 'level0', 'level0', roles=36),
            self.index_occurrence(paths[2], 'level0', 'level0', roles=36,
                                  relations=[{'usr': 'level2', 'roles': 8192}])])
        export = self.class_index(*rows)
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {test, *paths})
        result = impact.build_map(self.root, [
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': [], 'skipped': True}
        ], 'abc', 'now', 0, index_export=export)
        unmeasurable = result['coverage_unmeasurable_classes']['ChecklistCoreTests.CoreTests']
        self.assertEqual(unmeasurable['sources'], sorted({test, *paths}))
        walk = unmeasurable['walk']
        self.assertIs(walk['complete'], True)
        self.assertEqual(walk['nodes'], 8)  # Class seed plus all seven declarations.
        self.assertEqual(walk['edges'], 7)  # Six chain edges plus the cycle.
        self.assertGreaterEqual(walk['seconds'], 0)
        self.assertNotIn('max_depth', unmeasurable)

    def test_index_call_graph_follows_contained_local_declarations(self):
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        outer = 'Sources/ChecklistCore/Used.swift'
        leaf = 'Sources/ChecklistCore/Unused.swift'
        export = self.class_index(
            self.index_occurrence(outer, 'outer', 'outer'),
            self.index_occurrence(outer, 'outer.local', 'local',
                                  relations=[{'usr': 'outer', 'roles': 512}]),
            self.index_occurrence(leaf, 'leaf', 'leaf'),
            self.index_occurrence(test, 'outer', 'outer', roles=36),
            self.index_occurrence(outer, 'leaf', 'leaf', roles=36,
                                  relations=[{'usr': 'outer.local', 'roles': 8192}]))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export),
                         {test, outer, leaf})

    def test_index_references_exclude_external_unsafe_and_undefined_symbols(self):
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        export = self.class_index(
            self.index_occurrence('../Sources/Escape.swift', 'escaped', 'escaped'),
            self.index_occurrence(str(self.root.parent / 'External.swift'), 'external', 'external'),
            self.index_occurrence('.build/checkouts/dep/Sources/Thing.swift', 'dependency', 'dependency'),
            self.index_occurrence('Sources/ChecklistCore/Missing.swift', 'missing', 'missing'),
            *(self.index_occurrence(test, usr, usr, roles=36)
              for usr in ('escaped', 'external', 'dependency', 'missing', 'no-definition')))
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', export), {test})

    def test_missing_index_fails_closed_without_lexical_fallback(self):
        used = 'Sources/ChecklistCore/Used.swift'
        test = self.root / 'Tests/ChecklistCoreTests/CoreTests.swift'
        test.write_text('class CoreTests { func testIt() { UsedType() } }')
        (self.root / used).write_text('struct UsedType {}')
        self.assertEqual(impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', self.index_export()), set())
        for export in (None, self.index_export()):
            with self.subTest(export=export):
                result = impact.build_map(self.root, [
                    {'class': 'ChecklistCoreTests.CoreTests', 'sources': [], 'skipped': True,
                     'unmeasurable_reason': 'Store-copy qualification'}
                ], 'abc', 'now', 0, index_export=export)
                self.assertEqual(result['coverage_unmeasurable_classes']['ChecklistCoreTests.CoreTests'], {
                    'reason': 'Store-copy qualification', 'sources': [], 'source': 'index-store', 'walk': ANY})
                self.assertEqual(impact.coverage_gaps(result, ['ChecklistCoreTests.CoreTests'], []),
                                 ['Missing index-store dependencies: ChecklistCoreTests.CoreTests'])
        for malformed in ({}, {'schema_version': 99, 'occurrences': []},
                          {'schema_version': 1, 'occurrences': 'bad'}):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                impact.index_references(self.root, 'ChecklistCoreTests.CoreTests', malformed)

    def test_skipped_qualification_cannot_certify_a_complete_inventory(self):
        test = 'Tests/Target/Forbidden.swift'
        (self.root / test).parent.mkdir(parents=True)
        (self.root / test).write_text('class Forbidden {}')
        export = self.index_export(self.index_occurrence(test, 'Target.Forbidden', 'Forbidden', kind=7))
        result = impact.build_map(self.root, [
            {'class': 'Target.Measured', 'sources': []},
            {'class': 'Target.Forbidden', 'sources': [], 'skipped': True,
             'unmeasurable_reason': 'Owner prohibits keychain'},
            {'qualification_case': 'Target.Profile/testPrivate', 'sources': [], 'skipped': True},
        ], 'abc', 'now', 0, index_export=export)
        self.assertEqual(impact.coverage_gaps(result, ['Target.Measured', 'Target.Forbidden'],
                         ['Target.Profile/testPrivate']),
                         ['Unmeasured qualification case: Target.Profile/testPrivate'])
        self.assertEqual(impact.coverage_gaps(result, ['Target.Missing'], []),
                         ['Unmeasured class: Target.Missing'])

    def index_refresh_fixture(self):
        used = 'Sources/ChecklistCore/Used.swift'
        test = 'Tests/ChecklistCoreTests/CoreTests.swift'
        export = self.class_index(
            self.index_occurrence(used, 'used', 'used'),
            self.index_occurrence(test, 'used', 'used', roles=36))
        export['source_hashes'] = {path: hashlib.sha256((self.root / path).read_bytes()).hexdigest()
                                   for path in (used, test)}
        result = impact.build_map(self.root, [
            {'class': 'Target.Measured', 'sources': [used]},
            {'class': 'ChecklistCoreTests.CoreTests', 'sources': [], 'skipped': True,
             'unmeasurable_reason': 'Requires owned store'}], 'original-commit', 'original-time', 12,
             index_export=export)
        result.update(complete=True, errors=[], coverage_errors=[],
                      class_inventory=['Target.Measured', 'ChecklistCoreTests.CoreTests'],
                      qualification_case_inventory=[], test_failures=[{'test': 'original failure'}])
        result['input_hashes'] = {path.relative_to(self.root).as_posix():
                                  hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in self.root.rglob('*') if path.is_file()}
        return result, export

    def test_saved_index_requires_matching_hashes_for_every_occurrence_file(self):
        _, export = self.index_refresh_fixture()
        impact.validate_index_sources(self.root, export)
        for hashes in ({}, {'Sources/ChecklistCore/Used.swift': 'stale'}):
            with self.subTest(hashes=hashes), self.assertRaises(ValueError):
                impact.validate_index_sources(self.root, dict(export, source_hashes=hashes))
        missing = dict(export, source_hashes=dict(export['source_hashes']))
        del missing['source_hashes']['Tests/ChecklistCoreTests/CoreTests.swift']
        with self.assertRaisesRegex(ValueError, 'occurrence has no source hash'):
            impact.validate_index_sources(self.root, missing)

    def test_full_generation_rejects_stale_saved_index_before_any_swift_command(self):
        _, export = self.index_refresh_fixture()
        export['source_hashes']['Sources/ChecklistCore/Used.swift'] = 'stale'
        saved = self.root / 'index.json'
        saved.write_text(json.dumps(export))
        output = self.root / 'map.json'
        with patch.object(impact.subprocess, 'check_output', return_value='synthetic-commit'), \
                patch.object(impact, '_run') as runner:
            result = impact.main(['--root', str(self.root), '--scratch-path', str(self.root / '.build'),
                '--index-export', str(saved), '--classes', 'ChecklistCoreTests.CoreTests',
                '--output', str(output)])
        self.assertEqual(result, 1)
        runner.assert_not_called()
        data = json.loads(output.read_text())
        self.assertFalse(data['complete'])
        self.assertEqual(data['errors'], ['index export source inputs differ: Sources/ChecklistCore/Used.swift'])
        self.assertEqual(data['measured_classes'], [])

    def test_index_only_refresh_keeps_native_evidence_and_replaces_lexical_edges(self):
        original, export = self.index_refresh_fixture()
        group = 'ChecklistCoreTests.CoreTests'
        original['coverage_unmeasurable_classes'][group] = {
            'reason': 'Requires owned store', 'sources': ['Sources/ChecklistCore/Unused.swift']}
        original['coverage_unmeasurable_classes'][group]['max_depth'] = 5
        refreshed = impact.refresh_index_map(self.root, original, export)
        self.assertTrue(refreshed['complete'])
        self.assertIs(refreshed['coverage_unmeasurable_classes'][group]['walk']['complete'], True)
        self.assertNotIn('max_depth', refreshed['coverage_unmeasurable_classes'][group])
        self.assertEqual(refreshed['index_store']['traversal'], 'fixed-point')
        for field in ('commit', 'generated_at', 'generation_seconds', 'measured_classes',
                      'measured_qualification_cases', 'test_failures', 'coverage_errors'):
            self.assertEqual(refreshed[field], original[field], field)
        self.assertEqual(refreshed['coverage_unmeasurable_classes'][group], {
            'reason': 'Requires owned store', 'source': 'index-store', 'walk': ANY,
            'sources': ['Sources/ChecklistCore/Used.swift', 'Tests/ChecklistCoreTests/CoreTests.swift']})
        self.assertNotIn('source', original['coverage_unmeasurable_classes'][group],
                         'refresh must not mutate the input evidence')

    def test_index_only_refresh_refuses_source_test_manifest_drift_or_stale_export(self):
        original, export = self.index_refresh_fixture()
        for name in ('Sources/ChecklistCore/Used.swift', 'Tests/ChecklistCoreTests/CoreTests.swift', 'Package.swift'):
            with self.subTest(path=name):
                path = self.root / name
                prior = path.read_bytes() if path.exists() else None
                path.write_text('changed input')
                with self.assertRaisesRegex(ValueError, 'source/test/manifest inputs differ'):
                    impact.refresh_index_map(self.root, original, export)
                if prior is None:
                    path.unlink()
                else:
                    path.write_bytes(prior)
        export['source_hashes']['Sources/ChecklistCore/Used.swift'] = 'stale-index'
        with self.assertRaisesRegex(ValueError, 'index export source inputs differ'):
            impact.refresh_index_map(self.root, original, export)

    def test_missing_or_incomplete_walk_cannot_certify_nonempty_index_edges(self):
        original, _ = self.index_refresh_fixture()
        group = 'ChecklistCoreTests.CoreTests'
        observation = original['coverage_unmeasurable_classes'][group]
        self.assertTrue(observation['sources'])
        for walk in ({}, {'complete': False}):
            with self.subTest(walk=walk):
                observation['walk'] = walk
                self.assertEqual(impact.coverage_gaps(original, [group], []),
                                 ['Missing index-store dependencies: ' + group])

    def test_index_only_refresh_cannot_certify_missing_edges_or_incomplete_coverage(self):
        original, export = self.index_refresh_fixture()
        original['complete'] = False
        with self.assertRaisesRegex(ValueError, 'complete coverage map'):
            impact.refresh_index_map(self.root, original, export)
        original['complete'] = True
        refreshed = impact.refresh_index_map(self.root, original, self.index_export())
        self.assertFalse(refreshed['complete'])
        self.assertEqual(refreshed['errors'], ['Missing index-store dependencies: ChecklistCoreTests.CoreTests'])

    def test_completed_native_methods_include_assertion_failures_and_skips(self):
        log = """Test Case '-[ChecklistCoreTests.CoreTests testPass]' started.
Test Case '-[ChecklistCoreTests.CoreTests testPass]' passed (0.001 seconds).
Test Case '-[ChecklistCoreTests.CoreTests testFail]' started.
/path/CoreTests.swift:10: error: -[ChecklistCoreTests.CoreTests testFail] : XCTAssertTrue failed
Test Case '-[ChecklistCoreTests.CoreTests testFail]' failed (0.001 seconds).
Test Case 'ChecklistCoreTests.CoreTests/testSkip' skipped (0.001 seconds).
Test Suite 'Selected tests' failed at 2026-10-26 00:00:01.
"""
        self.assertEqual(impact.completed_tests(log), {
            'ChecklistCoreTests.CoreTests/testPass', 'ChecklistCoreTests.CoreTests/testFail',
            'ChecklistCoreTests.CoreTests/testSkip'})

    def test_crash_after_started_method_does_not_claim_complete_execution(self):
        log = """Test Case '-[ChecklistCoreTests.CoreTests testPass]' passed (0.001 seconds).
Test Case '-[ChecklistCoreTests.CoreTests testCrash]' started.
Process terminated due to signal 6
"""
        expected = {'ChecklistCoreTests.CoreTests/testPass', 'ChecklistCoreTests.CoreTests/testCrash'}
        finished = impact.completed_tests(log)
        self.assertEqual(expected - finished, {'ChecklistCoreTests.CoreTests/testCrash'})
        self.assertNotEqual(expected, finished)
        self.assertEqual(impact.completed_tests('Executed 2 tests, with 0 failures.'), set())

    def test_child_coverage_objects_include_only_instrumented_native_executables(self):
        scratch = self.root / '.build'
        debug = scratch / 'debug'
        debug.mkdir(parents=True)
        for name in ['StorageCrashProbe', 'PlainNative', 'ShellHelper', 'NonExecutable']:
            path = debug / name
            path.write_text('synthetic')
            path.chmod(0o644 if name == 'NonExecutable' else 0o755)
        (debug / 'ChecklistCoreTests.xctest').mkdir()
        def output(command, **kwargs):
            name = Path(command[-1]).name
            if command[0] == 'file':
                return 'POSIX shell script' if name == 'ShellHelper' else 'Mach-O 64-bit executable arm64'
            return '__llvm_covmap' if name == 'StorageCrashProbe' else '__text'
        with patch.object(impact.subprocess, 'check_output', side_effect=output):
            self.assertEqual(impact.coverage_objects(scratch), [debug / 'StorageCrashProbe'])

    def test_executed_shared_source_reader_is_derived_without_owning_class_declaration(self):
        helper = self.root / 'Tests/ChecklistCoreTests/Reader.swift'
        helper.write_text('func readSource() { read("Sources/ChecklistCore/Used.swift") }')
        untouched = self.root / 'Tests/ChecklistCoreTests/Untouched.swift'
        untouched.write_text('func other() { read("Sources/ChecklistCore/Unused.swift") }')
        self.assertEqual(impact.inspection_references(self.root, 'ChecklistCoreTests.CoreTests',
                         ['Tests/ChecklistCoreTests/Reader.swift']), {'Sources/ChecklistCore/Used.swift'})

    def test_child_default_profiles_are_preserved_outside_source_tree(self):
        destinations = []
        for relative in ['default.profraw', 'Tests/ChecklistCoreTests/default.profraw',
                         'Sources/ChecklistCore/default.profraw']:
            profile = self.root / relative
            profile.parent.mkdir(parents=True, exist_ok=True)
            profile.write_bytes(relative.encode())
            destinations.append(relative)
        output = self.root / '.local/build/profiles'
        moved = impact.collect_default_profiles(self.root, output)
        self.assertEqual(len(moved), 3)
        for relative in destinations:
            self.assertFalse((self.root / relative).exists())
            self.assertEqual((output / relative).read_bytes(), relative.encode())
        self.assertEqual(impact.collect_default_profiles(self.root, output), [])

    def test_deleted_inventory_source_does_not_claim_current_hash(self):
        result = impact.build_map(self.root, [], 'abc', 'now', 0.0,
                                  inventory=['Sources/ChecklistCore/Deleted.swift'])
        self.assertEqual(result['source_hashes'], {})
        self.assertEqual(result['sources']['Sources/ChecklistCore/Deleted.swift'],
                         {'classes': [], 'qualification_cases': []})


class IndexStoreBindingTests(unittest.TestCase):
    def test_string_ref_copies_exact_byte_length_and_preserves_embedded_nuls(self):
        for raw, length, expected in ((b'caf\xc3\xa9-unowned', 5, 'café'),
                                      (b'route\x00tail', 6, 'route\x00')):
            with self.subTest(raw=raw):
                buffer = ctypes.create_string_buffer(raw)
                value = index_store.StringRef(ctypes.cast(buffer, ctypes.c_void_p), length)
                copied = index_store._string(value)
                self.assertEqual(copied, expected)
                buffer[0] = b'x'
                self.assertEqual(copied, expected, 'reader-owned bytes must be copied eagerly')
        self.assertEqual(index_store._string(index_store.StringRef(None, 0)), '')

    def test_object_callback_exception_reaches_python_caller(self):
        api = index_store.IndexStore.__new__(index_store.IndexStore)
        failure = ValueError('invalid semantic occurrence')
        stopped = []

        def visit(value):
            self.assertEqual(value, 42)
            raise failure

        def enumerate_objects(reader, context, callback):
            self.assertEqual(reader, 17)
            self.assertIsNone(context)
            stopped.append(callback(None, 42))
            return True  # Even a C enumerator ignoring stop cannot hide errors.

        with self.assertRaises(ValueError) as raised:
            api.apply(enumerate_objects, 17, visit)
        self.assertIs(raised.exception, failure)
        self.assertEqual(stopped, [False])

    def test_unit_callback_uses_string_ref_and_forwards_exceptions(self):
        api = index_store.IndexStore.__new__(index_store.IndexStore)
        buffer = ctypes.create_string_buffer(b'unit-name-unowned')
        name = index_store.StringRef(ctypes.cast(buffer, ctypes.c_void_p), 9)
        visited = []

        def enumerate_units(reader, options, context, callback):
            self.assertEqual((reader, options, context), (17, 1, None))
            return callback(None, name)

        api.apply(enumerate_units, 17, lambda value: visited.append(index_store._string(value)), units=True)
        self.assertEqual(visited, ['unit-name'])
        failure = ValueError('invalid unit')

        def fail(value):
            raise failure

        with self.assertRaises(ValueError) as raised:
            api.apply(enumerate_units, 17, fail, units=True)
        self.assertIs(raised.exception, failure)

    def test_empty_record_is_explicit_but_partial_record_still_fails(self):
        api = index_store.IndexStore.__new__(index_store.IndexStore)
        api.apply(lambda reader, context, callback: False, 17, lambda value: None, allow_empty=True)

        def partial(reader, context, callback):
            callback(None, 42)
            return False

        with self.assertRaisesRegex(RuntimeError, 'enumeration did not finish'):
            api.apply(partial, 17, lambda value: None, allow_empty=True)

    def test_incomplete_c_enumeration_cannot_claim_success(self):
        api = index_store.IndexStore.__new__(index_store.IndexStore)
        with self.assertRaisesRegex(RuntimeError, 'enumeration did not finish'):
            api.apply(lambda reader, context, callback: False, 17, lambda value: None)


if __name__ == '__main__':
    unittest.main()
