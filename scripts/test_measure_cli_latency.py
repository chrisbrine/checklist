"""CL-375 runner checks use fake replies/processes, never Checklist or a slot.

Fixtures stay outside src under WDIR/latency-runner-tests (no deletion).
"""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import measure_cli_latency as measure


class LatencyMeasurementTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2] / 'latency-runner-tests'
        root.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='fixture-', dir=root))
        self.output = self.root / 'result'
        self.seen = []
        self.lock = threading.Lock()
        self.backup_active = True
        self.operation_state = 'running'

    def args(self, *extra):
        return measure.arguments(['--cli', '/fixture/checklist', '--cwd', str(self.root),
                                  '--project-id', 'project-A', '--task-id', 'task-A',
                                  '--output', str(self.output), '--mode', 'calls', *extra])

    def runner(self, command, *, cwd, env, timeout):
        with self.lock:
            self.seen.append({'command': command, 'cwd': cwd, 'env': env.copy(), 'timeout': timeout})
        if command[0] == 'sysctl':
            return 0, b'{ 151.25 149.50 145.75 }\n', b'', False, 12345
        method, params = command[2], json.loads(command[3])
        if method == 'task_get':
            data = {'id': params['task_id'], 'project_id': params['project_id']}
        elif method == 'cleanup_job_list':
            time.sleep(.03)
            data = {'cleanup_jobs': [], 'total_count': 0, 'complete': True}
        elif method == 'service_info':
            if threading.current_thread() is not threading.main_thread():
                time.sleep(.03)
            data = {'build_id': 'fixture-build', 'build_number': 294}
        else:
            data = {'operation_id': params['operation_id'], 'method': 'backup_create', 'state': self.operation_state}
        if method == 'task_get' and threading.current_thread() is not threading.main_thread():
            time.sleep(.03)
        return 0, json.dumps({'data': data, 'write_admission': {'backup_active': self.backup_active}}), 'ChecklistTiming {"scope":"cli","total_ms":1}\nfull diagnostic\n', False, 12345

    def run_measurement(self, *extra, runner=None):
        return measure.Measurement(self.args(*extra), runner=runner or self.runner).run()

    def test_fifty_fresh_commands_identity_inheritance_load_and_complete_evidence(self):
        original = {key: os.environ.get(key) for key in ('CLAUDE_CODE_SESSION_ID', 'CHECKLIST_SESSION_ID', 'CODEX_THREAD_ID')}
        report = self.run_measurement()
        self.assertTrue(report['passed'], report['issues'])
        commands = [c for c in self.seen if c['command'][0] != 'sysctl']
        self.assertEqual(len(commands), 50)
        self.assertTrue(all(c['command'][1:3] == ['call', 'task_get'] for c in commands))
        for command in self.seen:
            self.assertEqual(command['env']['CHECKLIST_TIMING'], '1')
            self.assertEqual({key: command['env'].get(key) for key in original}, original)
            self.assertEqual(command['cwd'], str(self.root))
            self.assertGreater(command['timeout'], 0)
        self.assertEqual(report['phases']['calls']['count'], 50)
        self.assertEqual(report['phases']['calls']['load_start']['loadavg'], [151.25, 149.50, 145.75])
        records = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(records), 52)
        call = next(r for r in records if r.get('method'))
        self.assertIn('full diagnostic', call['stderr'])
        self.assertEqual(call['timing'], [{'scope': 'cli', 'total_ms': 1}])
        self.assertEqual(call['reply']['data']['id'], 'task-A')
        self.assertGreaterEqual(call['end_monotonic_s'], call['start_monotonic_s'])
        self.assertEqual(call['pid'], 12345)
        self.assertEqual(call['load_start']['loadavg'], [151.25, 149.50, 145.75])
        self.assertEqual(call['load_end']['loadavg'], [151.25, 149.50, 145.75])
        self.assertLessEqual(call['load_start']['end_monotonic_s'], call['start_monotonic_s'])
        self.assertGreaterEqual(call['load_end']['start_monotonic_s'], call['end_monotonic_s'])
        self.assertEqual(json.loads((self.output / 'summary.json').read_text())['passed'], True)

    def test_existing_backup_is_bracketed_and_never_started(self):
        report = self.run_measurement('--require-backup')
        self.assertTrue(report['passed'], report['issues'])
        methods = [c['command'][2] for c in self.seen if c['command'][0] != 'sysctl']
        self.assertEqual(methods, ['service_info'] + ['task_get'] * 50 + ['service_info'])
        self.assertTrue(report['phases']['calls']['backup_after']['active'])

    def test_inactive_backup_retains_fifty_calls_and_fails(self):
        self.backup_active = False
        report = self.run_measurement('--require-backup')
        self.assertFalse(report['passed'])
        self.assertIn('backup was not observed active at both call-series boundaries', report['issues'])
        self.assertEqual(report['phases']['calls']['count'], 50)

    def test_only_running_matching_backup_operation_proves_active_backup(self):
        report = self.run_measurement('--backup-operation-id', 'existing-op')
        self.assertTrue(report['passed'], report['issues'])
        methods = [c['command'][2] for c in self.seen if c['command'][0] != 'sysctl']
        self.assertEqual(methods, ['operation_get'] + ['task_get'] * 50 + ['operation_get'])
        self.assertEqual(measure.validate_reply('operation_get', {'data': {'operation_id': 'existing-op', 'method': 'restore_create', 'state': 'running'}}, 'p', 't', 'existing-op'), 'operation_get did not identify the requested backup_create')
        self.output = self.root / 'queued'
        self.operation_state = 'queued'
        self.assertFalse(self.run_measurement('--backup-operation-id', 'existing-op')['passed'])

    def test_one_burst_has_ten_cleanup_calls_two_probes_and_observed_process_overlap(self):
        report = self.run_measurement('--mode', 'burst')
        self.assertTrue(report['passed'], report['issues'])
        methods = [c['command'][2] for c in self.seen if c['command'][0] != 'sysctl']
        self.assertEqual(methods.count('cleanup_job_list'), 10)
        self.assertEqual(methods.count('task_get'), 1)
        self.assertEqual(methods.count('service_info'), 1)
        observed = report['phases']['burst']['overlap']
        self.assertTrue(observed['complete'])
        self.assertEqual(observed['probes_overlap_all_cleanup_processes'], {'task_get': True, 'service_info': True})
        self.assertNotIn('service_intervals', observed)

    def test_overlap_distinguishes_process_and_service_intervals(self):
        records = []
        for i, method in enumerate(['cleanup_job_list'] * 10 + ['service_info', 'task_get']):
            records.append({'method': method, 'start_monotonic_s': 1, 'end_monotonic_s': 2,
                            'timing': [{'scope': 'ipc', 'method': method, 'service': {'received_uptime_s': 10 + i, 'reply_ready_uptime_s': 10.5 + i}}]})
        observed = measure.overlap(records)
        self.assertTrue(observed['complete'])
        self.assertEqual(observed['probes_overlap_all_cleanup_service_requests'], {'service_info': False, 'task_get': False})
        self.assertFalse(observed['service_overlap_complete'])
        for record in records:
            record['timing'][0]['service'] = {'received_uptime_s': 10, 'reply_ready_uptime_s': 11}
        self.assertTrue(measure.overlap(records)['service_overlap_complete'])
        records[-1]['start_monotonic_s'] = 3
        self.assertFalse(measure.overlap(records)['complete'])

    def test_zero_exit_error_wrong_task_and_malformed_read_are_not_successes(self):
        for method, reply in [('service_info', {'error': {'code': 'FORBIDDEN'}}),
                              ('task_get', {'data': {'id': 'wrong'}}),
                              ('cleanup_job_list', {'data': {'cleanup_jobs': [], 'total_count': True, 'complete': True}}),
                              ('service_info', {'data': {}, 'command_outcome': 'accepted'})]:
            with self.subTest(method=method, reply=reply):
                self.assertIsNotNone(measure.validate_reply(method, reply, 'project-A', 'task-A'))
        def bad(command, **kwargs):
            if command[0] == 'sysctl':
                return self.runner(command, **kwargs)
            return 0, '{"error":{"code":"FORBIDDEN"}}', 'complete error diagnostics', False, 12345
        report = self.run_measurement(runner=bad)
        self.assertFalse(report['passed'])
        self.assertEqual(report['phases']['calls']['count'], 50)
        self.assertIn('complete error diagnostics', (self.output / 'calls.jsonl').read_text())

    def test_timeout_nonzero_invalid_load_and_latency_limit_all_fail_with_evidence(self):
        def failed(command, **kwargs):
            if command[0] == 'sysctl':
                return 0, '{ 1 nan 3 }', 'load diagnostics', False, 12345
            return 7, b'partial stdout', b'partial stderr', True, 12345
        report = self.run_measurement('--limit-seconds', '.000000001', runner=failed)
        self.assertFalse(report['passed'])
        self.assertTrue(any('exceeds' in issue for issue in report['issues']))
        self.assertTrue(any('calls-load-start' in issue for issue in report['issues']))
        self.assertIn('partial stderr', (self.output / 'calls.jsonl').read_text())
        self.assertTrue((self.output / 'summary.json').is_file())

    def test_real_process_timeout_captures_partial_streams(self):
        result = measure.execute([sys.executable, '-c', 'import sys,time; print("partial",flush=True); print("diagnostic",file=sys.stderr,flush=True); time.sleep(3)'],
                                 cwd=str(self.root), env=dict(os.environ), timeout=.15)
        self.assertLess(result[0], 0)
        self.assertTrue(result[3])
        self.assertIsInstance(result[4], int)
        self.assertIn(b'partial', result[1])
        self.assertIn(b'diagnostic', result[2])

    def test_full_runner_starts_fifty_real_fake_cli_processes(self):
        fixture = self.root / 'fake-checklist'
        fixture.write_text('#!' + sys.executable + '\n' + '''import json,os,sys
params=json.loads(sys.argv[3])
print(json.dumps({'data':{'id':params['task_id'],'project_id':params['project_id']}}))
identity={key:os.environ.get(key) for key in ('CLAUDE_CODE_SESSION_ID','CHECKLIST_SESSION_ID','CODEX_THREAD_ID')}
print('ChecklistTiming '+json.dumps({'scope':'fixture','pid':os.getpid(),'identity':identity,'timing_enabled':os.environ.get('CHECKLIST_TIMING')}),file=sys.stderr)
''')
        fixture.chmod(0o700)
        args = self.args('--cli', str(fixture), '--limit-seconds', '10')
        def run(command, **kwargs):
            return self.runner(command, **kwargs) if command[0] == 'sysctl' else measure.execute(command, **kwargs)
        report = measure.Measurement(args, runner=run).run()
        self.assertTrue(report['passed'], report['issues'])
        records = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
        calls = [r for r in records if 'method' in r]
        self.assertEqual(len({r['timing'][0]['pid'] for r in calls}), 50)
        self.assertTrue(all(r['pid'] == r['timing'][0]['pid'] for r in calls))
        identity = {key: os.environ.get(key) for key in ('CLAUDE_CODE_SESSION_ID', 'CHECKLIST_SESSION_ID', 'CODEX_THREAD_ID')}
        self.assertTrue(all(r['timing'][0]['identity'] == identity and r['timing'][0]['timing_enabled'] == '1' for r in calls))

    def test_overall_deadline_stops_incomplete_series_and_preserves_summary(self):
        def slow(command, **kwargs):
            time.sleep(.01)
            return self.runner(command, **kwargs)
        report = self.run_measurement('--max-seconds', '.04', runner=slow)
        self.assertFalse(report['passed'])
        self.assertLess(report['phases']['calls']['count'], 50)
        self.assertTrue(any('deadline' in issue for issue in report['issues']))
        self.assertTrue((self.output / 'summary.json').is_file())

    def test_burst_deadline_saves_all_call_failures_and_finishes(self):
        def slow(command, **kwargs):
            time.sleep(.01)
            return self.runner(command, **kwargs)
        started = time.monotonic()
        report = self.run_measurement('--mode', 'burst', '--max-seconds', '.001', runner=slow)
        self.assertFalse(report['passed'])
        self.assertLess(time.monotonic() - started, 2)
        records = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(len([r for r in records if 'method' in r]), 12)

    def test_instrumented_burst_fails_without_service_overlap_despite_process_overlap(self):
        def no_service_overlap(command, **kwargs):
            code, stdout, stderr, timed_out, pid = self.runner(command, **kwargs)
            if command[0] != 'sysctl':
                method = command[2]
                start = 10 if method == 'cleanup_job_list' else 20
                timing = {'scope': 'ipc', 'method': method, 'service': {'received_uptime_s': start, 'reply_ready_uptime_s': start + 1}}
                stderr += 'ChecklistTiming ' + json.dumps(timing) + '\n'
            return code, stdout, stderr, timed_out, pid
        report = self.run_measurement('--mode', 'burst', runner=no_service_overlap)
        self.assertTrue(report['phases']['burst']['overlap']['complete'])
        self.assertFalse(report['passed'])
        self.assertIn('instrumented burst did not establish each probe overlapping a cleanup request in the service', report['issues'])

    def test_latency_limit_targets_series_and_burst_probes_not_cleanup_or_backup_brackets(self):
        original = measure.Measurement.command
        cases = [('slow-cleanup', 'burst', 'cleanup_job_list', False, True),
                 ('slow-brackets', 'calls', 'service_info', True, True),
                 ('slow-series', 'calls', 'task_get', False, False),
                 ('slow-burst-info', 'burst', 'service_info', False, False),
                 ('slow-burst-task', 'burst', 'task_get', False, False)]
        for label, mode, slow_method, backup, passed in cases:
            with self.subTest(label=label):
                self.output = self.root / label
                def synthetic_latency(instance, command, record_label):
                    record = original(instance, command, record_label)
                    if command[0] != 'sysctl' and command[2] == slow_method:
                        record['end_monotonic_s'] += 2
                        record['wall_seconds'] += 2
                    return record
                options = ['--mode', mode] + (['--require-backup'] if backup else [])
                with patch.object(measure.Measurement, 'command', synthetic_latency):
                    report = self.run_measurement(*options)
                self.assertEqual(report['passed'], passed, report['issues'])
                records = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
                slow = [r for r in records if r.get('method') == slow_method]
                self.assertTrue(slow)
                self.assertTrue(all(r['wall_seconds'] > 1 for r in slow))
                if not passed:
                    self.assertTrue(any('exceeds' in issue for issue in report['issues']))

    def test_duration_only_baseline_timing_preserves_process_only_burst_pass(self):
        def duration_only(command, **kwargs):
            code, stdout, stderr, timed_out, pid = self.runner(command, **kwargs)
            if command[0] != 'sysctl':
                stderr += 'ChecklistTiming ' + json.dumps({'scope': 'ipc', 'method': command[2],
                                                          'service': {'total_ms': 10, 'queue_wait_ms': 1}}) + '\n'
            return code, stdout, stderr, timed_out, pid
        report = self.run_measurement('--mode', 'burst', runner=duration_only)
        self.assertTrue(report['passed'], report['issues'])
        observed = report['phases']['burst']['overlap']
        self.assertTrue(observed['complete'])
        self.assertFalse(observed['service_overlap_required'])
        self.assertFalse(observed['service_overlap_complete'])
        self.assertEqual(observed['service_timing_available_count'], 0)
        self.assertEqual(observed['service_evidence_kind'], 'process-only baseline; no service boundary timestamps advertised')

    def test_any_partial_new_service_boundary_requires_complete_service_overlap(self):
        for field in ('received_uptime_s', 'coordinator_dequeued_uptime_s', 'reply_ready_uptime_s'):
            with self.subTest(field=field):
                self.output = self.root / field
                def partial(command, **kwargs):
                    code, stdout, stderr, timed_out, pid = self.runner(command, **kwargs)
                    if command[0] != 'sysctl':
                        stderr += 'ChecklistTiming ' + json.dumps({'scope': 'ipc', 'method': command[2],
                                                                  'service': {'total_ms': 10, field: 10}}) + '\n'
                    return code, stdout, stderr, timed_out, pid
                report = self.run_measurement('--mode', 'burst', runner=partial)
                self.assertFalse(report['passed'])
                observed = report['phases']['burst']['overlap']
                self.assertTrue(observed['complete'])
                self.assertTrue(observed['service_overlap_required'])
                self.assertFalse(observed['service_overlap_complete'])
                self.assertEqual(observed['service_timing_available_count'], 0)
                self.assertEqual(observed['service_evidence_kind'], 'incomplete receipt/reply boundaries')

    def test_main_exit_and_argument_guards(self):
        with patch.object(measure.Measurement, 'run', return_value={'passed': False, 'issues': ['failure']}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(measure.main(['--cli', '/cli', '--cwd', '/', '--project-id', 'p', '--task-id', 't', '--output', str(self.output)]), 1)
        for extra in [('--count', '49'), ('--call-timeout', 'inf'), ('--max-seconds', '0'), ('--mode', 'burst', '--require-backup')]:
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.args(*extra)
        self.output = Path(measure.__file__).resolve().parents[1] / 'not-allowed-evidence'
        with self.assertRaisesRegex(ValueError, 'outside the source checkout'):
            self.run_measurement()


if __name__ == '__main__':
    unittest.main()
