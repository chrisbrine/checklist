#!/usr/bin/env python3
"""External binding release check (21 Nov 2026).

A live-backup-seeded slot start inspects for about 50 minutes at high load. In that time an
editor save in another project replaced a bound file, and the release refused the seed.
These cases keep the release guard: a replaced leaf passes, an overlap with a Checklist data
root is refused, and a path that changes during the release check is refused.
Run: python3 -I script/test_external_binding_release.py
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_instances  # noqa: E402


class ExternalBindingReleaseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / 'project' / 'source.txt'
        self.path.parent.mkdir()
        self.path.write_text('first')
        self.cache = test_instances.ExternalBindingOverlapCache()
        self.assertFalse(self.cache.overlap(self.path, 'records.data.file_scopes[].canonical_key'))

    def tearDown(self):
        self.folder.cleanup()

    def replace_leaf(self):
        before = self.path.lstat().st_ino
        replacement = self.path.with_name('source.txt.save')
        replacement.write_text('second')
        os.replace(replacement, self.path)
        self.assertNotEqual(self.path.lstat().st_ino, before, 'fixture: the save replaces the inode')

    def test_replaced_leaf_passes_release_and_is_counted(self):
        self.replace_leaf()
        self.cache.revalidate()
        self.assertEqual(self.cache.changed_since_inspection, 1)

    def test_unchanged_binding_passes_without_a_change_count(self):
        self.cache.revalidate()
        self.assertEqual(self.cache.changed_since_inspection, 0)

    def test_overlap_at_release_is_refused(self):
        self.replace_leaf()
        self.cache.full_overlap = lambda path: True
        with self.assertRaisesRegex(ValueError, 'overlaps a Checklist data root'):
            self.cache.revalidate()

    def test_change_during_the_release_check_is_refused(self):
        readings = iter([b'a', b'b'])
        self.cache.named_identity = lambda path: next(readings)
        with self.assertRaisesRegex(ValueError, 'changed during release'):
            self.cache.revalidate()

    def test_replaced_ancestor_folder_is_checked_again(self):
        # Swap the project folder for a new folder with the same name and file: the release
        # repeats the overlap check on the new ancestry instead of trusting the old result.
        checked = []
        original = self.cache.full_overlap
        self.cache.full_overlap = lambda path: checked.append(path) or original(path)
        moved = self.path.parent.with_name('project.old')
        self.path.parent.rename(moved)
        self.path.parent.mkdir()
        self.path.write_text('first')
        self.cache.revalidate()
        self.assertEqual(checked, [self.path])
        self.assertEqual(self.cache.changed_since_inspection, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
