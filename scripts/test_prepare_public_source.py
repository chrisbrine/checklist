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

    def test_uuid_provider_identities_and_live_project_refused(self):
        # Assemble private-shaped inputs so this test source remains exportable.
        v4 = 'c0ffee00-1234-4567-89ab-0123456789ab'
        values = ['auto-codex/' + v4,
                  'auto-claude-' + 'a1b2c3/workspace:' + v4,
                  'auto-claude-' + 'f' * 40 + '/' + v4.upper() + ':' + v4.upper(),
                  'a3854aea-' + 'b62c-4fbc-b86b-' + '40ce4a4f0cd6']
        # UUIDv7 detection must not depend on a particular timestamp prefix.
        for prefix in ['01a1616c', '019abcde', '12345678', 'ffffffff']:
            for variant in '89ab':
                thread = prefix + '-1234-7abc-' + variant + 'def-0123456789ab'
                values.extend([thread, thread.upper(), 'auto-codex/' + thread,
                               'rollout-2026-10-21-' + thread + '.jsonl',
                               'thread_' + thread])
        for value in values:
            (self.root / 'README.md').write_text('Heading\n' + value)
            with self.subTest(value=value), self.assertRaises(ValueError) as error:
                prepare.read_source(self.root, 'README.md', {})
            self.assertIn('README.md:2', str(error.exception))
            self.assertNotIn(value, str(error.exception))

    def test_synthetic_uuid_namespace_and_content_hashes_allowed(self):
        for suffix in ['000', '001', '00a', 'fff']:
            synthetic = '00000000-0000-0000-0000-000000000' + suffix
            values = [synthetic, 'auto-codex/' + synthetic,
                      'auto-claude-' + 'abc123/' + synthetic + ':' + synthetic]
            for value in values:
                (self.root / 'README.md').write_text(value)
                with self.subTest(value=value):
                    self.assertEqual(prepare.read_source(self.root, 'README.md', {})[0], value.encode())
        values = ['abc123ef' * 8, '01a1616c' + '7abc89ab' * 4,
                  'c0ffee00-1234-4567-89ab-0123456789ab',  # Ordinary example UUIDv4.
                  '12345678-1234-' + '7abc-0def-0123456789ab',  # Not RFC UUIDv7 variant.
                  '12345678-1234-' + '6abc-8def-0123456789ab']
        for value in values:
            (self.root / 'README.md').write_text(value)
            with self.subTest(value=value):
                self.assertEqual(prepare.read_source(self.root, 'README.md', {})[0], value.encode())

    def test_synthetic_actor_allowance_is_narrow_and_checks_workspace_uuid(self):
        synthetic = '00000000-0000-0000-0000-000000000001'
        values = ['auto-codex/' + '00000000-0000-0000-0000-000000001000',
                  'auto-codex/' + '00000001-0000-0000-0000-000000000001',
                  'auto-claude-' + 'abc/00000000-0000-0000-0001-000000000001:' + synthetic]
        for value in values:
            (self.root / 'README.md').write_text(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                prepare.read_source(self.root, 'README.md', {})

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

    def test_planning_validator_applies_shared_uuid_privacy_rules(self):
        prepare.prepare(prepare.ROOT, self.target)
        readme = self.target / 'README.md'
        original = readme.read_text()
        values = ['auto-codex/' + 'c0ffee00-1234-4567-89ab-0123456789ab',
                  'auto-claude-' + 'ab/workspace:c0ffee00-1234-4567-89ab-0123456789ab',
                  '12345678-1234-' + '7abc-8def-0123456789ab',
                  'a3854aea-' + 'b62c-4fbc-b86b-' + '40ce4a4f0cd6']
        for value in values:
            readme.write_text(original + '\n' + value + '\n')
            result = prepare.subprocess.run([prepare.sys.executable, 'scripts/validate-plan.py'],
                                            cwd=self.target, text=True, capture_output=True)
            with self.subTest(value=value):
                self.assertEqual(result.returncode, 1, result.stderr)
                errors = json.loads(result.stdout)['errors']
                self.assertTrue(any('Concrete private identifier' in error and 'README.md:' in error
                                    for error in errors))
                self.assertNotIn(value, result.stdout + result.stderr)
        readme.write_text(original + '\n' + 'abc123ef' * 8 + '\n' +
                          'auto-codex/' + '00000000-0000-0000-0000-000000000001' + '\n')
        result = prepare.subprocess.run([prepare.sys.executable, 'scripts/validate-plan.py'],
                                        cwd=self.target, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['errors'], [])

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
