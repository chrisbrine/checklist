"""CL-366: fake bundles, temporary Git repositories and stores; no native calls."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contextlib import ExitStack, redirect_stdout
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import test_instance_restage as policy
import test_instances as harness


class RestageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.command('init', '-q')
        self.command('config', 'user.email', 'fixture@example.invalid')
        self.command('config', 'user.name', 'Fixture')
        self.inputs = {'Sources/ChecklistApp/Views/View.swift': b'view',
                       'Sources/ChecklistCore/StorageBootstrap.swift': b'bootstrap',
                       'Sources/ChecklistCore/SchemaMigrations.swift': b'static let currentSchema = 4\nPRAGMA user_version=4\n'}
        for name, data in self.inputs.items():
            file = self.repo / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(data)
        self.command('add', '.')
        self.command('commit', '-qm', 'seed')
        self.commit = self.command('rev-parse', 'HEAD').strip()
        self.origin = self.root / 'origin'; self.target = self.root / 'target'
        for capture in [self.origin, self.target]: shutil.copytree(self.repo / 'Sources', capture / 'source/Sources')
        self.manifest = {'build_id': 'old', 'source_fingerprint': 'a' * 64, 'input_roots': ['Sources'],
                         'inputs': sorted([{'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                           'executable': False} for name, data in self.inputs.items()], key=lambda e: e['path'])}
        self.target_manifest = dict(self.manifest, build_id='new', source_fingerprint='b' * 64)
        self.live = self.root / 'live'; self.snapshot = self.publish('snapshot-one', 10)
        (self.live / 'checklist-store.identity.json').write_text(json.dumps(
            {'logical_store_id': 'store', 'incarnation': 'inc', 'schema_revision': 4}))
        self.seed = {'kind': 'backup', 'live_snapshot': True, 'source': str(self.snapshot.parent),
                     'source_hash': hashlib.sha256(self.snapshot.read_bytes()).hexdigest(),
                     'before_start': {'identity': {'incarnation': 'inc'}}}
        self.reply = self.root / 'reply.json'
        self.reply.write_text(json.dumps(self.operation_reply()))
        self.completion = policy.backup_completion(self.reply)
        self.now = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)

    def command(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True)

    def publish(self, name, stamp, captured=None):
        captured = captured or datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        folder = self.live / 'backups' / name; folder.mkdir(parents=True)
        value = {'format': 1, 'kind': 'checklist-store-snapshot', 'operationID': name, 'storeID': 'store', 'sourceRoot': str(self.live),
                 'schema': 4, 'capturedAt': captured}
        file = folder / 'manifest.json'; file.write_text(json.dumps(value)); os.utime(file, (stamp, stamp))
        (folder / 'intent.json').write_text(json.dumps({'format': '1', 'kind': value['kind'], 'operation_id': name,
                                                       'store_id': 'store', 'source_root': str(self.live)}))
        return file

    def operation_reply(self, **changes):
        data = {'status': 'complete', 'format': 'checklist-store-snapshot', 'path': str(self.snapshot.parent),
                'manifest_sha256': hashlib.sha256(self.snapshot.read_bytes()).hexdigest(), 'operation_id': 'snapshot-one'}
        data.update(changes)
        return {'method': 'backup_create', 'state': 'succeeded', 'operation_id': 'job', 'result': {'data': data}}

    def proof(self, commit=True, when=None, schema=4):
        return policy.reuse_proof(self.repo, self.live, self.seed, self.origin, self.manifest,
                                  self.target, self.target_manifest, self.commit if commit else None,
                                  self.completion, lambda: schema, when)

    def test_safe_diff_records_original_target_commit_and_reason(self):
        (self.target / 'source/Sources/ChecklistApp/Views/View.swift').write_text('new view')
        proof = self.proof()
        self.assertEqual(proof['changed_paths'], ['Sources/ChecklistApp/Views/View.swift'])
        self.assertEqual(proof['seeded_commit'], self.commit)
        self.assertEqual(proof['target_build_id'], 'new')
        for text in ['complete backup of this store', 'schema 4', '72 hours', 'no listed storage']:
            self.assertIn(text, proof['reason'])
        self.assertEqual(proof['seed_completion'], self.completion)
        self.assertEqual(proof['seed_max_age_hours'], 72)

    def test_every_policy_path_refuses_and_view_is_allowed(self):
        # Concrete guards against removing a critical family from the one policy list.
        required = ['StorageBootstrap', 'StorageUpgradePreparation', 'StorageSnapshot', 'StorageRestore', 'StorageRecovery']
        for name in required:
            self.assertTrue(policy.sensitive_paths(['Sources/ChecklistCore/' + name + '.swift']))
        for path in ['Sources/ChecklistCore/SchemaMigrations.swift', 'Sources/ChecklistCore/FileDurability.swift',
                     'Sources/ChecklistCore/ManagedPaths.swift', 'Sources/ChecklistService/main.swift',
                     'Sources/ChecklistCore/Store.swift', 'script/build_and_run.sh', 'Package.resolved',
                     'Sources/ChecklistIPC/LocalPlatformServices.swift', 'Sources/ChecklistCLI/ChecklistCommand.swift', 'Sources/ChecklistCore/GroupKeys.swift',
                     'Sources/ChecklistCore/GRDBRecordEnvelopeAdapter.swift', 'Sources/ChecklistCore/RecordEnvelope.swift']:
            self.assertTrue(policy.sensitive_paths([path]), path)
        self.assertEqual(policy.sensitive_paths(['Sources/ChecklistApp/Views/View.swift']), [])
        for path in ['Sources/ChecklistCore/StorageBootstrap.swift', 'Sources/ChecklistCore/SchemaMigrations.swift']:
            file = self.target / 'source' / path
            file.write_text('changed')
            with self.assertRaisesRegex(ValueError, 'Fresh real-size'): self.proof()
            file.write_bytes(self.inputs[path])

    def test_deleted_and_renamed_sensitive_file_refuses(self):
        file = self.target / 'source/Sources/ChecklistCore/StorageBootstrap.swift'
        file.rename(file.with_name('Unrelated.swift'))
        with self.assertRaisesRegex(ValueError, 'StorageBootstrap'): self.proof()
        file.with_name('Unrelated.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'StorageBootstrap'): self.proof()

    def test_unknown_wrong_or_dirty_seed_commit_refuses(self):
        with self.assertRaisesRegex(ValueError, 'commit is unknown'): self.proof(False)
        for commit in ['0' * 40, 'HEAD']:
            with self.assertRaises(ValueError): policy.verify_seed_commit(self.repo, self.manifest, commit)
        self.manifest['inputs'][0]['sha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'differs from captured'): self.proof()

    def test_omitted_or_extra_seed_inputs_refuse(self):
        self.manifest['inputs'].pop()
        with self.assertRaisesRegex(ValueError, 'differs from captured'): self.proof()

    def test_newer_backup_does_not_end_reuse(self):
        first = self.proof()
        self.publish('snapshot-two', 20); self.publish('qualification-round/snapshot-three', 30)
        self.assertEqual(self.proof(), first)

    def test_named_qualification_backup_can_seed(self):
        manifest = self.publish('qualification-round/snapshot-two', 20)
        digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.seed.update(source=str(manifest.parent), source_hash=digest)
        self.completion.update(path=str(manifest.parent), manifest_sha256=digest, operation_id='qualification-round/snapshot-two')
        self.assertEqual(self.proof()['backup_manifest_sha256'], digest)

    def test_age_limit_is_72_hours_with_a_small_clock_allowance(self):
        captured = '2026-10-30T12:00:00Z'
        self.rewrite_manifest(capturedAt=captured)
        start = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)
        self.proof(when=start + timedelta(hours=72))
        self.proof(when=start - timedelta(minutes=5))
        with self.assertRaisesRegex(ValueError, '72-hour limit.*Fresh real-size'): self.proof(when=start + timedelta(hours=72, seconds=1))
        with self.assertRaisesRegex(ValueError, '72-hour limit'): self.proof(when=start - timedelta(minutes=6))

    def rewrite_manifest(self, **changes):
        value = json.loads(self.snapshot.read_text()); value.update(changes)
        self.snapshot.write_text(json.dumps(value))
        digest = hashlib.sha256(self.snapshot.read_bytes()).hexdigest()
        self.seed['source_hash'] = digest; self.completion['manifest_sha256'] = digest
        return digest

    def test_schema_must_equal_seed_live_and_stage(self):
        with self.assertRaisesRegex(ValueError, 'schema.*differ.*Fresh real-size'): self.proof(schema=5)
        self.rewrite_manifest(schema=3)
        with self.assertRaisesRegex(ValueError, 'seed schema 3'): self.proof()
        self.rewrite_manifest(schema=4)
        (self.live / 'checklist-store.identity.json').write_text(json.dumps(
            {'logical_store_id': 'store', 'incarnation': 'inc', 'schema_revision': 5}))
        with self.assertRaisesRegex(ValueError, 'live schema 5'): self.proof()

    def test_another_store_or_incarnation_refuses(self):
        identity = self.live / 'checklist-store.identity.json'
        for value in [{'logical_store_id': 'other', 'incarnation': 'inc', 'schema_revision': 4},
                      {'logical_store_id': 'store', 'incarnation': 'restored', 'schema_revision': 4}]:
            identity.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'another store or incarnation'): self.proof()

    def test_partial_generation_with_manifest_and_intent_is_not_complete(self):
        # CL-377: a final-name folder with both files and no receipt. No reply exists, so it cannot qualify.
        with self.assertRaisesRegex(ValueError, 'No usable backup_create reply'): policy.backup_completion(self.root / 'absent.json')
        failed = {'method': 'backup_create', 'state': 'failed', 'result': {'data': self.operation_reply()['result']['data']}}
        accepted = {'command_outcome': 'accepted', 'data': {'method': 'backup_create', 'state': 'queued'}}
        incomplete = self.operation_reply(status='incomplete')
        for value in [failed, accepted, incomplete, {'error': {'code': 'BACKUP_INCOMPLETE'}}]:
            self.reply.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'No usable backup_create reply'): policy.backup_completion(self.reply)
        self.reply.write_text(json.dumps({'method': 'backup_create', 'state': 'failed', 'error': {'code': 'BACKUP_INCOMPLETE'}}))
        with self.assertRaisesRegex(ValueError, 'operation state is failed'): policy.backup_completion(self.reply)
        self.reply.write_text('{invalid')
        with self.assertRaisesRegex(ValueError, 'No usable'): policy.backup_completion(self.reply)

    def test_reply_shapes_and_reply_for_another_backup(self):
        data = self.operation_reply()['result']['data']
        for value in [self.operation_reply(), {'data': self.operation_reply()}, {'data': data}]:
            self.reply.write_text(json.dumps(value))
            self.assertEqual(policy.backup_completion(self.reply)['manifest_sha256'], data['manifest_sha256'])
        for key, wrong in [('path', str(self.root / 'other')), ('manifest_sha256', 'f' * 64), ('operation_id', 'other')]:
            self.completion = dict(data, source='backup_create reply', reply_sha256='x'); self.completion[key] = wrong
            with self.assertRaisesRegex(ValueError, 'names another backup'): self.proof()

    def test_seed_folder_must_be_published_unchanged_and_live(self):
        good = self.proof()['backup_manifest_sha256']
        self.seed['source_hash'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'changed since slot create'): self.proof()
        self.seed['source_hash'] = good
        source = self.seed['source']
        for wrong in [str(self.live / 'backups/.snapshot-staging-one'), str(self.root / 'elsewhere/snapshot-one')]:
            self.seed['source'] = wrong
            with self.assertRaisesRegex(ValueError, 'Fresh real-size'): self.proof()
        self.seed['source'] = source
        self.seed['live_snapshot'] = False
        with self.assertRaisesRegex(ValueError, 'live-backup seed'): self.proof()

    def test_malformed_published_manifest_requests_fresh_copy(self):
        self.snapshot.write_text('{invalid')
        with self.assertRaisesRegex(ValueError, 'Fresh real-size'): self.proof()

    def test_linked_publication_refuses(self):
        intent = self.snapshot.parent / 'intent.json'; data = intent.read_bytes(); intent.unlink()
        outside = self.root / 'intent'; outside.write_bytes(data); intent.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'linked'): self.proof()

    def test_listed_path_refuses_by_name_before_seed_or_schema_checks(self):
        (self.target / 'source/Sources/ChecklistCore/StorageBootstrap.swift').write_text('changed')
        self.seed['source_hash'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'Sources/ChecklistCore/StorageBootstrap.swift'): self.proof(schema=9)

    def metadata(self):
        return {'slot': 1, 'build_id': 'new', 'source_fingerprint': 'b' * 64, 'stage_path': str(self.target),
                'seed': self.seed, 'mode': 'stopped', 'restage': self.proof(),
                'checks': {'build_id': 'new', 'source_fingerprint': 'b' * 64, 'passed': True}}

    def verify(self, path):
        return (self.origin, self.manifest) if Path(path) == self.origin else (self.target, self.target_manifest)

    def test_promotion_revalidates_cumulative_proof_and_requires_fresh_check(self):
        metadata = self.metadata()
        with patch.object(harness, 'REPO', self.repo), patch.object(harness, 'LIVE', self.live), \
             patch.object(harness, 'verify_stage', side_effect=self.verify), redirect_stdout(io.StringIO()) as output:
            self.assertTrue(all(harness.promotion_gates(metadata, [metadata]).values()))
            self.assertIn('complete backup of this store', output.getvalue())
            self.assertIn('seeded_commit', output.getvalue())
            metadata['checks']['passed'] = False
            self.assertFalse(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            metadata['checks']['passed'] = True
            (self.target / 'source/Sources/ChecklistCore/StorageBootstrap.swift').write_text('unsafe')
            self.assertFalse(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            # An original, freshly copied same-build slot keeps the existing fresh gate.
            fresh = dict(metadata); fresh.pop('restage')
            self.assertTrue(all(harness.promotion_gates(fresh, [fresh]).values()))

    def test_promotion_newer_backup_passes_old_seed_or_modified_proof_refuses(self):
        metadata = self.metadata()
        with patch.object(harness, 'REPO', self.repo), patch.object(harness, 'LIVE', self.live), \
             patch.object(harness, 'verify_stage', side_effect=self.verify), redirect_stdout(io.StringIO()) as output:
            self.publish('snapshot-new', 50)
            self.assertTrue(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            proof = metadata['restage']
            metadata['restage'] = dict(proof, changed_paths=['fabricated'])
            self.assertFalse(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            metadata['restage'] = proof
            without = {k: v for k, v in proof.items() if k != 'seed_completion'}
            metadata['restage'] = without
            self.assertFalse(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            self.assertIn('--backup-reply', output.getvalue())
            metadata['restage'] = proof
            late = datetime.now(timezone.utc) + timedelta(hours=73)
            with patch.object(policy, 'datetime', wraps=datetime) as clock:
                clock.now.return_value = late
                self.assertFalse(harness.promotion_gates(metadata, [metadata])['live_snapshot_check_same_build'])
            self.assertIn('72-hour limit', output.getvalue())

    def test_restage_preserves_store_clears_checks_and_uses_original_on_second_stage(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(harness, 'BASE', self.root / 'slots'))
            p = harness.paths(1); p['data'].mkdir(parents=True); p['bundle'].mkdir()
            store = p['data'] / 'checklist.sqlite'; store.write_bytes(b'owned-store-do-not-copy')
            metadata = dict(self.metadata(), build_id='old', source_fingerprint='a' * 64, stage_path=str(self.origin))
            metadata.pop('restage'); harness.save(p, metadata)
            for capture in [self.target]:
                info = capture / 'Checklist.app/Contents/Info.plist'; info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.checklist.app'}))
            for name, value in [('caller_session', 'actual'), ('read_marker', {'session_id': 'actual', 'released': False, 'tickets': ['CL-366']}),
                                ('stopped', None), ('bundle_check', self.manifest), ('require_managed_path_support', 4), ('sign_identity', '-')]:
                stack.enter_context(patch.object(harness, name, return_value=value))
            stack.enter_context(patch.object(harness, 'REPO', self.repo)); stack.enter_context(patch.object(harness, 'LIVE', self.live))
            stack.enter_context(patch.object(harness, 'verify_stage', side_effect=self.verify))
            stack.enter_context(patch.object(harness, 'stage_selection', return_value=(self.target, self.target_manifest)))
            stack.enter_context(patch.object(harness, 'mark_qualification'))
            def fake_run(command, **kwargs):
                if command[0] == 'ditto': shutil.copytree(command[1], command[2])
                else: self.assertEqual(command[0], 'codesign')
            stack.enter_context(patch.object(harness, 'run', side_effect=fake_run))
            missing = SimpleNamespace(slot=1, session_id='actual', seeded_commit=self.commit, backup_reply=None)
            with self.assertRaisesRegex(ValueError, '--backup-reply'): harness.restage(missing, p)
            args = SimpleNamespace(slot=1, session_id='actual', seeded_commit=self.commit, backup_reply=self.reply)
            inode = store.stat().st_ino
            harness.restage(args, p)
            final = harness.load(p)
            self.assertEqual(store.read_bytes(), b'owned-store-do-not-copy'); self.assertEqual(store.stat().st_ino, inode)
            self.assertIsNone(final['checks']); self.assertEqual(final['restage']['seeded_stage_path'], str(self.origin))
            self.reply.unlink()  # A later restage keeps the recorded completion.
            harness.restage(args, p)
            self.assertEqual(harness.load(p)['restage']['seeded_stage_path'], str(self.origin))
            (self.target / 'source/Sources/ChecklistCore/SchemaMigrations.swift').write_text('changed')
            before = (p['folder'] / 'slot.json').read_bytes()
            with self.assertRaisesRegex(ValueError, 'Fresh real-size'): harness.restage(args, p)
            self.assertEqual((p['folder'] / 'slot.json').read_bytes(), before)
            self.assertEqual(store.stat().st_ino, inode)

    def test_running_foreign_or_incomplete_slot_refuses_before_bundle_changes(self):
        p = {'folder': self.root / 'owned-slot'}
        metadata = self.metadata()
        for reason in ['running', 'foreign', 'released', 'restaging']:
            with ExitStack() as stack:
                stack.enter_context(patch.object(harness, 'caller_session', return_value='actual'))
                stopped = stack.enter_context(patch.object(harness, 'stopped'))
                if reason == 'running': stopped.side_effect = ValueError('Slot must be stopped')
                stack.enter_context(patch.object(harness, 'load', return_value=dict(metadata, mode='restaging' if reason == 'restaging' else 'stopped')))
                stack.enter_context(patch.object(harness, 'read_marker', return_value={
                    'session_id': 'foreign' if reason == 'foreign' else 'actual', 'released': reason == 'released'}))
                bundle = stack.enter_context(patch.object(harness, 'bundle_check'))
                run = stack.enter_context(patch.object(harness, 'run'))
                save = stack.enter_context(patch.object(harness, 'save'))
                with self.assertRaises(ValueError): harness.restage(SimpleNamespace(slot=1), p)
                bundle.assert_not_called(); run.assert_not_called(); save.assert_not_called()

    def test_cli_restage_dispatches_with_exact_stage_commit_and_owner(self):
        with patch.dict(os.environ, {k: '' for k in ['CODEX_THREAD_ID', 'CLAUDE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID', 'CHECKLIST_SESSION_ID']}), \
             patch.object(sys, 'argv', ['test_instances.py', 'restage', '--slot', '1', '--stage', '/fake',
                                        '--session-id', 'actual', '--seeded-commit', self.commit, '--backup-reply', '/reply.json']), \
             patch.object(harness, 'checked'), patch.object(harness, 'locked', return_value=ExitStack()), \
             patch.object(harness, 'restage') as restage:
            harness.main()
            args = restage.call_args.args[0]
            self.assertEqual(args.stage, Path('/fake')); self.assertEqual(args.seeded_commit, self.commit)
            self.assertEqual(args.session_id, 'actual'); self.assertEqual(args.backup_reply, Path('/reply.json'))

    def test_cli_requires_stage_and_owner_identity_before_slot_access(self):
        with patch.dict(os.environ, {k: '' for k in ['CODEX_THREAD_ID', 'CLAUDE_SESSION_ID', 'CLAUDE_CODE_SESSION_ID', 'CHECKLIST_SESSION_ID']}), \
             patch.object(sys, 'argv', ['test_instances.py', 'restage', '--slot', '1', '--stage', '/fake']), \
             patch.object(harness, 'checked') as checked:
            with self.assertRaises(ValueError): harness.main()
            checked.assert_not_called()


if __name__ == '__main__': unittest.main()
