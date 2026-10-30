"""CL-367 regressions; only temporary trees and a rename Trash fake."""
import io
import json
from contextlib import redirect_stdout
import os
from pathlib import Path
import sys
import subprocess
import time
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import clean_scratch as cleanup
from test_clean_scratch import CleanScratchTests

class ReleasedFolderTests(unittest.TestCase):
    setUp = CleanScratchTests.setUp
    item = CleanScratchTests.item
    write = CleanScratchTests.write
    plan = CleanScratchTests.plan
    run_cleanup = CleanScratchTests.run_cleanup

    def released(self, name='released'):
        root = self.item(name)
        cleanup.write_marker(root, 'session', 'retired workspace', tickets=['CL-367'])
        cleanup.write_marker(root, 'session', release=True)
        return root

    def test_manual_release_moves_whole_root_once_including_managed_and_git(self):
        root = self.released()
        for n in range(600):
            self.write(root, f'store-copy/managed/{n}', b'copied managed file')
        self.write(root, 'src/.git/config', b'private git metadata')
        self.write(root, 'notes.md', b'evidence preserved externally before release')
        moved = []
        def rename(paths):
            for path in paths:
                moved.append(path)
                destination = self.trash / path.name
                path.rename(destination)
                yield path, destination
        with patch.object(cleanup, 'du_sizes', side_effect=AssertionError('per-move size scan')):
            result, records = self.run_cleanup(apply=True, mover=rename)
        self.assertEqual(result, 0)
        self.assertEqual(moved, [root])
        self.assertEqual(len([r for r in records if r['action'] == 'trash_move']), 1)
        self.assertTrue((self.trash/root.name/'store-copy/managed/599').is_file())

    def test_release_restarts_quiet_window_and_other_recent_changes_still_hold(self):
        root = self.released()
        file = self.write(root, 'store-copy/managed/object', b'old content')
        before = cleanup.inventory(root)
        latest = max(max(e[4], e[5]) / 1e9 for e in before.values())
        self.assertEqual(self.plan(root, now=latest+cleanup.QUIET_SECONDS-1)['moves'], [])
        self.assertEqual(self.plan(root, now=latest+cleanup.QUIET_SECONDS+1)['moves'], [root])
        os.utime(file, (latest+300, latest+300))
        self.assertEqual(self.plan(root, now=latest+cleanup.QUIET_SECONDS+1)['moves'], [])

    def test_manual_release_still_holds_nested_marker_process_keep_and_installed_copy(self):
        root = self.released()
        self.write(root, 'store-copy/data', b'copy')
        nested = root/'inner'; nested.mkdir()
        cleanup.write_marker(nested, 'session', 'still assigned', tickets=['CL-367'])
        self.assertIn('persistent workspace', self.plan(root)['reason'])
        cleanup.write_marker(nested, 'session', release=True)
        for kwargs in [{'processes':[root/'store-copy/data']}, {'keep':[root]}, {'fingerprint':None}]:
            self.assertEqual(self.plan(root, **kwargs)['moves'], [])
        self.write(root, 'build-info.json', json.dumps({'source_fingerprint':self.fingerprint}).encode())
        self.assertEqual(self.plan(root)['moves'], [])

    def test_shared_size_row_rechecks_marker_change_instead_of_printing_null(self):
        root = self.item('held-then-released')
        self.write(root, 'managed/object', b'content')
        cleanup.write_marker(root, 'session', 'assigned', tickets=['CL-367'])
        original = cleanup.held_preview
        calls = []
        def release_after_probe(*args, **kwargs):
            result = original(*args, **kwargs)
            calls.append(result)
            if len(calls) == 1:
                cleanup.write_marker(root, 'session', release=True)
            return result
        output = io.StringIO()
        with patch.object(cleanup, 'held_preview', side_effect=release_after_probe), redirect_stdout(output):
            failed = cleanup.preview_items([(root, 'session')], self.objects, set(), self.fingerprint,
                [], lambda: self.now, 'session', False, sizer=lambda paths: {p: 4096 for p in paths})
        self.assertFalse(failed)
        row = json.loads(output.getvalue())
        self.assertIsInstance(row, dict)
        self.assertEqual(row['eligible_paths'], [str(root)])

    def test_many_large_released_trees_use_one_rename_each(self):
        roots=[]
        counts=[41162, 8192, 8192]
        for number in range(3):
            root=self.released(f'released-{number}'); roots.append(root)
            managed=root/'store-copy/managed'; managed.mkdir(parents=True)
            for n in range(counts[number]): (managed/str(n)).write_bytes(b'managed')
            # Logical size exercises byte accounting; sparse bytes are not 96 GiB on disk.
            with (root/'store-copy/large').open('wb') as output: output.truncate(32*1024**3)
        moves=[]
        def rename(paths):
            for path in paths:
                moves.append(path); destination=self.trash/path.name
                path.rename(destination); yield path,destination
        load=subprocess.check_output(['sysctl','-n','vm.loadavg'],text=True).strip()
        started=time.monotonic()
        with patch.object(cleanup,'du_sizes',side_effect=AssertionError('repeated sizing')):
            result,records=self.run_cleanup(apply=True,mover=rename)
        elapsed=time.monotonic()-started
        print(json.dumps({'case':'released managed trees', 'file_counts':counts,
                          'apply_wall_seconds':elapsed,'load':load,'root_renames':len(moves)}),flush=True)
        self.assertLess(elapsed,300,'multi-folder apply exceeded five minutes')
        self.assertEqual(result,0)
        self.assertEqual(moves,roots)
        self.assertEqual(sum(r['bytes'] for r in records if r['action']=='trash_move'),
                         3*32*1024**3 + sum(counts)*7 + sum((self.trash/r.name/cleanup.WORKSPACE_MARKER).stat().st_size for r in roots))
