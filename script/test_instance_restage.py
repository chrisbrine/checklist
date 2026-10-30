"""Conservative CL-366 reuse policy. No store writes or native process operations."""
from datetime import datetime, timedelta, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

# One policy list, shared by restage and promotion. Add new storage/startup
# implementation paths here when introducing them; broad families cover splits.
FRESH_COPY_PATHS = (
    'Sources/ChecklistCore/TriageMembershipUpgrade.swift',
    'Sources/ChecklistCore/Storage*', 'Sources/ChecklistCore/SchemaMigrations.swift',
    'Sources/ChecklistCore/Store.swift', 'Sources/ChecklistCore/StoredRecord.swift',
    'Sources/ChecklistCore/LegacyStoredValue.swift', 'Sources/ChecklistCore/ManagedPath*',
    'Sources/ChecklistCore/GroupKeys.swift', 'Sources/ChecklistCore/GRDBRecordEnvelopeAdapter.swift',
    'Sources/ChecklistCore/RecordEnvelope.swift', 'Sources/ChecklistIPC/LocalPlatformServices.swift',
    'Sources/ChecklistIPC/InstallationCredentialStore.swift', 'Sources/ChecklistIPC/LegacyKeychainCredentialMigration.swift',
    'Sources/ChecklistCore/FileDurability.swift', 'Sources/ChecklistCore/Backup*',
    'Sources/ChecklistCore/CommandOperations.swift', 'Sources/ChecklistCore/ArchiveStorage*',
    'Sources/ChecklistService/*', 'Sources/ChecklistIPC/ChecklistInstance.swift',
    'Sources/ChecklistIPC/StorageUpgradeStatus.swift', 'Sources/ChecklistApp/*App.swift',
    'Sources/ChecklistCLI/*', 'Packages/*', 'Package.swift', 'Package.resolved',
    'Resources/*.plist', 'script/build_and_run.sh', 'script/verify_install.py',
    'script/verify_stage.py', 'script/build_input_inventory.py', 'script/build_support.py',
)
FRESH_COPY = 'Fresh real-size live-backup copy required; create a new seeded slot and qualify startup/protected backup.'
MAX_SEED_AGE_HOURS = 72
REASON = ('complete backup of this store (saved backup_create reply); store schema {schema} equals the current schema; '
          'captured within {hours} hours; verified seeded commit; no listed storage validation, migration, backup or '
          'startup path changed since the seeded commit')


def sensitive_paths(changed):
    return sorted(path for path in changed if any(fnmatch.fnmatchcase(path, rule) for rule in FRESH_COPY_PATHS))


def git(repo, *args):
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(repo), *args], capture_output=True)
    if result.returncode:
        raise ValueError('Seeded build commit is unknown or unavailable. ' + FRESH_COPY)
    return result.stdout


def verify_seed_commit(repo, manifest, commit):
    """Bind a full commit to *all* captured inputs, including membership and modes.

    A supplied SHA is evidence to verify, never an override. Legacy captures have
    no commit field; callers can name their known commit with --seeded-commit.
    """
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Seeded build commit is unknown; supply its full --seeded-commit. ' + FRESH_COPY)
    resolved = git(repo, 'rev-parse', '--verify', commit + '^{commit}').decode().strip()
    if resolved != commit: raise ValueError('Seeded commit mismatch. ' + FRESH_COPY)
    roots = manifest['input_roots']
    entries = []
    objects = []
    for raw in git(repo, 'ls-tree', '-r', '-z', commit, '--', *roots).split(b'\0'):
        if not raw: continue
        header, raw_path = raw.split(b'\t', 1)
        mode, kind, oid = header.split()
        path = os.fsdecode(raw_path)
        parts = Path(path).parts
        if parts[-1] == '.DS_Store' or '__pycache__' in parts: continue
        if parts[0] == 'Packages' and any(p in {'.build', '.swiftpm', '.local', '__pycache__'} for p in parts[1:]): continue
        if kind != b'blob' or mode not in [b'100644', b'100755']:
            raise ValueError('Unsupported seeded commit entry. ' + FRESH_COPY)
        entries.append({'path': path, 'executable': mode == b'100755'})
        objects.append(oid)
    result = subprocess.run(['git', '-C', str(repo), 'cat-file', '--batch'],
                            input=b'\n'.join(objects) + b'\n', capture_output=True, check=True)
    offset = 0
    for entry in entries:
        end = result.stdout.index(b'\n', offset)
        size = int(result.stdout[offset:end].split()[2]); offset = end + 1
        data = result.stdout[offset:offset + size]; offset += size + 1
        entry.update(size=size, sha256=hashlib.sha256(data).hexdigest())
    if sorted(entries, key=lambda e: e['path']) != manifest['inputs']:
        raise ValueError('Seeded commit differs from captured build inputs. ' + FRESH_COPY)
    return commit


