"""Conservative CL-366 reuse policy. No store writes or native process operations."""
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


def newest_complete_backup(live):
    """Published manifest+intent pairs only, including named qualification backups.

    Full bytes were verified by snapshot_seed. Reuse checks publication identity
    and the seed manifest hash, without rehashing every backup's managed payload.
    """
    candidates = []
    for pattern in ['snapshot-*/manifest.json', 'qualification-*/snapshot-*/manifest.json']:
        for file in (live / 'backups').glob(pattern):
            if file.is_symlink() or any(p.is_symlink() for p in file.parents):
                raise ValueError('Linked backup publication. ' + FRESH_COPY)
            intent_file = file.parent / 'intent.json'
            if intent_file.is_symlink(): raise ValueError('Linked backup intent. ' + FRESH_COPY)
            if not intent_file.is_file(): continue  # Never published.
            manifest = json.loads(file.read_bytes())
            intent = json.loads(intent_file.read_bytes())
            expected = {'format': str(manifest['format']), 'kind': manifest['kind'],
                        'operation_id': manifest['operationID'], 'store_id': manifest['storeID'],
                        'source_root': manifest['sourceRoot']}
            if (manifest['kind'] != 'checklist-store-snapshot' or manifest['format'] not in [1, 2]
                    or intent != expected or Path(manifest['sourceRoot']).absolute() != live):
                raise ValueError('Invalid live backup publication. ' + FRESH_COPY)
            candidates.append(file)
    if not candidates: raise ValueError('No complete live backup. ' + FRESH_COPY)
    return max(candidates, key=lambda f: (f.stat().st_mtime_ns, str(f)))


def reuse_proof(repo, live, seed, origin_capture, origin_manifest, target_capture, target_manifest, commit):
    if seed.get('kind') != 'backup' or seed.get('live_snapshot') is not True:
        raise ValueError('Reuse requires a live-backup seed. ' + FRESH_COPY)
    try:
        latest = newest_complete_backup(live)
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise ValueError('Cannot verify the newest complete live backup: ' + str(error) + '. ' + FRESH_COPY) from error
    if (Path(seed['source']).resolve() != latest.parent.resolve()
            or seed['source_hash'] != hashlib.sha256(latest.read_bytes()).hexdigest()):
        raise ValueError('Seed is no longer the newest complete live backup. ' + FRESH_COPY)
    commit = verify_seed_commit(repo, origin_manifest, commit)
    changed = stage_diff(origin_capture / 'source', target_capture / 'source')
    sensitive = sensitive_paths(changed)
    if sensitive:
        raise ValueError('Storage validation, migration, backup or startup paths changed: ' + ', '.join(sensitive) + '. ' + FRESH_COPY)
    return {'seeded_stage_path': str(origin_capture), 'seeded_build_id': origin_manifest['build_id'],
            'seeded_source_fingerprint': origin_manifest['source_fingerprint'], 'seeded_commit': commit,
            'target_build_id': target_manifest['build_id'], 'target_source_fingerprint': target_manifest['source_fingerprint'],
            'backup_manifest_sha256': seed['source_hash'], 'changed_paths': changed,
            'reason': 'newest complete live-backup seed; verified seeded commit; no storage validation, migration, backup or startup path changed'}
