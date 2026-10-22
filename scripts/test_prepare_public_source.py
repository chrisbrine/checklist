"""Owned-fixture checks for the unpublished public export boundary."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_public', Path(__file__).with_name('prepare-public-source.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        (self.root / 'scripts').mkdir(parents=True)
        self.target = Path(self.temp.name) / 'export'

    def manifest(self, paths, exceptions=None):
        (self.root / prepare.INVENTORY).write_text(json.dumps({
            'format': 1, 'files': paths, 'synthetic_exceptions': exceptions or {}}))

    def test_inventory_refuses_traversal_private_and_duplicate_paths(self):
        for names in [['../outside'], ['/absolute'], ['a', 'a'], ['b', 'a'],
                      ['.local/receipt.json'], ['docs/research/a.md'], ['store.sqlite']]:
            with self.subTest(names=names):
                self.manifest(names)
                with self.assertRaises(ValueError):
                    prepare.inventory(self.root)

    def test_unlisted_private_files_are_not_selected(self):
        self.manifest(['README.md'])
        (self.root / 'README.md').write_text('Synthetic product')
        (self.root / 'private-audit.md').write_text('private')
        self.assertEqual(prepare.inventory(self.root)[0], ['README.md'])

    def test_symlink_file_and_directory_refused(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (outside / 'secret').write_text('private')
        (self.root / 'link').symlink_to(outside, target_is_directory=True)
        (self.root / 'secret').symlink_to(outside / 'secret')
        for name in ['link/secret', 'secret']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                prepare.read_source(self.root, name, {})

    def test_private_identifiers_refused_without_printing_the_secret(self):
        values = ['/' + 'Users/real-owner/data', '/' + 'home/real-owner',
                  '/tmp/' + 'cc-socks/12345.sock', 'session_' + 'a' * 24,
                  '/private/tmp/' + 'claude-12345', '-----BEGIN ' + 'PRIVATE KEY-----']
        for value in values:
            (self.root / 'README.md').write_text(value)
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                prepare.read_source(self.root, 'README.md', {})
            self.assertNotIn(value, str(error.exception))

    def test_synthetic_exception_is_hash_bound(self):
        (self.root / 'Tests').mkdir()
        path = self.root / 'Tests/Fixture.swift'
        data = ('/' + 'Users/fictional').encode()
        path.write_bytes(data)
        exceptions = {'Tests/Fixture.swift': {'sha256': hashlib.sha256(data).hexdigest(),
                      'patterns': ['home_path'], 'reason': 'Synthetic owner path'}}
        self.assertEqual(prepare.read_source(self.root, 'Tests/Fixture.swift', exceptions)[0], data)
        path.write_bytes(data + b'/changed')
        with self.assertRaisesRegex(ValueError, 'renewed review'):
            prepare.read_source(self.root, 'Tests/Fixture.swift', exceptions)

    def test_existing_and_inside_destinations_refused(self):
        self.target.mkdir()
        (self.target / 'keep').write_text('retained')
        for target in [self.target, self.root / 'export']:
            with self.subTest(target=target), self.assertRaises(ValueError):
                prepare.prepare(self.root, target)
        self.assertEqual((self.target / 'keep').read_text(), 'retained')

    def test_invalid_export_is_not_left_at_destination(self):
        self.manifest(['README.md'])
        (self.root / 'README.md').write_text('Synthetic product')
        with patch.object(prepare.subprocess, 'run', return_value=type('Result', (), {'stdout': '{"errors":["bad"]}'})()):
            with self.assertRaisesRegex(ValueError, 'validation failed'):
                prepare.prepare(self.root, self.target)
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.glob('.checklist-public-*')), [])

    def test_actual_export_is_complete_reproducible_and_validated(self):
        report = prepare.prepare(prepare.ROOT, self.target)
        second = prepare.prepare(prepare.ROOT, self.target.with_name('second'))
        self.assertEqual(report, second)
        expected = {entry['path'] for entry in report['files']}
        actual = {str(p.relative_to(self.target)) for p in self.target.rglob('*') if p.is_file()}
        self.assertEqual(actual, expected | {'public-source-manifest.json'})
        for entry in report['files']:
            path = self.target / entry['path']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry['sha256'])
            self.assertEqual(f'{path.stat().st_mode & 0o777:06o}', entry['mode'])
        self.assertFalse(any(p.startswith(('.git/', '.local/')) for p in actual))
        self.assertNotIn('Tests/ChecklistCoreTests/ArchivePreviewStoreCopyTests.swift', actual)
        self.assertIn('Package.swift', actual)
        self.assertIn('Sources/ChecklistService/main.swift', actual)
        self.assertEqual(report['planning_validation']['errors'], [])


if __name__ == '__main__':
    unittest.main()
