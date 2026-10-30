#!/usr/bin/env python3
"""CL-368 regression tests; temporary trees and fake status/move readers only."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import clean_builds as clean
import register_legacy_evidence as registration
from clean_scratch import write_owner_record


class EvidenceOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'
        self.evidence = self.repo / '.local/evidence'
        self.evidence.mkdir(parents=True)
        self.moves = []
        self.statuses = {'CL-344': 'active', 'CL-275': 'done', 'CL-52': 'done'}
        self.cleaner = clean.Cleaner(self.repo, self.root / 'Checklist.app',
            process_reader=lambda: [], status_reader=lambda keys: dict(self.statuses),
            batch_mover=lambda paths: self.move(paths))
        self.live = patch.object(clean.slots, 'live_root', return_value=self.root / 'live')
        self.live.start(); self.addCleanup(self.live.stop)

    def move(self, paths):
        self.moves.extend(paths)
        return {p: self.root / ('trashed-' + p.name) for p in paths}

    def folder(self, name):
        path = self.evidence / name
        path.mkdir(parents=True)
        return path

    def run_cleanup(self):
        self.cleaner.apply = True
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream): self.cleaner.evidence()
        return [json.loads(line) for line in stream.getvalue().splitlines()]

    def test_r58g_report_owns_alternative_ticket_fixture(self):
        runner = self.folder('integration-49/round58h/r58g')
        (runner / 'report.md').write_text('Round 58h check-runner report R58G\n\nCL-344: 1 NOT SHOWN, 2 NOT SHOWN, 3 PASS.\n\nCase CL-275\n')
        alternative = runner / 'alternative-CL-275'; alternative.mkdir()
        (alternative / 'CL-52-task.json').write_text('{}')
        (alternative / 'files.json').write_text('[{"ticket":"CL-275"}]')
        rows = self.run_cleanup()
        self.assertEqual(self.moves, [])
        owned = [row for row in rows if row['kind'] == 'evidence']
        self.assertEqual(len(owned), 1)
        self.assertEqual(owned[0]['path'], str(runner))
        self.assertEqual(owned[0]['tickets'], ['CL-344'])
        self.assertIn('CL-344', owned[0]['reason'])
        self.assertEqual(clean.evidence_owners(alternative)[0], {'CL-344'})

    def test_report_only_runner_is_discovered_through_unscoped_containers(self):
        runner = self.folder('integration-49/round58h/r58g')
        (runner / 'report.md').write_text('CL-344: NOT SHOWN\n')
        (runner / 'probe.log').write_text('data')
        rows = self.run_cleanup()
        owned = [row for row in rows if row['kind'] == 'evidence']
        self.assertEqual(len(owned), 1)
        self.assertEqual(owned[0]['path'], str(runner))
        self.assertEqual(owned[0]['tickets'], ['CL-344'])

    def test_enclosing_files_record_owns_whole_tree(self):
        for source in ('files.json', 'owner.json'):
            with self.subTest(source=source):
                runner = self.folder('integration-' + source)
                if source == 'files.json': (runner / source).write_text('[{"ticket":"CL-344"}]')
                else: write_owner_record(runner, ['CL-344'], 'evidence')
                child = runner / 'CL-275'; child.mkdir(); (child / 'CL-52.log').write_text('data')
                self.assertEqual(clean.evidence_owners(child)[0], {'CL-344'})
                self.assertEqual([p for step, p, _ in self.cleaner.evidence_plan(runner)[4] if step == 'handin'], [runner])

    def test_name_only_requires_all_enclosing_and_nested_tickets(self):
        parent = self.folder('CL-344-container')
        child = parent / 'CL-275'; child.mkdir(); (child / 'CL-52.log').write_text('data')
        rows = self.run_cleanup()
        self.assertEqual(self.moves, [])
        row = next(row for row in rows if row['path'] == str(parent))
        self.assertEqual(row['tickets'], ['CL-275', 'CL-344', 'CL-52'])
        self.assertIn('name-only ownership requires every named and enclosing ticket', row['reason'])
        self.assertEqual(clean.evidence_owners(child)[0], {'CL-344', 'CL-275', 'CL-52'})
        self.statuses['CL-344'] = 'canceled'
        self.run_cleanup()
        self.assertEqual(self.moves, [parent])

    def test_file_names_alone_cannot_create_owner(self):
        runner = self.folder('runner'); (runner / 'CL-275.json').write_text('{}')
        self.assertEqual(clean.evidence_owners(runner), (set(), 'none', []))

    def test_report_case_prose_does_not_register(self):
        runner = self.folder('runner'); (runner / 'report.md').write_text('Case CL-275\nA read of CL-52 succeeded.\n')
        plan = registration.registration_plan(self.repo)
        self.assertEqual(plan['proposed_count'], 0)
        self.assertEqual(plan['unresolved_count'], 1)

    def test_registration_plan_dry_run_and_apply(self):
        runner = self.folder('runner'); (runner / 'notes.md').write_text('Tickets: CL-344\nImplementation evidence.\n')
        (runner / 'CL-275').mkdir()
        unknown = self.folder('unknown'); (unknown / 'CL-52.log').write_text('log')
        plan = registration.registration_plan(self.repo)
        self.assertFalse((runner / 'owner.json').exists())
        self.assertEqual(plan['proposed_count'], 1)
        self.assertEqual(plan['unresolved_count'], 1)
        self.assertEqual(plan['rows'][0]['tickets'], ['CL-344'])
        result = registration.apply_plan(plan, self.repo)
        self.assertEqual(result[0]['tickets'], ['CL-344'])
        self.assertFalse((unknown / 'owner.json').exists())
        self.assertFalse((runner / 'CL-275/owner.json').exists())

    def test_registration_refuses_changed_source_before_any_write(self):
        runner = self.folder('runner'); (runner / 'report.md').write_text('Ticket: CL-344\n')
        plan = registration.registration_plan(self.repo)
        (runner / 'report.md').write_text('Ticket: CL-275\n')
        with self.assertRaisesRegex(ValueError, 'sources changed'):
            registration.apply_plan(plan, self.repo)
        self.assertFalse((runner / 'owner.json').exists())

    def test_malformed_owner_retains_tree_and_is_not_registered(self):
        runner = self.folder('runner'); (runner / 'owner.json').write_text('{}')
        child = runner / 'CL-275'; child.mkdir()
        self.assertTrue(clean.evidence_owners(child)[2])
        plan = registration.registration_plan(self.repo)
        self.assertEqual(plan['proposed_count'], 0)
        self.assertEqual(plan['unresolved_count'], 1)


if __name__ == '__main__':
    unittest.main()
