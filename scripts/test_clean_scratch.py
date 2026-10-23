"""Scratch cleanup tests use temporary fixtures only; never real scratch or Trash."""
import ast
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
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
        def fail(path):
            raise OSError('fixture Trash unavailable')
        result, records = self.run_cleanup(apply=True, mover=fail)
        self.assertEqual(result, 1);self.assertTrue(file.exists())
        self.assertIn('Trash unavailable', records[0]['reason'])

    def test_remaining_files_change_during_move_stops_later_moves(self):
        item = self.item();self.write(item, '.build/object')
        note = self.write(item, 'note', b'unique evidence')
        source = self.write(item, 'src/source.py', b'old source\n')
        def changing_mover(path):
            destination = self.trash / path.name;path.rename(destination)
            note.write_bytes(b'changed concurrently')
            return destination
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
        reader = iter([[], [], [], [item / 'new-process-cwd']])
        result, records = self.run_cleanup(apply=True, process_reader=lambda: next(reader))
        self.assertEqual(result, 1);self.assertTrue(source.exists())
        self.assertEqual(records[0]['action'], 'trash_move')
        self.assertIn('running process began', records[1]['reason'])

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
