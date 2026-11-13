"""CL-444 launch-control checks use fake processes, /usr/bin/true and the C control.

They never start Checklist, a slot or a load generator. Fixtures stay outside src
under WDIR/launch-control-tests (no deletion).
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import measure_process_launch as measure


def timing_line(prefix, value):
    return prefix + json.dumps(value) + '\n'


def cli_stderr(entered, *, call=True, total_ms=400.0):
    """ChecklistTiming lines of one CLI process that entered main at `entered`."""
    text = timing_line('ChecklistTiming ', {'scope': 'cli_setup', 'main_entered_uptime_s': entered, 'total_ms': 5})
    if call:
        for method, sent, received, ready, resumed in (('connection_bootstrap', .020, .030, .050, .055),
                                                       ('service_info', .060, .080, .180, .190)):
            text += timing_line('ChecklistTiming ', {
                'scope': 'ipc', 'method': method, 'sent_uptime_s': entered + sent, 'waiter_resumed_uptime_s': entered + resumed,
                'service': {'received_uptime_s': entered + received, 'reply_ready_uptime_s': entered + ready}})
            text += timing_line('ChecklistTiming ', {'scope': 'client', 'method': method, 'total_ms': 1})
    text += 'ChecklistTiming {malformed\nChecklist: a plain diagnostic\n'
    return text + timing_line('ChecklistTiming ', {'scope': 'cli', 'total_ms': total_ms})


def control_stderr(entered, rounds=0):
    value = {'scope': 'control', 'kind': 'c', 'main_entered_uptime_s': entered, 'cpu_at_main_s': .001,
             'main_end_uptime_s': entered + .004 + .010 * rounds,
             'rounds': [{'sent_uptime_s': entered + .001 + .010 * i, 'received_uptime_s': entered + .003 + .010 * i,
                         'reply_ready_uptime_s': entered + .004 + .010 * i, 'waiter_resumed_uptime_s': entered + .008 + .010 * i}
                        for i in range(rounds)]}
    return timing_line('ControlTiming ', value)


class FakeLauncher:
    """Each process starts 1 s after the previous one on a fake uptime clock."""

    def __init__(self, fail=None, total=None):
        self.seen, self.now, self.fail, self.total = [], 1000.0, fail or (lambda command, count: False), total or {}

    def __call__(self, command, *, env, timeout, capture, files):
        self.seen.append({'command': command, 'env': env.copy(), 'timeout': timeout, 'capture': capture})
        self.now += 1
        start = self.now
        name = Path(command[0]).name
        kind = ('cli_call' if command[1:2] == ['call'] else 'cli_version') if name == 'checklist' else \
            'true' if name == 'true' else 'swift_min' if name == 'control_swift' else 'c_echo' if command[1:2] == ['echo'] else \
            'c_cpu' if command[1:2] == ['cpu'] else 'c_min'
        count = sum(1 for seen in self.seen if seen['command'] == command)
        entered = start + .030
        stdout, stderr, total = b'', '', self.total.get(kind, .010)
        if kind == 'cli_call':
            total = self.total.get(kind, .5) + .001 * count
            stdout = json.dumps({'data': {'build_id': 'fixture-build'}, 'write_admission': {'backup_active': False}}).encode()
            stderr = cli_stderr(entered)
        elif kind == 'cli_version':
            total, stdout, stderr = .060, 'Checklist 0.0.1 · build fixture-build (1)\n'.encode(), cli_stderr(entered, call=False, total_ms=20)
        elif kind != 'true':
            total, stderr = .050, control_stderr(entered, rounds=2 if kind == 'c_echo' else 0)
        failed = self.fail(command, count)
        return {'argv': list(command), 'load_start': [150.5, 120.25, 90.0], 'load_end': [151.5, 120.25, 90.0],
                'spawn_start_uptime_s': start, 'spawn_return_uptime_s': start + .002, 'reaped_uptime_s': start + total,
                'pid': 4000 + len(self.seen), 'timed_out': False, 'returncode': 3 if failed else 0, 'capture': capture,
                'cpu_user_s': .004, 'cpu_system_s': .001, 'voluntary_switches': 2, 'involuntary_switches': 7,
                'stdout': stdout, 'stderr': stderr.encode()}


class LaunchControlTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[2] / 'launch-control-tests'
        root.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='fixture-', dir=root))
        self.output = self.root / 'result'
        self.cwd = os.getcwd()
        self.controls = {'control_c': '/fixture/control_c', 'control_swift': '/fixture/control_swift'}

    def tearDown(self):
        os.chdir(self.cwd)

    def args(self, *extra, minimum_count=50):
        return measure.arguments(['--cli', '/fixture/checklist', '--cwd', str(self.root), '--output', str(self.output), *extra],
                                 minimum_count=minimum_count)

    def run_fake(self, *extra, launcher=None, minimum_count=50, kinds='cli_call,cli_version,true,c_min,swift_min', clock=None):
        launcher = launcher or FakeLauncher()
        options = {'clock': clock} if clock else {}
        summary = measure.Measurement(self.args('--kinds', kinds, *extra, minimum_count=minimum_count), launcher=launcher,
                                      builder=lambda directory: self.controls, **options).run()
        return summary, launcher

    def record(self, kind, stderr, start=100.0, total=.5):
        return {'kind': kind, 'spawn_start_uptime_s': start, 'spawn_return_uptime_s': start + .002, 'reaped_uptime_s': start + total,
                'cpu_user_s': .080, 'cpu_system_s': .020, 'timing': measure.prefixed_json(stderr, 'ChecklistTiming '),
                'control': (measure.prefixed_json(stderr, 'ControlTiming ') or [None])[0]}

    def test_cli_call_phases_are_disjoint_and_add_up_to_the_total(self):
        phases = measure.phases(self.record('cli_call', cli_stderr(100.030)))
        expected = {'total': .5, 'spawn_call': .002, 'spawn_to_main': .030, 'delivery': .010 + .005 + .020 + .010,
                    'service': .020 + .100, 'client': .4 - .045 - .120, 'exit_reap': .5 - .030 - .4, 'cpu': .1, 'off_cpu': .4,
                    'main_to_first_send': .020, 'bootstrap_delivery': .010, 'bootstrap_service': .020, 'bootstrap_reply': .005,
                    'between_requests': .005, 'call_delivery': .020, 'call_service': .100, 'call_reply': .010,
                    'reply_to_main_end': .4 - .190}
        self.assertEqual(set(phases), set(expected))
        for name, value in expected.items():
            self.assertAlmostEqual(phases[name], value, places=9, msg=name)
        parts = ('spawn_to_main', 'client', 'delivery', 'service', 'exit_reap')
        self.assertAlmostEqual(sum(phases[name] for name in parts), phases['total'], places=9)
        detail = sum(phases[name] for name in measure.CLI_DETAIL)
        self.assertAlmostEqual(detail, phases['client'] + phases['delivery'] + phases['service'], places=9)

    def test_control_and_true_phases(self):
        echo = measure.phases(self.record('c_echo', control_stderr(100.010, rounds=2), total=.040))
        self.assertAlmostEqual(echo['spawn_to_main'], .010, places=9)
        self.assertAlmostEqual(echo['delivery'], 2 * (.002 + .004), places=9)
        self.assertAlmostEqual(echo['service'], 2 * .001, places=9)
        self.assertAlmostEqual(echo['client'], .024 - .012 - .002, places=9)
        self.assertAlmostEqual(echo['exit_reap'], .040 - .010 - .024, places=9)
        self.assertAlmostEqual(echo['cpu_before_main'], .001, places=9)
        plain = measure.phases(self.record('c_min', control_stderr(100.010), total=.020))
        self.assertNotIn('delivery', plain)
        self.assertAlmostEqual(plain['client'], .004, places=9)
        self.assertEqual(set(measure.phases(self.record('true', '', total=.003))), {'total', 'spawn_call', 'cpu', 'off_cpu'})
        version = measure.phases(self.record('cli_version', cli_stderr(100.030, call=False, total_ms=20), total=.060))
        self.assertAlmostEqual(version['client'], .020, places=9)
        self.assertAlmostEqual(version['exit_reap'], .010, places=9)

    def test_missing_or_incomplete_timing_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'cli_setup'):
            measure.phases(self.record('cli_call', 'Checklist: no timing\n'))
        with self.assertRaisesRegex(ValueError, 'ControlTiming'):
            measure.phases(self.record('c_min', ''))
        with self.assertRaisesRegex(ValueError, 'expected 2 complete request timings, found 1'):
            measure.phases(self.record('c_echo', control_stderr(100.010, rounds=1)))
        broken = self.record('cli_call', cli_stderr(100.030))
        next(t for t in broken['timing'] if t.get('method') == 'service_info')['service'].pop('received_uptime_s')
        with self.assertRaisesRegex(ValueError, 'complete request timings'):
            measure.phases(broken)

    def test_validation_names_each_failure(self):
        def check(kind, stdout, returncode=0, timed_out=False):
            record = {'kind': kind, 'returncode': returncode, 'timed_out': timed_out, 'stdout_text': stdout}
            return measure.validate(record), record
        self.assertEqual(check('true', '', timed_out=True)[0], 'process passed the call timeout and was ended')
        self.assertEqual(check('true', '', returncode=1)[0], 'exit status 1')
        self.assertIn('invalid JSON reply', check('cli_call', 'not json')[0])
        self.assertEqual(check('cli_call', '{"data":{}}')[0], 'service_info reply has no data.build_id')
        self.assertEqual(check('cli_call', '{"error":{"code":"X"},"data":{"build_id":"b"}}')[0], 'service_info reply has no data.build_id')
        error, record = check('cli_call', '{"data":{"build_id":"b"},"write_admission":{"backup_active":true}}')
        self.assertIsNone(error)
        self.assertEqual((record['build_id'], record['backup_active']), ('b', True))
        self.assertNotIn('stdout_text', record)
        self.assertIn('version output', check('cli_version', 'other')[0])
        self.assertIsNone(check('cli_version', 'Checklist 1 · build b (2)\n')[0])

    def test_arguments_refuse_unsafe_or_short_runs(self):
        base = ['--cwd', str(self.root), '--output', str(self.output)]
        for extra in (['--cli', '/fixture/checklist', '--count', '49'], ['--cli', 'relative/checklist'], [],
                      ['--cli', '/fixture/checklist', '--kinds', 'true,other'], ['--cli', '/fixture/checklist', '--kinds', 'true,true'],
                      ['--cli', '/fixture/checklist', '--kinds', ''], ['--cli', '/fixture/checklist', '--call-timeout', '0'],
                      ['--cli', '/fixture/checklist', '--max-seconds', 'inf'], ['--cli', '/fixture/checklist', '--control-cpu-ms', '-1']):
            with self.subTest(extra=extra), self.assertRaises(SystemExit), open(os.devnull, 'w') as null:
                stderr, sys.stderr = sys.stderr, null
                try:
                    measure.arguments(base + extra)
                finally:
                    sys.stderr = stderr
        with self.assertRaises(SystemExit), open(os.devnull, 'w') as null:
            stderr, sys.stderr = sys.stderr, null
            try:
                measure.arguments(['--cli', '/fixture/checklist', '--cwd', str(self.root / 'absent'), '--output', str(self.output)])
            finally:
                sys.stderr = stderr
        controls_only = measure.arguments(base + ['--kinds', 'true,c_min'])
        self.assertEqual((controls_only.kinds, controls_only.count, controls_only.capture), (['true', 'c_min'], 50, 'file'))
        self.assertEqual(measure.arguments(base + ['--cli', '/fixture/checklist']).kinds, list(measure.KINDS))
        commands = measure.Measurement(self.args('--control-cpu-ms', '37.5')).commands(self.controls, 'control.sock')
        self.assertEqual(set(commands), set(measure.KINDS))
        self.assertEqual(commands['c_cpu'], ['/fixture/control_c', 'cpu', '37.5'])
        self.assertEqual(commands['c_echo'], ['/fixture/control_c', 'echo', str(self.output.resolve()), 'control.sock'])

    def test_run_interleaves_kinds_and_summarizes_fifty_rounds(self):
        summary, launcher = self.run_fake()
        self.assertTrue(summary['passed'], summary['issues'])
        kinds = ['cli_call', 'cli_version', 'true', 'c_min', 'swift_min']
        names = {'checklist': None, 'true': 'true', 'control_c': 'c_min', 'control_swift': 'swift_min'}
        order = []
        for seen in launcher.seen:
            name = Path(seen['command'][0]).name
            order.append(names[name] or ('cli_call' if seen['command'][1] == 'call' else 'cli_version'))
        self.assertEqual(order[:5], kinds)  # round 0, the warm-up
        self.assertEqual(order[5:10], kinds)
        self.assertEqual(order[10:15], kinds[1:] + kinds[:1])  # each round starts with the next kind
        self.assertEqual(len(order), 51 * 5)
        for seen in launcher.seen:
            cli = Path(seen['command'][0]).name == 'checklist'
            self.assertEqual(seen['env'].get('CHECKLIST_TIMING') == '1', cli)
            self.assertEqual((seen['timeout'], seen['capture']), (15, 'file'))
        self.assertEqual(launcher.seen[0]['command'], ['/fixture/checklist', 'call', 'service_info', '{}'])
        self.assertEqual(os.getcwd(), os.path.realpath(self.root))
        for kind in kinds:
            self.assertEqual(summary['kinds'][kind]['count'], 50, kind)
        call = summary['kinds']['cli_call']['phases_seconds']
        # Totals are .5 + .001 * n for n = 2...51 (n = 1 is the warm-up).
        self.assertAlmostEqual(call['total']['median'], .5 + .001 * 26, places=9)
        self.assertAlmostEqual(call['total']['p95'], .5 + .001 * 49, places=9)
        self.assertAlmostEqual(call['total']['max'], .5 + .001 * 51, places=9)
        self.assertAlmostEqual(call['spawn_to_main']['median'], .030, places=9)
        self.assertAlmostEqual(summary['kinds']['cli_call']['wall_per_cpu_median'], (.5 + .001 * 26) / .005, places=6)
        self.assertEqual(summary['kinds']['cli_call']['over_limit'], 0)
        self.assertEqual(set(summary['kinds']['true']['phases_seconds']), {'total', 'spawn_call', 'cpu', 'off_cpu'})
        self.assertEqual(summary['load_1min'], {'min': 150.5, 'median': 150.5, 'max': 151.5})
        self.assertEqual(summary['load_5min'], {'min': 120.25, 'median': 120.25, 'max': 120.25})
        self.assertEqual(summary['load_15min'], {'min': 90.0, 'median': 90.0, 'max': 90.0})
        self.assertEqual((summary['load_first'], summary['load_last']), ([150.5, 120.25, 90.0], [151.5, 120.25, 90.0]))
        self.assertEqual((summary['builds'], summary['backup_active_calls'], summary['record_count']), (['fixture-build'], 0, 255))
        rows = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 255)
        self.assertEqual(sum(1 for row in rows if row.get('warmup')), 5)
        self.assertTrue(all('stdout' not in row and 'stdout_text' not in row and 'stderr' not in row for row in rows))
        self.assertEqual(rows[0]['stdout_bytes'], len(json.dumps({'data': {'build_id': 'fixture-build'}, 'write_admission': {'backup_active': False}})))
        saved = json.loads((self.output / 'summary.json').read_text())
        self.assertEqual(saved['kinds']['cli_call']['count'], 50)
        text = (self.output / 'summary.md').read_text()
        self.assertIn('| cli_call | 50 | 526.0 / 549.0 / 551.0 |', text)
        self.assertIn('| reply_to_main_end | 210.0 | 210.0 | 210.0 |', text)
        self.assertIn("5-minute range {'min': 120.25, 'median': 120.25, 'max': 120.25}", text)
        self.assertIn('Issues: none', text)

    def test_slow_calls_are_counted_and_do_not_fail_the_run(self):
        summary, _ = self.run_fake('--limit-seconds', '0.5405', kinds='cli_call,true')
        self.assertTrue(summary['passed'])
        self.assertEqual(summary['kinds']['cli_call']['over_limit'], 11)  # .541 to .551
        self.assertEqual(summary['kinds']['true']['over_limit'], 0)

    def test_failed_process_and_missing_timing_fail_the_run(self):
        launcher = FakeLauncher(fail=lambda command, count: command[-1] == 'version' and count == 3)
        summary, _ = self.run_fake(launcher=launcher, kinds='cli_version,true')
        self.assertFalse(summary['passed'])
        self.assertEqual(summary['issues'], ['cli_version 2: exit status 3'])
        self.assertEqual(summary['kinds']['cli_version']['count'], 49)

        def missing(command, *, env, timeout, capture, files):
            raise FileNotFoundError(2, 'No such file or directory', command[0])
        self.output = self.root / 'missing'
        summary = measure.Measurement(self.args('--kinds', 'true', '--count', '1', minimum_count=1), launcher=missing).run()
        self.assertFalse(summary['passed'])
        self.assertEqual(len(summary['issues']), 2)
        self.assertIn('FileNotFoundError', summary['issues'][0])
        self.assertEqual(summary['kinds'], {})

    def test_deadline_stops_new_rounds_and_is_reported(self):
        ticks = iter(range(0, 10000, 100))
        summary, launcher = self.run_fake('--max-seconds', '250', kinds='true', clock=lambda: next(ticks))
        self.assertFalse(summary['passed'])
        self.assertEqual(summary['issues'], ['overall deadline reached after 2 of 50 rounds'])
        self.assertEqual(len(launcher.seen), 3)

    def test_output_must_be_new_and_outside_the_checkout(self):
        inside = Path(__file__).resolve().parents[1] / 'launch-evidence-refused'
        self.output = inside
        with self.assertRaisesRegex(ValueError, 'outside the source checkout'):
            self.run_fake(kinds='true')
        self.assertFalse(inside.exists())
        self.output = self.root / 'result'
        self.output.mkdir()
        with self.assertRaises(FileExistsError):
            self.run_fake(kinds='true')
        self.assertEqual(measure.main(['--kinds', 'true', '--cwd', str(self.root), '--output', str(self.output)]), 1)

    def launch_real(self, command, capture, timeout=10):
        files = [os.open(self.root / name, os.O_RDWR | os.O_CREAT, 0o600) for name in ('real.stdout', 'real.stderr')]
        try:
            return measure.launch(command, env=dict(os.environ, FIXTURE_VALUE='inherited'), timeout=timeout, capture=capture, files=files)
        finally:
            for descriptor in files:
                os.close(descriptor)

    def test_real_launch_captures_streams_clock_order_and_usage(self):
        code = ("import os,sys; sys.stdout.write('o' * 200000); sys.stdout.flush(); "
                "sys.stderr.write(os.environ['FIXTURE_VALUE'] + ' ' + str(sys.stdin.read() == '')); sys.exit(4)")
        for capture in ('file', 'pipe'):
            with self.subTest(capture=capture):
                result = self.launch_real([sys.executable, '-c', code], capture)
                self.assertEqual((result['returncode'], result['timed_out']), (4, False))
                self.assertEqual(result['stdout'], b'o' * 200000)  # above one pipe buffer
                self.assertEqual(result['stderr'], b'inherited True')
                self.assertLessEqual(result['spawn_start_uptime_s'], result['spawn_return_uptime_s'])
                self.assertLessEqual(result['spawn_return_uptime_s'], result['reaped_uptime_s'])
                self.assertGreater(result['cpu_user_s'] + result['cpu_system_s'], 0)
                self.assertEqual(len(result['load_start']), 3)
                self.assertEqual('output_end_uptime_s' in result, capture == 'pipe')
                true = self.launch_real(['/usr/bin/true'], capture)
                self.assertEqual((true['returncode'], true['stdout'], true['stderr']), (0, b'', b''))
        self.assertEqual((self.root / 'real.stdout').stat().st_size, 0)  # captured files are left empty

    def test_real_launch_ends_a_process_that_passes_the_timeout(self):
        for capture in ('file', 'pipe'):
            with self.subTest(capture=capture):
                result = self.launch_real(['/bin/sleep', '30'], capture, timeout=.3)
                self.assertEqual((result['timed_out'], result['returncode']), (True, -9))
                self.assertLess(result['reaped_uptime_s'] - result['spawn_start_uptime_s'], 10)
        with self.assertRaises(FileNotFoundError):
            self.launch_real([str(self.root / 'absent-binary')], 'pipe')

    @unittest.skipUnless(shutil.which('cc'), 'needs a C compiler')
    def test_real_c_control_reports_main_and_echo_round_trips(self):
        controls = self.root / 'controls'
        controls.mkdir()
        (controls / 'control.c').write_text(measure.CONTROL_C)
        subprocess.run(['cc', '-O2', '-o', str(controls / 'control_c'), str(controls / 'control.c')], check=True, timeout=300)
        args = self.args('--kinds', 'true,c_min,c_echo,c_cpu', '--control-cpu-ms', '20', '--controls', str(controls), '--count', '2', minimum_count=1)
        run = measure.Measurement(args)
        summary = run.run()
        self.assertTrue(summary['passed'], summary['issues'])
        self.assertEqual({kind: value['count'] for kind, value in summary['kinds'].items()}, {'true': 2, 'c_min': 2, 'c_echo': 2, 'c_cpu': 2})
        used = summary['kinds']['c_cpu']['phases_seconds']
        self.assertGreaterEqual(used['cpu']['median'], .020)  # the loop used the requested CPU time
        self.assertGreaterEqual(used['client']['median'], .019)
        self.assertLess(summary['kinds']['c_min']['phases_seconds']['cpu']['median'], .020)
        self.assertIsNotNone(run.server.poll())  # the echo process has ended
        self.assertTrue((self.output / 'control.sock').is_socket())
        echo = summary['kinds']['c_echo']['phases_seconds']
        for name in ('spawn_to_main', 'client', 'delivery', 'service', 'exit_reap', 'cpu_before_main'):
            self.assertGreaterEqual(echo[name]['median'], 0, name)
        self.assertGreater(echo['delivery']['max'], 0)
        rows = [json.loads(line) for line in (self.output / 'calls.jsonl').read_text().splitlines()]
        for row in rows:
            if row['kind'] != 'true':
                parts = sum(row['phases'][name] for name in ('spawn_to_main', 'client', 'exit_reap')) + row['phases'].get('delivery', 0) + row['phases'].get('service', 0)
                self.assertAlmostEqual(parts, row['phases']['total'], places=6)
                self.assertGreaterEqual(row['phases']['spawn_to_main'], 0)
                self.assertGreaterEqual(row['phases']['exit_reap'], 0)


if __name__ == '__main__':
    unittest.main()
