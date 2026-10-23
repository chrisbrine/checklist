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
        self.repo = self.root / 'retained';self.repo.mkdir()
        self.git('init', '-q')
        self.package = b'let package = Package(name: "Checklist")\n'
        (self.repo / 'Package.swift').write_bytes(self.package)
        (self.repo / 'source.py').write_bytes(b'old source\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        # Historical source counts even when it differs from today's HEAD.
        (self.repo / 'source.py').write_bytes(b'new source\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'new fixture')
        self.objects = cleanup.git_objects(self.repo)
        self.sessions = self.root / 'sessions';self.sessions.mkdir()
        self.qualification = self.root / 'qualification';self.qualification.mkdir()
        self.installed = self.root / 'installed.json'
        self.fingerprint = 'a' * 64
        self.installed.write_text(json.dumps({'source_fingerprint': self.fingerprint}))
        self.now = time.time() + 7200  # Age fixture ctimes without changing the machine clock.
        self.trash = self.root / 'trash';self.trash.mkdir()

    def git(self, *arguments):
        return subprocess.check_output(['git', '-C', str(self.repo), *arguments], stderr=subprocess.STDOUT)

    def item(self, name='copy', host='-Users-Checklist', qualification=False):
        path = self.qualification / name if qualification else self.sessions / host / 'session' / 'scratchpad' / name
        path.mkdir(parents=True)
        return path

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
        with redirect_stdout(output), patch.dict(os.environ, CHECKLIST_TRASH_DIR=str(self.trash)):
            result = cleanup.clean(self.sessions, self.qualification, self.repo, self.installed,
                                   apply=apply, process_reader=kwargs.pop('process_reader', lambda: []),
                                   clock=lambda: self.now, **kwargs)
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
        found = list(cleanup.candidates(self.sessions, self.qualification))
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
        old = self.item('old', qualification=True);self.write(old, '.build/object')
        latest = self.item('latest', qualification=True);self.write(latest, '.build/object')
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
                self.assertIn('persistent build slot', self.plan(item)['reason'])
                self.assertEqual(self.plan(item)['moves'], [])
        ordinary = self.item('review-copy');self.write(ordinary, 'src/Package.swift', self.package)
        self.write(ordinary, '.build/object')
        self.assertTrue(self.plan(ordinary)['moves'])

    def test_nested_persistent_slot_retains_its_whole_scratch_item(self):
        item = self.item('round')
        self.write(item, 'slots/ws1/src/Package.swift', self.package)
        self.write(item, 'slots/ws1/.build/object')
        self.assertIn('persistent build slot', self.plan(item)['reason'])
        self.assertEqual(self.plan(item)['moves'], [])

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
        arguments = ['clean_scratch.py', '--preview', '--sessions-root', str(self.sessions),
                     '--qualification-root', str(self.qualification), '--repo', str(self.repo),
                     '--installed-info', str(self.installed), '--keep-qualified', str(self.root / 'keep')]
        with patch.object(sys, 'argv', arguments), patch.object(cleanup, 'clean', return_value=0) as runner:
            self.assertEqual(cleanup.main(), 0)
        self.assertEqual(runner.call_args.args[:4], (self.sessions, self.qualification, self.repo, self.installed))
        self.assertEqual(runner.call_args.args[4:], ([self.root / 'keep'], False))


def stat_mode_fifo(path):
    import stat
    return stat.S_ISFIFO(path.lstat().st_mode)


if __name__ == '__main__':
    unittest.main()
