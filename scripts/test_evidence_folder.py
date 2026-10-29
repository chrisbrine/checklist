#!/usr/bin/env python3
"""CL-359 item 0: evidence folders and build stages are registered with tickets at creation."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import clean_scratch
import evidence_folder


class EvidenceFolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve() / 'repo'; self.repo.mkdir()
        environment = patch.dict(os.environ, {'CHECKLIST_TICKETS': '', 'CODEX_THREAD_ID': 'fixture-session',
                                              'CLAUDE_SESSION_ID': '', 'CHECKLIST_SESSION_ID': ''})
        environment.start(); self.addCleanup(environment.stop)

    def run_main(self, *argv):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = evidence_folder.main(list(argv))
        return result, json.loads(output.getvalue())

    def test_new_writes_owner_record_under_evidence(self):
        result, row = self.run_main('new', '--repo', str(self.repo), '--ticket', 'CL-2', '--ticket', 'CL-1',
                                    '--purpose', 'hand-in', 'integration-49/RW1')
        folder = self.repo / '/'.join(['.local', 'evidence', 'integration-49', 'RW1'])
        self.assertEqual((result, row['path']), (0, str(folder)))
        record = clean_scratch.read_owner_record(folder)
        self.assertEqual((record['kind'], record['tickets'], record['purpose'], record['session_id']),
                         ('evidence', ['CL-1', 'CL-2'], 'hand-in', 'fixture-session'))

    def test_refuses_without_tickets_bad_names_and_existing_folders(self):
        with self.assertRaisesRegex(ValueError, 'register the new folder'):
            evidence_folder.new_evidence(self.repo, 'x', None)
        self.assertFalse((self.repo / '.local/evidence/x').exists())
        for name in ['../escape', '/abs', 'a/../b', '']:
            with self.assertRaisesRegex(ValueError, 'relative path'):
                evidence_folder.new_evidence(self.repo, name, ['CL-1'])
        with self.assertRaisesRegex(ValueError, 'ticket keys must'):
            evidence_folder.new_evidence(self.repo, 'y', ['cl-1'])
        evidence_folder.new_evidence(self.repo, 'z', ['CL-1'])
        with self.assertRaisesRegex(ValueError, 'exists'):
            evidence_folder.new_evidence(self.repo, 'z', ['CL-1'])
        old = self.repo / '.local/evidence/old'; old.mkdir()
        with patch.dict(os.environ, CHECKLIST_TICKETS='CL-4, CL-3'):
            _, record = evidence_folder.new_evidence(self.repo, 'old', None, existing=True)
        self.assertEqual(record['tickets'], ['CL-3', 'CL-4'])
        target = Path(self.temp.name) / 'outside'; target.mkdir()
        (self.repo / '.local/evidence/link').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'link'):
            evidence_folder.new_evidence(self.repo, 'link/inner', ['CL-1'])

    def test_register_merges_same_kind_refuses_other_kind_and_invalid_records(self):
        folder = self.repo / 'capture'; folder.mkdir()
        self.run_main('register', '--kind', 'build', '--ticket', 'CL-1', str(folder))
        _, row = self.run_main('register', '--kind', 'build', '--ticket', 'CL-5', str(folder))
        self.assertEqual(row['tickets'], ['CL-1', 'CL-5'])
        with self.assertRaisesRegex(ValueError, 'registered as build'):
            clean_scratch.write_owner_record(folder, ['CL-1'], 'evidence')
        (folder / 'owner.json').write_text('{"version": 1, "kind": "build", "tickets": ["bad"]}')
        with self.assertRaises(ValueError):
            clean_scratch.read_owner_record(folder)
        link = self.repo / 'linked'; link.mkdir(); (link / 'owner.json').symlink_to(folder / 'owner.json')
        with self.assertRaisesRegex(ValueError, 'invalid owner record'):
            clean_scratch.read_owner_record(link)

    def test_tickets_command_and_cli_refusal(self):
        self.assertEqual(clean_scratch.requested_tickets(None, {'CHECKLIST_TICKETS': 'CL-2,,CL-1'}), ['CL-1', 'CL-2'])
        self.assertEqual(clean_scratch.requested_tickets(['CL-3'], {'CHECKLIST_TICKETS': 'CL-1'}), ['CL-3'])
        result = subprocess.run([sys.executable, str(ROOT / 'script/evidence_folder.py'), 'new', '--repo', str(self.repo), 'n'],
                                capture_output=True, text=True, env=dict(os.environ, CHECKLIST_TICKETS=''))
        self.assertEqual(result.returncode, 1); self.assertIn('register the new folder', result.stderr)
        self.assertFalse((self.repo / '.local/evidence/n').exists())


class StageRegistrationTests(unittest.TestCase):
    """build_and_run.sh: a stage-only build refuses before its lock without tickets."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve() / 'repo'; (self.repo / 'script').mkdir(parents=True)
        for name in ['build_and_run.sh', 'evidence_folder.py', 'clean_scratch.py', 'retire_old_bundles.py']:
            (self.repo / 'script' / name).write_bytes((ROOT / 'script' / name).read_bytes())

    def run_script(self, *argv, tickets=''):
        return subprocess.run(['bash', str(self.repo / 'script/build_and_run.sh'), *argv], capture_output=True, text=True,
                              env=dict(os.environ, CHECKLIST_TICKETS=tickets, CHECKLIST_BUILD_SCOPE='private-copy'), timeout=60)

    def test_stage_modes_refuse_unregistered_and_bad_arguments_before_lock(self):
        for mode in ['--stage', '--rebuild-stage', '--clean-stage']:
            result = self.run_script(mode)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('register it with --ticket KEY or CHECKLIST_TICKETS', result.stderr)
        for argv in [('--stage', '--ticket'), ('--stage', '--other'), ('--stage', '--ticket', 'bad')]:
            self.assertEqual(self.run_script(*argv).returncode, 2)
        self.assertFalse((self.repo / '.local/build/.build-lock').exists())

    def test_registered_stage_passes_the_gate(self):
        # Past the ticket gate the fixture repo lacks build inputs; the failure is the next step, not the gate.
        for argv, tickets in [(('--stage', '--ticket', 'CL-1'), ''), (('--stage',), 'CL-1,CL-2')]:
            result = self.run_script(*argv, tickets=tickets)
            self.assertNotIn('register it with --ticket', result.stderr)
            self.assertNotIn('Unknown argument', result.stderr)
            self.assertFalse((self.repo / '.local/build/.build-lock').exists())

    def test_capture_registration_step_records_keys_next_to_the_stage(self):
        source = (ROOT / 'script/build_and_run.sh').read_text()
        start = source.index('if [ -n "$BUILD_TICKETS" ]; then'); stop = source.index('phase stop capture', start)
        capture = self.repo / '.local/build' / ('f' * 64); capture.mkdir(parents=True)
        for tickets in ['CL-1', 'CL-2']:
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + source[start:stop]], capture_output=True, text=True,
                                    env=dict(os.environ, ROOT_DIR=str(self.repo), CAPTURE_DIR=str(capture), BUILD_TICKETS=tickets,
                                             MODE='--stage', BUILD_SCOPE='private-copy'))
            self.assertEqual(result.returncode, 0, result.stderr)
        record = clean_scratch.read_owner_record(capture)
        self.assertEqual((record['kind'], record['tickets']), ('build', ['CL-1', 'CL-2']))


if __name__ == '__main__':
    unittest.main()
