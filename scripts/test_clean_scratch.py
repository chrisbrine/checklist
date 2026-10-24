"""Scratch cleanup tests use temporary fixtures only; never real scratch or Trash."""
import ast
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import clean_scratch as cleanup


class CleanScratchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        caller = patch.dict(os.environ, {'CODEX_THREAD_ID': 'session', 'CLAUDE_SESSION_ID': ''})
        caller.start();self.addCleanup(caller.stop)
        self.repo = self.root / 'retained';self.repo.mkdir()
        self.package = b'let package = Package(name: "Checklist")\n'
        (self.repo / 'Package.swift').write_bytes(self.package)
        (self.repo / 'source.py').write_bytes(b'old source\n')
        historical = cleanup.blob_id(self.repo / 'source.py')
        (self.repo / 'source.py').write_bytes(b'new source\n')
        # Inject retained object identities: these fixtures never invoke Git.
        self.objects = {historical, cleanup.blob_id(self.repo / 'source.py'),
                        cleanup.blob_id(self.repo / 'Package.swift')}
        self.sessions = self.root / 'sessions';self.sessions.mkdir()
        self.qualification = self.root / 'qualification';self.qualification.mkdir()
        self.installed = self.root / 'installed.json'
        self.fingerprint = 'a' * 64
        self.installed.write_text(json.dumps({'source_fingerprint': self.fingerprint}))
        self.now = time.time() + 7200  # Age fixture ctimes without changing the machine clock.
        self.trash = self.root / 'trash';self.trash.mkdir()

    def item(self, name='copy', host='-Users-Checklist', qualification=False, session='session'):
        path = self.qualification / name if qualification else self.sessions / host / session / 'scratchpad' / name
        path.mkdir(parents=True)
        return path

    def mark(self, root, session='session', release=False):
        if release and cleanup.read_marker(root) is None:
            cleanup.write_marker(root, session, 'fixture persistent workspace')
        return cleanup.write_marker(root, session, 'fixture persistent workspace', release)

    def write(self, root, path, contents=b'generated'):
        target = root / path;target.parent.mkdir(parents=True, exist_ok=True);target.write_bytes(contents)
        return target

    def plan(self, item, **kwargs):
        return cleanup.plan(item, kwargs.pop('kind', 'session'), self.objects,
                            kwargs.pop('processes', []), kwargs.pop('fingerprint', self.fingerprint),
                            now=kwargs.pop('now', self.now), **kwargs)

    def run_cleanup(self, apply=False, **kwargs):
        output = io.StringIO()
        # Inject temporary Trash; native Trash is never called by any test.
        with redirect_stdout(output), patch.dict(os.environ, CHECKLIST_TRASH_DIR=str(self.trash)), \
             patch.object(cleanup, 'git_objects', return_value=self.objects):
            result = cleanup.clean(self.sessions, self.qualification, self.repo, self.installed,
                                   apply=apply, process_reader=kwargs.pop('process_reader', lambda: []),
                                   clock=lambda: self.now, session_id=kwargs.pop('session_id', 'session'), **kwargs)
        return result, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_preview_counts_history_build_unknown_and_git_metadata_without_mutation(self):
        item = self.item()
        self.write(item, 'src/source.py', b'old source\n')
        self.write(item, '.build/output.o', b'1234')
        self.write(item, 'notes.md', b'unique notes')
        self.write(item, 'src/.git/config', b'unique git')
        before = cleanup.inventory(item)
        result, records = self.run_cleanup()
        self.assertEqual(result, 0)
        self.assertEqual(cleanup.inventory(item), before)
        record = records[0]
        self.assertEqual(record['build_bytes'], 4)
        self.assertEqual(record['git_redundant_source_bytes'], len(b'old source\n'))
        self.assertEqual(record['kept_bytes'], len(b'unique notesunique git'))
        self.assertEqual(sum(record[key] for key in ['build_bytes', 'git_redundant_source_bytes', 'kept_bytes']), record['total_bytes'])
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_apply_moves_only_recoverable_bytes_and_is_repeatable(self):
        item = self.item()
        source = self.write(item, 'src/source.py', b'old source\n')
        build = self.write(item, '.build/output.o')
        note = self.write(item, 'report.md', b'private report')
        modified = self.write(item, 'src/Package.swift', b'modified source')
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0)
        self.assertFalse(source.exists());self.assertFalse(build.exists())
        self.assertEqual(note.read_bytes(), b'private report')
        self.assertEqual(modified.read_bytes(), b'modified source')
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 2)
        trashed_files = [p for p in self.trash.rglob('*') if p.is_file()]
        self.assertEqual(sorted(p.read_bytes() for p in trashed_files), [b'generated', b'old source\n'])
        self.assertEqual(self.run_cleanup(apply=True)[0], 0)
        self.assertEqual(len(list(self.trash.iterdir())), 2)

    def test_running_cwd_executable_open_file_or_argument_skips_entire_item(self):
        item = self.item();self.write(item, '.build/object')
        for path in [item, item / '.build/executable', item / 'open.txt', item / 'source']:
            with self.subTest(path=path):
                decision = self.plan(item, processes=[path])
                self.assertIn('running process', decision['reason'])
                self.assertEqual(decision['moves'], [])
        self.assertTrue(self.plan(item, processes=[Path(str(item) + '-other/file')])['moves'])

    def test_process_reader_parses_lsof_and_absolute_arguments(self):
        item = self.item()
        lsof = subprocess.CompletedProcess([], 0, stdout=f'p10\nn{item}/open.txt\nn{item}\n', stderr='')
        command = f'/usr/bin/swift --scratch-path={item}/.build "{item}/space file"\n'
        with patch.object(cleanup.subprocess, 'run', return_value=lsof), \
             patch.object(cleanup.subprocess, 'check_output', return_value=command):
            paths = cleanup.running_paths()
        for value in [item, item / 'open.txt', item / '.build', item / 'space file']:
            self.assertIn(value, paths)

    def test_process_paths_are_deduplicated_and_match_exact_candidate_ancestors(self):
        item = self.item()
        other = Path(str(item) + '-other')
        paths = [item / '.build/output', item / 'source', other / 'file']
        self.assertEqual(cleanup.used_items(paths, [item, item / '.build', other]),
                         {item, item / '.build', other})
        self.assertEqual(cleanup.used_items(paths[2:], [item]), set())
        lsof = subprocess.CompletedProcess([], 0, stdout=(f'p10\nn{item}/source\n' * 10), stderr='')
        with patch.object(cleanup.subprocess, 'run', return_value=lsof), \
             patch.object(cleanup.subprocess, 'check_output', return_value=f'{item}/source\n'):
            self.assertEqual(cleanup.running_paths(), [(item / 'source').resolve()])

    def test_process_inspection_failure_refuses_all_moves(self):
        item = self.item();self.write(item, '.build/object')
        with self.assertRaisesRegex(ValueError, 'inspection incomplete'):
            self.run_cleanup(apply=True, process_reader=lambda: (_ for _ in ()).throw(ValueError('inspection incomplete')))
        self.assertTrue((item / '.build/object').exists())
        lsof = subprocess.CompletedProcess([], 1, stdout='', stderr='permission denied')
        with patch.object(cleanup.subprocess, 'run', return_value=lsof):
            with self.assertRaisesRegex(ValueError, 'inspection incomplete'):
                cleanup.running_paths()

    def test_recent_file_directory_or_preserved_mtime_with_new_ctime_skips(self):
        item = self.item();file = self.write(item, '.build/object')
        for changed in [file, file.parent, item]:
            with self.subTest(changed=changed):
                os.utime(changed, (self.now - 20 * 60, self.now - 20 * 60))
                self.assertIn('last 45 minutes', self.plan(item)['reason'])
                os.utime(changed, (1, 1))
        # Fresh copies with rsync-preserved old mtime are still in use/recent.
        self.assertIn('last 45 minutes', self.plan(item, now=time.time())['reason'])
        self.assertEqual(self.plan(item, now=self.now)['build_bytes'], len(b'generated'))

    def test_symlink_and_special_files_are_kept_and_targets_never_walked(self):
        item = self.item();outside = self.root / 'outside';outside.mkdir()
        self.write(outside, 'secret', b'unique')
        (item / '.build').symlink_to(outside, target_is_directory=True)
        (item / 'source.py').symlink_to(self.repo / 'source.py')
        os.mkfifo(item / 'pipe')
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0);self.assertEqual(records[0]['eligible_paths'], [])
        self.assertEqual((outside / 'secret').read_bytes(), b'unique')
        self.assertTrue((item / '.build').is_symlink())
        self.assertTrue(stat_mode_fifo(item / 'pipe'))

    def test_discovery_does_not_follow_host_session_scratchpad_or_item_links(self):
        outside = self.root / 'outside';outside.mkdir()
        (self.sessions / 'Checklist-link').symlink_to(outside, target_is_directory=True)
        item = self.item();self.write(item, '.build/object')
        (item.parent / 'linked-item').symlink_to(outside, target_is_directory=True)
        (item.parent.parent.parent / 'linked-session').symlink_to(item.parent.parent, target_is_directory=True)
        other = self.sessions / 'Other';(other / 'session').mkdir(parents=True)
        (other / 'session/scratchpad').symlink_to(item.parent, target_is_directory=True)
        found = list(cleanup.candidates(self.sessions, self.qualification, 'session'))
        self.assertEqual({p.name for p, _ in found}, {'copy', 'linked-item'})
        self.assertIn('symbolic link', self.plan(item.parent / 'linked-item')['reason'])

    def test_spare_requires_own_checklist_package_not_sibling_or_name(self):
        owned = self.item('owned', 'spare-one')
        self.write(owned, 'src/Package.swift', self.package);self.write(owned, '.build/object')
        unknown = self.item('Checklist-named', 'spare-one');self.write(unknown, '.build/object')
        other = self.item('other', 'spare-one');self.write(other, 'Package.swift', b'name: "Other"')
        self.write(other, '.build/object')
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0)
        self.assertFalse((owned / '.build').exists())
        for path in [unknown, other]:
            self.assertTrue((path / '.build/object').exists())
            self.assertIn('no retained Checklist package', next(r['reason'] for r in records if r.get('path') == str(path)))

    def test_qualification_runs_are_scanned_and_latest_fingerprint_kept(self):
        old = self.item('old', qualification=True);self.mark(old, release=True);self.write(old, '.build/object')
        latest = self.item('latest', qualification=True);self.mark(latest, release=True);self.write(latest, '.build/object')
        self.write(latest, 'capture-manifest.json', json.dumps({'source_fingerprint': self.fingerprint}).encode())
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0);self.assertFalse((old / '.build').exists())
        self.assertTrue((latest / '.build/object').exists())
        self.assertIn('latest installed round', next(r['reason'] for r in records if r.get('path') == str(latest)))

    def qualification_run(self, name='run', fingerprint='b' * 64, release=True):
        root = self.item(name, qualification=True)
        cleanup.mark_qualification(root, fingerprint, 'disposable qualification fixture')
        if release:
            cleanup.write_marker(root, 'session', release=True)
        self.write(root, 'store/checklist.sqlite', b'copied-store-not-in-git')
        self.write(root, 'store/objects/object', b'copied-managed-object')
        return root

    def test_obsolete_released_run_previews_and_trashes_whole_copied_store(self):
        root = self.qualification_run()
        before = cleanup.inventory(root)
        result, records = self.run_cleanup()
        self.assertEqual(result, 0)
        self.assertEqual(cleanup.inventory(root), before)
        self.assertEqual(records[0]['eligible_paths'], [str(root)])
        self.assertEqual(records[0]['qualification_bytes'], records[0]['total_bytes'])
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0)
        self.assertFalse(root.exists())
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 1)
        copied = next(self.trash.rglob('checklist.sqlite'))
        self.assertEqual(copied.read_bytes(), b'copied-store-not-in-git')

    def test_latest_root_identity_and_unknown_installed_identity_retain_stores(self):
        root = self.qualification_run(fingerprint=self.fingerprint)
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 0)
        self.assertIn('latest installed round', records[0]['reason'])
        self.assertEqual(records[0]['eligible_paths'], [])
        self.assertTrue((root / 'store/checklist.sqlite').exists())
        self.installed.write_text('{}')
        self.assertEqual(self.run_cleanup(apply=True)[1][0]['eligible_paths'], [])

    def test_qualification_retirement_keeps_active_recent_running_and_explicit_runs(self):
        root = self.qualification_run(release=False)
        self.assertIn('persistent workspace', self.plan(root, kind='qualification')['reason'])
        cleanup.write_marker(root, 'session', release=True)
        for options, reason in [({'now': time.time()}, 'last 45 minutes'),
                                ({'processes': [root / 'store/checklist.sqlite']}, 'running process'),
                                ({'keep': [root]}, 'explicitly retained')]:
            with self.subTest(reason=reason):
                decision = self.plan(root, kind='qualification', **options)
                self.assertEqual(decision['moves'], [])
                self.assertIn(reason, decision['reason'])

    def test_qualification_retirement_keeps_nested_workspaces_latest_receipts_and_links(self):
        for case in ['nested', 'latest', 'link', 'git']:
            with self.subTest(case=case):
                root = self.qualification_run(case)
                if case == 'nested':
                    nested = root / 'persistent';nested.mkdir();self.mark(nested)
                elif case == 'latest':
                    self.write(root, 'nested/build-info.json', json.dumps({'source_fingerprint': self.fingerprint}).encode())
                elif case == 'link':
                    (root / 'outside').symlink_to(self.repo)
                else:
                    self.write(root, '.git/config', b'preserve')
                self.assertEqual(self.plan(root, kind='qualification')['moves'], [])

    def test_unmarked_older_than_seven_days_is_reported_with_size_but_never_moved(self):
        root = self.item('unknown', qualification=True)
        self.write(root, 'store/checklist.sqlite', b'unknown-store')
        outside = self.root / 'outside';outside.mkdir();self.write(outside, 'file', b'not counted')
        (root / 'link').symlink_to(outside)
        before = cleanup.inventory(root)
        self.assertEqual(self.run_cleanup()[1], [])  # Under seven days.
        self.now += 8 * 24 * 60 * 60
        for apply in [False, True]:
            result, records = self.run_cleanup(apply=apply, include_released=True)
            self.assertEqual(result, 0)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]['action'], 'unmarked_qualification')
            self.assertGreater(records[0]['age_seconds'], 7 * 24 * 60 * 60)
            self.assertEqual(records[0]['total_bytes'], sum(e[3] for e in before.values() if not stat.S_ISDIR(e[2])))
            self.assertEqual(records[0]['eligible_paths'], [])
            self.assertEqual(cleanup.inventory(root), before)
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_qualification_marker_binds_owner_and_fingerprint_across_release_and_reuse(self):
        root = self.qualification_run(release=False)
        with patch.dict(os.environ, CODEX_THREAD_ID='foreign'):
            with self.assertRaisesRegex(ValueError, 'owning session'):
                cleanup.mark_qualification(root, 'c' * 64, 'foreign')
        for value in ['round-28', 'A' * 64, None]:
            with self.assertRaisesRegex(ValueError, 'fingerprint'):
                cleanup.mark_qualification(root, value, 'invalid')
        cleanup.write_marker(root, 'session', release=True)
        cleanup.write_marker(root, 'session', 'reused')
        marker = cleanup.read_marker(root)
        self.assertEqual(marker['source_fingerprint'], 'b' * 64)
        self.assertFalse(marker['released'])
        with patch.dict(os.environ, {'CODEX_THREAD_ID': '', 'CLAUDE_SESSION_ID': ''}):
            with self.assertRaisesRegex(ValueError, 'session unknown'):
                cleanup.mark_qualification(root, 'b' * 64, 'missing owner')
        with self.assertRaisesRegex(ValueError, 'override'):
            cleanup.mark_qualification(root, 'b' * 64, 'wrong owner', 'foreign')

    def test_new_qualification_run_fences_installed_change_before_trash(self):
        root = self.qualification_run()
        calls = 0
        def reader():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.installed.write_text(json.dumps({'source_fingerprint': 'c' * 64}))
            return []
        result, records = self.run_cleanup(apply=True, process_reader=reader)
        self.assertEqual(result, 1)
        self.assertTrue(root.exists())
        self.assertIn('installed round changed', records[-1]['reason'])

    def test_qualification_marker_cli_and_corrupt_or_linked_roots_fail_closed(self):
        root = self.item('marked-by-cli', qualification=True)
        with patch.object(sys, 'argv', ['clean_scratch.py', '--mark', str(root),
                '--purpose', 'qualification', '--source-fingerprint', 'b' * 64]), redirect_stdout(io.StringIO()):
            self.assertEqual(cleanup.main(), 0)
        self.assertEqual(cleanup.read_marker(root)['source_fingerprint'], 'b' * 64)
        linked = self.qualification / 'linked';linked.symlink_to(root)
        self.assertNotIn(linked, [p for p, _ in cleanup.candidates(self.sessions, self.qualification, 'session')])
        (root / cleanup.WORKSPACE_MARKER).write_text('{')
        result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 1)
        self.assertEqual(records[0]['action'], 'kept_error')
        self.assertTrue(root.exists())
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_latest_round_in_session_copy_and_explicit_copy_both_kept(self):
        for receipt in ['capture-manifest.json', 'source-manifest.json', 'build-info.json']:
            with self.subTest(receipt=receipt):
                item = self.item(receipt)
                self.write(item, '.local/capture/' + receipt, json.dumps({'source_fingerprint': self.fingerprint}).encode())
                self.write(item, '.build/object')
                self.assertEqual(self.plan(item)['moves'], [])
        explicit = self.item('explicit');self.write(explicit, '.build/object')
        self.assertEqual(self.plan(explicit, keep=[explicit / 'source'])['moves'], [])
        self.assertEqual(self.plan(explicit, keep=[explicit.parent])['moves'], [])
        self.assertTrue(self.plan(explicit, keep=[Path(str(explicit) + '-other')])['moves'])

    def test_missing_or_malformed_installed_identity_retains_all(self):
        item = self.item();self.write(item, '.build/object')
        for payload in ['{}', '{', '{"source_fingerprint": 123}']:
            self.installed.write_text(payload)
            result, records = self.run_cleanup(apply=True)
            self.assertEqual(result, 0);self.assertIn('identity unavailable', records[0]['reason'])
            self.assertTrue((item / '.build/object').exists())
        self.installed.unlink()
        self.assertIsNone(cleanup.installed_fingerprint(self.installed))

    def test_malformed_capture_receipt_is_retained(self):
        item = self.item();self.write(item, 'capture-manifest.json', b'{')
        self.write(item, '.build/object')
        self.assertIn('unreadable build identity', self.plan(item)['reason'])

    def test_persistent_ws_slots_keep_warm_builds_but_ordinary_copy_can_clean(self):
        for name in ['ws1', 'wsp2', 'wsreview3']:
            with self.subTest(name=name):
                item = self.item(name);self.write(item, 'src/Package.swift', self.package)
                self.write(item, '.build/object')
                self.assertIn('unmarked legacy persistent workspace', self.plan(item)['reason'])
                self.assertEqual(self.plan(item)['moves'], [])
        ordinary = self.item('review-copy');self.write(ordinary, 'src/Package.swift', self.package)
        self.write(ordinary, '.build/object')
        self.assertTrue(self.plan(ordinary)['moves'])

    def test_nested_persistent_slot_retains_its_whole_scratch_item(self):
        item = self.item('round')
        self.write(item, 'slots/ws1/src/Package.swift', self.package)
        self.write(item, 'slots/ws1/.build/object')
        self.assertIn('unmarked legacy persistent workspace', self.plan(item)['reason'])
        self.assertEqual(self.plan(item)['moves'], [])

    def test_marked_workspaces_of_any_name_direct_or_nested_keep_source_and_warm_build(self):
        for prefix in ['', 'slots/']:
            for name in ['rv1', 'rv2', 'rv3', 'rw-current', 'arbitrary-name']:
                with self.subTest(prefix=prefix, name=name):
                    item = self.item(('direct-' if not prefix else 'nested-') + name)
                    workspace = item / prefix / name if prefix else item
                    self.write(workspace, 'src/source.py', b'old source\n')
                    self.write(workspace, '.build/object')
                    self.mark(workspace)
                    before = cleanup.inventory(item)
                    result, records = self.run_cleanup(apply=True)
                    self.assertEqual(result, 0)
                    record = next(r for r in records if r.get('path') == str(item))
                    self.assertIn('persistent workspace marker', record['reason'])
                    self.assertEqual(record['eligible_paths'], [])
                    self.assertEqual(record['kept_bytes'], record['total_bytes'])
                    self.assertEqual(cleanup.inventory(item), before)

    def test_other_session_unmarked_idle_item_never_selected_even_with_released_scan(self):
        foreign = self.item('idle', session='other-session')
        self.write(foreign, 'src/source.py', b'old source\n');self.write(foreign, '.build/object')
        own = self.item('own');self.write(own, '.build/object')
        for include in [False, True]:
            with self.subTest(include_released=include):
                found = list(cleanup.candidates(self.sessions, self.qualification, 'session', include))
                self.assertEqual(found, [(own, 'session')])
                with patch.object(cleanup, 'inventory', wraps=cleanup.inventory) as inspected:
                    self.assertEqual(self.run_cleanup(include_released=include)[0], 0)
                self.assertNotIn(foreign, [c.args[0] for c in inspected.call_args_list])
        self.assertEqual(self.run_cleanup(apply=True, include_released=True)[0], 0)
        self.assertTrue((foreign / '.build/object').exists())

    def test_released_marker_allows_cleanup_but_does_not_bypass_quiet_or_process_rules(self):
        item = self.item('rv1');self.write(item, 'src/source.py', b'old source\n')
        self.write(item, '.build/object');self.mark(item)
        self.assertEqual(self.plan(item)['moves'], [])
        self.mark(item, release=True)
        self.assertTrue(self.plan(item)['moves'])
        self.assertIn('last 45 minutes', self.plan(item, now=time.time())['reason'])
        self.assertIn('running process', self.plan(item, processes=[item])['reason'])
        self.assertEqual(self.run_cleanup(apply=True)[0], 0)
        self.assertFalse((item / '.build/object').exists())
        self.assertFalse((item / 'src/source.py').exists())
        self.assertTrue((item / cleanup.WORKSPACE_MARKER).exists())

    def test_foreign_root_requires_owning_sessions_release_and_explicit_scan(self):
        foreign = self.item('rv1', session='other-session')
        self.write(foreign, '.build/object');self.mark(foreign, session='other-session')
        self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session', True)), [])
        self.mark(foreign, session='other-session', release=True)
        self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session')), [])
        self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session', True)), [(foreign, 'session')])
        self.assertEqual(self.run_cleanup(apply=True, include_released=True)[0], 0)
        self.assertFalse((foreign / '.build/object').exists())
        # A purported release by an unrelated session is not the folder owner's release.
        self.write(foreign, cleanup.WORKSPACE_MARKER, json.dumps({'version': 1, 'session_id': 'intruder',
                   'purpose': 'wrong owner', 'released': True}).encode())
        self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session', True)), [])

    def test_nested_or_ancestor_marker_protects_even_under_released_root(self):
        item = self.item('round');self.mark(item, release=True)
        self.write(item, 'slots/rv1/.build/object');self.mark(item / 'slots/rv1')
        self.assertEqual(self.plan(item)['moves'], [])
        # Direct plan calls on a descendant must also respect its workspace root.
        self.assertEqual(self.plan(item / 'slots/rv1/.build')['moves'], [])

    def test_invalid_linked_and_unreadable_markers_fail_closed(self):
        item = self.item();self.write(item, '.build/object')
        marker = item / cleanup.WORKSPACE_MARKER
        for value in ['{', '[]', '{"released": true}',
                      '{"version": 1, "session_id": "session", "purpose": "build", "released": "true"}']:
            with self.subTest(value=value):
                marker.write_text(value)
                self.assertEqual(self.plan(item)['moves'], [])
                self.assertIn('invalid/unreadable workspace marker', self.plan(item)['reason'])
        marker.unlink();marker.symlink_to(self.installed)
        self.assertEqual(self.plan(item)['moves'], [])
        with self.assertRaisesRegex(ValueError, 'invalid workspace marker'):
            self.mark(item, release=True)

    def test_mark_and_release_commands_keep_owner_and_require_purpose(self):
        item = self.item('rv2')
        argv = ['clean_scratch.py', '--session-id', 'session']
        for mode in [['--mark', str(item), '--purpose', 'review slot'], ['--release', str(item)]]:
            with patch.object(sys, 'argv', argv + mode), redirect_stdout(io.StringIO()), \
                 patch.object(cleanup, 'git_objects', side_effect=AssertionError('marker command used Git')):
                self.assertEqual(cleanup.main(), 0)
        value = cleanup.read_marker(item)
        self.assertEqual(value, {'version': 1, 'session_id': 'session', 'purpose': 'review slot', 'released': True})
        with self.assertRaisesRegex(ValueError, 'another scratch session'):
            cleanup.write_marker(item, 'foreign', release=True)
        with self.assertRaisesRegex(ValueError, 'nonblank'):
            cleanup.write_marker(item, 'session', ' ')
        unmarked = self.item('unmarked')
        with self.assertRaisesRegex(ValueError, 'before releasing'):
            cleanup.write_marker(unmarked, 'session', release=True)
        self.mark(item)  # Reusing a released slot protects it again.
        self.assertFalse(cleanup.read_marker(item)['released'])

    def test_legacy_ws_migration_is_reported_and_release_is_explicit(self):
        for name in ['ws1', 'wsp2', 'wsreview3']:
            item = self.item(name);self.write(item, 'src/source.py', b'old source\n')
            self.write(item, '.build/object')
            result, records = self.run_cleanup()
            self.assertEqual(result, 0)
            self.assertIn('unmarked legacy persistent workspace', next(r['reason'] for r in records if r['path'] == str(item)))
            self.mark(item);self.assertEqual(self.plan(item)['moves'], [])
            self.mark(item, release=True);self.assertTrue(self.plan(item)['moves'])

    def test_qualification_requires_marker_ownership_or_explicit_released_scan(self):
        unknown = self.item('unknown', qualification=True);self.write(unknown, '.build/object')
        foreign = self.item('foreign', qualification=True);self.write(foreign, '.build/object')
        self.mark(foreign, session='other-session', release=True)
        own = self.item('own', qualification=True);self.mark(own, release=True)
        self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session')), [(own, 'qualification')])
        found = list(cleanup.candidates(self.sessions, self.qualification, 'session', True))
        self.assertEqual({p for p, _ in found}, {own, foreign})
        with self.assertRaisesRegex(ValueError, 'owning session'):
            cleanup.write_marker(foreign, 'session', release=True)

    def test_foreign_release_revoked_before_apply_stops_cleanup(self):
        item = self.item('rv3', session='other-session');self.write(item, '.build/object')
        self.mark(item, session='other-session', release=True)
        calls = 0
        def reader():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.mark(item, session='other-session')
            return []
        result, records = self.run_cleanup(apply=True, include_released=True, process_reader=reader)
        self.assertEqual(result, 1)
        self.assertTrue((item / '.build/object').exists())
        self.assertIn('ownership/release changed', records[0]['reason'])

    def test_unknown_caller_refuses_cleanup_without_git_or_inventory(self):
        with patch.object(cleanup, 'git_objects', side_effect=AssertionError('Git before caller validation')):
            with self.assertRaisesRegex(ValueError, 'caller session unknown'):
                cleanup.clean(self.sessions, self.qualification, self.repo, self.installed)

    def test_retained_git_object_query_uses_reachable_history_only(self):
        result = (b'a' * 40 + b' path\n' + b'b' * 40 + b'\n')
        with patch.object(cleanup.subprocess, 'check_output', return_value=result) as reader:
            self.assertEqual(cleanup.git_objects(self.repo), {'a' * 40, 'b' * 40})
        self.assertEqual(reader.call_args.args[0], ['git', '-C', str(self.repo), 'rev-list', '--objects', '--all'])

    def test_legacy_ws_without_src_is_still_kept_for_migration(self):
        item = self.item('wsp7');self.write(item, '.build/object')
        self.assertIn('unmarked legacy persistent workspace', self.plan(item)['reason'])
        self.assertEqual(self.plan(item)['moves'], [])

    def test_session_symlinks_are_never_followed_even_with_released_scan(self):
        item = self.item('released');self.mark(item, release=True);self.write(item, '.build/object')
        alias = item.parent.parent.parent / 'alias'
        alias.symlink_to(item.parent.parent, target_is_directory=True)
        with patch.object(cleanup, 'in_scope', wraps=cleanup.in_scope) as scope:
            self.assertEqual(list(cleanup.candidates(self.sessions, self.qualification, 'session', True)), [(item, 'session')])
        self.assertFalse(any('alias' in c.args[0].parts for c in scope.call_args_list))

    def test_empty_scope_invokes_neither_git_nor_process_inspection(self):
        self.item('foreign', session='other-session')
        with patch.object(cleanup, 'git_objects', side_effect=AssertionError('Git outside scope')):
            with redirect_stdout(io.StringIO()):
                self.assertEqual(cleanup.clean(self.sessions, self.qualification, self.repo, self.installed,
                                 session_id='session', process_reader=lambda: self.fail('process inspection outside scope')), 0)

    def test_cli_cannot_select_another_sessions_identity(self):
        with patch.object(sys, 'argv', ['clean_scratch.py', '--preview', '--session-id', 'other-session']), \
             patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                cleanup.main()
            self.assertEqual(error.exception.code, 2)
        with patch.dict(os.environ, {'CODEX_THREAD_ID': '', 'CLAUDE_SESSION_ID': ''}), \
             patch.object(sys, 'argv', ['clean_scratch.py', '--preview']), patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                cleanup.main()
            self.assertEqual(error.exception.code, 2)

    def test_changed_inventory_and_new_process_before_apply_refuse_move(self):
        item = self.item();file = self.write(item, '.build/object')
        original = cleanup.plan
        def changed(*args, **kwargs):
            decision = original(*args, **kwargs)
            file.write_bytes(b'changed while planning')
            return decision
        with patch.object(cleanup, 'plan', side_effect=changed):
            result, records = self.run_cleanup(apply=True)
        self.assertEqual(result, 1);self.assertIn('changed during inspection', records[0]['reason'])
        reader = iter([[], [item / '.build/object']])
        result, records = self.run_cleanup(apply=True, process_reader=lambda: next(reader))
        self.assertEqual(result, 1);self.assertIn('began using', records[0]['reason'])
        self.assertTrue(file.exists());self.assertEqual(list(self.trash.iterdir()), [])

    def test_failed_trash_move_keeps_bytes_and_reports_error(self):
        item = self.item();file = self.write(item, '.build/object')
        def fail(paths):
            raise OSError('fixture Trash unavailable')
        result, records = self.run_cleanup(apply=True, mover=fail)
        self.assertEqual(result, 1);self.assertTrue(file.exists())
        self.assertIn('Trash unavailable', records[0]['reason'])

    def test_remaining_files_change_during_move_stops_later_moves(self):
        item = self.item();self.write(item, '.build/object')
        note = self.write(item, 'note', b'unique evidence')
        source = self.write(item, 'src/source.py', b'old source\n')
        def changing_mover(paths):
            for path in paths:
                destination = self.trash / path.name;path.rename(destination)
                note.write_bytes(b'changed concurrently')
                yield path, destination
        with patch.object(cleanup, 'MOVE_BATCH_SIZE', 1):
            result, records = self.run_cleanup(apply=True, mover=changing_mover)
        self.assertEqual(result, 1);self.assertTrue(source.exists())
        self.assertEqual(records[0]['action'], 'trash_move')
        self.assertIn('remaining files changed', records[1]['reason'])

    def test_install_changes_before_first_move_are_retained(self):
        item = self.item();file = self.write(item, '.build/object')
        calls = 0
        def reader():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.installed.write_text(json.dumps({'source_fingerprint': 'b' * 64}))
            return []
        result, records = self.run_cleanup(apply=True, process_reader=reader)
        self.assertEqual(result, 1);self.assertTrue(file.exists())
        self.assertIn('installed round changed', records[0]['reason'])
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_process_starts_between_trash_moves(self):
        item = self.item();self.write(item, '.build/object')
        source = self.write(item, 'src/source.py', b'old source\n')
        self.write(item, 'note', b'private')
        reader = iter([[], [], [item / 'new-process-cwd']])
        with patch.object(cleanup, 'MOVE_BATCH_SIZE', 1):
            result, records = self.run_cleanup(apply=True, process_reader=lambda: next(reader))
        self.assertEqual(result, 1);self.assertTrue(source.exists())
        self.assertEqual(records[0]['action'], 'trash_move')
        self.assertIn('running process began', records[1]['reason'])

    def test_empty_subdirectories_do_not_fragment_whole_build_or_git_trees(self):
        item = self.item()
        for name in ['.build', 'CompilationCache.noindex', 'module-cache']:
            self.write(item, name + '/deep/tree/object')
            (item / name / 'deep/empty').mkdir()
        self.write(item, 'src/deep/source.py', b'old source\n')
        (item / 'src/empty').mkdir()
        self.write(item, 'unique-note', b'keep')
        # Even empty Git metadata must survive.
        (item / '.git').mkdir()
        expected = {item / name for name in ['.build', 'CompilationCache.noindex', 'module-cache', 'src']}
        self.assertEqual(set(self.plan(item)['moves']), expected)
        with patch.object(cleanup, 'trash_paths', wraps=cleanup.trash_paths) as mover:
            result, records = self.run_cleanup(apply=True, mover=mover)
        self.assertEqual(result, 0)
        self.assertEqual(set(mover.call_args.args[0]), expected)
        self.assertEqual(mover.call_count, 1)
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 4)
        self.assertTrue((item / '.git').is_dir())
        self.assertEqual((item / 'unique-note').read_bytes(), b'keep')

    def test_batch_spans_items_and_partly_eligible_folder_keeps_unique_files(self):
        expected = set()
        for i in range(5):
            item = self.item(f'copy-{i}')
            expected.add(self.write(item, 'mixed/old.py', b'old source\n'))
            self.write(item, 'mixed/unique.py', b'unlanded')
            self.write(item, '.build/deep/object')
            expected.add(item / '.build')
        with patch.object(cleanup, 'trash_paths', wraps=cleanup.trash_paths) as mover:
            result, records = self.run_cleanup(apply=True, mover=mover)
        self.assertEqual(result, 0)
        self.assertEqual(mover.call_count, 1)
        self.assertEqual(set(mover.call_args.args[0]), expected)
        self.assertEqual(len([r for r in records if r['action'] == 'trashed']), 5)
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 10)
        for item, _ in cleanup.candidates(self.sessions, self.qualification, 'session'):
            self.assertEqual((item / 'mixed/unique.py').read_bytes(), b'unlanded')
            self.assertFalse((item / 'mixed/old.py').exists())

    def test_batch_bounds_count_and_encoded_argv_bytes(self):
        entries = [(None, Path('/tmp/' + 'é' * i)) for i in range(1, 9)]
        with patch.object(cleanup, 'MOVE_BATCH_SIZE', 3), patch.object(cleanup, 'MOVE_BATCH_BYTES', 40):
            batches = list(cleanup.move_batches(entries))
        self.assertEqual([entry for batch in batches for entry in batch], entries)
        for batch in batches:
            self.assertLessEqual(len(batch), 3)
            self.assertLessEqual(sum(len(os.fsencode(p)) + 1 for _, p in batch), 40)

    def test_native_trash_is_one_call_and_retains_partial_success_receipts(self):
        paths = [Path('/fixture/a'), Path('/fixture/b')]
        for code, stdout, count in [(0, '# Moved "/fixture/a" to "/Trash/a"\n# Moved "/fixture/b" to "/Trash/b"\n', 2),
                                    (1, '# Moved "/fixture/a" to "/Trash/a"\n', 1)]:
            result = subprocess.CompletedProcess(['trash'], code, stdout=stdout, stderr='failure' if code else '')
            receipts = []
            with patch.dict(os.environ, {}, clear=True), patch.object(cleanup, 'TRASH_TOOL') as tool, \
                 patch.object(cleanup.subprocess, 'run', return_value=result) as runner:
                tool.exists.return_value = True
                tool.__str__.return_value = '/usr/bin/trash'
                try:
                    receipts.extend(cleanup.trash_paths(paths))
                except subprocess.CalledProcessError:
                    self.assertEqual(code, 1)
                self.assertEqual(runner.call_count, 1)
                self.assertEqual(runner.call_args.args[0], ['/usr/bin/trash', '--stopOnError', '--verbose', *map(str, paths)])
            self.assertEqual(len(receipts), count)

    def test_native_receipts_preserve_quotes_and_newlines_in_path_names(self):
        paths = [Path('/fixture/a"\nline'), Path('/fixture/b\n"line')]
        destinations = [Path('/Trash/a"\nline'), Path('/Trash/b\n"line')]
        output = ''.join(f'# Moved "{p}" to "{d}"\n' for p, d in zip(paths, destinations))
        result = subprocess.CompletedProcess(['trash'], 0, stdout=output, stderr='')
        with patch.dict(os.environ, {}, clear=True), patch.object(cleanup, 'TRASH_TOOL') as tool, \
             patch.object(cleanup.subprocess, 'run', return_value=result):
            tool.exists.return_value = True
            self.assertEqual(list(cleanup.trash_paths(paths)), list(zip(paths, destinations)))

    def test_partial_batch_failure_reports_moved_and_unmoved_item_bytes(self):
        first = self.item('a');self.write(first, '.build/object')
        second = self.item('b');self.write(second, '.build/object')
        def partial(paths):
            yield paths[0], cleanup.trash(paths[0])
            raise OSError('partial failure')
        result, records = self.run_cleanup(apply=True, mover=partial)
        self.assertEqual(result, 1)
        self.assertFalse(first.exists());self.assertTrue(second.exists())
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 1)
        errors = [r for r in records if r['action'] == 'kept_error']
        self.assertEqual(len(errors), 2)
        self.assertEqual([len(r['destinations']) for r in errors], [1, 0])
        self.assertTrue(all(r['build_bytes'] == len(b'generated') for r in errors))

    def test_incomplete_receipts_refuse_success(self):
        item = self.item();self.write(item, '.build/object')
        result, records = self.run_cleanup(apply=True, mover=lambda paths: [])
        self.assertEqual(result, 1)
        self.assertIn('receipts incomplete', records[0]['reason'])
        self.assertTrue(item.exists())

    def test_large_deep_tree_apply_time_bound_and_linear_inspection(self):
        # 250 items, 32,000 small files plus 11 GB logical sparse output. The
        # temporary Trash seam measures traversal/batching without native UI.
        for i in range(250):
            item = self.item(f'copy-{i:03d}')
            for j in range(128):
                self.write(item, f'.build/checkouts/dependency/level-{j % 8}/Sources/file-{j}', b'x')
            (item / '.build/checkouts/dependency/empty').mkdir()
            with (item / '.build/large.o').open('wb') as output:
                output.truncate(44_000_000)
            self.write(item, 'note.md', b'private evidence')
        started = time.monotonic()
        with patch.object(cleanup, 'inventory', wraps=cleanup.inventory) as inspected, \
             patch.object(cleanup, 'trash_paths', wraps=cleanup.trash_paths) as mover, \
             patch.object(cleanup, 'running_paths', return_value=[]) as processes:
            result, records = self.run_cleanup(apply=True, mover=mover, process_reader=processes)
        elapsed = time.monotonic() - started
        self.assertEqual(result, 0)
        self.assertLess(elapsed, 60, f'large tree apply took {elapsed:.2f}s')
        self.assertEqual(mover.call_count, 8)  # One batch per 32-item window.
        self.assertEqual(processes.call_count, 9)
        self.assertEqual(inspected.call_count, 750)  # Plan, pre-move, post-move per item.
        summaries = [r for r in records if r['action'] == 'trashed']
        self.assertEqual(len(summaries), 250)
        self.assertEqual(sum(r['build_bytes'] for r in summaries), 11_000_032_000)
        self.assertTrue(all(r['kept_bytes'] == len(b'private evidence') for r in summaries))
        print(f'large-tree fixture: 250 items, 32,000 small files, 11,000,032,000 logical eligible bytes, {elapsed:.3f}s apply')

    def test_main_refuses_symlink_root(self):
        link = self.root / 'linked-sessions';link.symlink_to(self.sessions, target_is_directory=True)
        with patch.object(sys, 'argv', ['clean_scratch.py', '--apply', '--sessions-root', str(link)]), \
             patch('sys.stderr', io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                cleanup.main()
            self.assertEqual(error.exception.code, 2)

    def test_no_permanent_deletion_calls(self):
        tree = ast.parse(Path(cleanup.__file__).read_text())
        calls = [node.func.attr for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)]
        for forbidden in ['unlink', 'rmtree', 'remove', 'rmdir', 'removedirs', 'system', 'popen']:
            self.assertNotIn(forbidden, calls)

    def test_cli_requires_explicit_mode_and_uses_overridden_fixture_roots(self):
        for args in [[], ['--preview', '--apply']]:
            with self.subTest(args=args), patch.object(sys, 'argv', ['clean_scratch.py', *args]), redirect_stdout(io.StringIO()), patch('sys.stderr', io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    cleanup.main()
                self.assertEqual(error.exception.code, 2)
        arguments = ['clean_scratch.py', '--preview', '--session-id', 'session', '--sessions-root', str(self.sessions),
                     '--qualification-root', str(self.qualification), '--repo', str(self.repo),
                     '--installed-info', str(self.installed), '--keep-qualified', str(self.root / 'keep')]
        with patch.object(sys, 'argv', arguments), patch.object(cleanup, 'clean', return_value=0) as runner:
            self.assertEqual(cleanup.main(), 0)
        self.assertEqual(runner.call_args.args[:4], (self.sessions, self.qualification, self.repo, self.installed))
        self.assertEqual(runner.call_args.args[4:], ([self.root / 'keep'], False))
        self.assertEqual(runner.call_args.kwargs, {'session_id': 'session', 'include_released': False})


def stat_mode_fifo(path):
    import stat
    return stat.S_ISFIFO(path.lstat().st_mode)


if __name__ == '__main__':
    unittest.main()
