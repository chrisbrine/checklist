#!/usr/bin/env python3
"""Unit tests for script/memory_guard.py result evaluation (no Swift run)."""
import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location('memory_guard', pathlib.Path(__file__).resolve().parent.parent / 'script/memory_guard.py')
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class EvaluateTests(unittest.TestCase):
    def test_clean_report_passes(self):
        self.assertEqual(guard.evaluate({'failures': []}, None, 0), (True, 'passed'))

    def test_missing_report_fails(self):
        self.assertFalse(guard.evaluate(None, None, 1)[0])

    def test_footprint_or_structural_failure_fails(self):
        self.assertFalse(guard.evaluate({'failures': ['footprint']}, None, 1)[0])
        self.assertFalse(guard.evaluate({'failures': ['structural']}, None, 1)[0])

    def test_failed_test_without_guard_failure_fails(self):
        passed, reason = guard.evaluate({'failures': []}, None, 1)
        self.assertFalse(passed)
        self.assertIn('not complete', reason)

    def test_self_test_passes_only_when_its_kind_is_caught(self):
        self.assertTrue(guard.evaluate({'failures': ['footprint']}, 'whole_store_json', 1)[0])
        self.assertTrue(guard.evaluate({'failures': ['structural']}, 'whole_manifest', 1)[0])
        self.assertFalse(guard.evaluate({'failures': []}, 'whole_store_json', 0)[0])
        self.assertFalse(guard.evaluate({'failures': ['structural']}, 'whole_store_json', 1)[0])

    def test_arguments_are_checked(self):
        with self.assertRaises(SystemExit):
            guard.main(['--limit-mib', '0'])

    def test_default_limit_is_stated(self):
        self.assertGreater(guard.DEFAULT_LIMIT_MIB, 0)
        self.assertEqual(set(guard.SELF_TESTS.values()), {'footprint', 'structural'})


if __name__ == '__main__':
    unittest.main()
