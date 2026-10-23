"""Bundle retirement checks use only temporary applications and Trash folders."""
import ast
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'script/retire_old_bundles.py'
spec = importlib.util.spec_from_file_location('retire_old_bundles', SCRIPT)
retirement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retirement)


class RetireOldBundlesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.applications = self.root / 'Applications';self.applications.mkdir()
        self.trash = self.root / 'Trash';self.trash.mkdir()
        self.environment = dict(os.environ, CHECKLIST_TRASH_DIR=str(self.trash))
        self.env_patch = patch.dict(os.environ, {'CHECKLIST_TRASH_DIR': str(self.trash)})
        self.env_patch.start();self.addCleanup(self.env_patch.stop)

    def bundle(self, name, contents=b'fixture'):
        bundle = self.applications / name
        bundle.mkdir();(bundle / 'payload').write_bytes(contents)
        return bundle

    def run_script(self, *arguments):
        return subprocess.run([sys.executable, str(SCRIPT), '--applications-root', str(self.applications), *arguments],
                              env=self.environment, capture_output=True, text=True)

    def test_after_install_moves_older_copies_and_reports_each_decision_and_size(self):
        moved = [self.bundle(name) for name in [
            '.Checklist-previous-20261019T010000Z-10.app', '.Checklist-rejected-20261019T020000Z-11.app',
            '.Checklist-snapshot-old.app', '.Checklist-qualification-old.app']]
        keep = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        later = self.bundle('.Checklist-previous-20261021T010000Z-30.app')
        incoming = self.bundle('.Checklist-incoming-20261020T020000Z-25.app')
        installed = self.bundle('Checklist.app')
        unrelated = self.bundle('Other.app')
        result = self.run_script('--after-install', '--keep', str(keep))
        self.assertEqual(result.returncode, 0, result.stderr)
        for bundle in moved:
            self.assertFalse(bundle.exists());self.assertIn('moved: ' + str(bundle), result.stdout)
            destinations = list(self.trash.glob(bundle.stem + '-*.app'))
            self.assertEqual(len(destinations), 1);self.assertEqual((destinations[0] / 'payload').read_bytes(), b'fixture')
            self.assertIn(str(destinations[0]), result.stdout)
        for bundle in [keep, later]:
            self.assertTrue(bundle.is_dir());self.assertIn('kept: ' + str(bundle), result.stdout)
        self.assertIn('immediate previous bundle', result.stdout)
        self.assertIn('later concurrent install', result.stdout)
        self.assertIn('skipped: ' + str(incoming), result.stdout)
        for bundle in [incoming, installed, unrelated]: self.assertTrue(bundle.is_dir())
        self.assertNotIn(str(installed), result.stdout)
        self.assertIn('Total size moved: 28 bytes', result.stdout)

    def test_empty_keep_retires_all_unused_copies_and_repeat_is_harmless(self):
        previous = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        result = self.run_script('--after-install', '--keep', '')
        self.assertEqual(result.returncode, 0, result.stderr);self.assertFalse(previous.exists())
        result = self.run_script('--after-install', '--keep', '')
        self.assertEqual(result.returncode, 0, result.stderr);self.assertIn('Total size moved: 0 bytes', result.stdout)

    def test_running_bundle_is_kept_in_both_modes_until_process_exits(self):
        bundle = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        executable = bundle / 'Contents/MacOS/sleep';executable.parent.mkdir(parents=True)
        shutil.copyfile('/bin/sleep', executable);executable.chmod(0o755)
        # Give the relocated system executable its own fixture signature.
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)], check=True, capture_output=True)
        # Popen waits for exec to finish, so proc_pidpath sees the copied executable.
        process = subprocess.Popen([str(executable), '30'])
        try:
            self.assertIsNone(process.poll())
            for arguments in [('--after-install', '--keep', ''), ('--retire-previous', str(bundle))]:
                result = self.run_script(*arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(bundle.is_dir());self.assertIn('kept: ' + str(bundle), result.stdout)
                self.assertIn('running process uses this bundle', result.stdout)
                self.assertIn('Total size moved: 0 bytes', result.stdout)
            self.assertEqual(list(self.trash.iterdir()), [])
        finally:
            process.terminate();process.wait(timeout=5)
        result = self.run_script('--retire-previous', str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr);self.assertFalse(bundle.exists())

    def test_process_path_matching_respects_bundle_boundary(self):
        bundle = self.bundle('.Checklist-snapshot.app')
        sibling = Path(str(bundle) + '-other/Contents/MacOS/worker')
        with patch.object(retirement, 'executable_paths', return_value=iter([sibling])), redirect_stdout(io.StringIO()):
            self.assertEqual(retirement.retire([bundle]), 0)
        self.assertFalse(bundle.exists())

    def test_retire_previous_explicit_path(self):
        bundle = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        result = self.run_script('--retire-previous', str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr);self.assertFalse(bundle.exists())
        self.assertIn('moved: ' + str(bundle), result.stdout)
        result = self.run_script('--retire-previous', str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr);self.assertIn('bundle is already absent', result.stdout)

    def test_retire_previous_uses_newest_receipt_under_build_root(self):
        old = self.bundle('.Checklist-previous-20261019T010000Z-10.app')
        newest = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        old_record = self.root / '.local/build/last-install.json';old_record.parent.mkdir(parents=True)
        new_record = self.root / '.local/build/capture/last-install.json';new_record.parent.mkdir()
        old_record.write_text(json.dumps({'previous_bundle': str(old)}))
        new_record.write_text(json.dumps({'previous_bundle': str(newest)}))
        os.utime(old_record, ns=(1_000_000_000, 1_000_000_000))
        os.utime(new_record, ns=(2_000_000_000, 2_000_000_000))
        with patch.object(retirement, 'REPO', self.root), \
             patch.object(sys, 'argv', [str(SCRIPT), '--applications-root', str(self.applications), '--retire-previous']), \
             redirect_stdout(io.StringIO()) as output:
            self.assertEqual(retirement.main(), 0)
        self.assertTrue(old.exists());self.assertFalse(newest.exists())
        self.assertIn('moved: ' + str(newest), output.getvalue())

    def test_receipt_without_previous_bundle_is_a_noop(self):
        record = self.root / '.local/build/last-install.json';record.parent.mkdir(parents=True)
        record.write_text(json.dumps({'previous_bundle': None}))
        with patch.object(retirement, 'REPO', self.root), \
             patch.object(sys, 'argv', [str(SCRIPT), '--applications-root', str(self.applications), '--retire-previous']), \
             redirect_stdout(io.StringIO()) as output:
            self.assertEqual(retirement.main(), 0)
        self.assertIn('no previous bundle recorded', output.getvalue());self.assertEqual(list(self.trash.iterdir()), [])

    def test_refuses_non_previous_and_outside_paths(self):
        installed = self.bundle('Checklist.app')
        snapshot = self.bundle('.Checklist-snapshot-old.app')
        outside = self.root / '.Checklist-previous-20261020T010000Z-20.app';outside.mkdir()
        for path in [installed, snapshot, outside]:
            with self.subTest(path=path):
                result = self.run_script('--retire-previous', str(path))
                self.assertNotEqual(result.returncode, 0);self.assertTrue(path.is_dir())
                self.assertIn('applications folder', result.stderr)
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_failed_move_keeps_source_and_exits_nonzero(self):
        bundle = self.bundle('.Checklist-snapshot-old.app')
        blocked = self.root / 'not-a-folder';blocked.write_text('blocked')
        self.environment['CHECKLIST_TRASH_DIR'] = str(blocked)
        result = self.run_script('--after-install', '--keep', '')
        self.assertNotEqual(result.returncode, 0);self.assertTrue(bundle.is_dir())
        self.assertIn('failed: ' + str(bundle), result.stderr)
        self.assertIn('Total size moved: 0 bytes', result.stdout)
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_native_trash_routes_report_destination_without_finder(self):
        # Only mock native calls; this test cannot reach the real Trash.
        bundle = self.bundle('.Checklist-snapshot-old.app');destination = self.trash / bundle.name
        for native in [True, False]:
            with self.subTest(native=native), \
                 patch.object(Path, 'exists', return_value=native), patch.object(retirement.subprocess, 'run') as runner:
                stdout = f'# Moved "{bundle}" to "{destination}"\n' if native else str(destination) + '\n'
                runner.return_value = subprocess.CompletedProcess([], 0, stdout=stdout, stderr='')
                self.assertEqual(retirement.native_trash(bundle), destination)
                command = runner.call_args.args[0]
                if native: self.assertEqual(command, ['/usr/bin/trash', '--stopOnError', '--verbose', str(bundle)])
                else:
                    self.assertEqual(command[:3], ['/usr/bin/osascript', '-l', 'JavaScript'])
                    self.assertIn('trashItemAtURLResultingItemURLError', command[4])
                    self.assertNotIn('Finder', command[4]);self.assertEqual(command[-1], str(bundle))
                self.assertTrue(runner.call_args.kwargs['check'])
        self.assertTrue(bundle.is_dir());self.assertEqual(list(self.trash.iterdir()), [])

    def test_source_has_no_permanent_delete_calls_and_is_executable(self):
        tree = ast.parse(SCRIPT.read_text())
        calls = [node.func.attr if isinstance(node.func, ast.Attribute) else node.func.id
                 for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, (ast.Attribute, ast.Name))]
        for forbidden in ['unlink', 'rmtree', 'remove', 'rmdir', 'removedirs', 'system', 'popen']:
            self.assertNotIn(forbidden, calls)
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                self.assertNotIn('rm -', node.value)
                self.assertNotIn('removeItemAt', node.value)
        self.assertEqual(SCRIPT.stat().st_mode & 0o777, 0o755)

    def test_help_names_required_installed_checks(self):
        result = self.run_script('--help')
        self.assertEqual(result.returncode, 0);self.assertIn('only after the installed checks pass', ' '.join(result.stdout.split()))

    def test_installer_hook_runs_after_verification_and_failure_only_warns(self):
        # Execute the bounded tail with stubbed Python, never the installer itself.
        script = (REPO / 'script/build_and_run.sh').read_text()
        block = script[script.index('# Installed verification is mandatory'):script.index('# Interactive modes can wait')]
        hook = script.index('if ! python3 "$ROOT_DIR/script/retire_old_bundles.py"')
        self.assertLess(hook, script.index('lldb --'))
        self.assertLess(hook, script.index('/usr/bin/log stream'))
        binary = self.root / 'bin';binary.mkdir();trace = self.root / 'trace.jsonl'
        stub = binary / 'python3'
        stub.write_text('#!' + sys.executable + '\n' + """import json,os,sys
with open(os.environ['TRACE'], 'a') as output: output.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1].endswith('verify_install.py'):
    exit_code = os.environ['VERIFY_EXIT']
elif sys.argv[1].endswith('retire_old_bundles.py'):
    exit_code = os.environ['RETIRE_EXIT']
elif sys.argv[1] == '-':
    source = sys.stdin.read()
    if 'from clean_builds import post_install' not in source:
        raise SystemExit('Unexpected cleanup heredoc')
    exit_code = os.environ['CLEANUP_EXIT']
else:
    raise SystemExit('Unexpected Python call')
if sys.argv[1] == '-': print('fixture cleanup exit '+exit_code, flush=True)
raise SystemExit(int(exit_code))
""")
        stub.chmod(0o755)
        previous = self.bundle('.Checklist-previous-20261020T010000Z-20.app')
        capture = self.root / 'capture with spaces';capture.mkdir()
        build = self.root / 'build';build.mkdir()
        cases = [(mode, verify, retire, cleanup, had_previous)
                 for mode in ['--verify', '--install-stage', '--install', 'run', '--debug', '--logs', '--telemetry']
                 for verify, retire, cleanup, had_previous in [
                     (0, 0, 0, '1'), (0, 1, 0, '0'), (0, 0, 1, '1'),
                     (0, 1, 1, '1'), (1, 0, 0, '1')]]
        for mode, verify, retire, cleanup, had_previous in cases:
            with self.subTest(mode=mode, verify=verify, retire=retire, cleanup=cleanup, previous=had_previous):
                trace.write_text('')
                (capture/'post-install-cleanup.jsonl').unlink(missing_ok=True)
                (build/'.build-lock').mkdir(exist_ok=True)
                environment = dict(self.environment, MODE=mode, ROOT_DIR=str(REPO), DEST=str(self.applications / 'Checklist.app'),
                                   BUILD_ROOT=str(build), BUILD_LOCK_OWNED='1', CAPTURE_DIR=str(capture), HAD_PREVIOUS=had_previous, PREVIOUS=str(previous), INSTALL_STARTED='1234', TRACE=str(trace),
                                   VERIFY_EXIT=str(verify), RETIRE_EXIT=str(retire), CLEANUP_EXIT=str(cleanup),
                                   PATH=str(binary) + os.pathsep + os.environ['PATH'])
                result = subprocess.run(['bash', '-c', 'set -euo pipefail\nsleep() { :; }\n' + block],
                                        env=environment, capture_output=True, text=True)
                failed_verify = mode in ['--verify', '--install-stage'] and verify
                if not failed_verify:
                    log=capture/'post-install-cleanup.jsonl'
                    deadline=time.monotonic()+3
                    while time.monotonic()<deadline and (not log.exists() or 'fixture cleanup exit ' not in log.read_text()):
                        time.sleep(0.01)
                    self.assertIn('fixture cleanup exit '+str(cleanup),log.read_text())
                    self.assertFalse((build/'.build-lock').exists())
                calls = [json.loads(line) for line in trace.read_text().splitlines()]
                if mode in ['--verify', '--install-stage'] and verify:
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(calls, [
                        [str(REPO / 'script/verify_install.py'), environment['DEST'], '--install-started', '1234'],
                        [str(REPO / 'script/verify_install.py'), '--failure-guidance', '--install-started', '1234']])
                    self.assertNotIn('Warning:', result.stderr)
                    self.assertNotIn('After the installed checks pass', result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = []
                    if mode in ['--verify', '--install-stage']:
                        expected.append([str(REPO / 'script/verify_install.py'), environment['DEST'], '--install-started', '1234'])
                    expected.append([str(SCRIPT), '--after-install', '--keep', str(previous) if had_previous == '1' else ''])
                    self.assertEqual(calls[:-1], expected)
                    self.assertEqual(calls[-1][:3], ['-', str(REPO), str(capture)])
                    self.assertEqual(len(calls[-1]), 3)
                    self.assertIn('Build cleanup started in background', result.stdout)
                    self.assertEqual('Warning: old Checklist bundles' in result.stderr, bool(retire))
                    self.assertNotIn('Warning: build cleanup', result.stderr)
                    self.assertIn('--retire-previous', result.stdout)
                    if had_previous == '1': self.assertIn('Previous bundle retained at ' + str(previous), result.stdout)
                self.assertTrue(previous.is_dir());self.assertEqual(list(self.trash.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
