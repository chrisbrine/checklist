#!/usr/bin/env python3
"""Cleanup safety tests: only temporary trees; never native Trash/live slots."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import stat
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import clean_builds as clean
import clean_scratch
import test_instances as slots


class CleanupTests(unittest.TestCase):
    def setUp(self):
        # Caller scratch markers must not protect disposable cleanup fixtures.
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.build = self.repo / '.local/build'; self.build.mkdir(parents=True)
        self.evidence = self.repo / '.local/evidence'; self.evidence.mkdir()
        self.apps = self.root / 'Applications'; self.apps.mkdir()
        self.installed = self.apps / 'Checklist.app'
        self.previous = self.apps / '.Checklist-previous-20261022T010203Z-10.app'
        self.live = self.root / 'live'; self.live.mkdir()
        self.base = self.root / 'slots'; self.base.mkdir()
        self.trash = self.root / 'Trash'; self.trash.mkdir()
        self.ids = ['a'*64, 'b'*64, 'c'*64]
        self.info(self.installed, self.ids[0]); self.info(self.previous, self.ids[1])
        self.record()
        self.moves = []
        self.processes = []
        self.statuses = {'CL-1': 'done', 'CL-2': 'active'}
        for name, value in [('BASE', self.base), ('LIVE', self.live)]:
            p = patch.object(slots, name, value); p.start(); self.addCleanup(p.stop)
        p = patch.object(slots, 'live_root', return_value=self.live); p.start(); self.addCleanup(p.stop)
        # post_install never reaches the real scratch, sessions or CLI (CL-359 release step).
        self.releases = []
        p = patch.object(clean, 'release_done', side_effect=lambda repo: self.releases.append(repo) or 0)
        p.start(); self.addCleanup(p.stop)
        self.cleaner = clean.Cleaner(self.repo, self.installed, process_reader=lambda: self.processes,
                                     mover=self.move, batch_mover=self.move_batch, status_reader=lambda keys: dict(self.statuses))

    def info(self, bundle, key):
        p = bundle / 'Contents/Resources/build-info.json'; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({'source_fingerprint': key}))

    def record(self, previous=True):
        (self.build / 'last-install.json').write_text(json.dumps({'installed': str(self.installed),
            'previous_bundle': str(self.previous) if previous else None,
            'build': {'source_fingerprint': self.ids[0]}}))

    def capture(self, key):
        p = self.build / key; p.mkdir()
        (p / 'capture-manifest.json').write_text(json.dumps({'source_fingerprint': key}))
        for name in ['build-info.json', 'build-verification.json', 'last-install.json', 'build-timings.jsonl']:
            (p / name).write_text('receipt')
        for name in ['source', 'Checklist.app', '.build', 'products']:
            (p / name).mkdir(); (p / name / 'bytes').write_bytes(b'output')
        (p / 'unknown-note').write_text('preserve')
        return p

    def handin(self, name='CL-1'):
        p = self.evidence / name; p.mkdir(parents=True)
        (p / 'files.json').write_text(json.dumps([{'ticket': 'CL-1'}]))
        (p / 'report').write_text('evidence')
        return p

    def slot(self):
        p = slots.paths(1); p['folder'].mkdir()
        (p['folder'] / 'slot.json').write_text(json.dumps({'slot': 1}))
        return p

    def move(self, p):
        destination = self.trash / str(len(self.moves))
        p.rename(destination); self.moves.append((p, destination)); return destination

    def move_batch(self, paths):
        return {p: self.move(p) for p in paths}

    def run_clean(self, method, apply=False):
        self.cleaner.apply = apply
        output = io.StringIO()
        with contextlib.redirect_stdout(output): method()
        return [json.loads(line) for line in output.getvalue().splitlines() if line.startswith('{')]

    def test_coverage_and_index_selection_evidence_survives_preview_and_apply(self):
        paths = [self.build / 'test-impact-map.json', self.build / 'test-impact-index.json',
                 self.build / 'index-inputs.json']
        for path in paths: path.write_text('selection evidence')
        for apply in (False, True):
            reports = self.run_clean(self.cleaner.builds, apply)
            selected = [report for report in reports if report['kind'] == 'test_selection_cache']
            self.assertEqual(len(selected), 3)
            self.assertTrue(all(report['action'] == 'kept' for report in selected))
            self.assertTrue(all(path.exists() for path in paths))
        self.assertEqual(self.moves, [])

    def test_preview_changes_nothing_and_apply_preserves_both_builds_and_all_receipts(self):
        captures = [self.capture(key) for key in self.ids]
        before = {p: p.read_bytes() for p in self.repo.rglob('*') if p.is_file()}
        self.run_clean(self.cleaner.builds)
        self.assertEqual(before, {p:p.read_bytes() for p in self.repo.rglob('*') if p.is_file()})
        self.run_clean(self.cleaner.builds, True)
        self.assertEqual(len(self.moves), 4)
        for p in captures[:2]: self.assertTrue((p/'source/bytes').exists())
        for name in ['capture-manifest.json', 'build-info.json', 'build-verification.json', 'last-install.json', 'build-timings.jsonl', 'unknown-note']:
            self.assertTrue((captures[2]/name).exists())
        self.assertEqual(self.cleaner.moved, 4 * len(b'output'))
        self.assertEqual(sum(clean.size_of(clean.inventory(p)) for _,p in self.moves), self.cleaner.moved)

    def test_only_unpaired_legacy_scratch_is_retired_current_configurations_stay_warm(self):
        legacy = self.build / ('swiftpm-'+'1'*20); legacy.mkdir(); (legacy/'object').write_text('old')
        for token in ['2'*20, '3'*20]:
            (self.build/('swiftpm-'+token)).mkdir(); (self.build/('lane-'+token)/'source').mkdir(parents=True)
        self.run_clean(self.cleaner.builds, True)
        self.assertFalse(legacy.exists()); self.assertEqual(len(self.moves), 1)
        self.assertEqual(len(list(self.build.glob('swiftpm-*'))), 2)

    def test_checkout_install_preview_uses_bundle_identities_and_reports_sizes(self):
        captures = [self.capture(key) for key in self.ids]
        reports = self.run_clean(self.cleaner.builds)
        self.assertEqual([r['path'] for r in reports if r['action'] == 'kept'],
                         [str(p) for p in captures[:2]])
        eligible = [r for r in reports if r['action'] == 'eligible']
        self.assertEqual(len(eligible), 4)
        self.assertTrue(all(r['bytes'] == len(b'output') for r in eligible))
        self.assertEqual(self.moves, [])

    def test_other_checkout_install_ignores_stale_missing_or_invalid_local_receipt(self):
        captures = [self.capture(key) for key in self.ids]
        receipt = self.build / 'last-install.json'
        for state in ['stale', 'absent', 'invalid']:
            with self.subTest(state=state):
                if state == 'stale':
                    receipt.write_text(json.dumps({'installed': str(self.installed),
                        'build': {'source_fingerprint': 'd'*64}, 'previous_bundle': '/old/absent.app'}))
                elif state == 'absent': receipt.unlink()
                else: receipt.write_text('{')
                reports = self.run_clean(self.cleaner.builds)
                self.assertEqual(sum(r['action'] == 'eligible' for r in reports), 4)
                self.assertTrue(all(str(p) in [r['path'] for r in reports if r['action'] == 'kept']
                                    for p in captures[:2]))
        self.assertEqual(self.moves, [])
        self.run_clean(self.cleaner.builds, True)
        self.assertEqual(len(self.moves), 4)
        self.assertTrue(all((p/'source/bytes').exists() for p in captures[:2]))

    def test_missing_previous_identity_retains_every_build(self):
        self.capture(self.ids[2]); shutil.rmtree(self.previous)
        with self.assertRaises(OSError):
            self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_other_checkout_reinstall_same_fingerprint_ignores_missing_older_predecessor(self):
        captures = [self.capture(key) for key in self.ids]
        newer = self.apps/'.Checklist-previous-20261023T010203Z-20.app'
        self.info(newer, self.ids[0])
        shutil.rmtree(self.previous)
        reports = self.run_clean(self.cleaner.builds)
        self.assertEqual(clean.installation(self.build, self.installed),
                         ({self.ids[0]}, [self.installed, newer]))
        self.assertEqual([r['path'] for r in reports if r['action'] == 'kept'],
                         [str(captures[0])])
        eligible = [r for r in reports if r['action'] == 'eligible']
        self.assertEqual(len(eligible), 8)
        self.assertTrue(all(r['bytes'] == len(b'output') for r in eligible))
        self.assertEqual(self.moves, [])

    def test_unreadable_installed_or_previous_identity_retains_every_build_and_reports_reason(self):
        captures = [self.capture(key) for key in self.ids]
        before = {p: p.read_bytes() for folder in captures for p in folder.rglob('*') if p.is_file()}
        for bundle in [self.installed, self.previous]:
            for state in ['missing', 'invalid']:
                with self.subTest(bundle=bundle, state=state):
                    path = bundle/'Contents/Resources/build-info.json'
                    if state == 'missing': path.unlink()
                    else: path.write_text(json.dumps({'source_fingerprint': 'invalid'}))
                    output = io.StringIO()
                    with patch.object(sys, 'argv', ['clean_builds.py', '--preview', '--only', 'builds',
                            '--repo', str(self.repo), '--installed-app', str(self.installed)]), \
                         contextlib.redirect_stdout(output):
                        self.assertEqual(clean.main(), 1)
                    reports = [json.loads(line) for line in output.getvalue().splitlines()]
                    self.assertEqual(reports[0]['action'], 'kept_error')
                    self.assertTrue(reports[0]['reason'])
                    self.assertFalse(any(r['action'] == 'eligible' for r in reports))
                    self.assertEqual(before, {p: p.read_bytes() for folder in captures for p in folder.rglob('*') if p.is_file()})
                    self.info(bundle, self.ids[0] if bundle == self.installed else self.ids[1])
        self.assertEqual(self.moves, [])

    def test_newest_previous_bundle_wins_over_stale_record_and_older_bundles(self):
        for key in self.ids: self.capture(key)
        newer = self.apps/'.Checklist-previous-20261023T010203Z-20.app'
        self.info(newer, self.ids[2])
        reports = self.run_clean(self.cleaner.builds)
        self.assertTrue(any(r['path'] == str(self.build/self.ids[1]/'source')
                            and r['action'] == 'eligible' for r in reports))
        self.assertTrue(any(r['path'] == str(self.build/self.ids[2])
                            and r['action'] == 'kept' for r in reports))
        (newer/'Contents/Resources/build-info.json').unlink()
        with self.assertRaises(OSError): self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_ambiguous_previous_bundles_retain_every_build(self):
        self.capture(self.ids[2])
        self.info(self.apps/'.Checklist-previous-20261022T010203Z-11.app', self.ids[2])
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_missing_recorded_previous_cannot_fall_back_to_older_survivor(self):
        self.capture(self.ids[2])
        self.info(self.apps/'.Checklist-previous-20261021T010203Z-9.app', self.ids[2])
        shutil.rmtree(self.previous)
        with self.assertRaises(OSError): self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_unreadable_identity_shape_retains_every_build(self):
        self.capture(self.ids[2])
        (self.installed/'Contents/Resources/build-info.json').write_text('[]')
        with self.assertRaisesRegex(ValueError, 'source fingerprint'):
            self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_first_install_without_previous_can_retire_old_outputs(self):
        self.record(False); shutil.rmtree(self.previous); self.capture(self.ids[2])
        self.run_clean(self.cleaner.builds, True); self.assertEqual(len(self.moves),4)

    def test_no_previous_and_stale_receipt_cannot_prove_first_install(self):
        self.record(False); shutil.rmtree(self.previous); self.info(self.installed, 'd'*64)
        self.capture(self.ids[2])
        with self.assertRaisesRegex(ValueError, 'previous bundle identity'):
            self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_build_process_preserves_entire_capture(self):
        p = self.capture(self.ids[2]); self.processes = [p/'source/Package.swift']
        reports = self.run_clean(self.cleaner.builds, True)
        self.assertTrue(all((p/name/'bytes').exists() for name in ['source', 'Checklist.app', '.build', 'products']))
        self.assertEqual(len(reports), 1); self.assertIn('uses this capture', reports[0]['reason'])
        self.assertEqual(self.moves, [])

    def test_running_copied_bundle_preserves_its_checkout_capture(self):
        p = self.capture(self.ids[2])
        bundle = self.apps/'Renamed Qualification.app'; self.info(bundle, self.ids[2])
        self.processes = [bundle/'Contents/MacOS/ChecklistApp']
        reports = self.run_clean(self.cleaner.builds, True)
        self.assertEqual(reports[0]['action'], 'kept')
        self.assertIn('running app bundle', reports[0]['reason'])
        self.assertTrue((p/'source').exists()); self.assertEqual(self.moves, [])

    def test_running_test_slot_bundle_outside_applications_preserves_capture(self):
        p = self.capture(self.ids[2])
        bundle = self.base/'slot-1/Checklist Test 1.app'; self.info(bundle, self.ids[2])
        self.processes = [bundle/'Contents/MacOS/ChecklistService']
        reports = self.run_clean(self.cleaner.builds, True)
        self.assertEqual(reports[0]['action'], 'kept')
        self.assertTrue((p/'source').exists()); self.assertEqual(self.moves, [])

    def test_copied_bundle_starts_before_batch_preserves_its_capture(self):
        p = self.capture(self.ids[2])
        bundle = self.apps/'Renamed Qualification.app'; self.info(bundle, self.ids[2])
        with patch.object(self.cleaner, 'process_reader', side_effect=[[], [bundle/'Contents/MacOS/ChecklistApp']]):
            reports = self.run_clean(self.cleaner.builds, True)
        self.assertTrue(all(r['action'] == 'kept' for r in reports))
        self.assertTrue((p/'source').exists()); self.assertEqual(self.moves, [])

    def test_unreadable_running_bundle_identity_retains_every_build(self):
        self.capture(self.ids[2])
        bundle = self.apps/'Renamed Qualification.app'; bundle.mkdir()
        self.processes = [bundle/'Contents/MacOS/ChecklistApp']
        with self.assertRaises(OSError): self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_live_store_overlap_is_never_retired(self):
        p = self.capture(self.ids[2]); self.live = p/'source'
        with patch.object(slots,'live_root', return_value=self.live): self.run_clean(self.cleaner.builds,True)
        self.assertTrue((p/'source/bytes').exists())

    def test_explicit_keep_protects_build_evidence_and_idle_slot(self):
        p = self.capture(self.ids[2]); e=self.handin(); slot=self.slot()
        self.cleaner.keep = [p,e,slot['folder']]
        self.run_clean(self.cleaner.builds,True); self.run_clean(self.cleaner.evidence,True)
        with patch.object(slots,'launch_state',return_value={'registered':False}), patch.object(slots,'processes',return_value={}):
            with patch.object(slots,'destroy') as destroy: self.run_clean(self.cleaner.test_slots,True)
            destroy.assert_not_called()
        self.assertEqual(self.moves,[])

    def marker(self, root, released=False):
        clean_scratch.write_marker(root, 'fixture-session', 'persistent test workspace')
        if released: clean_scratch.write_marker(root, 'fixture-session', release=True)

    def assert_marker_keeps(self, method, path, reason='persistent workspace marker'):
        for apply in [False, True]:
            reports = self.run_clean(method, apply)
            report = next(r for r in reports if r['path'] == str(path))
            self.assertEqual(report['action'], 'kept', report)
            self.assertIn(reason, report['reason'])
            self.assertTrue(path.exists())
        self.assertEqual(self.moves, [])

    def test_evidence_workspace_markers_at_root_child_and_ancestor(self):
        for location in ['root', 'child', 'ancestor']:
            with self.subTest(location=location):
                p = self.handin('round-' + location + '/CL-1')
                root = p if location == 'root' else p / 'nested' if location == 'child' else p.parent
                root.mkdir(exist_ok=True)
                self.marker(root)
                self.assert_marker_keeps(self.cleaner.evidence, p)

    def test_invalid_linked_and_unreadable_workspace_markers_keep_evidence(self):
        for kind in ['malformed', 'linked', 'unreadable']:
            with self.subTest(kind=kind):
                p = self.handin(kind + '/CL-1')
                marker = p / clean_scratch.WORKSPACE_MARKER
                if kind == 'malformed': marker.write_text('{')
                elif kind == 'linked': marker.symlink_to(p / 'report')
                else: self.marker(p)
                native_open = clean_scratch.os.open
                def read(path, *args, **kwargs):
                    if kind == 'unreadable' and Path(path) == marker:
                        raise PermissionError('fixture unreadable marker')
                    return native_open(path, *args, **kwargs)
                with patch.object(clean_scratch.os, 'open', side_effect=read):
                    self.assert_marker_keeps(self.cleaner.evidence, p, 'invalid/unreadable workspace marker')

    def test_released_workspace_marker_does_not_bypass_open_ticket_or_inner_marker(self):
        p = self.handin('released/CL-1-CL-2'); self.marker(p, released=True)
        reports = self.run_clean(self.cleaner.evidence, True)
        self.assertTrue(p.exists()); self.assertIn('open or unknown', reports[-1]['reason'])
        self.statuses['CL-2'] = 'done'
        nested = p / 'nested'; nested.mkdir(); self.marker(nested)
        self.assert_marker_keeps(self.cleaner.evidence, p)
        clean_scratch.write_marker(nested, 'fixture-session', release=True)
        reports = self.run_clean(self.cleaner.evidence)
        self.assertEqual(reports[-1]['action'], 'eligible')
        self.run_clean(self.cleaner.evidence, True)
        self.assertFalse(p.exists()); self.assertEqual(len(self.moves), 1)

    def test_marked_capture_protects_every_output_and_unpaired_scratch(self):
        p = self.capture(self.ids[2]); self.marker(p)
        scratch = self.build / ('swiftpm-' + '1'*20); scratch.mkdir(); self.marker(scratch)
        for apply in [False, True]:
            reports = self.run_clean(self.cleaner.builds, apply)
            self.assertEqual(len(reports), 5)
            self.assertTrue(all(r['action'] == 'kept' and 'workspace marker' in r['reason'] for r in reports))
        self.assertEqual(self.moves, [])
        self.assertTrue((p/'source/bytes').exists()); self.assertTrue(scratch.exists())

    def test_marked_idle_slot_never_destroys(self):
        p = self.slot(); self.marker(p['folder'])
        with patch.object(slots, 'launch_state', return_value={'registered': False}), \
             patch.object(slots, 'processes', return_value={}), patch.object(slots, 'destroy') as destroy:
            self.assert_marker_keeps(self.cleaner.test_slots, p['folder'])
            destroy.assert_not_called()

    def test_ancestor_marker_added_before_evidence_move_is_rechecked(self):
        p = self.handin(); calls = 0
        def processes():
            nonlocal calls
            calls += 1
            if calls == 2: self.marker(self.evidence)
            return []
        self.cleaner.process_reader = processes
        reports = self.run_clean(self.cleaner.evidence, True)
        self.assertEqual(reports[-1]['action'], 'kept')
        self.assertIn('workspace marker', reports[-1]['reason'])
        self.assertTrue(p.exists()); self.assertEqual(self.moves, [])

    def test_ancestor_marker_added_before_build_batch_is_rechecked(self):
        p = self.capture(self.ids[2]); calls = 0
        def processes():
            nonlocal calls
            calls += 1
            if calls == 2: self.marker(p)
            return []
        self.cleaner.process_reader = processes
        reports = self.run_clean(self.cleaner.builds, True)
        self.assertTrue(all(r['action'] == 'kept' and 'workspace marker' in r['reason'] for r in reports))
        self.assertEqual(self.moves, [])

    def test_post_install_honors_workspace_markers(self):
        current = self.capture(self.ids[0])
        obsolete = self.capture(self.ids[2]); self.marker(obsolete)
        scratch = self.build / ('swiftpm-' + '1'*20); scratch.mkdir(); self.marker(scratch)
        self.cleaner.apply = True
        with patch.object(clean, 'Cleaner', return_value=self.cleaner), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(clean.post_install(self.repo, current), 0)
        self.assertEqual(self.moves, [])
        self.assertTrue((obsolete/'source/bytes').exists()); self.assertTrue(scratch.exists())

    def test_swiftpm_cyclic_and_dangling_links_retained_in_preview_and_apply(self):
        for kind in ['cycle', 'dangling']:
            with self.subTest(kind=kind):
                scratch = self.build / ('swiftpm-' + ('1' if kind == 'cycle' else '2')*20)
                scratch.mkdir(); link = scratch / 'link'
                link.symlink_to('link' if kind == 'cycle' else 'missing')
                for apply in [False, True]:
                    reports = self.run_clean(self.cleaner.builds, apply)
                    report = next(r for r in reports if r['path'] == str(scratch))
                    self.assertEqual(report['action'], 'kept', report)
                    self.assertIn('unresolved SwiftPM link', report['reason'])
                    self.assertIn(str(link), report['reason'])
                    self.assertTrue(scratch.exists())
        self.assertEqual(self.moves, [])

    def test_open_and_unknown_evidence_retained_done_or_canceled_trashed(self):
        p=self.handin('CL-1-CL-2'); self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())
        self.statuses.pop('CL-2'); self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())
        self.statuses['CL-2']='canceled'; self.run_clean(self.cleaner.evidence,True); self.assertFalse(p.exists())
        self.assertTrue(self.moves[0][1].exists())

    def test_owner_record_decides_before_files_json_and_folder_name(self):
        # files.json and the name say CL-2 (open); owner.json registers CL-1 (Done).
        p=self.handin('CL-2-handin'); (p/'files.json').write_text(json.dumps([{'ticket':'CL-2'}]))
        clean_scratch.write_owner_record(p,['CL-1'],'evidence','fixture')
        rows=self.run_clean(self.cleaner.evidence,True)
        row=next(r for r in rows if r.get('path')==str(p))
        self.assertEqual((row['action'],row['registration'],row['tickets']),('trashed','owner.json',['CL-1']))
        # An open registered ticket keeps its folder even when the name says Done.
        q=self.handin('CL-1-open'); clean_scratch.write_owner_record(q,['CL-2'],'evidence')
        self.run_clean(self.cleaner.evidence,True); self.assertTrue(q.exists())

    def test_invalid_owner_record_retains_and_unregistered_folders_are_listed(self):
        bad=self.handin('CL-1-bad'); (bad/'owner.json').write_text('{"version": 1, "kind": "evidence", "tickets": []}')
        old=self.handin('CL-1-old')
        loose=self.evidence/'store-copy'; loose.mkdir(); (loose/'checklist.sqlite').write_bytes(b'db')
        rows=self.run_clean(self.cleaner.evidence,True); self.cleaner.apply=False
        self.assertTrue(bad.exists())
        self.assertEqual(next(r for r in rows if r.get('path')==str(old))['registration'],'unregistered')
        output=io.StringIO()
        with contextlib.redirect_stdout(output): clean.finish(self.cleaner)
        summary=json.loads(output.getvalue())
        self.assertIn(str(old),summary['unregistered']); self.assertIn(str(loose),summary['unregistered'])
        self.assertNotIn(str(bad),summary['unregistered'])

    def test_registered_store_copy_in_evidence_retires_whole_on_done(self):
        p=self.evidence/'qualification-copy'; (p/'managed').mkdir(parents=True); (p/'checklist.sqlite').write_bytes(b'db')
        clean_scratch.write_owner_record(p,['CL-1'],'evidence')
        self.run_clean(self.cleaner.evidence,True); self.assertFalse(p.exists())

    def test_build_capture_and_slot_reports_carry_registration(self):
        old=self.capture('d'*64); clean_scratch.write_owner_record(old,['CL-7'],'build')
        bare=self.capture('e'*64)
        rows=self.run_clean(self.cleaner.builds)
        child=next(r for r in rows if r.get('path')==str(old/'source'))
        self.assertEqual((child['capture_registration'],child['tickets']),('owner.json',['CL-7']))
        self.assertIn(str(bare),self.cleaner.unregistered); self.assertNotIn(str(old),self.cleaner.unregistered)
        p=self.slot(); (p['folder']/'slot.json').write_text(json.dumps({'slot':1,'tickets':['CL-3']}))
        self.assertEqual(clean.slot_registration(p),{'registration':'slot.json','tickets':['CL-3']})
        (p['folder']/'slot.json').write_text(json.dumps({'slot':1}))
        self.assertEqual(clean.slot_registration(p)['registration'],'unregistered')

    def test_post_install_runs_release_done_after_build_cleanup(self):
        current=self.capture(self.ids[0]); self.cleaner.apply=True
        with patch.object(clean,'Cleaner',return_value=self.cleaner), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(clean.post_install(self.repo,current),0)
            self.assertEqual(self.releases,[self.repo])
            self.assertFalse((self.build/'.build-lock').exists())
            # A failed release reports failure but never undoes the build cleanup.
            self.assertEqual(clean.post_install(self.repo,current,release=lambda repo:1),1)

    def test_manifest_mixed_tickets_override_folder_done_key(self):
        p=self.handin(); (p/'files.json').write_text(json.dumps([{'ticket':'CL-2'}]))
        self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())

    def test_nested_round_selects_ticket_children_preserves_unscoped_round_logs(self):
        p=self.handin('integration-23/CL-1'); log=p.parent/'round.log'; log.write_text('retain')
        self.run_clean(self.cleaner.evidence,True)
        self.assertFalse(p.exists()); self.assertTrue(log.exists())

    def test_explicit_cleanup_manifest_scopes_round_folder(self):
        p=self.evidence/'round';p.mkdir();(p/'cleanup.json').write_text(json.dumps({'tickets':['CL-1','CL-2']}))
        self.run_clean(self.cleaner.evidence,True);self.assertTrue(p.exists())
        self.statuses['CL-2']='done';self.run_clean(self.cleaner.evidence,True);self.assertFalse(p.exists())

    def test_malformed_manifest_and_unscoped_evidence_are_retained(self):
        # CL-359 rework: an unreadable record or no owner retains the folder without failing the run.
        p=self.handin();(p/'files.json').write_text('[{')
        unknown=self.evidence/'unknown';unknown.mkdir();(unknown/'report').write_text('retain')
        reports=self.run_clean(self.cleaner.evidence,True)
        self.assertTrue(p.exists());self.assertTrue(unknown.exists());self.assertFalse(self.cleaner.failed)
        self.assertIn('ownership record unreadable', next(r for r in reports if r['path']==str(p))['reason'])
        # An entry with no ticket key falls back to the folder name (CL-1 is done).
        (p/'files.json').write_text('[{}]'); self.run_clean(self.cleaner.evidence,True)
        self.assertFalse(p.exists());self.assertTrue(unknown.exists());self.assertFalse(self.cleaner.failed)

    def test_symlinked_roots_items_and_nested_links_never_escape(self):
        outside=self.root/'outside';outside.mkdir();(outside/'CL-1').mkdir()
        (self.evidence/'alias').symlink_to(outside, target_is_directory=True)
        p=self.handin();(p/'link').symlink_to(self.live, target_is_directory=True)
        self.run_clean(self.cleaner.evidence,True)
        self.assertEqual(self.moves,[]);self.assertTrue((outside/'CL-1').exists())
        with self.assertRaises(ValueError): clean.Cleaner(self.evidence/'alias', self.installed)

    def test_installed_and_previous_app_overlap_never_moves(self):
        for app in [self.installed, self.previous]:
            self.cleaner.item(app,'fixture')
        self.assertEqual(self.moves,[])

    def test_process_inspection_failure_does_not_move_anything(self):
        self.handin()
        with patch.object(self.cleaner,'process_reader',side_effect=ValueError('unknown process state')):
            self.run_clean(self.cleaner.evidence,True)
        self.assertEqual(self.moves,[]);self.assertTrue(self.cleaner.failed)

    def test_process_start_between_plan_and_move_retains_evidence(self):
        p=self.handin()
        with patch.object(self.cleaner,'process_reader',side_effect=[[],[p/'report']]):
            self.run_clean(self.cleaner.evidence,True)
        self.assertEqual(self.moves,[])

    def test_evidence_batch_uses_two_snapshots_and_rechecks_only_selected_paths(self):
        handins = sorted(self.handin('round/package-' + str(n)) for n in range(12))
        kept = self.evidence / 'unscoped'; kept.mkdir()
        (kept / 'log').write_text('keep')
        with patch.object(self.cleaner, 'process_reader', return_value=[]) as reader, \
             patch.object(clean, 'inventory', wraps=clean.inventory) as inventories, \
             patch.object(self.cleaner, 'batch_mover', wraps=self.move_batch) as mover:
            reports = self.run_clean(self.cleaner.evidence, True)
        self.assertEqual(reader.call_count, 2)
        mover.assert_called_once_with(handins)
        self.assertEqual([call.args[0] for call in inventories.call_args_list],
                         [handins[0].parent, kept] + handins)
        self.assertEqual(sum(r['action'] == 'trashed' for r in reports), 12)
        self.assertTrue(kept.exists())

    def test_evidence_batch_new_use_keeps_only_the_used_handin(self):
        used = self.handin('round/used'); idle = self.handin('round/idle')
        with patch.object(self.cleaner, 'process_reader', side_effect=[[], [used / 'report']]) as reader:
            reports = self.run_clean(self.cleaner.evidence, True)
        self.assertEqual(reader.call_count, 2)
        self.assertTrue(used.exists()); self.assertFalse(idle.exists())
        self.assertIn('uses this path', next(r for r in reports if r['path'] == str(used))['reason'])

    def test_deep_store_copy_is_sized_once_and_reported_as_one_retained_container(self):
        store = self.evidence / 'round/copy'
        deep = store / 'managed/source-captures' / '/'.join('level-' + str(n) for n in range(40))
        deep.mkdir(parents=True)
        (store / 'checklist.sqlite').write_bytes(b'store')
        # Internal file names and manifests are not cleanup hand-ins.
        (deep / 'files.json').write_text('[{"ticket":"CL-1"}]')
        (deep / 'CL-1').mkdir(); (deep / 'CL-1/log').write_bytes(b'retain')
        handin = self.handin('round/handin')
        expected = clean.size_of(clean.inventory(store))
        with patch.object(clean, 'inventory', wraps=clean.inventory) as inventories:
            reports = self.run_clean(self.cleaner.evidence, True)
        self.assertEqual([c.args[0] for c in inventories.call_args_list], [store.parent, handin])
        retained = [r for r in reports if r['action'] == 'kept']
        self.assertEqual({r['path'] for r in retained}, {str(store.parent), str(store)})
        report = next(r for r in retained if r['path'] == str(store))
        self.assertEqual(report['bytes'], expected)
        self.assertIn('store/source tree retained', report['reason'])
        self.assertTrue((deep / 'CL-1/log').exists())

    def test_kept_evidence_needs_no_process_observation(self):
        self.handin('CL-2')
        with patch.object(self.cleaner, 'process_reader', side_effect=AssertionError('retained item scanned')):
            self.run_clean(self.cleaner.evidence, True)
        self.assertEqual(self.moves, [])

    def test_ticket_reopened_between_plan_and_move_retains_evidence(self):
        self.handin()
        with patch.object(self.cleaner,'status_reader',side_effect=[{'CL-1':'done'},{'CL-1':'active'}]):
            self.run_clean(self.cleaner.evidence,True)
        self.assertEqual(self.moves,[])

    def test_changed_tree_between_inspection_and_move_is_retained(self):
        p=self.handin(); calls=0
        def process_reader():
            nonlocal calls
            calls+=1
            if calls==1:(p/'new').write_text('new work')
            return []
        self.cleaner.process_reader=process_reader
        self.run_clean(self.cleaner.evidence,True)
        self.assertEqual(self.moves,[]);self.assertTrue(self.cleaner.failed)

    def test_install_changes_before_batch_retains_remaining_outputs(self):
        self.capture(self.ids[2])
        calls=0
        def processes():
            nonlocal calls
            calls+=1
            if calls==2:self.info(self.installed, 'd'*64)
            return []
        with patch.object(self.cleaner, 'process_reader', side_effect=processes):
            self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_build_lock_refuses_manual_apply_and_preview(self):
        lock=self.build/'.build-lock';lock.mkdir()
        for apply in [False,True]:
            with self.assertRaisesRegex(ValueError,'build lock held'):
                with clean.build_lock(self.build,apply):self.fail('should not enter')
        self.assertTrue(lock.exists())

    def test_apply_build_lease_blocks_other_commands_and_releases(self):
        with clean.build_lock(self.build,True):
            self.assertTrue((self.build/'.build-lock').exists())
            with self.assertRaises(ValueError):
                with clean.build_lock(self.build,True):pass
        self.assertFalse((self.build/'.build-lock').exists())

    def test_running_slot_registered_job_and_check_lock_are_retained(self):
        p=self.slot()
        cases=[({'registered':True},{},[]),({'registered':False},{'app':[42]},[]),
               ({'registered':False},{},[p['folder']/'check.log'])]
        with patch.object(slots,'destroy') as destroy:
            for launch,procs,paths in cases:
                self.processes=paths
                with patch.object(slots,'launch_state',return_value=launch),patch.object(slots,'processes',return_value=procs):
                    self.run_clean(self.cleaner.test_slots,True)
            (self.base/'.slot-1.lock').mkdir();self.processes=[]
            with patch.object(slots,'launch_state',side_effect=AssertionError('must not inspect locked slot')):
                self.run_clean(self.cleaner.test_slots,True)
            destroy.assert_not_called()
        self.assertTrue(p['folder'].exists())

    def test_idle_slot_preview_then_apply_uses_slot_lock_and_nonstopping_destroy(self):
        p=self.slot()
        def destroy(value, *, unused_only):
            self.assertTrue(unused_only);self.assertTrue((self.base/'.slot-1.lock').exists())
            self.move(value['folder'])
        with patch.object(slots,'launch_state',return_value={'registered':False}),patch.object(slots,'processes',return_value={}):
            with patch.object(slots,'destroy',side_effect=destroy) as mock:
                self.run_clean(self.cleaner.test_slots);mock.assert_not_called()
                self.run_clean(self.cleaner.test_slots,True);mock.assert_called_once()
        self.assertFalse(p['folder'].exists());self.assertFalse((self.base/'.slot-1.lock').exists())

    def test_slot_starts_after_lock_before_destroy_is_retained(self):
        self.slot()
        with patch.object(slots,'launch_state',side_effect=[{'registered':False},{'registered':True}]),patch.object(slots,'processes',return_value={}):
            with patch.object(slots,'destroy') as destroy: self.run_clean(self.cleaner.test_slots,True)
            destroy.assert_not_called()
        self.assertTrue(self.cleaner.failed)

    def test_unused_destroy_never_stops_a_running_slot(self):
        p=self.slot()
        with patch.object(slots,'stop') as stop,patch.object(slots,'launch_state',return_value={'registered':True}):
            with self.assertRaisesRegex(ValueError,'must be stopped'):slots.destroy(p,unused_only=True)
            stop.assert_not_called()

    def test_unused_destroy_refuses_external_check_with_open_file(self):
        p=self.slot()
        with patch.object(slots,'stopped'),patch.object(clean_scratch,'running_paths',return_value=[p['folder']/'report']),patch.object(slots,'delete_slot_keychain') as keychain:
            with self.assertRaisesRegex(ValueError,'running app or check'):slots.destroy(p,unused_only=True)
            keychain.assert_not_called()

    def test_slot_live_root_alias_is_refused(self):
        self.slot()
        with patch.object(slots,'LIVE',self.base/'slot-1/data'):
            with self.assertRaisesRegex(ValueError,'live root'):self.run_clean(self.cleaner.test_slots,True)
        self.assertEqual(self.moves,[])

    def test_status_file_project_duplicates_and_reload(self):
        path=self.root/'statuses.json';payload={'project_id':'project','tasks':[{'key':'CL-1','status_category':'done'}]}
        path.write_text(json.dumps(payload))
        reader=clean.status_reader(self.repo,Path('/unused'),'project',path)
        self.assertEqual(reader({'CL-1'}),{'CL-1':'done'})
        payload['tasks'][0]['status_category']='active';path.write_text(json.dumps(payload))
        self.assertEqual(reader({'CL-1'}),{'CL-1':'active'})
        payload['tasks']*=2;path.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError,'duplicate'):reader({'CL-1'})
        with self.assertRaisesRegex(ValueError,'project_id'):clean.status_rows({'project_id':'other'},'project')

    def test_cli_reads_only_scoped_statuses_from_project_folder_with_pagination(self):
        responses=[{'projects':[{'id':'project'}]},
                   {'tasks':[{'key':'CL-1','status_category':'done'}],'has_more':True,'next_cursor':'next'},
                   {'tasks':[{'key':'CL-2','status_category':'active'}],'has_more':False}]
        def run(command, **kwargs):
            self.assertEqual(kwargs['cwd'],self.repo)
            self.assertIn(command[2],['project_resolve','task_list'])
            args=json.loads(command[3])
            if command[2]=='task_list':self.assertEqual(args['fields'],['status_category'])
            return subprocess.CompletedProcess(command,0,json.dumps({'data':responses.pop(0)}),'')
        with patch.object(clean.subprocess,'run',side_effect=run):
            reader=clean.status_reader(self.repo,Path('/CLI'),None)
            self.assertEqual(reader({'CL-1','CL-2'}),{'CL-1':'done','CL-2':'active'})
        self.assertEqual(responses,[])

    def test_post_install_hook_is_after_checks_and_only_changes_post_install_tail(self):
        source=(ROOT/'script/build_and_run.sh').read_text()
        hook=source.index('post_install_cleanup()')
        self.assertGreater(hook,source.index('Installed verification failed.'))
        self.assertGreater(hook,source.index('echo "Installed $DEST"'))
        self.assertIn('post_install_cleanup\n',source[hook:])
        self.assertNotIn('rm -',source[hook:])

    def test_post_install_requires_own_build_lease(self):
        (self.build/'.build-lock').mkdir()
        output=io.StringIO()
        with patch.object(clean,'Cleaner',return_value=self.cleaner), contextlib.redirect_stdout(output):
            # A held lease refuses the build cleanup; the release still runs (CL-359).
            self.assertEqual(clean.post_install(self.repo,self.build/self.ids[0]),1)
        rows=[json.loads(line) for line in output.getvalue().splitlines() if line.startswith('{')]
        failed=[r for r in rows if r.get('action')=='build_cleanup']
        self.assertEqual(len(failed),1); self.assertIn('build lock held',failed[0]['reason'])
        self.assertEqual(self.releases,[self.repo])
        self.assertTrue((self.build/'.build-lock').is_dir())

    def test_fingerprint_folder_with_only_build_info_is_kept_and_reported(self):
        # Build 165 (2f7a90c3...) holds only build-info.json: kept, reported, and the pass goes on.
        bare=self.build/('d'*64); bare.mkdir(); (bare/'build-info.json').write_text(json.dumps({'source_fingerprint':'d'*64}))
        old=self.capture(self.ids[2])
        for apply in (False,True):
            rows=self.run_clean(self.cleaner.builds,apply)
            kept=[r for r in rows if r.get('path')==str(bare)]
            self.assertEqual(len(kept),1); self.assertEqual(kept[0]['action'],'kept')
            self.assertIn('no capture manifest',kept[0]['reason'])
        self.assertEqual((bare/'build-info.json').read_text(),json.dumps({'source_fingerprint':'d'*64}))
        self.assertEqual(sorted(p.name for p in bare.iterdir()),['build-info.json'])
        self.assertFalse((old/'source').exists()); self.assertTrue((old/'capture-manifest.json').exists())
        # A malformed manifest is kept and reported the same way.
        broken=self.build/('e'*64); broken.mkdir(); (broken/'capture-manifest.json').write_text('{')
        rows=self.run_clean(self.cleaner.builds,True)
        self.assertIn('unreadable capture manifest',[r for r in rows if r.get('path')==str(broken)][0]['reason'])
        self.assertTrue(broken.exists())

    def test_post_install_release_runs_when_build_cleanup_fails(self):
        current=self.capture(self.ids[0]); self.cleaner.apply=True
        def broken():
            raise FileNotFoundError(2,'No such file or directory','capture-manifest.json')
        for release_result,expected in ((0,1),(1,1)):
            self.releases.clear(); output=io.StringIO()
            calls=[]
            release=lambda repo:calls.append(repo) or release_result
            with patch.object(clean,'Cleaner',return_value=self.cleaner), patch.object(self.cleaner,'builds',side_effect=broken), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(clean.post_install(self.repo,current,release=release),expected)
            self.assertEqual(calls,[self.repo])
            rows=[json.loads(line) for line in output.getvalue().splitlines() if line.startswith('{')]
            summary=[r for r in rows if r.get('action')=='post_install'][0]
            self.assertEqual(summary['build_cleanup']['status'],'failed')
            self.assertIn('No such file or directory',summary['build_cleanup']['reason'])
            self.assertEqual(summary['release_done']['status'],'failed' if release_result else 'ok_or_skipped')
            self.assertFalse((self.build/'.build-lock').exists())
        # The default release hook (patched in setUp) also runs after a failure.
        with patch.object(clean,'Cleaner',return_value=self.cleaner), patch.object(self.cleaner,'builds',side_effect=broken), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(clean.post_install(self.repo,current),1)
        self.assertEqual(self.releases,[self.repo])
        # A raising release is reported and never hides the build result.
        def raising(repo): raise RuntimeError('status reader crashed')
        output=io.StringIO()
        with patch.object(clean,'Cleaner',return_value=self.cleaner), contextlib.redirect_stdout(output):
            self.assertEqual(clean.post_install(self.repo,current,release=raising),1)
        summary=[json.loads(l) for l in output.getvalue().splitlines() if l.startswith('{') and '"post_install"' in l][0]
        self.assertEqual((summary['build_cleanup']['status'],summary['release_done']['status']),('ok','failed'))

    def test_build_info_inside_older_stage_is_preserved_before_trash(self):
        p=self.capture(self.ids[2]);(p/'build-info.json').unlink()
        self.info(p/'Checklist.app',self.ids[2])
        data=(p/'Checklist.app/Contents/Resources/build-info.json').read_bytes()
        self.run_clean(self.cleaner.builds)
        self.assertFalse((p/'build-info.json').exists())
        self.run_clean(self.cleaner.builds,True)
        self.assertEqual((p/'build-info.json').read_bytes(),data)
        self.assertFalse((p/'Checklist.app').exists())

    def test_conflicting_older_build_info_retains_app(self):
        p=self.capture(self.ids[2]);self.info(p/'Checklist.app',self.ids[2])
        self.run_clean(self.cleaner.builds,True)
        self.assertTrue((p/'Checklist.app').exists());self.assertTrue(self.cleaner.failed)

    def test_bounded_check_option_captures_evidence_and_destroys_even_on_failure(self):
        self.slot()
        with patch.object(sys,'argv',['test_instances.py','check','--slot','1','--destroy-after-check']), patch.object(slots,'check',side_effect=ValueError('failed check')), patch.object(slots,'destroy') as destroy:
            output=io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(ValueError,'failed check'): slots.main()
            destroy.assert_called_once_with(slots.paths(1))
            self.assertIn('Bounded check evidence:',output.getvalue())
        self.assertFalse((self.base/'.slot-1.lock').exists())

    def test_ordinary_check_keeps_slot_for_promotion(self):
        self.slot()
        with patch.object(sys,'argv',['test_instances.py','check','--slot','1']), patch.object(slots,'check') as check, patch.object(slots,'destroy') as destroy:
            slots.main();check.assert_called_once();destroy.assert_not_called()

    def test_post_install_runs_retirement_under_own_lease(self):
        captures=[self.capture(key) for key in self.ids]
        self.cleaner.apply=True
        def batch(paths):
            self.assertTrue((self.build/'.build-lock').exists())
            return self.move_batch(paths)
        self.cleaner.batch_mover=batch
        with patch.object(clean,'Cleaner',return_value=self.cleaner):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(clean.post_install(self.repo,captures[0]),0)
        self.assertEqual(len(self.moves),4)
        self.assertTrue((captures[0]/'source').exists());self.assertTrue((captures[1]/'source').exists())
        self.assertFalse((self.build/'.build-lock').exists())

    def test_shell_hook_returns_before_cleanup_and_logs_failure(self):
        source=(ROOT/'script/build_and_run.sh').read_text()
        start=source.index('post_install_cleanup()');stop=source.index('# Interactive modes',start)
        helper=self.repo/'script';helper.mkdir()
        capture=self.build/self.ids[0];capture.mkdir()
        (self.build/'.build-lock').mkdir()
        (helper/'clean_builds.py').write_text("import time\ndef post_install(repo, capture):\n time.sleep(1)\n print('fixture failure',flush=True)\n return 1\n")
        began=time.monotonic()
        result=subprocess.run(['/bin/bash','-c',source[start:stop]],env=dict(os.environ,
            ROOT_DIR=str(self.repo),BUILD_ROOT=str(self.build),CAPTURE_DIR=str(capture)),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertLess(time.monotonic()-began,0.8)
        self.assertIn('Build cleanup started in background',result.stdout)
        self.assertFalse((self.build/'.build-lock').exists())
        # Bound this fixture wait; the actual hook owns no recurring runtime.
        deadline=time.monotonic()+4
        log=capture/'post-install-cleanup.jsonl'
        while time.monotonic()<deadline and (not log.exists() or 'fixture failure' not in log.read_text()):
            time.sleep(0.05)
        self.assertIn('fixture failure',log.read_text())

    def test_shell_cleanup_lease_release_failure_keeps_install_successful(self):
        source=(ROOT/'script/build_and_run.sh').read_text()
        start=source.index('post_install_cleanup()');stop=source.index('# Interactive modes',start)
        capture=self.build/self.ids[0];capture.mkdir()
        lock=self.build/'.build-lock';lock.mkdir();(lock/'unexpected').write_text('retain')
        result=subprocess.run(['/bin/bash','-c','set -euo pipefail\n'+source[start:stop]],
            env=dict(os.environ,ROOT_DIR=str(self.repo),BUILD_ROOT=str(self.build),CAPTURE_DIR=str(capture)),
            capture_output=True,text=True)
        self.assertEqual(result.returncode,0)
        self.assertIn('Warning: build cleanup',result.stderr)
        self.assertNotIn('started in background',result.stdout)
        self.assertTrue(lock.exists())

    def test_readonly_capture_only_selected_root_gains_write(self):
        retained=self.capture(self.ids[0]); obsolete=self.capture(self.ids[2])
        roots=[retained/'source',obsolete/'source']
        for root in roots:
            (root/'nested').mkdir();(root/'nested/file').write_text('immutable')
            (root/'nested/file').chmod(0o444);(root/'nested').chmod(0o555);root.chmod(0o555)
        def restore():
            for root in [retained,obsolete,self.trash]:
                for path in root.rglob('*'):
                    if path.is_dir():path.chmod(0o755)
        self.addCleanup(restore)
        self.run_clean(self.cleaner.builds)
        self.assertEqual(stat.S_IMODE(roots[1].stat().st_mode),0o555)
        def batch(paths):
            self.assertEqual(stat.S_IMODE(roots[1].stat().st_mode),0o755)
            self.assertEqual(stat.S_IMODE((roots[1]/'nested').stat().st_mode),0o555)
            self.assertEqual(stat.S_IMODE(roots[0].stat().st_mode),0o555)
            return self.move_batch(paths)
        self.cleaner.batch_mover=batch
        self.run_clean(self.cleaner.builds,True)
        self.assertFalse(roots[1].exists())
        self.assertEqual(stat.S_IMODE(roots[0].stat().st_mode),0o555)

    def test_failed_move_restores_selected_root_permissions(self):
        obsolete=self.capture(self.ids[2]);root=obsolete/'source';root.chmod(0o555)
        self.addCleanup(lambda:root.chmod(0o755))
        self.cleaner.batch_mover=lambda paths:{p:ValueError('fixture failure') for p in paths}
        reports=self.run_clean(self.cleaner.builds,True)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode),0o555)
        self.assertTrue(self.cleaner.failed);self.assertEqual(self.cleaner.moved,0)
        self.assertEqual(len([r for r in reports if r['action']=='kept_error']),4)

    def test_swiftpm_internal_links_retire_external_and_loop_links_report_path(self):
        internal=self.build/('swiftpm-'+'1'*20);internal.mkdir()
        (internal/'debug').mkdir();(internal/'debug/object').write_text('compiled')
        (internal/'relative').symlink_to('debug',target_is_directory=True)
        (internal/'absolute').symlink_to(internal/'debug/object')
        external=self.build/('swiftpm-'+'2'*20);external.mkdir()
        outside=external/'outside';outside.symlink_to(self.live,target_is_directory=True)
        loop=self.build/('swiftpm-'+'3'*20);loop.mkdir();(loop/'loop').symlink_to('loop')
        reports=self.run_clean(self.cleaner.builds,True)
        self.assertFalse(internal.exists());self.assertTrue(external.exists());self.assertTrue(loop.exists())
        self.assertTrue(any(str(outside) in r['reason'] for r in reports))
        self.assertTrue(any(str(loop/'loop') in r['reason'] for r in reports))
        self.assertTrue(self.live.exists())

    def test_batch_rechecks_processes_and_tree_before_any_move(self):
        p=self.capture(self.ids[2])
        with patch.object(self.cleaner,'process_reader',side_effect=[[],[p/'source/bytes']]) as reader:
            self.run_clean(self.cleaner.builds,True)
        self.assertEqual(reader.call_count,2);self.assertTrue((p/'source').exists())
        self.assertEqual(len(self.moves),0)

    def test_many_build_outputs_use_one_batch_and_two_process_observations(self):
        for n in range(100,130):self.capture(f'{n:064x}')
        with patch.object(self.cleaner,'batch_mover',side_effect=self.move_batch) as batch, \
             patch.object(self.cleaner,'process_reader',return_value=[]) as reader:
            reports=self.run_clean(self.cleaner.builds,True)
        batch.assert_called_once();self.assertEqual(len(batch.call_args.args[0]),120)
        self.assertEqual(reader.call_count,2)
        self.assertEqual(sum(r['action']=='trashed' for r in reports),120)

    def test_preview_many_items_resolves_each_candidate_once_and_reads_processes_once(self):
        for n in range(100,160):self.capture(f'{n:064x}')
        paths=[self.root/f'process-{n}' for n in range(3000)]
        resolved=Path.resolve;calls=0
        def resolve(path,*args,**kwargs):
            nonlocal calls
            calls+=1
            return resolved(path,*args,**kwargs)
        began=time.monotonic()
        with patch.object(Path,'resolve',resolve), \
             patch.object(self.cleaner,'process_reader',return_value=paths) as reader:
            reports=self.run_clean(self.cleaner.builds)
        self.assertEqual(reader.call_count,1);self.assertEqual(len(reports),240)
        self.assertLess(calls,10000)  # Regression was candidate count × process count.
        self.assertLess(time.monotonic()-began,10)
        self.assertEqual(self.moves,[])

    def test_native_batch_keeps_success_receipts_on_partial_failure(self):
        import retire_old_bundles as bundles
        a=self.root/'a';b=self.root/'b'
        result=subprocess.CompletedProcess([],5,f'# Moved "{a}" to "{self.trash}/a"\n','b refused')
        with patch.dict(os.environ,{},clear=True),patch.object(bundles.subprocess,'run',return_value=result) as run:
            outcomes=bundles.trash_many([a,b])
        self.assertEqual(outcomes[a],self.trash/'a');self.assertIsInstance(outcomes[b],ValueError)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0],['/usr/bin/trash','--verbose',str(a),str(b)])
        self.assertEqual(run.call_args.kwargs['timeout'],45)

    def test_native_batch_timeout_preserves_already_confirmed_destinations(self):
        import retire_old_bundles as bundles
        a=self.root/'a';b=self.root/'b'
        timeout=subprocess.TimeoutExpired('trash',45,output=f'# Moved "{a}" to "{self.trash}/a"\n'.encode())
        with patch.dict(os.environ,{},clear=True),patch.object(bundles.subprocess,'run',side_effect=timeout):
            outcomes=bundles.trash_many([a,b])
        self.assertEqual(outcomes[a],self.trash/'a')
        self.assertIn('timed out',str(outcomes[b]))

    def test_failed_batch_process_refresh_reports_every_item_without_chmod(self):
        p=self.capture(self.ids[2]);root=p/'source';root.chmod(0o555)
        self.addCleanup(lambda:root.chmod(0o755))
        with patch.object(self.cleaner,'process_reader',side_effect=[[],ValueError('inspection incomplete')]):
            reports=self.run_clean(self.cleaner.builds,True)
        self.assertEqual(len(reports),4)
        self.assertTrue(all(r['action']=='kept_error' for r in reports))
        self.assertEqual(stat.S_IMODE(root.stat().st_mode),0o555)
        self.assertEqual(self.moves,[])

    def test_process_path_resolution_deduplicates_raw_observations(self):
        p=self.root/'open';lsof=subprocess.CompletedProcess([],0,f'n{p}\n'*1000,'')
        with patch.object(clean_scratch.subprocess,'run',return_value=lsof), \
             patch.object(clean_scratch.subprocess,'check_output',return_value=f'{p}\n'*1000), \
             patch.object(Path,'resolve',autospec=True,side_effect=lambda path:path) as resolve:
            self.assertEqual(clean_scratch.running_paths(),[p])
        self.assertEqual(resolve.call_count,1)

    def test_summary_reports_logical_trash_bytes(self):
        self.handin();self.run_clean(self.cleaner.evidence,True)
        output=io.StringIO()
        with contextlib.redirect_stdout(output):self.assertEqual(clean.finish(self.cleaner),0)
        report=json.loads(output.getvalue());self.assertGreater(report['bytes_removed'],0)
        self.assertIn('Trash',report['meaning'])

    # CL-359: canceled tickets retire evidence; a note records what it was.
    def test_evidence_notes_record_folder_size_hashes_attachments_before_move(self):
        import hashlib
        p = self.handin('integration-9/CL-1')
        (p/'files.json').write_text(json.dumps([{'ticket':'CL-1','path':'script/a.py'},{'ticket':'CL-1','path':'docs/b.md'}]))
        (p/'notes.md').write_text('Implementer: fixture'); (p/'report.md').write_text('report')
        kept = self.handin('integration-9/CL-2'); (kept/'files.json').write_text(json.dumps([{'ticket':'CL-2'}]))
        notes = self.root/'notes.jsonl'; posted = []
        self.cleaner.notes_path = notes
        self.cleaner.attachment_reader = lambda key: ['screenshot.png']
        self.cleaner.note_poster = lambda key, text: posted.append((key, text, p.exists()))
        self.run_clean(self.cleaner.evidence, True)
        self.assertFalse(p.exists()); self.assertTrue(kept.exists())
        self.assertEqual([(k, existed) for k, _, existed in posted], [('CL-1', True)])
        text = posted[0][1]
        self.assertIn('notes.md sha256 ' + hashlib.sha256(b'Implementer: fixture').hexdigest(), text)
        self.assertIn('report.md sha256 ' + hashlib.sha256(b'report').hexdigest(), text)
        for part in ['/'.join(['.local', 'evidence', 'integration-9', 'CL-1']), '4 files', 'screenshot.png', 'docs/b.md, script/a.py']:
            self.assertIn(part, text)
        rows = [json.loads(line) for line in notes.read_text().splitlines()]
        self.assertEqual([(r['ticket'], r['action'], r['posted']) for r in rows], [('CL-1', 'trashed', True)])
        self.assertGreater(rows[0]['bytes'], 0)

    def test_preview_writes_notes_without_posting_and_failed_post_retains_evidence(self):
        p = self.handin(); notes = self.root/'n.jsonl'; self.cleaner.notes_path = notes
        self.statuses['CL-1'] = 'canceled'
        self.run_clean(self.cleaner.evidence)
        self.assertTrue(p.exists())
        rows = [json.loads(line) for line in notes.read_text().splitlines()]
        self.assertEqual([(r['action'], r['posted']) for r in rows], [('eligible', False)])
        self.assertIn('Files attached to CL-1: not read', rows[0]['text'])
        def fail(key, text): raise subprocess.CalledProcessError(1, ['checklist', 'call', 'message_send'])
        self.cleaner.note_poster = fail; self.cleaner.note_cache = {}
        self.run_clean(self.cleaner.evidence, True)
        self.assertTrue(p.exists()); self.assertTrue(self.cleaner.failed)
        self.assertEqual(json.loads(notes.read_text())['action'], 'kept_error')

    def test_cli_note_poster_and_attachment_reader_calls(self):
        calls = []
        def run(command, **kwargs):
            self.assertEqual(kwargs['cwd'], self.repo)
            method, args = command[2], json.loads(command[3]); calls.append((method, args))
            data = {'task_get': {'key': 'CL-1', 'id': 'task-1'}, 'message_send': {'message_id': 'm'},
                    'attachment_list': {'attachments': [{'filename': 'b.png'}, {'name': 'a.log'}]}}[method]
            return subprocess.CompletedProcess(command, 0, json.dumps({'data': data}), '')
        with patch.object(clean.subprocess, 'run', side_effect=run):
            clean.note_poster(self.repo, Path('/CLI'), 'project')('CL-1', 'text')
            self.assertEqual(clean.attachment_reader(self.repo, Path('/CLI'), 'project')('CL-1'), ['a.log', 'b.png'])
        self.assertEqual([c[0] for c in calls], ['task_get', 'message_send', 'task_get', 'attachment_list'])
        self.assertEqual(calls[1][1], {'project_id': 'project', 'task_id': 'task-1', 'kind': 'note', 'body': 'text'})

    def test_post_notes_requires_apply_and_notes_file(self):
        for extra in [['--preview', '--post-notes', '--evidence-notes', 'x'], ['--apply', '--post-notes']]:
            with self.subTest(extra=extra), patch.object(sys, 'argv', ['clean_builds.py', *extra, '--only', 'evidence',
                    '--repo', str(self.repo), '--installed-app', str(self.installed)]), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error: clean.main()
                self.assertEqual(error.exception.code, 2)

    # CL-359 rework (P359b): every hand-in files.json shape seen under .local/evidence.
    SHAPES = {
        'list-ticket': [{'path': 'a.py', 'ticket': 'CL-1'}],
        'list-ticket-list': [{'path': 'a.py', 'ticket': ['CL-1']}],
        'list-tickets': [{'path': 'a.py', 'tickets': ['CL-1']}],
        'files-object': {'base': 'abc', 'files': [{'path': 'a.py', 'ticket': 'CL-1'}]},
        'files-object-no-ticket': {'base': 'abc', 'files': [{'path': 'a.py', 'base_sha256': None}]},
        'top-level-ticket': {'ticket': 'CL-1', 'changed': ['a.py'], 'sha256': {'a.py': 'f'}},
        'name-map': {'final-slot-1.json': {'sha256': 'f', 'bytes': 1}},
        'list-no-ticket': [{'path': 'a.py'}],
        'list-of-strings': ['a.py'],
        'empty-list': [],
    }

    def test_every_files_json_shape_reads_without_exceptions(self):
        expected = {name: ({'CL-1'}, 'files.json') for name in
                    ['list-ticket', 'list-ticket-list', 'list-tickets', 'files-object', 'top-level-ticket']}
        for name, data in self.SHAPES.items():
            for folder in ['integration-9/' + name + '-CL-1', 'integration-9/' + name]:
                with self.subTest(shape=name, folder=folder):
                    p = self.evidence / folder; p.mkdir(parents=True)
                    (p / 'files.json').write_text(json.dumps(data))
                    keys, basis, problems = clean.evidence_owners(p)
                    self.assertEqual(problems, [])
                    named = folder.endswith('CL-1')
                    if name in expected:
                        self.assertEqual(keys, {'CL-1'}); self.assertIn('files.json', basis)
                    elif named:
                        self.assertEqual(keys, {'CL-1'}); self.assertIn('folder name', basis)
                    else:
                        self.assertEqual((keys, basis), (set(), 'none'))
        # Nested file names add owners but never establish ownership alone.
        runner = self.evidence / 'integration-30/e2-abc'; runner.mkdir(parents=True)
        (runner / 'files.json').write_text(json.dumps(self.SHAPES['name-map'])); (runner / 'CL-1-task.json').write_text('{}')
        self.assertEqual(clean.evidence_owners(runner), (set(), 'none', []))
        wider = self.evidence / 'integration-31/CL-1'; wider.mkdir(parents=True)
        (wider / 'files.json').write_text('[{"path": "a"}]'); (wider / 'CL-2.log').write_text('log')
        self.assertEqual(clean.evidence_owners(wider)[:2],
                         ({'CL-1', 'CL-2'}, 'file names and folder name (1 files.json entries have no ticket key)'))
        shutil.rmtree(runner); shutil.rmtree(wider)
        reports = self.run_clean(self.cleaner.evidence)
        self.assertFalse(self.cleaner.failed)
        handins = {Path(r['path']).name: r for r in reports if r.get('kind') == 'evidence'}
        self.assertEqual(len(handins), 2 * len(self.SHAPES))
        for name in self.SHAPES:
            self.assertEqual(handins[name + '-CL-1']['action'], 'eligible', name)
            unowned = handins[name]
            self.assertEqual(unowned['action'], 'eligible' if name in expected else 'kept', name)
            if name not in expected: self.assertIn('unknown owner', unowned['reason'])

    def test_cleanup_json_receipts_and_ticket_rows(self):
        cases = {'cl173-timing': {'completed_at': 't', 'private_copies': []},
                 'cl173-timing-r4': [{'source': '/private/tmp/x', 'trash_exists': True}],
                 'pass1-enative': {'triage_key': 'CL-T102', 'tickets': [{'key': 'CL-1', 'status': 'Queued'}]},
                 'round': {'tickets': ['CL-1', 'CL-2']}}
        for name, data in cases.items():
            p = self.evidence / 'integration-22' / name; p.mkdir(parents=True)
            (p / 'cleanup.json').write_text(json.dumps(data))
        owners = {name: clean.evidence_owners(self.evidence / 'integration-22' / name) for name in cases}
        self.assertEqual(owners['cl173-timing'], (set(), 'none', []))
        self.assertEqual(owners['cl173-timing-r4'], (set(), 'none', []))
        self.assertEqual(owners['pass1-enative'][:2], ({'CL-1'}, 'cleanup.json'))
        self.assertEqual(owners['round'][0], {'CL-1', 'CL-2'})
        reports = {Path(r['path']).name: r for r in self.run_clean(self.cleaner.evidence) if r.get('kind') == 'evidence'}
        self.assertFalse(self.cleaner.failed)
        self.assertEqual(reports['pass1-enative']['action'], 'eligible')
        self.assertIn('open or unknown ticket status: CL-2', reports['round']['reason'])
        for name in ['cl173-timing', 'cl173-timing-r4']: self.assertIn('unknown owner', reports[name]['reason'])

    def test_folder_name_fallback_is_marked_in_the_note(self):
        p = self.handin('integration-10/CL-1-r1'); (p / 'files.json').write_text(json.dumps([{'path': 'a.py'}, {'path': 'b.py'}]))
        notes = self.root / 'notes.jsonl'; self.cleaner.notes_path = notes
        self.run_clean(self.cleaner.evidence)
        rows = [json.loads(line) for line in notes.read_text().splitlines()]
        self.assertEqual([(r['ticket'], r['action']) for r in rows], [('CL-1', 'eligible')])
        self.assertEqual(rows[0]['owner_basis'], 'folder name (2 files.json entries have no ticket key)')
        self.assertIn('Owner basis: folder name (2 files.json entries have no ticket key).', rows[0]['text'])
        self.assertIn('a.py, b.py', rows[0]['text'])

    def test_one_failed_folder_still_writes_notes_for_the_others(self):
        good = self.handin('integration-1/CL-1'); bad = self.handin('integration-2/CL-1')
        notes = self.root / 'notes.jsonl'; self.cleaner.notes_path = notes
        native = clean.inventory
        def inventory(path):
            if path == self.evidence / 'integration-2': raise PermissionError('fixture unreadable folder')
            return native(path)
        with patch.object(clean, 'inventory', side_effect=inventory):
            reports = self.run_clean(self.cleaner.evidence)
        self.assertTrue(self.cleaner.failed)
        self.assertEqual([r['action'] for r in reports if r['path'] == str(self.evidence / 'integration-2')], ['kept_error'])
        rows = [json.loads(line) for line in notes.read_text().splitlines()]
        self.assertEqual([(r['folder'], r['action']) for r in rows], [(str(good), 'eligible')])
        self.assertTrue(bad.exists())

    def test_preview_reads_all_ticket_statuses_in_one_batch(self):
        for name in ['CL-1', 'integration-3/CL-2', 'integration-4/CL-1-CL-2']: self.handin(name)
        calls = []
        def reader(keys): calls.append(sorted(keys)); return dict(self.statuses)
        self.cleaner.status_reader = reader
        self.run_clean(self.cleaner.evidence)
        self.assertEqual(calls, [['CL-1', 'CL-2']])
        # Apply rechecks each selected folder with a fresh read before the move.
        calls.clear(); self.run_clean(self.cleaner.evidence, True)
        self.assertEqual(calls, [['CL-1', 'CL-2'], ['CL-1']])
        self.assertFalse((self.evidence / 'CL-1').exists())

    def test_batched_status_failure_retains_every_handin_as_error(self):
        p = self.handin()
        def reader(keys): raise subprocess.CalledProcessError(1, ['checklist', 'call', 'task_list'])
        self.cleaner.status_reader = reader
        reports = self.run_clean(self.cleaner.evidence, True)
        self.assertTrue(p.exists()); self.assertTrue(self.cleaner.failed)
        self.assertIn('ticket status read failed', reports[-1]['reason'])

    def test_main_preview_exits_zero_with_old_shapes_and_writes_notes(self):
        for name, data in [('integration-5/CL-1', {'files': [{'ticket': 'CL-1', 'path': 'a'}]}),
                           ('integration-13/slot-disconnect', {'ticket': 'NEW', 'changed': ['a']}),
                           ('integration-26/CL-2-timing', [{'source': 'x'}])]:
            p = self.evidence / name; p.mkdir(parents=True); (p / 'files.json').write_text(json.dumps(data))
        status = self.root / 'status.json'; notes = self.root / 'notes.jsonl'
        status.write_text(json.dumps({'project_id': 'project', 'tasks': [{'key': 'CL-1', 'status_category': 'done'},
                                                                        {'key': 'CL-2', 'status_category': 'canceled'}]}))
        output = io.StringIO()
        with patch.object(sys, 'argv', ['clean_builds.py', '--preview', '--only', 'evidence', '--repo', str(self.repo),
                                        '--installed-app', str(self.installed), '--project-id', 'project',
                                        '--status-file', str(status), '--evidence-notes', str(notes)]), \
             patch.object(clean, 'storage_report'), contextlib.redirect_stdout(output):
            self.assertEqual(clean.main(), 0)
        rows = [json.loads(line) for line in notes.read_text().splitlines()]
        self.assertEqual(sorted((Path(r['folder']).name, r['owner_basis']) for r in rows),
                         [('CL-1', 'files.json, folder name'), ('CL-2-timing', 'folder name (1 files.json entries have no ticket key)')])
        self.assertIn('unknown owner', output.getvalue())

    def test_marked_slot_preview_needs_no_inventory(self):
        p = self.slot(); self.marker(p['folder'])
        with patch.object(clean, 'inventory', side_effect=AssertionError('inventory in preview')), \
             patch.object(clean, 'du_sizes', return_value={p['folder']: 4096}):
            reports = self.run_clean(self.cleaner.test_slots)
        self.assertEqual([(r['action'], r['bytes']) for r in reports], [('kept', 4096)])
        self.assertIn('persistent workspace marker', reports[0]['reason'])

    def test_background_sizes_cover_every_group_path(self):
        groups = {'evidence': [self.evidence], 'build': [self.build, self.root / 'missing']}
        sizer = clean.background_sizes(groups)
        totals = {label: sum(sizer(paths).values()) for label, paths in groups.items()}
        self.assertEqual(set(totals), {'evidence', 'build'}); self.assertGreater(totals['build'], 0)
        self.assertEqual(sizer([self.root / 'missing']), {})

class ReleaseDoneAfterInstallTests(unittest.TestCase):
    """CL-359 item 1: each install releases Done/canceled marks; open and running folders stay."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.sessions = self.root/'sessions'; self.qualification = self.root/'qualification'; self.qualification.mkdir()
        self.scratch = self.sessions/'-Users-Checklist'/'installer'/'scratchpad'; self.scratch.mkdir(parents=True)

    def work(self, name, tickets, session='installer'):
        p = self.sessions/'-Users-Checklist'/session/'scratchpad'/name; p.mkdir(parents=True)
        clean_scratch.write_marker(p, session, 'package '+name, tickets=tickets)
        return p

    def release(self, environ, statuses):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = clean.release_done(self.root, environ=environ, reader=lambda keys: {k: statuses.get(k) for k in keys},
                                        sessions_root=self.sessions, qualification_root=self.qualification)
        return result, [json.loads(l) for l in output.getvalue().splitlines()]

    def test_done_released_open_and_foreign_kept_running_folder_survives_apply(self):
        done=self.work('done', ['CL-1']); canceled=self.work('canceled', ['CL-3']); open_=self.work('open', ['CL-1','CL-2'])
        foreign=self.work('foreign', ['CL-1'], session='other')
        result, rows = self.release({'CODEX_THREAD_ID': 'installer'}, {'CL-1':'done','CL-2':'active','CL-3':'canceled'})
        self.assertEqual(result, 0)
        self.assertTrue(clean_scratch.ticket_released(done)); self.assertTrue(clean_scratch.ticket_released(canceled))
        self.assertFalse(clean_scratch.read_marker(open_)['released'])
        self.assertFalse(clean_scratch.read_marker(foreign)['released'])
        self.assertIn('open or unknown ticket status: CL-2', {r.get('reason') for r in rows})
        # The release only changes markers; the next apply still keeps a folder a process uses.
        decision = clean_scratch.plan(done, 'session', set(), [done], 'a'*64, now=time.time()+7200)
        self.assertIn('running process', decision['reason'])

    def test_missing_session_skips_and_status_failure_reports(self):
        self.work('done', ['CL-1'])
        result, rows = self.release({}, {})
        self.assertEqual((result, rows[0]['status']), (0, 'skipped'))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = clean.release_done(self.root, environ={'CODEX_THREAD_ID': 'installer'},
                                        reader=lambda keys: (_ for _ in ()).throw(ValueError('service restarting')),
                                        sessions_root=self.sessions, qualification_root=self.qualification)
        self.assertEqual(result, 1)
        self.assertFalse(clean_scratch.read_marker(self.scratch/'done')['released'])


