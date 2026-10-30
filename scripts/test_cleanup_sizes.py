"""Disjoint cleanup preview sizing; temporary trees and injected readers only."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from cleanup_sizes import background_sizes


class CleanupSizeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='checklist-size-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'allocated data' * 4096)
        return path

    @staticmethod
    def du(paths):
        result = subprocess.run(['/usr/bin/du', '-sk', *map(str, paths)],
                                capture_output=True, text=True, check=True)
        return {Path(name): int(size) * 1024 for size, name in
                (line.split('\t', 1) for line in result.stdout.splitlines())}

    def test_many_held_folders_and_qualification_share_one_scan(self):
        qualification = self.root / 'qualification'
        held = []
        for index in range(48):
            held.append(self.write(f'qualification/held-{index}/managed/item').parents[1])
        calls = []
        lock = threading.Lock()

        def read(paths):
            with lock:
                calls.extend(paths)
            return self.du(paths)

        sizer = background_sizes({'qualification': [qualification]}, held,
                                 size_reader=read, workers=3, chunk=5)
        with ThreadPoolExecutor(max_workers=8) as pool:
            rows = list(pool.map(lambda path: sizer([path])[path], held))
        self.assertEqual(sizer([qualification]), self.du([qualification]))
        self.assertEqual(rows, [self.du([path])[path] for path in held])
        self.assertEqual(set(calls), set(held))
        self.assertEqual(len(calls), len(held))
        # Repeated report/row reads use the completed results.
        self.assertEqual(sizer(held), dict(zip(held, rows)))
        self.assertEqual(len(calls), len(held))

    def test_nested_targets_partition_container_without_ancestor_rescan(self):
        self.write('scratch/pass/package/src/file')
        self.write('scratch/pass/other/file')
        self.write('scratch/remainder/file')
        scratch = self.root / 'scratch'
        container = scratch / 'pass'
        package = container / 'package'
        source = package / 'src'
        calls = []

        def read(paths):
            calls.extend(paths)
            return self.du(paths)

        requested = [scratch, container, package, source]
        sizer = background_sizes({'scratch': [scratch], 'overlap': [container]},
                                 [package, source], size_reader=read, chunk=2)
        self.assertEqual(sizer(requested), {path: self.du([path])[path] for path in requested})
        self.assertEqual(len(calls), len(set(calls)))
        self.assertTrue(all(not any(a in b.parents for b in calls) for a in calls))
        self.assertNotIn(scratch, calls)
        self.assertNotIn(container, calls)
        self.assertNotIn(package, calls)
        self.assertIn(source, calls)

    def test_symlink_target_is_not_traversed(self):
        self.write('outside/private/file')
        self.write('scratch/retained/file')
        scratch = self.root / 'scratch'
        link = scratch / 'link'
        link.symlink_to(self.root / 'outside', target_is_directory=True)
        calls = []

        def read(paths):
            calls.extend(paths)
            return {path: 1 for path in paths}

        sizer = background_sizes({'scratch': [scratch]}, [link / 'private'], size_reader=read)
        sizer([scratch])
        self.assertIn(link, calls)
        self.assertEqual(sizer([link / 'private']), {})
        self.assertFalse(any(link in path.parents for path in calls))

    def test_large_directory_jobs_are_independent_and_group_roots_split_twice(self):
        for package in ('a', 'b', 'c'):
            self.write(f'scratch/w10/{package}/tree/item')
        self.write('scratch/readme')
        scratch = self.root / 'scratch'
        round_root = scratch / 'w10'
        calls = []
        lock = threading.Lock()

        def read(paths):
            with lock:
                calls.append(list(paths))
            return self.du(paths)

        sizer = background_sizes({'scratch': [scratch], 'nested': [round_root]},
                                 size_reader=read, workers=2, chunk=16)
        self.assertEqual(sizer([scratch, round_root]),
                         {path: self.du([path])[path] for path in (scratch, round_root)})
        directories = [path for batch in calls for path in batch if path.is_dir()]
        self.assertEqual(set(directories), set(round_root.iterdir()))
        self.assertTrue(all(len(batch) == 1 for batch in calls if any(path.is_dir() for path in batch)))
        flattened = [path for batch in calls for path in batch]
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertTrue(all(not any(a in b.parents for b in flattened) for a in flattened))

    def test_worker_bound_and_missing_root(self):
        for index in range(20):
            self.write(f'root/{index}/file')
        active = maximum = 0
        lock = threading.Lock()

        def read(paths):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(active, maximum)
            time.sleep(.005)
            with lock:
                active -= 1
            return {path: 1 for path in paths}

        root = self.root / 'root'
        missing = self.root / 'missing'
        sizer = background_sizes({'scratch': [root, missing]}, list(root.iterdir()),
                                 size_reader=read, workers=2, chunk=1)
        self.assertEqual(sizer([root])[root], root.lstat().st_blocks * 512 + 20)
        self.assertEqual(sizer([missing]), {})
        self.assertLessEqual(maximum, 2)
        self.assertGreater(maximum, 0)


if __name__ == '__main__':
    unittest.main()
