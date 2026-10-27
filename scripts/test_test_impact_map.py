"""Coverage mapping tests use synthetic LLVM exports, never Swift or live stores."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('test_impact_map', Path(__file__).resolve().parents[1] / 'script/test_impact_map.py')
impact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(impact)


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


if __name__ == '__main__':
    unittest.main()
