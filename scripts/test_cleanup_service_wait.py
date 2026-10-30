#!/usr/bin/env python3
"""Post-install readiness tests: temporary markers, fake readers and fake time."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import clean_builds
import clean_scratch
from cleanup_service_wait import ServiceReadiness


class FakeClock:
    def __init__(self):
        self.seconds = 0.0
        self.sleeps = []

    def now(self):
        return self.seconds

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.seconds += seconds


class ServiceReadinessTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.reports = []
        self.wait = ServiceReadiness(clock=self.clock.now, sleep=self.clock.sleep,
                                     report=self.reports.append)

    def test_reader_fails_twice_then_succeeds_with_measured_wait(self):
        calls = []

        def reader(keys):
            calls.append(keys)
            if len(calls) <= 2:
                raise ConnectionError('new service is still starting')
            return {'CL-372': 'done'}

        self.assertEqual(self.wait.read(reader, ['CL-372']), {'CL-372': 'done'})
        self.assertEqual(len(calls), 3)
        self.assertEqual(self.clock.sleeps, [1.0, 1.0])
        self.assertEqual(self.reports, [{'action': 'release_done_service_wait',
            'status': 'ready', 'waited_seconds': 2.0, 'attempts': 3}])

    def test_deadline_includes_cli_time_and_is_shared_by_every_subprocess(self):
        budgets = []

        def reader(keys):
            for _ in range(8):
                budgets.append(self.wait.call_timeout())
                # A stuck CLI is terminated within the supplied subprocess timeout.
                self.clock.seconds += budgets[-1]
                if self.clock.seconds >= 60:
                    raise subprocess.TimeoutExpired('fake CLI', budgets[-1])
            return {'CL-372': 'done'}

        with self.assertRaises(TimeoutError):
            self.wait.read(reader, ['CL-372'])
        self.assertEqual(self.clock.seconds, 60)
        self.assertEqual(budgets, [10.0] * 6)
        self.assertEqual(self.clock.sleeps, [])
        self.assertEqual(self.reports[-1]['waited_seconds'], 60.0)
        self.assertEqual(self.reports[-1]['status'], 'unavailable')

    def test_remaining_budget_shrinks_and_sleep_does_not_cross_deadline(self):
        self.wait = ServiceReadiness(timeout_seconds=2.5, retry_interval_seconds=2,
            clock=self.clock.now, sleep=self.clock.sleep, report=self.reports.append)
        budgets = []

        def reader(keys):
            budgets.append(self.wait.call_timeout())
            raise ConnectionError('unavailable')

        with self.assertRaises(TimeoutError):
            self.wait.read(reader, ['CL-372'])
        self.assertEqual(budgets, [2.5, 0.5])
        self.assertEqual(self.clock.sleeps, [2, 0.5])
        self.assertEqual(self.clock.seconds, 2.5)
        self.assertEqual(self.reports[-1]['attempts'], 2)

    def test_actual_cli_reader_shares_deadline_across_project_and_ticket_calls(self):
        calls = []

        def run(arguments, **kwargs):
            calls.append((arguments[2], kwargs['timeout']))
            self.clock.seconds += kwargs['timeout']
            if self.clock.seconds >= 60:
                raise subprocess.TimeoutExpired(arguments, kwargs['timeout'])
            if arguments[2] == 'project_resolve':
                data = {'projects': [{'id': 'fixture-project'}]}
            else:
                key = json.loads(arguments[3])['key']
                data = {'key': key, 'status_category': 'done'}
            return SimpleNamespace(stdout=json.dumps({'data': data}))

        reader = clean_scratch.cli_status_reader(Path('/fake/checklist'), ROOT,
                                                  timeout=self.wait.call_timeout)
        with patch.object(clean_scratch.subprocess, 'run', side_effect=run):
            with self.assertRaises(TimeoutError):
                self.wait.read(reader, ['CL-' + str(i) for i in range(10)])
        self.assertEqual(calls, [('project_resolve', 10.0)] + [('task_get', 10.0)] * 5)
        self.assertEqual(self.clock.seconds, 60)
        self.assertEqual(self.clock.sleeps, [])

    def test_after_timeout_later_folders_do_not_restart_wait_or_reader(self):
        calls = []

        def reader(keys):
            calls.append(keys)
            raise ValueError('new service unavailable')

        with self.assertRaises(TimeoutError):
            self.wait.read(reader, ['CL-372'])
        count = len(calls)
        with self.assertRaises(TimeoutError):
            self.wait.read(reader, ['CL-367'])
        self.assertEqual(len(calls), count)
        self.assertEqual(self.clock.seconds, 60)
        self.assertEqual(len(self.reports), 1)

    def test_after_readiness_status_error_is_not_retried(self):
        self.wait.read(lambda keys: {'CL-372': 'done'}, ['CL-372'])

        def failed(keys):
            raise ValueError('malformed later status')

        with self.assertRaisesRegex(ValueError, 'malformed later status'):
            self.wait.read(failed, ['CL-367'])
        self.assertEqual(self.clock.sleeps, [])
        self.assertEqual(len(self.reports), 1)
        self.assertEqual(self.wait.call_timeout(), 60)


class PostInstallServiceReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sessions = self.root / 'sessions'
        self.scratch = self.sessions / 'Checklist-fixture' / 'installer' / 'scratchpad'
        self.scratch.mkdir(parents=True)
        self.qualification = self.root / 'qualification'
        self.qualification.mkdir()
        self.clock = FakeClock()
        self.wait = ServiceReadiness(clock=self.clock.now, sleep=self.clock.sleep)

    def marked(self, name, key):
        path = self.scratch / name
        path.mkdir()
        clean_scratch.write_marker(path, 'installer', 'CL-372 temporary fixture', tickets=[key])
        return path

    def release(self, reader):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(clean_builds, 'ServiceReadiness', return_value=self.wait):
            result = clean_builds.release_done(self.root, environ={'CODEX_THREAD_ID': 'installer'},
                reader=reader, sessions_root=self.sessions, qualification_root=self.qualification)
        return result, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_post_install_releases_after_reader_fails_twice(self):
        done = self.marked('finished', 'CL-372')
        active = self.marked('unfinished', 'CL-367')
        calls = []

        def reader(keys):
            calls.append(keys)
            # No marker may be released before a complete successful read.
            if len(calls) <= 2:
                self.assertFalse(clean_scratch.read_marker(done)['released'])
                self.assertFalse(clean_scratch.read_marker(active)['released'])
                raise ConnectionError('starting')
            return {key: ('done' if key == 'CL-372' else 'active') for key in keys}

        result, events = self.release(reader)
        self.assertEqual(result, 0)
        self.assertTrue(clean_scratch.read_marker(done)['released'])
        self.assertFalse(clean_scratch.read_marker(active)['released'])
        self.assertEqual(self.clock.seconds, 2)
        wait = next(event for event in events if event['action'] == 'release_done_service_wait')
        self.assertEqual((wait['status'], wait['waited_seconds'], wait['attempts']), ('ready', 2.0, 3))

    def test_post_install_timeout_preserves_all_marker_bytes_and_reports_failure(self):
        paths = [self.marked('one', 'CL-372'), self.marked('two', 'CL-367')]
        before = {path: (path / clean_scratch.WORKSPACE_MARKER).read_bytes() for path in paths}

        def reader(keys):
            raise ConnectionError('service never ready')

        result, events = self.release(reader)
        self.assertEqual(result, 1)
        self.assertEqual(before, {path: (path / clean_scratch.WORKSPACE_MARKER).read_bytes() for path in paths})
        self.assertEqual(self.clock.seconds, 60)
        waits = [event for event in events if event['action'] == 'release_done_service_wait']
        self.assertEqual(len(waits), 1)
        self.assertEqual((waits[0]['status'], waits[0]['waited_seconds']), ('unavailable', 60.0))
        self.assertEqual(len([event for event in events if event['action'] == 'kept_error']), 2)


if __name__ == '__main__':
    unittest.main()
