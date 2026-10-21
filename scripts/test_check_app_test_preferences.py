"""Regression checks for the read-only, post-process preference leak gate."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preference_check", Path(__file__).with_name("check-app-test-preferences.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class PreferenceCheckTests(unittest.TestCase):
    def test_late_leak_at_second_count_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / "Checklist.TestDefaults.preexisting.plist"
            workspace = root / "Checklist.Workspace.synthetic.plist"
            old.write_bytes(b"existing")
            workspace.write_bytes(b"workspace")
            late = root / "Checklist.TestDefaults.this-run.plist"
            def settle(_):
                if sleep.call_count == 2:
                    late.write_bytes(b"empty plist")
            with patch.object(checker.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
                 patch.object(checker.time, "sleep", side_effect=settle) as sleep:
                self.assertEqual(checker.check(["tests"], root), 1)
            run.assert_called_once_with(["tests"], check=False)
            self.assertEqual(sleep.call_args_list, [unittest.mock.call(3), unittest.mock.call(3)])
            self.assertEqual(old.read_bytes(), b"existing")
            self.assertEqual(workspace.read_bytes(), b"workspace")
            self.assertTrue(late.exists(), "The checker must never clean up a leak")
            self.assertEqual(checker.test_plists(root), {old.name, late.name})

    def test_first_sample_leak_cannot_be_hidden_by_second_sample(self):
        with patch.object(checker, "test_plists", side_effect=[set(), {"Checklist.TestDefaults.late.plist"}, set()]), \
             patch.object(checker.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
             patch.object(checker.time, "sleep"):
            self.assertEqual(checker.check(["tests"], Path("unused")), 1)

    def test_success_and_test_command_failure_are_preserved(self):
        for status in [0, 7]:
            with self.subTest(status=status), \
                 patch.object(checker, "test_plists", return_value=set()), \
                 patch.object(checker.subprocess, "run", return_value=subprocess.CompletedProcess([], status)), \
                 patch.object(checker.time, "sleep"):
                self.assertEqual(checker.check(["tests"], Path("unused")), status)


if __name__ == "__main__":
    unittest.main()
