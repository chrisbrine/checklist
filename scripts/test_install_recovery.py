"""CL-513 install recovery checks using temporary bundles and a fake host."""
from contextlib import redirect_stderr, redirect_stdout
import ctypes
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import install_recovery as recovery


def bundle(path, number):
    contents = path / 'Contents'
    resources = contents / 'Resources'
    resources.mkdir(parents=True)
    build_id = f'{number:016x}'
    info = {'production_version': '0.0.1', 'version': f'0.0.1.{number}', 'build_id': build_id,
            'build_number': number, 'source_fingerprint': f'{number:064x}'}
    for name in ('build-info.json', 'source-manifest.json'):
        (resources / name).write_text(json.dumps(info))
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleShortVersionString': '0.0.1', 'CFBundleVersion': str(number),
        'ChecklistVersion': info['version'], 'ChecklistBuildID': build_id,
    }))


class InstallRecoveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.installed = self.root / 'Checklist.app'
        self.incoming = self.root / '.incoming.app'
        self.previous = self.root / '.previous.app'
        self.rejected = self.root / '.rejected.app'
        bundle(self.installed, 328)
        bundle(self.incoming, 331)
        self.now = 1000
        self.new_ready = None
        self.previous_ready = True
        self.previous_ready_at = 0
        self.upgrading = False
        self.app_running = True
        self.open_failure = False
        self.bad_signature = False
        self.restore_open_hangs = False
        self.restore_jobs = ('running',)
        self.restore_opens = 0
        self.restore_signals = []
        self.candidate = None
        self.signals = []
        self.survive_kill = False
        self.replace_after_term = {}
        self.events = []
        self.output, self.errors = io.StringIO(), io.StringIO()

    def number(self, path):
        return json.loads((path / 'Contents/Resources/build-info.json').read_text())['build_number']

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def processes(self, runner, timeout):
        self.assertGreater(timeout, 0)
        if self.candidate is not None and self.app_running and self.number(self.installed) == 331:
            return [(pid, path) for pid, (path, _) in self.candidate.items()]
        if not self.app_running:
            return []
        paths = [(42, str(self.installed / 'Contents/MacOS/ChecklistApp'))]
        if self.restore_opens:
            paths.append((44, str(self.installed / 'Contents/MacOS/ChecklistService')))
        return paths

    def stop(self, root, destination, deadline, runner, processes, clock, sleep):
        self.assertEqual(destination, self.installed)
        self.events.append(('stop', clock(), deadline, self.number(destination) if destination.exists() else None))
        self.app_running = False
        sleep(3)

    def stop_replacement(self, destination, bundle, deadline, runner, processes, clock, sleep):
        if self.candidate is None:
            self.stop(None, destination, deadline, runner, processes, clock, sleep)
        else:
            recovery.stop_candidate(destination, bundle, deadline, runner, processes, clock, sleep,
                                    inspect=self.candidate.get, send=self.send)

    def send(self, pid, sig):
        self.signals.append((pid, sig, self.now))
        if sig == signal.SIGTERM and pid in self.replace_after_term:
            self.candidate[pid] = self.replace_after_term[pid]
        if sig == signal.SIGKILL and not self.survive_kill:
            self.candidate.pop(pid)

    def inspect_restored(self, pid):
        return next(((path, 333) for number, path in self.processes(None, 5) if number == pid), None)

    def send_restored(self, pid, sig):
        self.assertEqual((pid, sig), (42, signal.SIGTERM))
        self.assertEqual(self.number(self.installed), 328)
        self.restore_signals.append((pid, sig, self.now))
        self.events.append(('quit', self.now))
        self.app_running = False

    def restore_job(self):
        return self.restore_jobs[min(self.restore_opens - 1, len(self.restore_jobs) - 1)]

    def runner(self, command, *, timeout, **kwargs):
        name = Path(command[0]).name
        self.assertGreater(timeout, 0)
        self.events.append((name, self.now, timeout, tuple(command[1:])))
        if name == 'open':
            if command[1] == '-n' and self.open_failure:
                raise subprocess.CalledProcessError(1, command)
            if command[1] == '-g' and self.restore_open_hangs:
                self.sleep(timeout)
                raise subprocess.TimeoutExpired(command, timeout)
            self.assertEqual(command[2], str(self.installed))
            if command[1] == '-g':
                self.restore_opens += 1
            self.app_running = True
        elif name == 'launchctl':
            self.assertEqual(command[1:], ['print', f'gui/{os.getuid()}/org.checklist.coordination'])
            state = self.restore_job()
            if state == 'absent':
                return subprocess.CompletedProcess(command, 113, '', 'Could not find service')
            return subprocess.CompletedProcess(command, 0, f'{command[2]} = {{\n\tstate = {state}\n}}\n', '')
        elif name == 'checklist':
            number = self.number(self.installed)
            self.assertTrue(self.app_running)
            if number == 331 and self.upgrading:
                return subprocess.CompletedProcess(command, 1, '', 'Checklist: STORAGE_UPGRADING: pending')
            if number == 328:
                ready = self.previous_ready and self.restore_job() == 'running' and self.now >= self.previous_ready_at
            else:
                ready = self.new_ready is not None and self.now >= self.new_ready
            if not ready:
                self.sleep(timeout)
                raise subprocess.TimeoutExpired(command, timeout)
            info = json.loads((self.installed / 'Contents/Resources/build-info.json').read_text())
            return subprocess.CompletedProcess(command, 0, json.dumps({
                'data': dict(info, name='Checklist', capabilities=['durable_store']),
            }), '')
        elif name == 'codesign' and self.bad_signature:
            raise subprocess.CalledProcessError(1, command)
        else:
            self.assertIn(name, {'codesign', 'lsregister', 'defaults'})
        return subprocess.CompletedProcess(command, 0)

    def install(self, needs_upgrade=False):
        with (redirect_stdout(self.output), redirect_stderr(self.errors),
              patch.dict(os.environ, CHECKLIST_DATA_ROOT=str(self.root), CHECKLIST_VERIFY_DEADLINE_SECONDS='300'),
              patch.object(recovery, 'process_identity', self.inspect_restored),
              patch.object(os, 'kill', self.send_restored)):
            return recovery.install(self.root, self.installed, self.incoming, self.previous, self.rejected,
                                    {'needs_upgrade': needs_upgrade}, 1000, runner=self.runner,
                                    processes=self.processes, stop=self.stop, stop_replacement=self.stop_replacement,
                                    clock=self.clock, sleep=self.sleep)

    def test_unresponsive_stage_restores_previous_at_the_deadline(self):
        self.assertFalse(self.install())
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)
        self.assertFalse(self.previous.exists())
        stops = [event for event in self.events if event[0] == 'stop']
        self.assertEqual(stops, [('stop', 1000, 1060, 328), ('stop', 1060, 1240, 331)])
        recovery_events = [event for event in self.events if event[1] >= 1060]
        self.assertEqual([event[0] for event in recovery_events], ['stop', 'lsregister', 'defaults', 'open', 'checklist'])
        self.assertEqual(recovery_events[2][3][:-1], ('write', 'org.checklist.app', 'registeredServiceBuild', '-string'))
        self.assertTrue(recovery_events[2][3][-1].startswith('installer-rollback-'))
        self.assertEqual(recovery_events[3][3][0], '-g')
        self.assertIn('65.0 s (stop request to first healthy service answer from the restored build)', self.output.getvalue())

    def test_spawn_failure_after_first_reopen_recovers_on_second(self):
        self.restore_jobs = ('spawn failed', 'running')
        self.assertFalse(self.install())
        self.assertEqual(self.restore_opens, 2)
        self.assertEqual(self.restore_signals, [(42, signal.SIGTERM, 1083)])
        recovery_events = [event for event in self.events if event[1] >= 1060]
        self.assertEqual([event[0] for event in recovery_events],
                         ['stop', 'lsregister', 'defaults', 'open', 'checklist', 'launchctl',
                          'quit', 'lsregister', 'defaults', 'open', 'checklist'])
        sentinels = [event[3][-1] for event in recovery_events if event[0] == 'defaults']
        self.assertEqual(len(set(sentinels)), 2)
        self.assertIn('spawn failed', self.errors.getvalue())
        self.assertIn('verified its service', self.output.getvalue())
        self.assertNotIn('Restore failed:', self.errors.getvalue())
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)

    def test_nonrunning_job_exhausts_retries_inside_recovery_deadline(self):
        self.restore_jobs = ('spawn failed',)
        self.assertFalse(self.install())
        self.assertEqual(self.restore_opens, 3)
        self.assertEqual(len(self.restore_signals), 2)
        self.assertEqual(self.now, 1240)
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)
        self.assertEqual(self.errors.getvalue().count('state: spawn failed.'), 2)
        self.assertIn('Restore failed:', self.errors.getvalue())
        self.assertNotIn('verified its service', self.output.getvalue())

    def test_absent_then_exited_job_can_start_after_final_reopen(self):
        self.restore_jobs = ('absent', 'exited', 'running')
        self.previous_ready_at = 1133
        self.assertFalse(self.install())
        self.assertEqual(self.restore_opens, 3)
        self.assertEqual(self.restore_signals, [(42, signal.SIGTERM, 1083), (42, signal.SIGTERM, 1103)])
        self.assertIn('state: absent.', self.errors.getvalue())
        self.assertIn('state: exited.', self.errors.getvalue())
        self.assertIn('verified its service', self.output.getvalue())
        self.assertLess(self.now, 1240)

    def test_healthy_stage_within_limit_keeps_new_bundle(self):
        self.new_ready = 1020
        self.assertTrue(self.install())
        self.assertEqual(self.number(self.installed), 331)
        self.assertEqual(self.number(self.previous), 328)
        self.assertFalse(self.rejected.exists())
        self.assertFalse(any(event[0] in {'lsregister', 'defaults'} for event in self.events))
        self.assertIn('40.0 s (stop request to first healthy service answer from the new build)', self.output.getvalue())

    def test_upgrade_gets_existing_wait_and_never_swaps_back(self):
        self.assertFalse(self.install(needs_upgrade=True))
        self.assertEqual(self.now, 1305)
        self.assertEqual(self.number(self.installed), 331)
        self.assertEqual(self.number(self.previous), 328)
        self.assertFalse(self.rejected.exists())
        self.assertNotIn('Restoring', self.errors.getvalue())
        for text in ['deadline expired', 'protected pre-upgrade generation', 'docs/database-storage.md',
                     'docs/self-hosting.md', 'at least 305.0 s']:
            self.assertIn(text, self.errors.getvalue())

    def test_observed_upgrade_prevents_swap_even_if_preparation_reported_no_upgrade(self):
        self.upgrading = True
        self.assertFalse(self.install())
        self.assertEqual(self.now, 1305)
        self.assertEqual(self.number(self.installed), 331)
        self.assertEqual(self.number(self.previous), 328)
        self.assertFalse(self.rejected.exists())
        self.assertIn('protected pre-upgrade generation', self.errors.getvalue())

    def test_restore_that_never_answers_stops_at_recovery_deadline(self):
        self.previous_ready = False
        self.assertFalse(self.install())
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)
        self.assertEqual(self.now, 1240)
        self.assertEqual(self.restore_opens, 1)
        self.assertEqual(self.restore_signals, [])
        self.assertIn('state: running.', self.errors.getvalue())
        self.assertIn('Restore failed:', self.errors.getvalue())
        self.assertIn('at least 240.0 s (no healthy service answer observed)', self.errors.getvalue())

    def test_failed_new_launch_restores_without_waiting_for_deadline(self):
        self.open_failure = True
        self.assertFalse(self.install())
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)
        self.assertLess(self.now, 1060)

    def test_first_install_signature_failure_moves_unverified_bundle_aside(self):
        self.installed.rename(self.root / 'offline-fixture.app')
        self.bad_signature = True
        self.assertFalse(self.install())
        self.assertFalse(self.installed.exists())
        self.assertEqual(self.number(self.rejected), 331)
        self.assertFalse(any(event[0] == 'open' for event in self.events))

    def test_hung_restore_launch_is_bounded_and_reports_failure(self):
        self.restore_open_hangs = True
        self.assertFalse(self.install())
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.now, 1078)
        self.assertIn('Restore failed:', self.errors.getvalue())
        self.assertIn('timed out after 15', self.errors.getvalue())

    def test_stubborn_candidate_is_killed_and_previous_bundle_is_verified(self):
        self.candidate = {
            42: (str(self.installed / 'Contents/MacOS/ChecklistApp'), 111),
            43: (str(self.installed / 'Contents/MacOS/ChecklistService'), 112),
        }
        self.assertFalse(self.install())
        self.assertEqual(self.signals, [(42, signal.SIGTERM, 1060), (43, signal.SIGTERM, 1060),
                                        (42, signal.SIGKILL, 1065), (43, signal.SIGKILL, 1065)])
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)
        self.assertFalse(self.previous.exists())
        self.assertIn('67.0 s (stop request to first healthy service answer from the restored build)',
                      self.output.getvalue())
        self.assertIn('Sent SIGKILL to candidate PID 43', self.errors.getvalue())
        self.assertEqual([event[0] for event in self.events if event[1] >= 1065],
                         ['lsregister', 'defaults', 'open', 'checklist'])

    def test_other_bundle_and_pid_that_switches_executable_are_never_signalled_as_candidates(self):
        unrelated = str(self.root / 'Other.app/Contents/MacOS/ChecklistService')
        self.candidate = {
            42: (str(self.installed / 'Contents/MacOS/ChecklistApp'), 111),
            43: (unrelated, 112),
        }
        self.replace_after_term[42] = (unrelated, 111)
        self.assertFalse(self.install())
        self.assertEqual(self.signals, [(42, signal.SIGTERM, 1060)])
        self.assertEqual(self.number(self.installed), 328)
        self.assertEqual(self.number(self.rejected), 331)

    def test_reused_pid_at_same_path_is_never_sent_sigkill(self):
        executable = str(self.installed / 'Contents/MacOS/ChecklistApp')
        self.candidate = {42: (executable, 111)}
        self.replace_after_term[42] = (executable, 222)
        self.assertFalse(self.install())
        self.assertEqual(self.signals, [(42, signal.SIGTERM, 1060)])
        self.assertIn('Candidate processes are running after shutdown: 42', self.errors.getvalue())
        self.assertEqual(self.number(self.installed), 331)
        self.assertEqual(self.number(self.previous), 328)
        self.assertFalse(self.rejected.exists())

    def test_candidate_surviving_sigkill_leaves_bundles_in_place_and_reports_failure(self):
        executable = str(self.installed / 'Contents/MacOS/ChecklistApp')
        self.candidate = {42: (executable, 111)}
        self.survive_kill = True
        self.assertFalse(self.install())
        self.assertEqual(self.signals, [(42, signal.SIGTERM, 1060), (42, signal.SIGKILL, 1065)])
        self.assertEqual(self.now, 1070)
        self.assertEqual(self.number(self.installed), 331)
        self.assertEqual(self.number(self.previous), 328)
        self.assertFalse(self.rejected.exists())
        self.assertIn('Candidate processes survived SIGKILL after 5 seconds: PID 42', self.errors.getvalue())
        self.assertIn(f'Check {self.installed}, {self.previous} and {self.rejected}.', self.errors.getvalue())
        self.assertIn('at least 70.0 s (no healthy service answer observed)', self.errors.getvalue())
        self.assertFalse(any(event[0] in {'lsregister', 'defaults'} for event in self.events))


class ProcessIdentityTests(unittest.TestCase):
    def test_path_is_bound_to_the_same_kernel_start_time_on_both_sides(self):
        class Library:
            def __init__(self, starts):
                self.starts = iter(starts)

            def proc_pid_rusage(self, pid, flavor, buffer):
                usage = ctypes.cast(buffer, ctypes.POINTER(recovery.ProcessUsage)).contents
                usage.start_abstime = next(self.starts)
                return 0

            def proc_pidpath(self, pid, buffer, size):
                buffer.value = b'/fixture/Checklist.app/Contents/MacOS/ChecklistApp'
                return len(buffer.value)

        for starts, expected in (((111, 111), ('/fixture/Checklist.app/Contents/MacOS/ChecklistApp', 111)),
                                 ((111, 222), None)):
            with self.subTest(starts=starts), patch.object(ctypes, 'CDLL', return_value=Library(starts)):
                self.assertEqual(recovery.process_identity(42), expected)


if __name__ == '__main__':
    unittest.main(verbosity=2)
