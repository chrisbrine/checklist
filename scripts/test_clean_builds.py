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
        self.temp = tempfile.TemporaryDirectory()
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

    def test_missing_previous_identity_retains_every_build(self):
        self.capture(self.ids[2]); shutil.rmtree(self.previous)
        with self.assertRaises(OSError): self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_mismatched_last_install_retains_every_build(self):
        self.capture(self.ids[2]); self.info(self.installed, 'd'*64)
        with self.assertRaisesRegex(ValueError, 'does not match'): self.run_clean(self.cleaner.builds, True)
        self.assertEqual(self.moves, [])

    def test_first_install_without_previous_can_retire_old_outputs(self):
        self.record(False); self.capture(self.ids[2])
        self.run_clean(self.cleaner.builds, True); self.assertEqual(len(self.moves),4)

    def test_build_process_preserves_used_outputs(self):
        p = self.capture(self.ids[2]); self.processes = [p/'source/Package.swift', p/'Checklist.app/Contents/MacOS/ChecklistApp']
        self.run_clean(self.cleaner.builds, True)
        self.assertTrue((p/'source').exists()); self.assertTrue((p/'Checklist.app').exists())
        self.assertEqual(len(self.moves), 2)

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

    def test_open_unknown_and_canceled_evidence_retained_only_all_done_trashed(self):
        p=self.handin('CL-1-CL-2'); self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())
        self.statuses.pop('CL-2'); self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())
        self.statuses['CL-2']='canceled'; self.run_clean(self.cleaner.evidence,True); self.assertTrue(p.exists())
        self.statuses['CL-2']='done'; self.run_clean(self.cleaner.evidence,True); self.assertFalse(p.exists())
        self.assertTrue(self.moves[0][1].exists())

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
        p=self.handin();(p/'files.json').write_text('[{}]')
        unknown=self.evidence/'unknown';unknown.mkdir();(unknown/'report').write_text('retain')
        self.run_clean(self.cleaner.evidence,True)
        self.assertTrue(p.exists());self.assertTrue(unknown.exists());self.assertTrue(self.cleaner.failed)

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
        self.assertEqual(self.moves, []); self.assertTrue(self.cleaner.failed)

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
        with patch.object(clean,'Cleaner',return_value=self.cleaner):
            with self.assertRaisesRegex(ValueError,'build lock held'):
                clean.post_install(self.repo,self.build/self.ids[0])

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
        self.assertEqual(len(self.moves),3)

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


if __name__ == '__main__': unittest.main()