def stage_diff(before, after):
    """Git's exact file diff, including both sides of renames and staged dirty inputs."""
    before, after = Path(before).resolve(), Path(after).resolve()
    paths = set()
    # Git names a no-index deletion /dev/null. The reverse diff supplies its
    # real source path; union both directions so deletes/renames cannot hide it.
    for left, right in [(before, after), (after, before)]:
        result = subprocess.run(['git', 'diff', '--no-index', '--no-ext-diff', '--no-textconv',
                                 '--no-renames', '--name-only', '-z', '--', str(left), str(right)], capture_output=True)
        if result.returncode not in [0, 1]: raise ValueError('Cannot compare captured stage sources. ' + FRESH_COPY)
        for raw in result.stdout.split(b'\0'):
            if not raw or raw == b'/dev/null': continue
            path = Path(os.fsdecode(raw))
            root = next((root for root in [before, after] if path.is_relative_to(root)), None)
            if root is None: raise ValueError('Unexpected git diff path. ' + FRESH_COPY)
            paths.add(path.relative_to(root).as_posix())
    return sorted(paths)


def backup_completion(reply_path):
    """Read the saved backup_create or operation_get reply for one generation.

    No file marks a finished backup. The service renames a verified stage to its
    final name first, then commits the receipt to SQL only (commands result,
    backup-generation metadata, backup_created event). A crash between the two
    leaves a final-name folder with every file (snapshot-5aca4aec, CL-377), so
    folder contents cannot prove completion. The service's reply can.
    """
    try:
        raw = Path(reply_path).read_bytes()
        if len(raw) > 1_048_576: raise ValueError('reply is too large')
        value = json.loads(raw)
        operation = value['data'] if isinstance(value.get('data'), dict) and 'result' in value['data'] else value
        if 'result' in operation or 'state' in operation:
            if operation.get('method') != 'backup_create' or operation.get('state') != 'succeeded':
                raise ValueError('operation state is ' + str(operation.get('state')) + ', not succeeded')
            data = operation['result']['data']
        else:
            data = operation['data']
        if data['status'] != 'complete' or data['format'] != 'checklist-store-snapshot':
            raise ValueError('reply is not a complete backup')
        return {'source': 'backup_create reply', 'reply_sha256': hashlib.sha256(raw).hexdigest(), 'path': data['path'],
                'manifest_sha256': data['manifest_sha256'], 'operation_id': data['operation_id']}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise ValueError('No usable backup_create reply for the seed (' + str(error) + '). ' + FRESH_COPY) from error