class TmpdirIsolationTests(unittest.TestCase):
    def test_cleanup_with_tmpdir_in_another_marked_scratch_session(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            scratch = Path(directory) / 'other-session/scratchpad/workspace'
            scratch.mkdir(parents=True)
            clean_scratch.write_marker(scratch, 'other-session', 'fake caller scratch')
            identities = ('CODEX_THREAD_ID', 'CLAUDE_SESSION_ID', 'CHECKLIST_SESSION_ID',
                          'CLAUDE_CODE_SESSION_ID')
            for identity in (None,) + identities:
                with self.subTest(identity=identity):
                    environment = dict.fromkeys(identities, '')
                    if identity:
                        environment[identity] = 'other-session'
                    environment['TMPDIR'] = str(scratch)
                    with patch.dict(os.environ, environment), \
                         patch.object(tempfile, 'tempdir', str(scratch)):
                        # Construct a fresh fixture under the hostile caller environment.
                        # Its real cleanup path must still move only obsolete outputs.
                        result = unittest.TestResult()
                        CleanupTests('test_preview_changes_nothing_and_apply_preserves_both_builds_and_all_receipts').run(result)
                        self.assertEqual(result.testsRun, 1)
                        self.assertTrue(result.wasSuccessful(), result.errors + result.failures)
            # Isolation must not weaken real scratch ownership or ancestor protection.
            child = scratch / 'foreign-workspace'; child.mkdir()
            with self.assertRaisesRegex(ValueError, 'another scratch session'):
                clean_scratch.write_marker(child, 'fixture-session', 'foreign fixture')
            self.assertIn('persistent workspace marker',
                          clean_scratch.workspace_protection(child, clean_scratch.inventory(child)))



class ReleaseWorkspaceTests(unittest.TestCase):
    """CL-359: an install built from an integration copy reads ticket statuses in the registered checkout."""
    def test_environment_then_local_origin_then_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            checkout, copy, plain = Path(tmp) / 'checkout', Path(tmp) / 'copy', Path(tmp) / 'plain'
            for folder in (checkout, plain):
                subprocess.run(['git', 'init', '-q', str(folder)], check=True)
            subprocess.run(['git', 'clone', '-q', str(checkout), str(copy)], check=True, capture_output=True)
            self.assertEqual(clean.release_workspace(copy, {'CHECKLIST_WORKSPACE': str(plain)}), plain.resolve())
            self.assertEqual(clean.release_workspace(copy, {}), checkout.resolve())
            self.assertEqual(clean.release_workspace(plain, {}), plain.resolve())

if __name__ == '__main__': unittest.main()
