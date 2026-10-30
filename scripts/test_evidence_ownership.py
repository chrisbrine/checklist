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

    def runner_with_child(self, report, name='report.md', runner='integration-62/round62/r62b'):
        folder = self.folder(runner); (folder / name).write_text(report)
        child = folder / 'alternative-CL-275'; child.mkdir()
        (child / 'CL-52-task.json').write_text('{}')
        return folder, child

    def test_title_heading_report_keeps_child_until_its_ticket_is_finished(self):
        self.statuses['CL-361'] = 'active'
        runner, child = self.runner_with_child('## CL-361 "A title"\n\n| Item | Result |\n|---|---|\n| 1 | PASS |\n')
        row = next(r for r in self.run_cleanup() if r['path'] == str(child))
        self.assertEqual(self.moves, [])
        self.assertEqual(row['action'], 'kept')
        self.assertEqual(row['tickets'], ['CL-275', 'CL-361', 'CL-52'])
        self.assertIn('report mentions', row['owner_basis'])
        self.assertIn('every ticket a report or notes file mentions', row['reason'])
        self.assertIn('open or unknown ticket status: CL-361', row['reason'])
        self.statuses['CL-361'] = 'done'
        self.run_cleanup()
        self.assertEqual(self.moves, [child])

    def test_results_below_report_keeps_child_until_every_mention_is_finished(self):
        self.statuses.update({'CL-344': 'active', 'CL-345': 'done'})
        runner, child = self.runner_with_child('CL-344 and CL-345 results below.\n')
        row = next(r for r in self.run_cleanup() if r['path'] == str(child))
        self.assertEqual(self.moves, [])
        self.assertEqual(row['action'], 'kept')
        self.assertIn('CL-344', row['reason'])
        self.assertNotIn('CL-345', row['reason'])
        self.assertEqual(sorted(row['tickets']), ['CL-275', 'CL-344', 'CL-345', 'CL-52'])
        self.statuses['CL-344'] = 'canceled'
        self.run_cleanup()
        self.assertEqual(self.moves, [child])

    def test_notes_and_higher_integrator_reports_also_gate(self):
        for name in ('notes.md', 'integrator-report.md', 'round-notes.md'):
            with self.subTest(name=name):
                self.statuses['CL-361'] = 'active'
                folder = self.folder('integration-' + name + '/round/deeper')
                (folder.parent.parent / name).write_text('Later text.\n' * 40 + 'See CL-361 for this.\n')
                child = folder / 'CL-275'; child.mkdir()
                self.assertIn('CL-361', clean.evidence_owners(child)[0])

    def test_mention_gate_ignores_other_key_shapes_and_creates_no_owner(self):
        runner, child = self.runner_with_child('Hashes use SHA-256 and UTF-8 from GPT-6, Triage CL-T94; XCL-1 and CL-2x.\n')
        self.assertEqual(clean.evidence_owners(child)[0], {'CL-275', 'CL-52'})
        (runner / 'report.md').write_text('CL-361 and CL-362 results below.\n')
        bare = runner / 'plain'; bare.mkdir(); (bare / 'files.json').write_text('[{"path":"a"}]')
        self.assertEqual(clean.evidence_owners(bare), (set(), 'none', []))
        self.assertEqual(clean.evidence_owners(runner), (set(), 'none', []))

    def test_mention_gate_also_covers_a_ticket_manifest_and_the_folders_own_report(self):
        self.statuses['CL-361'] = 'active'
        runner = self.folder('integration-62/r62b'); (runner / 'report.md').write_text('## CL-361\n')
        child = runner / 'hand-in'; child.mkdir(); (child / 'files.json').write_text('[{"ticket":"CL-275"}]')
        keys, basis, _ = clean.evidence_owners(child)
        self.assertEqual(keys, {'CL-275', 'CL-361'})
        self.assertIn('report mentions', basis)
        own = self.folder('integration-63/CL-275-r1'); (own / 'notes.md').write_text('Rechecked with CL-361.\n')
        self.assertEqual(clean.evidence_owners(own)[0], {'CL-275', 'CL-361'})
        self.run_cleanup()
        self.assertEqual(self.moves, [])

    def test_explicit_child_owner_is_not_widened_by_an_enclosing_mention(self):
        runner = self.folder('integration-62/round'); (runner / 'integrator-report.md').write_text('CL-361 and CL-362\n')
        child = runner / 'r62a'; child.mkdir(); (child / 'report.md').write_text('CL-275: PASS\nRead CL-52.\n')
        self.assertEqual(clean.evidence_owners(child)[0], {'CL-275'})

    def test_unreadable_enclosing_report_retains_the_child(self):
        runner = self.folder('integration-62/r62b'); (runner / 'round-report.md').write_bytes(b'\xff\xfe CL-361')
        child = runner / 'CL-275'; child.mkdir()
        row = next(r for r in self.run_cleanup() if r['path'] == str(child))
        self.assertEqual(self.moves, [])
        self.assertEqual(row['registration'], 'invalid')
        self.assertIn('ownership record unreadable', row['reason'])

    def test_plan_proposes_attribution_from_first_lines_and_never_writes_it(self):
        heading = self.folder('heading'); (heading / 'report.md').write_text('## CL-344 "A title"\n')
        below = self.folder('below'); (below / 'notes.md').write_text('CL-344 and CL-275 results below.\n')
        late = self.folder('late'); (late / 'report.md').write_text('line\n' * 8 + 'CL-344\n')
        plain = self.folder('plain'); (plain / 'log.txt').write_text('CL-344')
        hashes = self.folder('hashes'); (hashes / 'notes.md').write_text('SHA-256 from GPT-6\n')
        plan = registration.registration_plan(self.repo)
        rows = {Path(r['path']).name: r for r in plan['rows']}
        self.assertEqual((plan['proposed_count'], plan['unresolved_count']), (0, 5))
        self.assertEqual((plan['attribution_proposed_count'], plan['unattributed_count']), (2, 3))
        self.assertEqual(rows['heading']['attribution']['tickets'], ['CL-344'])
        self.assertEqual(rows['heading']['attribution']['lines'],
                         [{'file': 'report.md', 'line': 1, 'text': '## CL-344 "A title"'}])
        self.assertEqual(rows['below']['attribution']['tickets'], ['CL-275', 'CL-344'])
        self.assertEqual(rows['below']['action'], 'unresolved')
        for name in ('late', 'plain', 'hashes'): self.assertNotIn('attribution', rows[name])
        self.assertNotIn('cleanup', rows['heading'])
        self.assertEqual(registration.apply_plan(plan, self.repo), [])
        self.assertEqual(list(self.evidence.rglob('owner.json')), [])

    def test_plan_says_what_cleanup_would_do(self):
        reads = []
        def reader(keys):
            reads.append(sorted(keys)); return dict(self.statuses)
        finished = self.folder('finished'); (finished / 'notes.md').write_text('Ticket: CL-275\n')
        opened = self.folder('open'); (opened / 'report.md').write_text('Ticket: CL-344\n')
        attributed = self.folder('attributed'); (attributed / 'report.md').write_text('## CL-52 title\n')
        blocked = self.folder('blocked'); (blocked / 'report.md').write_text('## CL-344 title\n')
        unknown = self.folder('unknown'); (unknown / 'log.txt').write_text('data')
        container = self.folder('container/round'); (container / 'report.md').write_text('Ticket: CL-275\n')
        (self.evidence / 'container/log.txt').write_text('data')
        plan = registration.registration_plan(self.repo, reader)
        rows = {str(Path(r['path']).relative_to(self.evidence)): r['cleanup'] for r in plan['rows']}
        self.assertEqual(rows['finished']['action'], 'moves_to_trash')
        self.assertEqual(rows['finished']['tickets'], ['CL-275'])
        self.assertIn('Trash', rows['finished']['reason'])
        self.assertEqual(rows['open']['action'], 'kept')
        self.assertIn('CL-344', rows['open']['reason'])
        self.assertEqual(rows['attributed']['action'], 'kept')
        self.assertEqual(rows['attributed']['if_attribution_registered'], 'moves_to_trash')
        self.assertIn('kept; open or unknown ticket status: CL-344', rows['blocked']['if_attribution_registered'])
        self.assertEqual(rows['unknown']['action'], 'kept')
        self.assertIn('container retained; cleanup decides 1 hand-ins', rows['container']['reason'])
        self.assertEqual(plan['cleanup_counts']['moves_to_trash_if_attribution_registered'], 1)
        self.assertEqual(self.moves, [])
        self.assertEqual(list(self.evidence.rglob('owner.json')), [])
        self.assertEqual(len(reads), 1)

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