def verify_seed(live, seed, completion, current_schema, when=None):
    """A seed qualifies when it is a complete backup of this store, at the current schema, within the age limit.

    snapshot_seed hashed every file at create. This check binds the seed to that
    manifest and needs no database, so a backup published later does not end reuse.
    """
    if seed.get('kind') != 'backup' or seed.get('live_snapshot') is not True:
        raise ValueError('Reuse requires a live-backup seed. ' + FRESH_COPY)
    try:
        backups = Path(live) / 'backups'
        folder = Path(seed['source']).absolute()
        parts = folder.relative_to(backups).parts
        if not (len(parts) == 1 and parts[0].startswith('snapshot-')
                or len(parts) == 2 and parts[0].startswith('qualification-') and parts[1].startswith('snapshot-')):
            raise ValueError('seed folder is not a published backup')
        chain = [folder / 'manifest.json', folder / 'intent.json', folder]
        chain += [parent for parent in folder.parents if parent == backups or backups in parent.parents]
        if any(path.is_symlink() for path in chain): raise ValueError('linked backup publication')
        raw = (folder / 'manifest.json').read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != seed['source_hash']: raise ValueError('seed manifest changed since slot create')
        manifest = json.loads(raw)
        intent = json.loads((folder / 'intent.json').read_bytes())
        if (manifest['kind'] != 'checklist-store-snapshot' or manifest['format'] not in [1, 2]
                or intent != {'format': str(manifest['format']), 'kind': manifest['kind'], 'operation_id': manifest['operationID'],
                              'store_id': manifest['storeID'], 'source_root': manifest['sourceRoot']}):
            raise ValueError('invalid backup publication')
        if Path(completion['path']).absolute() != folder or completion['manifest_sha256'] != digest or completion['operation_id'] != manifest['operationID']:
            raise ValueError('the backup_create reply names another backup')
        identity = json.loads((Path(live) / 'checklist-store.identity.json').read_bytes())
        if (Path(manifest['sourceRoot']).absolute() != Path(live) or manifest['storeID'] != identity['logical_store_id']
                or seed['before_start']['identity']['incarnation'] != identity['incarnation']):
            raise ValueError('seed is a backup of another store or incarnation')
        schema = current_schema()
        if not manifest['schema'] == identity['schema_revision'] == schema:
            raise ValueError(f'seed schema {manifest["schema"]}, live schema {identity["schema_revision"]} and stage schema {schema} differ')
        captured = datetime.fromisoformat(manifest['capturedAt'].replace('Z', '+00:00'))
        age = (when or datetime.now(timezone.utc)) - captured
        if age > timedelta(hours=MAX_SEED_AGE_HOURS) or age < timedelta(minutes=-5):
            raise ValueError(f'seed captured at {manifest["capturedAt"]} is outside the {MAX_SEED_AGE_HOURS}-hour limit')
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise ValueError('Seed does not qualify: ' + str(error) + '. ' + FRESH_COPY) from error
    return {'backup_manifest_sha256': digest, 'seed_captured_at': manifest['capturedAt'], 'seed_store_schema': schema,
            'seed_max_age_hours': MAX_SEED_AGE_HOURS, 'seed_completion': completion}


def reuse_proof(repo, live, seed, origin_capture, origin_manifest, target_capture, target_manifest, commit, completion, current_schema, when=None):
    """current_schema is a callable: a listed path change must refuse by name before the schema source is parsed."""
    if seed.get('kind') != 'backup' or seed.get('live_snapshot') is not True:
        raise ValueError('Reuse requires a live-backup seed. ' + FRESH_COPY)
    commit = verify_seed_commit(repo, origin_manifest, commit)
    changed = stage_diff(origin_capture / 'source', target_capture / 'source')
    sensitive = sensitive_paths(changed)
    if sensitive:
        raise ValueError('Storage validation, migration, backup or startup paths changed: ' + ', '.join(sensitive) + '. ' + FRESH_COPY)
    seed_proof = verify_seed(live, seed, completion, current_schema, when)
    return {'seeded_stage_path': str(origin_capture), 'seeded_build_id': origin_manifest['build_id'],
            'seeded_source_fingerprint': origin_manifest['source_fingerprint'], 'seeded_commit': commit,
            'target_build_id': target_manifest['build_id'], 'target_source_fingerprint': target_manifest['source_fingerprint'],
            'changed_paths': changed, **seed_proof,
            'reason': REASON.format(schema=seed_proof['seed_store_schema'], hours=MAX_SEED_AGE_HOURS)}
