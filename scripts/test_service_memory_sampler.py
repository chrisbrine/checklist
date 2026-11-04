#!/usr/bin/env python3
"""Unit tests for script/service_memory_sampler.py (CL-409).

The tests fake the process lookup, footprint, sysctl, sample and checklist
calls. They start no process and call no service.
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import signal
import tempfile
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location(
    'service_memory_sampler', pathlib.Path(__file__).resolve().parent.parent / 'script/service_memory_sampler.py')
sampler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sampler)

GIB = 1024 ** 3
START = 1_793_800_000.0  # 2026-11-04 UTC

FOOTPRINT_TEXT = """======================================================================
ChecklistService [56885]: 64-bit    Footprint: 1410321048 B (16384 bytes per page)
======================================================================
1401342616 B     9650176 B  1393082368 B       5837    TOTAL

Auxiliary data:
    phys_footprint: {fp} B
    phys_footprint_peak: {peak} B
"""


def idle(fp=700, peak=1500, **extra):
    return dict(fp=fp, peak=peak, active=False, **extra)


def busy(fp=1200, peak=1600, **extra):
    return dict(fp=fp, peak=peak, active=True, **extra)


class FakeHost:
    """Plays one state per sample. Footprint values in the states are MiB."""

    def __init__(self, states, moved=1, signal_at=None):
        self.states = states
        self.step = 0
        self.now = START
        self.calls = []
        self.moved = moved
        self.signal_at = signal_at
        self.backup_starts = []

    def state(self):
        return self.states[min(self.step, len(self.states) - 1)]

    def finder(self, executable):
        state = self.state()
        if state.get('gone'):
            return []
        return [{'pid': state.get('pid', 100), 'start_time': 'Wed Nov  4 11:11:20 2026'}]

    def runner(self, command, cwd=None, timeout=None):
        self.calls.append(command)
        state = self.state()
        tool = os.path.basename(command[0])
        if tool == 'footprint':
            if state.get('fail_footprint'):
                return 1, '', 'footprint: no such process'
            if '-f' not in command:
                return 0, 'full footprint report\n', ''
            return 0, FOOTPRINT_TEXT.format(fp=state['fp'] * 1024 * 1024, peak=state['peak'] * 1024 * 1024), ''
        if tool == 'sysctl':
            return 0, '{ 8.68 9.33 7.00 }\n', ''
        if tool == 'sample':
            pathlib.Path(command[command.index('-file') + 1]).write_text('stack\n')
            return 0, '', ''
        if tool == 'checklist':
            method = command[2]
            if method == 'service_info':
                admission = {'backup_active': state['active'], 'locked': state['active'],
                             'reason': 'backup_in_progress' if state['active'] else ''}
                if state['active'] and (not self.backup_starts or self.backup_starts[-1][1] != self.step - 1):
                    self.backup_starts.append([self.now, self.step])
                elif state['active']:
                    self.backup_starts[-1][1] = self.step
                return 0, json.dumps({'data': {'build_id': state.get('build', 'b289'), 'build_number': 289},
                                      'write_admission': admission}), ''
            if method == 'backup_retention_status':
                started = self.backup_starts[-1][0]
                occurred = sampler.time_fields(started + 1)['utc']
                return 0, json.dumps({'data': {'last_result': {'status': 'complete', 'moved_count': self.moved,
                                                               'occurred_at': occurred}}}), ''
        raise AssertionError(f'unexpected command {command}')

    def sleep(self, seconds):
        self.step += 1
        self.now += seconds
        if self.signal_at is not None and self.step == self.signal_at:
            os.kill(os.getpid(), signal.SIGTERM)

    def clock(self):
        return self.now


class SamplerTests(unittest.TestCase):
    # One temporary folder for the class. It goes to the Trash; no file is deleted.
    @classmethod
    def setUpClass(cls):
        cls.root = pathlib.Path(tempfile.mkdtemp(prefix='cl409-sampler-test-'))

    @classmethod
    def tearDownClass(cls):
        trash = pathlib.Path.home() / '.Trash'
        if trash.is_dir():
            shutil.move(str(cls.root), str(trash / f'{cls.root.name}-{uuid.uuid4().hex[:8]}'))

    def setUp(self):
        folder = self.root / self.id().rsplit('.', 1)[-1]
        folder.mkdir()
        self.out = folder / 'samples.jsonl'

    def run_host(self, host, *extra):
        argv = ['--out', str(self.out), '--interval', '15', '--retention-delay', '0', *extra]
        with contextlib.redirect_stdout(io.StringIO()):
            code = sampler.main(argv, runner=host.runner, finder=host.finder, clock=host.clock,
                                monotonic=host.clock, sleep=host.sleep)
        self.assertEqual(code, 0)
        summary = json.loads(pathlib.Path(f'{self.out}.summary.json').read_text())
        lines = [json.loads(line) for line in self.out.read_text().splitlines()]
        self.assertEqual(len(lines), summary['sample_count'])
        return summary, lines

    def test_backup_detection_over_a_series(self):
        host = FakeHost([idle(peak=1500), idle(peak=1500), busy(fp=1100, peak=1500), busy(fp=1400, peak=1700),
                         busy(fp=1300, peak=1700), idle(fp=800, peak=1700)])
        summary, lines = self.run_host(host, '--backups', '1')
        self.assertEqual(summary['stop_reason'], 'backups_complete: 1')
        self.assertEqual(summary['sample_count'], 6)
        [backup] = summary['backups']
        self.assertTrue(backup['complete'])
        self.assertEqual(backup['started']['epoch'], START + 30)
        self.assertEqual(backup['ended']['epoch'], START + 75)
        self.assertEqual(backup['duration_seconds'], 45)
        self.assertEqual(backup['active_samples'], 3)
        self.assertEqual(backup['max_footprint_mib'], 1400)
        self.assertEqual(backup['max_peak_mib'], 1700)
        self.assertEqual(backup['peak_before_mib'], 1500)
        self.assertEqual(backup['peak_after_mib'], 1700)
        self.assertEqual(backup['load_start'], [8.68, 9.33, 7.0])
        self.assertEqual(backup['load_end'], [8.68, 9.33, 7.0])
        self.assertEqual(backup['reasons'], ['backup_in_progress'])
        self.assertTrue(backup['retention']['moved'])
        self.assertTrue(pathlib.Path(backup['retention']['file']).exists())
        self.assertEqual(summary['moved_snapshot_count'], 1)
        self.assertEqual(summary['highest']['phys_footprint']['mib'], 1400)
        self.assertIn('local', lines[0]['time'])
        self.assertEqual(lines[0]['time']['utc'], '2026-11-04T13:46:40Z')
        self.assertEqual([line.get('backup_index') for line in lines], [None, None, 1, 1, 1, None])

    def test_stop_after_n_backups(self):
        states = [idle(), busy(), idle(), busy(), idle(), busy(), idle()]
        host = FakeHost(states, moved=0)
        summary, _ = self.run_host(host, '--backups', '2')
        self.assertEqual(summary['stop_reason'], 'backups_complete: 2')
        self.assertEqual(summary['complete_backup_count'], 2)
        self.assertEqual(summary['sample_count'], 5)
        self.assertEqual(summary['moved_snapshot_count'], 0)
        retention_calls = [c for c in host.calls if c[2:3] == ['backup_retention_status']]
        self.assertEqual(len(retention_calls), 2)

    def test_backup_active_at_first_sample_is_not_counted(self):
        host = FakeHost([busy(), idle(), busy(), idle()])
        summary, _ = self.run_host(host, '--backups', '1')
        self.assertEqual([b['complete'] for b in summary['backups']], [False, True])
        self.assertEqual(summary['complete_backup_count'], 1)

    def test_retention_waits_for_its_delay(self):
        host = FakeHost([idle(), busy(), idle(), idle(), idle(), idle(), idle()])
        argv = ['--out', str(self.out), '--interval', '15', '--retention-delay', '40', '--backups', '1']
        with contextlib.redirect_stdout(io.StringIO()):
            sampler.main(argv, runner=host.runner, finder=host.finder, clock=host.clock, monotonic=host.clock, sleep=host.sleep)
        summary = json.loads(pathlib.Path(f'{self.out}.summary.json').read_text())
        self.assertEqual(summary['sample_count'], 6)  # end at sample 3, read 45 s later
        self.assertNotIn('read_early_at_stop', summary['backups'][0]['retention'])

    def test_stop_on_pid_change(self):
        host = FakeHost([idle(), idle(), idle(pid=200), idle(pid=200)])
        summary, _ = self.run_host(host)
        self.assertEqual(summary['stop_reason'], 'service_pid_changed: 100 -> 200')
        self.assertEqual(summary['sample_count'], 2)

    def test_stop_on_build_change(self):
        host = FakeHost([idle(), idle(build='b290')])
        summary, lines = self.run_host(host)
        self.assertEqual(summary['stop_reason'], 'build_changed: b289 -> b290')
        self.assertEqual(lines[-1]['build_id'], 'b290')

    def test_stop_when_service_is_gone(self):
        host = FakeHost([idle(), dict(idle(), gone=True)])
        summary, _ = self.run_host(host)
        self.assertEqual(summary['stop_reason'], 'service_not_found')

    def test_alert_capture_once_per_backup(self):
        big = 5 * 1024
        states = [idle(), busy(fp=big, peak=big), busy(fp=big, peak=big), busy(fp=big, peak=big), idle(peak=big),
                  busy(fp=big, peak=big), busy(fp=big, peak=big), idle(peak=big)]
        host = FakeHost(states)
        summary, lines = self.run_host(host, '--backups', '2')
        self.assertEqual([alert['key'] for alert in summary['alerts']], ['backup-1', 'backup-2'])
        self.assertEqual(len([c for c in host.calls if c[0] == 'sample']), 2)
        self.assertEqual(len([c for c in host.calls if c[0] == 'footprint' and '-f' not in c]), 2)
        for alert in summary['alerts']:
            self.assertEqual(pathlib.Path(alert['footprint_report']).read_text(), 'full footprint report\n')
            self.assertTrue(pathlib.Path(alert['sample_file']).exists())
            self.assertEqual(alert['sample_exit'], 0)
        self.assertEqual(len(summary['backups'][0]['alerts']), 1)
        self.assertEqual(sum(1 for line in lines if 'alert_capture' in line), 2)

    def test_one_failed_sample_does_not_stop_the_loop(self):
        host = FakeHost([idle(), busy(fail_footprint=True), busy(fp=1300), idle()])
        summary, lines = self.run_host(host, '--backups', '1')
        self.assertEqual(summary['stop_reason'], 'backups_complete: 1')
        self.assertEqual(summary['error_sample_count'], 1)
        self.assertIn('footprint', lines[1]['errors'][0])
        self.assertEqual(summary['backups'][0]['max_footprint_mib'], 1300)

    def test_summary_on_sigterm(self):
        host = FakeHost([idle(), busy(), idle()], signal_at=2)
        previous = signal.getsignal(signal.SIGTERM)
        summary, _ = self.run_host(host, '--backups', '3', '--retention-delay', '600')
        self.assertEqual(summary['stop_reason'], 'signal SIGTERM')
        self.assertEqual(summary['sample_count'], 2)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        self.assertEqual(summary['backups'][0].get('ended'), None)

    def test_max_hours_stop_reads_pending_retention(self):
        host = FakeHost([idle(), busy(), idle(), idle()])
        summary, _ = self.run_host(host, '--max-hours', str(40 / 3600), '--retention-delay', '600')
        self.assertEqual(summary['stop_reason'], f'max_hours: {40 / 3600}')
        self.assertTrue(summary['backups'][0]['retention']['read_early_at_stop'])

    def test_launchd_root_is_the_service_and_its_child_is_a_helper(self):
        processes = [{'pid': 56885, 'ppid': 1, 'start_time': 'Wed Nov  4 15:19:01 2026'},
                     {'pid': 88405, 'ppid': 56885, 'start_time': 'Wed Nov  4 15:24:00 2026'}]
        args = sampler.parse_args(['--out', '/nonexistent/samples.jsonl'])
        run = sampler.Sampler(args, runner=lambda command, cwd=None, timeout=None: (1, '', 'unused'), finder=lambda executable: processes)
        self.assertIsNone(run.identify())
        self.assertEqual(run.service['pid'], 56885)
        self.assertEqual(run.helpers, [88405])
        processes.append({'pid': 99999, 'ppid': 1, 'start_time': 'Wed Nov  4 15:30:00 2026'})
        self.assertEqual(run.identify(), 'service_ambiguous: 56885, 99999')

    def test_lookup_finds_only_the_exact_executable(self):
        outputs = {('ps', '-axo', 'pid=,ppid=,comm='): '  1 0 /sbin/launchd\n 56885 1 Contents/MacOS/ChecklistService\n 777 1 Contents/MacOS/ChecklistService\n 88405 56885 Contents/MacOS/ChecklistService\n'}
        paths = {56885: sampler.DEFAULT_EXECUTABLE, 88405: sampler.DEFAULT_EXECUTABLE, 777: '/private/var/slot1/Checklist.app/Contents/MacOS/ChecklistService'}

        def runner(command, cwd=None, timeout=None):
            if command[:2] == ['ps', '-o']:
                return 0, 'Wed Nov  4 11:11:20 2026\n', ''
            return 0, outputs[tuple(command)], ''
        original = sampler._pidpath
        sampler._pidpath = paths.get
        try:
            found = sampler.find_processes(sampler.DEFAULT_EXECUTABLE, runner)
        finally:
            sampler._pidpath = original
        self.assertEqual(found, [{'pid': 56885, 'ppid': 1, 'start_time': 'Wed Nov  4 11:11:20 2026'}, {'pid': 88405, 'ppid': 56885, 'start_time': 'Wed Nov  4 11:11:20 2026'}])


class ParseTests(unittest.TestCase):
    def test_footprint_lines(self):
        values = sampler.parse_footprint(FOOTPRINT_TEXT.format(fp=1401342616, peak=2045446784))
        self.assertEqual(values, {'phys_footprint': 1401342616, 'phys_footprint_peak': 2045446784})
        with self.assertRaises(ValueError):
            sampler.parse_footprint('no data')

    def test_loadavg_and_admission(self):
        self.assertEqual(sampler.parse_loadavg('{ 1.5 2.0 3.25 }'), [1.5, 2.0, 3.25])
        self.assertTrue(sampler.in_backup({'backup_active': True}))
        self.assertTrue(sampler.in_backup({'locked': True, 'reason': 'backup_queue_draining'}))
        self.assertFalse(sampler.in_backup({'locked': True, 'reason': 'other'}))
        self.assertFalse(sampler.in_backup(None))

    def test_arguments_are_checked(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            sampler.parse_args(['--out', 'x', '--interval', '0'])
        args = sampler.parse_args(['--out', 'x'])
        self.assertEqual((args.interval, args.backups, args.max_hours, args.alert_bytes), (15, 3, 10, 4 * GIB))
        self.assertEqual(args.executable, '/Applications/Checklist.app/Contents/MacOS/ChecklistService')

    def test_no_delete_call_in_source(self):
        source = pathlib.Path(SPEC.origin).read_text()
        for word in ('os.remove', 'unlink', 'rmtree', 'rmdir'):
            self.assertNotIn(word, source)


if __name__ == '__main__':
    unittest.main()
