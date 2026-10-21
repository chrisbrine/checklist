#!/usr/bin/env python3
"""Manage four disposable Checklist test slots. Never build or alter the live store."""
import argparse
from contextlib import contextmanager, ExitStack
import ctypes
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import signal
import sqlite3
import stat
import struct
import subprocess
import sys
import time
import unicodedata
from urllib.parse import unquote, urlsplit
import uuid

from verify_stage import sha, signing_teams, verify as verify_stage
from verify_install import failure_guidance

REPO = Path(__file__).resolve().parent.parent
BASE = Path.home() / 'Library/Application Support/Checklist Test Instances'
DEFAULT_LIVE = Path.home() / 'Library/Application Support/Checklist'


def live_root(environment=None):
    environment = os.environ if environment is None else environment
    value = environment.get('CHECKLIST_DATA_ROOT')
    path = Path(value).absolute() if value else DEFAULT_LIVE
    # Match StoreDirectory.anchoredRoot without following the root's own entry.
    return path.parent.resolve() / path.name


LIVE = live_root()
BUILD = REPO / '.local/build'
RELOCATION_REQUIRED = 'Seed path safety requires the instance-local managed-path contract; unsafe references and file URLs are refused.'
KEYCHAIN_DELETE_LIMIT = 1024

# A field name alone does not establish file authority. The inspector below
# distinguishes canonical managed descriptors, project references, captured names
# and inert replay history. Unknown file references retain strict slot containment.
PATH_FIELDS = frozenset({'path', 'preview_path', 'icon_path', 'root_path', 'source_root',
                        'snapshot_path', 'output_path', 'working_directory', 'workspace',
                        'workspace_path', 'canonical_key', 'mcp_executable', 'git_path',
                        'object_relative_path', 'relative_path', 'resolved_path', 'database_path'})
PATH_LIST_FIELDS = frozenset({'paths', 'additional_paths'})


def slot_number(value):
    if str(value) not in ['1', '2', '3', '4']:
        raise ValueError('Slot must be 1, 2, 3 or 4.')
    return int(value)


def seed_value(value):
    if value in ['empty', 'latest-backup'] or (value.startswith('backup:') and value[7:]): return value
    if value.startswith('slot:'):
        slot_number(value[5:]); return value
    raise ValueError('Seed must be empty, latest-backup, backup:PATH or slot:M.')


def paths(number):
    number = slot_number(number)
    folder = BASE / f'slot-{number}'
    return {'folder': folder, 'data': folder / 'data', 'bundle': folder / f'Checklist Test {number}.app',
            'label': f'org.checklist.test{number}.coordination', 'keychain': f'org.checklist.test{number}.enrollments',
            'identifier': f'org.checklist.app.test{number}'}


def _canonical_path(path):
    """Observe the deepest existing ancestor and preserve a missing, link-resolved tail."""
    existing = Path(path).resolve()
    missing = []
    while True:
        try:
            before = existing.stat()
            break
        except (FileNotFoundError, NotADirectoryError):
            if existing == existing.parent: raise
            missing.append(existing.name)
            existing = existing.parent
    descriptor = os.open(existing, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino)
        if identity != (before.st_dev, before.st_ino):
            raise ValueError('Instance path changed while checking overlap.')
        if sys.platform == 'darwin':
            # F_GETPATH returns the vnode's on-disk spelling, including firmlink aliases.
            spelling = fcntl.fcntl(descriptor, 50, bytes(1024)).split(b'\0', 1)[0]
            existing = Path(os.fsdecode(spelling))
        else:
            existing = Path(os.path.realpath(existing))
    finally:
        os.close(descriptor)
    return existing, tuple(reversed(missing)), identity


def paths_overlap(a, b) -> bool:
    """Physical equal/ancestor overlap, with NFD/case-folded component fallback on every volume."""
    a_root, a_tail, a_identity = _canonical_path(a)
    b_root, b_tail, b_identity = _canonical_path(b)
    if not a_tail and not b_tail:
        if a_identity == b_identity: return True
        def ancestors(root):
            for parent in root.parents:
                info = parent.stat()
                yield info.st_dev, info.st_ino
        if a_identity in ancestors(b_root) or b_identity in ancestors(a_root): return True
    def components(root, tail):
        return tuple(unicodedata.normalize('NFD', unicodedata.normalize('NFD', part).casefold())
                     for part in (*root.parts, *tail))
    left, right = components(a_root, a_tail), components(b_root, b_tail)
    return left[:len(right)] == right or right[:len(left)] == left


def checklist_root_overlap(path, exclude=()) -> str | None:
    """First overlapping label: live, slot-1..4 (data then folder), then test-base."""
    roots = [('live', LIVE)]
    for number in range(1, 5):
        p = paths(number)
        roots.extend([(f'slot-{number}', p['data']), (f'slot-{number}', p['folder'])])
    roots.append(('test-base', BASE))
    for label, root in roots:
        if label not in exclude and paths_overlap(path, root): return label
    return None


def contained(path, root):
    """Reject lexical escapes and symlink traversal, including ancestor aliases."""
    path, root = Path(path).absolute(), Path(root).absolute()
    if '..' in path.parts or '..' in root.parts:
        raise ValueError('Refusing parent traversal in slot path.')
    if path != root and root not in path.parents:
        raise ValueError(f'Refusing path outside slot: {path}')
    for parent in reversed([path, *path.parents]):
        if parent.is_symlink():
            raise ValueError(f'Refusing symlink in slot path: {parent}')
    if root.exists() and root.stat().st_uid != os.getuid():
        raise ValueError('Slot must belong to the current user.')
    return path


def checked(number):
    p = paths(number)
    for key in ['folder', 'data']:
        collision = checklist_root_overlap(p[key], exclude=(f'slot-{number}', 'test-base'))
        if collision == 'live':
            raise ValueError(f'Slot {number} overlaps the effective live root: {LIVE}')
        if collision:
            raise ValueError(f'Slot {number} overlaps Checklist root {collision}.')
    contained(p['folder'], BASE)
    for key in ['data', 'bundle']:
        contained(p[key], p['folder'])
    return p


@contextmanager
def locked(number):
    p = checked(number)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = BASE / f'.slot-{slot_number(number)}.lock'
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise ValueError(f'Slot {number} is locked by another command: {lock}; preserve and reconcile it.')
    try:
        yield p
    finally:
        lock.rmdir()


def run(command, timeout=60, check=True, cwd=None):
    result = subprocess.run([str(x) for x in command], text=True, capture_output=True, timeout=timeout, cwd=cwd)
    if check and result.returncode:
        raise ValueError(f'Command failed ({result.returncode}): {command}\n{result.stdout}{result.stderr}')
    return result


def now():
    return datetime.now(timezone.utc).isoformat()


def load(p):
    file = contained(p['folder'] / 'slot.json', p['folder'])
    value = json.loads(file.read_text())
    if value['slot'] != slot_number(p['folder'].name.removeprefix('slot-')):
        raise ValueError('Slot metadata identity mismatch.')
    return value


def save(p, value):
    file = contained(p['folder'] / 'slot.json', p['folder'])
    temp = contained(p['folder'] / 'slot.json.tmp', p['folder'])
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.chmod(0o600)
    temp.replace(file)


def rewrite_info(info, number):
    p = paths(number)
    return dict(info, CFBundleIdentifier=p['identifier'], CFBundleName=f'Checklist Test {number}',
                CFBundleDisplayName=f'Checklist Test {number}', ChecklistInstanceSlot=slot_number(number))


def sign_identity(manifest):
    if 'CHECKLIST_SIGN_IDENTITY' in os.environ:
        identity = os.environ['CHECKLIST_SIGN_IDENTITY'] or '-'
    elif (BUILD / 'signing-identity').exists():
        path = BUILD / 'signing-identity'
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ValueError('Private signing selection must be an owned regular file.')
        identity = path.read_text().strip()
        if not identity or '\n' in identity or '\r' in identity:
            raise ValueError('Private signing selection must contain one identity on one line.')
        path.chmod(0o600)
    else:
        identity = '-'
    if hashlib.sha256(identity.encode()).hexdigest() != manifest['signing_identity_sha256']:
        raise ValueError('Current signing selection differs from the stage; select the same identity.')
    return identity


def require_instance_support(manifest):
    if not any(entry['path'] == 'Sources/ChecklistIPC/ChecklistInstance.swift' for entry in manifest['inputs']):
        raise ValueError('Stage predates bundle-derived test identity; rebuild before creating a slot.')


def require_managed_path_support(capture, manifest):
    """Relaxed seeds may run only with the verified schema-3 implementation."""
    required = {'Sources/ChecklistCore/ManagedPaths.swift', 'Sources/ChecklistCore/SchemaMigrations.swift'}
    inputs = {entry['path']: entry for entry in manifest.get('inputs', [])}
    if not required <= inputs.keys():
        raise ValueError('Stage predates the instance-local managed-path contract; rebuild before seeding a slot.')
    migration = Path(capture) / 'source/Sources/ChecklistCore/SchemaMigrations.swift'
    if sha(migration) != inputs['Sources/ChecklistCore/SchemaMigrations.swift']['sha256'] or 'managedPathsLedger' not in migration.read_text():
        raise ValueError('Stage has no verified schema-3 managed-path migration; rebuild before seeding a slot.')


def stage_selection(arguments):
    if arguments.stage:
        capture, manifest = verify_stage(arguments.stage)
        require_instance_support(manifest)
        return capture, manifest
    candidates = []
    if BUILD.exists():
        for folder in BUILD.iterdir():
            if (folder / 'Checklist.app').is_dir() and (folder / 'build-verification.json').is_file():
                candidates.append(folder)
    for folder in sorted(candidates, key=lambda x: (x / 'build-verification.json').stat().st_mtime, reverse=True):
        try:
            capture, manifest = verify_stage(folder)
            require_instance_support(manifest)
            print('Selected complete stage ' + manifest['build_id'])
            return capture, manifest
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
            print(f'Skipping incomplete/invalid stage {folder.name}: {error}', file=sys.stderr)
    raise ValueError('No complete verified stage. Run script/build_and_run.sh --stage first.')


def relative_path(value):
    path = PurePosixPath(value)
    if not value or len(path.parts) < 2 or path.is_absolute() or '\0' in value or any(x in ['', '.', '..'] for x in value.split('/')):
        raise ValueError('Unsafe snapshot relative path: ' + value)
    if path.parts[0] not in ['objects', 'source-captures', 'staging', 'icons', 'source-executions']:
        raise ValueError('Unsupported snapshot managed family: ' + value)
    return path


def database_observation(database, immutable=True):
    # Immutable is safe only for a completed snapshot. A running slot needs its WAL.
    connection = sqlite3.connect(database.as_uri() + ('?mode=ro&immutable=1' if immutable else '?mode=ro'), uri=True)
    connection.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
    try:
        version = connection.execute('PRAGMA user_version').fetchone()[0]
        quick = connection.execute('PRAGMA quick_check').fetchone()[0]
        counts = dict(connection.execute('SELECT type,count(*) FROM records GROUP BY type'))
        identity = connection.execute("SELECT value FROM metadata WHERE key='store_identity'").fetchone()
        return {'schema': version, 'quick_check': quick, 'record_counts': counts,
                'identity': json.loads(identity[0]) if identity else None}
    finally:
        connection.close()


def latest_backup():
    candidates = list((LIVE / 'backups').glob('snapshot-*/manifest.json'))
    if not candidates: raise ValueError('No completed live backup snapshot exists.')
    return max(candidates, key=lambda file: file.stat().st_mtime).parent


def is_live_snapshot(source, source_root):
    return LIVE / 'backups' in source.parents and Path(source_root).absolute() == LIVE


class ManagedPathMapping:
    """Derive managed suffixes; binding overlap belongs to CL-169's helpers."""
    def __init__(self):
        self.directories = {}

    def components(self, directory):
        directory = Path(directory).absolute()
        if directory not in self.directories:
            root, tail, _ = _canonical_path(directory)
            self.directories[directory] = (*root.parts, *tail)
        return self.directories[directory]

    @staticmethod
    def folded(parts):
        # Keep CL-169's unconditional NFD/case-folded component convention.
        return tuple(unicodedata.normalize('NFD', unicodedata.normalize('NFD', part).casefold()) for part in parts)

    def relative(self, path, root):
        path = Path(path).absolute()
        # Only the parent is canonicalized. The managed file leaf is never
        # resolved, opened or stat-ed, including for an unavailable descriptor.
        parts = (*self.components(path.parent), path.name)
        root_parts = self.components(root)
        if self.folded(parts[:len(root_parts)]) == self.folded(root_parts):
            return PurePosixPath(*parts[len(root_parts):])
        return None

    def rooted_suffix(self, path, root):
        # Preserve the copy's no-symlink check before resolving a redirected
        # child of a known root. A prefix may itself be a CL-169 root alias.
        path = Path(path).absolute()
        root_parts = self.folded(self.components(root))
        for prefix in path.parents:
            if self.folded(self.components(prefix)) == root_parts:
                return path.relative_to(prefix)
        return None


def require_local_paths(database, destination, immutable=True, source_root=None):
    """Read-only seed inspection. Never open a stored managed absolute path.

    source_root is the verified snapshot manifest's origin or the stopped source
    slot's root. Legacy managed descriptors from that root are admitted for Core's
    protected relocation, not redirected by this harness. Other Checklist roots
    remain forbidden. Counts are occurrences, including repeated project refs.
    """
    database = Path(database).absolute()
    destination = Path(os.path.normpath(destination)).absolute()
    source_root = Path(os.path.normpath(source_root)).absolute() if source_root is not None else None
    counts = dict.fromkeys(['managed_relative', 'managed_local_absolute', 'managed_origin_absolute',
                           'managed_unavailable_absolute', 'external_project_path_occurrences',
                           'relative_capture_paths', 'inert_history_path_occurrences', 'inert_metadata_path_occurrences',
                           'capture_git_provenance'], 0)
    mapping = ManagedPathMapping()

    def refuse(location, cause):
        raise ValueError(f'Seed contains {cause} ({location}). ' + RELOCATION_REQUIRED)

    def relative_to(path, root, location):
        try: return mapping.relative(path, root)
        except (OSError, RuntimeError, ValueError):
            refuse(location, 'a path whose filesystem ancestry cannot be safely compared')

    def unsafe_checklist_root(path, location, managed=False):
        # CL-169 owns overlap semantics. For managed descriptors inspect only
        # directory metadata; an outside file leaf is never filesystem authority.
        candidate = path.parent if managed else path
        try:
            return checklist_root_overlap(candidate) or paths_overlap(candidate, DEFAULT_LIVE)
        except (OSError, RuntimeError, ValueError):
            refuse(location, 'a path whose filesystem ancestry cannot be safely compared')

    def check_absolute(value, location):
        if not value.startswith('/') or '\0' in value or any(x in ['', '.', '..'] for x in value.split('/')[1:]):
            refuse(location, 'a relative, malformed or traversing stored file path')
        return Path(value)

    def check_local(relative, location):
        # During create the physical copy is .seed-data. Only inspect its local
        # entries; never stat the origin descriptor or an outside link target.
        try: contained(database.parent / relative, database.parent)
        except ValueError: refuse(location, 'a stored file path through a symlink')

    def check_slot_absolute(value, location):
        path = check_absolute(value, location)
        if not path.is_relative_to(destination): refuse(location, 'a stored absolute path outside the destination slot root')
        check_local(path.relative_to(destination), location)

    def check_managed(value, family, location):
        if not value.startswith('/'):
            try: relative = relative_path(value)
            except ValueError: refuse(location, 'a malformed root-relative managed path')
            if family is not None and relative.parts[0] != family:
                refuse(location, 'a managed path in the wrong family')
            check_local(relative, location)
            counts['managed_relative'] += 1
            return
        path = check_absolute(value, location)
        for root, category in [(destination, 'managed_local_absolute'), (source_root, 'managed_origin_absolute')]:
            if root is None: continue
            try: local_mapping = mapping.rooted_suffix(path, root)
            except (OSError, RuntimeError, ValueError):
                refuse(location, 'a path whose filesystem ancestry cannot be safely compared')
            if local_mapping is not None:
                try: local_relative = relative_path(str(local_mapping))
                except ValueError: refuse(location, 'a malformed managed absolute path')
                if family is not None and local_relative.parts[0] != family:
                    refuse(location, 'a managed path in the wrong family')
                check_local(local_relative, location)
            relative = relative_to(path, root, location)
            if relative is None: continue
            try: checked_relative = relative_path(str(relative))
            except ValueError: refuse(location, 'a malformed managed absolute path')
            if family is not None and checked_relative.parts[0] != family:
                refuse(location, 'a managed path in the wrong family')
            # Inspect only the corresponding entry in this copy. An origin's
            # absolute path is data; local content proof belongs to Core.
            check_local(relative, location)
            counts[category] += 1
            return
        if unsafe_checklist_root(path, location, managed=True):
            refuse(location, 'a managed path into a different Checklist data root')
        # Core makes an unproved outside descriptor unavailable without reading
        # it. Keep malformed family layouts fail-closed before publishing a seed.
        if family is not None and family not in path.parts[1:-1]:
            refuse(location, 'a managed path in the wrong family')
        counts['managed_unavailable_absolute'] += 1

    def check_binding(value, location, optional=False):
        if optional and not value: return
        path = check_absolute(value, location)
        if unsafe_checklist_root(path, location):
            refuse(location, 'a project reference into a Checklist data root or a recursive root containing one')
        counts['external_project_path_occurrences'] += 1

    def capture_context(location, record_kind):
        return record_kind == 'source_capture' or '.source_capture.' in location or location.endswith('.source_capture')

    def policy(key, parent, location, record_kind):
        capture = capture_context(location, record_kind)
        if record_kind == 'capture_bindings':
            if key == 'stored': return ('lookup', 'source-captures')
            if key == 'relative': return ('managed', 'source-captures')
        if key == 'path':
            if parent.get('mode') == 'managed': return ('managed', 'objects')
            if parent.get('mode') in {'reference', 'external_reference'}: return ('binding', None)
            if '.file_scopes[]' in location: return ('recursive_binding', None)
            if (capture and location.endswith('.files[]')) or any(name in location for name in ['.project_instruction_refs[]', '.instruction_coverage[]', '.link_chain[]']):
                return ('captured', None)
            if record_kind == 'request' and '.files[]' in location: return ('binding', None)
            if parent.get('kind') == 'workspace_file': return ('binding', None)
        if key == 'preview_path' and parent.get('mode') == 'managed': return ('managed', 'objects')
        if key == 'icon_path' and record_kind == 'project': return ('managed', 'icons')
        if key == 'snapshot_path' and (capture or record_kind == 'manifest'): return ('managed', 'source-captures')
        if record_kind == 'source_execution':
            if key == 'output_path': return ('managed', 'source-executions')
            if key == 'working_directory': return ('managed', 'source-captures')
        if key in {'stage', 'final'} and ('representation' in parent or location.endswith('.objects[]')):
            return ('managed', 'staging' if key == 'stage' else None)
        if key in {'object_relative_path', 'relative_path'}: return ('managed', None)
        if key == 'additional_paths' and capture: return ('project_relative', parent.get('source_root'))
        if key in {'root_path', 'source_root', 'workspace', 'workspace_path', 'canonical_key', 'additional_paths'}:
            return ('recursive_binding_optional' if key in {'workspace', 'workspace_path'} else 'recursive_binding', None)
        if key == 'paths': return ('binding', None)
        if key == 'target' and (parent.get('kind') == 'symlink' or {'path', 'sha256'} <= parent.keys()):
            return ('captured_link', parent.get('path', ''))
        if key == 'resolved_path' and any(name in location for name in ['.project_instruction_refs[]', '.instruction_coverage[]']):
            return ('captured', None)
        # Captures retain which trusted Git performed the inventory. The reader
        # never executes this field; later work resolves trusted Git afresh.
        if key == 'git_path' and capture: return ('provenance', None)
        if key in PATH_FIELDS or key in PATH_LIST_FIELDS: return ('strict', None)
        return (None, None)

    def inspect(value, location, record_kind=None, rule=(None, None), inert=False):
        if isinstance(value, bytes): value = value.decode('utf-8')
        if isinstance(value, dict):
            for key, child in value.items():
                key_rule = ('binding', None) if location.endswith('.path_sha256') else (None, None)
                inspect(key, location, record_kind, key_rule, inert)
                inspect(child, location + '.' + key, record_kind, policy(key, value, location, record_kind), inert)
        elif isinstance(value, list):
            for child in value: inspect(child, location + '[]', record_kind, rule, inert)
        elif isinstance(value, str):
            kind, family = rule
            has_file_url = re.search(r'\bfile:', value, re.IGNORECASE) is not None
            if has_file_url and kind is not None: refuse(location, 'a stored file URL')
            if kind is None:
                # Inspect serialized payloads at their leaves, not as quoted prose.
                try: decoded = json.loads(value)
                except (ValueError, TypeError): pass
                else:
                    if decoded != value:
                        inspect(decoded, location, record_kind, inert=inert)
                        return
                if re.fullmatch(r'file:\S*', value.strip(), re.IGNORECASE):
                    try:
                        url = urlsplit(value.strip())
                        if url.netloc.lower() not in {'', 'localhost'} or url.query or url.fragment or re.search(r'%(?![0-9a-fA-F]{2})', url.path):
                            refuse(location, 'a malformed or nonlocal stored file URL')
                        decoded_path = unquote(url.path, errors='strict')
                    except (ValueError, UnicodeError):
                        refuse(location, 'a malformed or nonlocal stored file URL')
                    check_slot_absolute(decoded_path, location)
                    return
            if inert:
                if kind is not None or value.startswith('/') or has_file_url:
                    counts['inert_metadata_path_occurrences' if inert == 'metadata' else 'inert_history_path_occurrences'] += 1
            elif kind == 'managed': check_managed(value, family, location)
            elif kind == 'lookup':
                if value.startswith('/'):
                    path = check_absolute(value, location)
                    if family not in path.parts[1:-1]: refuse(location, 'a capture lookup in the wrong family')
                else:
                    try: relative = relative_path(value)
                    except ValueError: refuse(location, 'a malformed capture lookup spelling')
                    if relative.parts[0] != family: refuse(location, 'a capture lookup in the wrong family')
                counts['inert_metadata_path_occurrences'] += 1
            elif kind in {'binding', 'recursive_binding', 'recursive_binding_optional'}:
                check_binding(value, location, optional=kind == 'recursive_binding_optional')
            elif kind == 'project_relative':
                if not value or value.startswith('/') or '\0' in value or any(x in ['', '.', '..'] for x in value.split('/')):
                    refuse(location, 'an unsafe project-relative source path')
                if not isinstance(family, str): refuse(location, 'a project-relative source path without its source root')
                source = check_absolute(family, location)
                check_binding(str(source / value), location)
            elif kind in {'captured', 'captured_link'}:
                if not value or value.startswith('/') or '\0' in value or (kind == 'captured' and any(x in ['', '.', '..'] for x in value.split('/'))):
                    refuse(location, 'an unsafe captured relative path')
                if kind == 'captured_link':
                    parts = list(PurePosixPath(family).parts[:-1])
                    for component in value.split('/'):
                        if component == '..':
                            if not parts: refuse(location, 'an escaping captured relative link')
                            parts.pop()
                        elif component not in ['', '.']: parts.append(component)
                counts['relative_capture_paths'] += 1
            elif kind == 'provenance':
                check_absolute(value, location)
                counts['capture_git_provenance'] += 1
            elif kind == 'strict' or value.startswith('/'):
                check_slot_absolute(value, location)
            elif has_file_url:
                counts['inert_history_path_occurrences'] += 1
            try: decoded = json.loads(value)
            except (ValueError, TypeError): return
            if decoded != value: inspect(decoded, location, record_kind, inert=inert)

    connection = sqlite3.connect(database.as_uri() + ('?mode=ro&immutable=1' if immutable else '?mode=ro'), uri=True)
    connection.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
    try:
        connection.execute('PRAGMA trusted_schema=OFF')
        tables = [row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'") if not row[0].startswith('sqlite_')]
        for table in tables:
            cursor = connection.execute('SELECT * FROM "' + table.replace('"', '""') + '"')
            columns = [column[0] for column in cursor.description]
            for row in cursor:
                record_kind = row[columns.index('type')] if table == 'records' and 'type' in columns else None
                metadata_key = row[columns.index('key')] if table == 'metadata' and 'key' in columns else None
                if metadata_key == 'managed-capture-paths-v3': record_kind = 'capture_bindings'
                for column, value in zip(columns, row):
                    inert = (table == 'commands' and column == 'result') or (table == 'events' and column == 'data')
                    if column == 'value' and metadata_key is not None and (metadata_key == 'preupgrade_snapshot' or metadata_key.startswith('backup-generation:')):
                        inert = 'metadata'
                    inspect(value, table + '.' + column, record_kind, policy(column, {}, table, record_kind), inert)
    except (UnicodeError, RecursionError) as error:
        raise ValueError('Seed values cannot be safely inspected. ' + RELOCATION_REQUIRED) from error
    finally:
        connection.close()
    return counts


def snapshot_seed(source, destination, destination_root=None):
    source = source.expanduser().absolute()
    # Live access is confined to published backups, never its open database or connections.
    for live in {LIVE, DEFAULT_LIVE}:
        if source == live or (live in source.parents and live / 'backups' not in source.parents):
            raise ValueError('Only completed backups may be read from the live data root.')
    contained(source, source)
    manifest_file = source / 'manifest.json'
    contained(manifest_file, source)
    raw = manifest_file.read_bytes()
    manifest = json.loads(raw)
    if manifest['format'] != 1 or manifest['kind'] != 'checklist-store-snapshot' or manifest['schema'] not in [0, 1, 2, 3]:
        raise ValueError('Unsupported snapshot format/schema.')
    uuid.UUID(manifest['storeID']); uuid.UUID(manifest['operationID'])
    contained(source / 'intent.json', source)
    intent = json.loads((source / 'intent.json').read_text())
    if intent != {'format': '1', 'kind': manifest['kind'], 'operation_id': manifest['operationID'],
                  'store_id': manifest['storeID'], 'source_root': manifest['sourceRoot']}:
        raise ValueError('Snapshot publication intent does not match its manifest.')
    expected = {'database.sqlite', 'intent.json', 'manifest.json'}
    entries = [('database.sqlite', manifest['databaseSHA256'], manifest['databaseSize'], None)]
    for entry in manifest['objects']:
        descriptor = entry['descriptor']
        relative_path(descriptor['relativePath'])
        name = 'managed/' + descriptor['relativePath']
        if name in expected:
            raise ValueError('Duplicate snapshot path.')
        expected.add(name)
        entries.append((name, entry['sha256'], entry['size'], descriptor))
    actual = set()
    for folder, directories, files in os.walk(source, followlinks=False):
        for name in directories[:]:
            path = Path(folder) / name
            if path.is_symlink():
                actual.add(str(path.relative_to(source))); directories.remove(name)
        actual.update(str((Path(folder) / name).relative_to(source)) for name in files)
    if actual != expected:
        raise ValueError('Snapshot has missing or unmanifested files.')
    links = {}
    for name, digest, size, descriptor in entries:
        file = source / name
        if descriptor and descriptor['kind'] == 'symlink':
            # Permit only immutable source links whose entire chain terminates in captured bytes.
            contained(file.parent, source)
            target = os.readlink(file)
            if target != descriptor['linkTarget'] or target.startswith('/') or '\0' in target:
                raise ValueError('Unsafe captured symlink.')
            parts = list(PurePosixPath(descriptor['relativePath']).parts)
            if len(parts) < 5 or parts[0] != 'source-captures' or parts[3] != 'source':
                raise ValueError('Symlink is outside an immutable source capture.')
            resolved = parts[:-1]
            for part in target.split('/'):
                if part == '..':
                    if len(resolved) <= 4: raise ValueError('Captured link escapes its source tree.')
                    resolved.pop()
                elif part not in ['', '.']: resolved.append(part)
            links[name] = 'managed/' + '/'.join(resolved)
            value = target.encode()
            valid = hashlib.sha256(value).hexdigest() == digest and len(value) == size
        else:
            contained(file, source)
            if not file.is_file() or (descriptor and descriptor['kind'] != 'file'):
                raise ValueError('Snapshot entry is not a regular file.')
            valid = sha(file) == digest and file.stat().st_size == size
        if not valid or (descriptor and (descriptor.get('expectedSHA256') not in [None, digest] or descriptor.get('expectedSize') not in [None, size])):
            raise ValueError('Snapshot entry hash/size mismatch: ' + name)
    for name in links:
        visited = set()
        while name in links:
            if name in visited or len(visited) >= 32: raise ValueError('Captured link cycle.')
            visited.add(name); name = links[name]
        if name not in expected: raise ValueError('Captured link target is absent.')
    observation = database_observation(source / 'database.sqlite')
    if observation['quick_check'] != 'ok' or observation['schema'] != manifest['schema']:
        raise ValueError('Snapshot database integrity/schema mismatch.')
    inspection = require_local_paths(source / 'database.sqlite', destination_root or destination, source_root=manifest['sourceRoot'])
    # Verification finishes before any source byte is used in the new store.
    shutil.copyfile(source / 'database.sqlite', destination / 'checklist.sqlite')
    (destination / 'checklist.sqlite').chmod(0o600)
    for name, digest, size, descriptor in entries[1:]:
        target = destination / descriptor['relativePath']
        contained(target.parent, destination)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if descriptor['kind'] == 'symlink':
            target.symlink_to(descriptor['linkTarget'])
        else:
            shutil.copyfile(source / name, target)
            target.chmod(0o700 if descriptor['executable'] else 0o600)
            if sha(target) != digest or target.stat().st_size != size: raise ValueError('Copy verification failed.')
    if sha(destination / 'checklist.sqlite') != manifest['databaseSHA256']:
        raise ValueError('Database copy verification failed.')
    require_local_paths(destination / 'checklist.sqlite', destination_root or destination, source_root=manifest['sourceRoot'])
    if observation['schema'] > 0:
        identity = observation['identity']
        if not identity or identity['logical_store_id'] != manifest['storeID'] or identity['state'] != 'ready':
            raise ValueError('Snapshot database identity mismatch.')
        (destination / 'checklist-store.identity.json').write_text(json.dumps(identity, sort_keys=True) + '\n')
        (destination / 'checklist-store.identity.json').chmod(0o600)
    age = max(0, time.time() - manifest_file.stat().st_mtime)
    print(f'Snapshot age: {age / 86400:.2f} days; schema {observation["schema"]}; quick_check {observation["quick_check"]}')
    return {'kind': 'backup', 'source': str(source), 'source_hash': hashlib.sha256(raw).hexdigest(),
            'age_seconds_at_create': age, 'source_root': manifest['sourceRoot'], 'before_start': observation,
            'live_snapshot': is_live_snapshot(source, manifest['sourceRoot']), 'path_inspection': inspection}


def slot_seed(other, destination, destination_root=None):
    stopped(other)
    metadata = load(other)
    source = contained(other['data'], other['folder'])
    if not source.is_dir(): raise ValueError('Source slot has no data root.')
    # Check every entry before copying; copytree must never follow an external alias.
    for folder, directories, files in os.walk(source, followlinks=False):
        for name in directories + files:
            file = Path(folder) / name
            mode = file.lstat().st_mode
            if stat.S_ISLNK(mode):
                if os.readlink(file).startswith('/') or not file.resolve().is_relative_to(source):
                    raise ValueError('Source slot contains a link outside its data root.')
            elif not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError('Source slot contains a special file.')
    shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True,
                    ignore=lambda folder, names: {'connections.json'} if Path(folder) == source else set())
    inspection = require_local_paths(destination / 'checklist.sqlite', destination_root or destination, immutable=False, source_root=source)
    inventory = [(str(file.relative_to(destination)), os.readlink(file) if file.is_symlink() else sha(file))
                 for file in sorted(destination.rglob('*')) if file.is_file() or file.is_symlink()]
    return {'kind': 'slot', 'slot': metadata['slot'], 'source_build_id': metadata['build_id'],
            'source_hash': hashlib.sha256(json.dumps(inventory).encode()).hexdigest(), 'age_seconds_at_create': 0,
            'source_root': str(source), 'path_inspection': inspection}


def process_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    buffer = ctypes.create_string_buffer(4096)
    return os.fsdecode(buffer.value) if library.proc_pidpath(int(pid), buffer, len(buffer)) > 0 else ''


def processes(p):
    matches = {'app': [], 'service': [], 'cli': []}
    for line in run(['ps', '-axo', 'pid=']).stdout.splitlines():
        pid = int(line.strip()); path = process_path(pid)
        for kind, name in [('app', 'ChecklistApp'), ('service', 'ChecklistService'), ('cli', 'checklist')]:
            if path == str(p['bundle'] / 'Contents/MacOS' / name): matches[kind].append(pid)
    return matches


def launch_state(p):
    result = run(['launchctl', 'print', f'gui/{os.getuid()}/{p["label"]}'], check=False)
    if result.returncode: return {'registered': False, 'state': 'absent', 'pid': None}
    def field(name):
        match = re.search(r'^\s*' + name + r' = (.+)$', result.stdout, re.MULTILINE)
        return match.group(1) if match else None
    program = field('program')
    if program != str(p['bundle'] / 'Contents/MacOS/ChecklistService'):
        raise ValueError('Launchd program does not belong to this slot; refusing to use its job.')
    return {'registered': True, 'state': field('state'), 'pid': int(field('pid')) if field('pid') else None}


def stopped(p):
    if launch_state(p)['registered'] or any(processes(p).values()):
        raise ValueError('Slot must be stopped, including its CLI/MCP processes.')


def trash(folder, root=None):
    contained(folder, BASE if root is None else root)
    destination = Path.home() / '.Trash' / (folder.name + '-Checklist-' + uuid.uuid4().hex)
    contained(destination, Path.home() / '.Trash')
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    folder.rename(destination)
    print('Moved to Trash: ' + str(destination))


def create(arguments, p):
    stopped(p)
    if p['folder'].exists():
        if not arguments.replace: raise ValueError('Slot exists; use --replace after stopping it.')
        load(p)  # Do not replace unrelated directories.
    capture, manifest = stage_selection(arguments)
    identity = sign_identity(manifest)
    if p['folder'].exists(): trash(p['folder'])
    p['folder'].mkdir(mode=0o700)
    metadata = {'slot': arguments.slot, 'build_id': manifest['build_id'], 'source_fingerprint': manifest['source_fingerprint'],
                'stage_path': str(capture), 'seed': {'kind': 'incomplete'}, 'created_at': now(), 'mode': 'incomplete', 'checks': None}
    save(p, metadata)
    pending = contained(p['folder'] / '.seed-data', p['folder']); pending.mkdir(mode=0o700)
    try:
        if arguments.seed != 'empty': require_managed_path_support(capture, manifest)
        seed = {'kind': 'empty', 'source_hash': None, 'age_seconds_at_create': 0}
        if arguments.seed == 'latest-backup':
            seed = snapshot_seed(latest_backup(), pending, p['data'])
        elif arguments.seed.startswith('backup:'):
            seed = snapshot_seed(Path(arguments.seed[7:]), pending, p['data'])
        elif arguments.seed.startswith('slot:'):
            seed = slot_seed(checked(slot_number(arguments.seed[5:])), pending, p['data'])
        elif arguments.seed != 'empty': raise ValueError('Seed must be empty, latest-backup, backup:PATH or slot:M.')
    except (ValueError, OSError, sqlite3.Error) as error:
        metadata.update(mode='refused', seed={'kind': 'refused', 'reason': str(error)})
        save(p, metadata)
        raise
    # Neither the service root nor an executable app is published for a refused seed.
    pending.rename(p['data'])
    run(['ditto', capture / 'Checklist.app', p['bundle']])
    info_file = p['bundle'] / 'Contents/Info.plist'
    info_file.write_bytes(plistlib.dumps(rewrite_info(plistlib.loads(info_file.read_bytes()), arguments.slot)))
    # Test bundles never register Login Items and carry no live launchd labels.
    agents = p['bundle'] / 'Contents/Library/LaunchAgents'
    if agents.exists(): shutil.rmtree(contained(agents, p['folder']))
    run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--identifier', p['identifier'], p['bundle']])
    run(['codesign', '--verify', '--deep', '--strict', p['bundle']])
    signing_teams(p['bundle'], manifest['signing_profile'])
    save(p, {'slot': arguments.slot, 'build_id': manifest['build_id'], 'source_fingerprint': manifest['source_fingerprint'],
             'stage_path': str(capture), 'seed': seed, 'created_at': now(), 'mode': 'stopped', 'checks': None})
    print(f'Created slot {arguments.slot}: build {manifest["build_id"]}; seed {seed["kind"]}')


def executable_payload(path):
    # Outer signing changes the app's embedded signature, not its Mach-O payload.
    data = bytearray(path.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Unsupported executable format; cannot bind slot to stage.')
    count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data): raise ValueError('Invalid Mach-O load command.')
        if command == 0x1d:
            boundary, length = struct.unpack_from('<II', data, offset + 8)
            if boundary < offset + size or boundary + length != len(data): raise ValueError('Invalid code signature boundary.')
            data[offset + 8:offset + 16] = bytes(8)
            return hashlib.sha256(data[:boundary]).hexdigest()
        offset += size
    raise ValueError('Executable is unsigned.')


def bundle_check(p, metadata):
    info = plistlib.loads((contained(p['bundle'] / 'Contents/Info.plist', p['folder'])).read_bytes())
    if info.get('ChecklistInstanceSlot') != metadata['slot'] or info.get('CFBundleIdentifier') != p['identifier']:
        raise ValueError('Slot bundle identity mismatch.')
    run(['codesign', '--verify', '--deep', '--strict', p['bundle']])
    capture, manifest = verify_stage(metadata['stage_path'])
    if manifest['build_id'] != metadata['build_id'] or manifest['source_fingerprint'] != metadata['source_fingerprint']:
        raise ValueError('Slot and original stage build identities differ.')
    signing_teams(p['bundle'], manifest['signing_profile'])
    for name in ['ChecklistApp', 'ChecklistService', 'checklist']:
        if executable_payload(p['bundle'] / 'Contents/MacOS' / name) != executable_payload(capture / 'Checklist.app/Contents/MacOS' / name):
            raise ValueError('Slot executable differs from original stage: ' + name)
    return manifest


def start_deadline_seconds():
    try: value = float(os.environ.get('CHECKLIST_START_DEADLINE_SECONDS', '2700'))
    except ValueError as error:
        raise ValueError('CHECKLIST_START_DEADLINE_SECONDS must be finite and at least 60 seconds.') from error
    if not math.isfinite(value) or value < 60:
        raise ValueError('CHECKLIST_START_DEADLINE_SECONDS must be finite and at least 60 seconds.')
    return value


def service_status(p, *, bound=None):
    """Wait for health while the slot's protected snapshot/migration keeps running."""
    bound = start_deadline_seconds() if bound is None else bound
    number = p['folder'].name.removeprefix('slot-')
    started = time.monotonic();deadline = started + bound;next_progress = started + 60
    command = [p['bundle'] / 'Contents/MacOS/checklist', 'service', 'status']
    def expired():
        raise ValueError(f'Slot {number} startup deadline expired after {bound:g} seconds; '
                         'the slot service keeps running its protected startup. '
                         f'Run start --slot {number} again to keep waiting, '
                         f'or status --slot {number} to inspect it; '
                         'destroying the slot during a protected snapshot discards that work.')
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0: expired()
        try: result = run(command, timeout=min(30, remaining), check=False)
        except subprocess.TimeoutExpired: pass
        else:
            try: payload = json.loads(result.stdout)
            except (ValueError, TypeError):
                if not (result.returncode and 'unavailable' in ((result.stderr or '') + (result.stdout or '')).lower()):
                    raise ValueError('Slot service returned invalid status: ' + str(result.stdout))
            else:
                body = payload.get('data', payload) if isinstance(payload, dict) else None
                if not isinstance(body, dict): raise ValueError('Slot service returned invalid status: ' + str(result.stdout))
                states = [payload.get('state'), body.get('state')]
                if any(state not in [None, 'ready', 'running', 'healthy', 'starting', 'unavailable'] for state in states):
                    raise ValueError('Slot service reported an error state: ' + result.stdout)
                errors = [value['error'] for value in [payload, body] if 'error' in value]
                if any(not isinstance(error, dict) or error.get('code') not in ['SERVICE_UNAVAILABLE', 'UNAVAILABLE'] for error in errors):
                    raise ValueError('Slot service returned an error status: ' + result.stdout)
                if not errors and not any(state in ['starting', 'unavailable'] for state in states):
                    if (result.returncode or body.get('name') != 'Checklist' or not isinstance(body.get('version'), str)
                            or not body['version'] or not isinstance(body.get('capabilities'), list) or 'durable_store' not in body['capabilities']):
                        raise ValueError('Slot service is not healthy: ' + result.stdout)
                    return payload
        now = time.monotonic()
        if now >= deadline: expired()
        if now >= next_progress:
            print(f'slot {number}: still starting (protected startup), {(now - started) / 60:.0f} min', file=sys.stderr, flush=True)
            next_progress = now + 60
        time.sleep(min(5, deadline - now))


def start(arguments, p):
    bound = start_deadline_seconds()  # Reject invalid configuration before bootstrap.
    metadata = load(p)
    if metadata['seed']['kind'] not in ['empty', 'backup', 'slot'] or metadata['mode'] in ['incomplete', 'refused']:
        raise ValueError('Slot creation did not complete: ' + metadata['seed'].get('reason', 'incomplete seed'))
    manifest = bundle_check(p, metadata)
    if metadata['seed']['kind'] != 'empty':
        require_managed_path_support(Path(metadata['stage_path']), manifest)
        require_local_paths(p['data'] / 'checklist.sqlite', p['data'], immutable=False, source_root=metadata['seed'].get('source_root'))
    logs = contained(p['folder'] / 'logs', p['folder']); logs.mkdir(mode=0o700, exist_ok=True)
    plist = contained(p['folder'] / 'service.plist', p['folder'])
    contents = {'Label': p['label'], 'MachServices': {p['label']: True},
                'Program': str(p['bundle'] / 'Contents/MacOS/ChecklistService'), 'ProcessType': 'Interactive',
                'RunAtLoad': False, 'KeepAlive': False,
                'StandardOutPath': str(logs / 'service.stdout.log'), 'StandardErrorPath': str(logs / 'service.stderr.log')}
    for key in ['StandardOutPath', 'StandardErrorPath']: contained(contents[key], p['folder'])
    if not launch_state(p)['registered']:
        plist.write_bytes(plistlib.dumps(contents))
        run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', plist])
    metadata['mode'] = 'gui' if arguments.gui or processes(p)['app'] else 'headless'; save(p, metadata)
    service_status(p, bound=bound)
    if arguments.gui:
        print(f'Opening Checklist Test {arguments.slot}: synthetic/test data only.')
        run(['open', '-n', p['bundle']])
    print(f'Slot {arguments.slot} ready ({metadata["mode"]}).')


def status(number):
    p = checked(number)
    if not p['folder'].exists(): return {'slot': number, 'created': False, 'launchd': launch_state(p), 'processes': processes(p)}
    metadata = load(p)
    size = sum(file.lstat().st_size for file in p['data'].rglob('*') if file.is_file() and not file.is_symlink())
    return dict(metadata, created=True, launchd=launch_state(p), processes=processes(p), data_root=str(p['data']), data_bytes=size)


def check(p):
    metadata = load(p)
    results = []; observation = None
    try:
        bundle_check(p, metadata)
        commands = [[sys.executable, REPO / 'scripts/cli-usage-smoke.py', '--binary', p['bundle'] / 'Contents/MacOS/checklist'],
                    [p['bundle'] / 'Contents/MacOS/checklist', 'service', 'status'],
                    [sys.executable, REPO / 'scripts/mcp-smoke.py', '--binary', p['bundle'] / 'Contents/MacOS/checklist', '--service-only']]
        for command in commands:
            if command[1:3] == ['service', 'status']:
                # A direct check can also encounter the slot's first startup.
                payload = service_status(p)
                result = subprocess.CompletedProcess(command, 0, json.dumps(payload) + '\n', '')
            else:
                result = run(command, timeout=360, check=False)
            item = {'command': list(map(str, command)), 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
            results.append(item)
            print(result.stdout, end='')
            if item['exit']: print(result.stderr, file=sys.stderr)
        passed = all(item['exit'] == 0 for item in results)
        if passed:
            observation = database_observation(contained(p['data'] / 'checklist.sqlite', p['folder']), immutable=False)
            if observation['quick_check'] != 'ok': raise ValueError('Slot database quick_check failed.')
    except (ValueError, OSError, subprocess.SubprocessError, sqlite3.Error) as error:
        results.append({'error': str(error)}); passed = False
    metadata['checks'] = {'build_id': metadata['build_id'], 'source_fingerprint': metadata['source_fingerprint'],
                          'checked_at': now(), 'passed': passed, 'results': results, 'store_observation': observation}
    save(p, metadata)
    if not passed: raise ValueError('Slot checks failed; recorded in slot.json.')
    print('Checks passed for build ' + metadata['build_id'])


def stop(p):
    before = processes(p)
    for pid in before['app']:
        if process_path(pid) != str(p['bundle'] / 'Contents/MacOS/ChecklistApp'): raise ValueError('App PID changed; refusing signal.')
        os.kill(pid, signal.SIGTERM)
    state = launch_state(p)
    if state['registered']:
        if state['pid'] and process_path(state['pid']) != str(p['bundle'] / 'Contents/MacOS/ChecklistService'):
            raise ValueError('Launchd PID does not belong to this slot; refusing bootout.')
        run(['launchctl', 'bootout', f'gui/{os.getuid()}/{p["label"]}'])
    deadline = time.monotonic() + 10
    while True:
        state = launch_state(p)
        remaining = processes(p)
        if not state['registered'] and not any(remaining.values()): break
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise ValueError('Slot still has a running process; preserve it for reconciliation. '
                             f'Remaining PIDs: {json.dumps(remaining, sort_keys=True)}; '
                             f'launchd state: {json.dumps(state, sort_keys=True)}')
        time.sleep(min(.1, seconds))
    if (p['folder'] / 'slot.json').exists():
        metadata = load(p); metadata['mode'] = 'stopped'; save(p, metadata)
    print('Stopped ' + p['label'])


def delete_slot_keychain(number, service):
    number = slot_number(number)
    if not re.fullmatch(fr'(?:org\.checklist\.test{number}\.enrollments|Checklist\.Test{number}\.HumanClaim)', service):
        raise ValueError('Refusing non-slot Keychain service identity: ' + service)
    for count in range(KEYCHAIN_DELETE_LIMIT):
        result = run(['security', 'delete-generic-password', '-s', service], check=False)
        if result.returncode == 44: return count
        if result.returncode:
            raise ValueError(f'Cannot delete slot Keychain service {service} after {count} removals: ' + result.stderr)
    raise ValueError(f'Keychain deletion limit {KEYCHAIN_DELETE_LIMIT} reached for {service}; slot folder preserved.')


def destroy(p):
    match = re.fullmatch(r'slot-([1-4])', p['folder'].name)
    if not match or p != paths(int(match[1])):
        raise ValueError('Refusing mismatched slot cleanup identity.')
    number = int(match[1])
    stop(p)
    if p['folder'].exists(): load(p)

    preferences = Path.home() / 'Library/Preferences'
    contained(preferences, preferences)
    window_uuid = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    domain_rule = re.compile(fr'(?:org\.checklist\.app\.test{number}|Checklist\.Test{number}\.Workspace\.{window_uuid})')
    domains = {p['identifier']}  # Also delete a cached standard domain with no plist yet.
    if preferences.exists():
        domains.update(file.stem for file in preferences.iterdir()
                       if file.suffix == '.plist' and domain_rule.fullmatch(file.stem))
    files = {}
    for domain in sorted(domains):
        if not domain_rule.fullmatch(domain): raise ValueError('Refusing non-slot preference domain: ' + domain)
        file = contained(preferences / (domain + '.plist'), preferences)
        if file.exists() and not file.is_file(): raise ValueError('Refusing non-file preference plist: ' + str(file))
        files[domain] = file
    saved_root = Path.home() / 'Library/Saved Application State'
    saved = contained(saved_root / (p['identifier'] + '.savedState'), saved_root)
    if not re.fullmatch(fr'org\.checklist\.app\.test{number}\.savedState', saved.name):
        raise ValueError('Refusing non-slot saved-state identity.')
    if saved.exists() and not saved.is_dir(): raise ValueError('Refusing non-directory saved state: ' + str(saved))

    receipt = {'slot': number, 'keychain_items_removed': {}, 'preference_domains_removed': [],
               'preference_domains_missing': [], 'trashed': []}
    for service in [p['keychain'], f'Checklist.Test{number}.HumanClaim']:
        receipt['keychain_items_removed'][service] = delete_slot_keychain(number, service)
    for domain, file in files.items():
        had_plist = file.exists()
        result = run(['defaults', 'delete', domain], check=False)
        missing = result.returncode == 1 and any(message in result.stdout + result.stderr for message in
                                                [f'Domain ({domain}) not found.', f"Domain '{domain}' not found."])
        if result.returncode and not missing:
            raise ValueError(f'Cannot remove slot preference domain {domain}: ' + result.stderr)
        contained(file, preferences)
        if file.exists():
            # cfprefsd can persist an empty dictionary after clearing the domain.
            # Clear through defaults first, then remove only that verified empty plist.
            try:
                empty = plistlib.loads(file.read_bytes()) == {}
            except (ValueError, OSError) as error:
                raise ValueError(f'Cannot verify cleared preference plist {file}: {error}') from error
            if not empty: raise ValueError('Refusing nonempty preference plist after defaults delete: ' + str(file))
            file.unlink()
        if file.exists() or file.is_symlink():
            raise ValueError(f'Cannot remove slot preference domain {domain}; plist must be gone: ' + result.stderr)
        receipt['preference_domains_missing' if missing and not had_plist else 'preference_domains_removed'].append(domain)
    for folder, root in [(saved, saved_root), (p['folder'], BASE)]:
        if folder.exists():
            trash(folder, root)
            receipt['trashed'].append(str(folder))
    receipt['preference_domains_removed_count'] = len(receipt['preference_domains_removed'])
    receipt['trashed_count'] = len(receipt['trashed'])
    print('Destroy receipt: ' + json.dumps(receipt, sort_keys=True))
    return receipt


def promotion_gates(selected, slots):
    def passed(value):
        checks = value.get('checks') or {}
        return value.get('seed', {}).get('kind') not in ['incomplete', 'refused'] and checks.get('passed') is True and checks.get('build_id') == selected['build_id'] and checks.get('source_fingerprint') == selected['source_fingerprint'] and value.get('build_id') == selected['build_id'] and value.get('source_fingerprint') == selected['source_fingerprint']
    return {'selected_build_check': passed(selected),
            'live_snapshot_check_same_build': any(passed(value) and value.get('seed', {}).get('kind') == 'backup' and value['seed'].get('live_snapshot') is True for value in slots)}


def promote(arguments, p):
    selected = load(p)
    if selected['seed']['kind'] in ['incomplete', 'refused']:
        raise ValueError('Promotion refused: slot creation did not complete. ' + RELOCATION_REQUIRED)
    bundle_check(p, selected)
    slots = []
    for number in range(1, 5):
        other = checked(number)
        if (other['folder'] / 'slot.json').exists():
            value = load(other)
            if value['build_id'] == selected['build_id'] and value['seed']['kind'] not in ['incomplete', 'refused']:
                bundle_check(other, value)
            slots.append(value)
    gates = promotion_gates(selected, slots)
    for gate, passed in gates.items(): print(f'{gate}: {"PASS" if passed else "FAIL"}')
    command = [str(REPO / 'script/build_and_run.sh'), '--install-stage', selected['stage_path']]
    print('Planned action: ' + json.dumps(command))
    if not gates['live_snapshot_check_same_build']:
        print('Missing live-backup qualification: run a same-build live-backup-seeded slot check.')
    if not all(gates.values()): raise ValueError('Promotion refused: all gates must pass, including a live-backup-seeded check of this build. ' + RELOCATION_REQUIRED)
    if not arguments.dry_run:
        install_started = time.time()
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as error:
            raise ValueError('Promotion: install ran; installed verification failed.\n' + failure_guidance(install_started)) from error
        print('Promoted build ' + selected['build_id'] + '; installed app and service verification passed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['create', 'start', 'status', 'check', 'stop', 'destroy', 'promote']:
        command = commands.add_parser(name)
        command.add_argument('--slot', type=slot_number, required=name in ['create', 'start', 'check', 'promote'])
        if name in ['stop', 'destroy']: command.add_argument('--all', action='store_true')
        if name == 'status': command.add_argument('--json', action='store_true')
        if name == 'create':
            source = command.add_mutually_exclusive_group()
            source.add_argument('--stage', type=Path); source.add_argument('--latest-stage', action='store_true')
            command.add_argument('--seed', type=seed_value, default='empty'); command.add_argument('--replace', action='store_true')
        if name == 'start':
            mode = command.add_mutually_exclusive_group()
            mode.add_argument('--headless', action='store_true'); mode.add_argument('--gui', action='store_true')
        if name == 'promote': command.add_argument('--dry-run', action='store_true')
    arguments = parser.parse_args()
    if arguments.command in ['stop', 'destroy'] and bool(arguments.slot) == bool(arguments.all):
        parser.error('Choose exactly one of --slot or --all.')
    if arguments.command == 'status':
        numbers = [arguments.slot] if arguments.slot else range(1, 5)
        for number in numbers: checked(number)
        values = [status(number) for number in numbers]
        if arguments.json: print(json.dumps(values, indent=2))
        else:
            for value in values:
                print(f'Slot {value["slot"]}: ' + json.dumps(value, sort_keys=True))
        return
    numbers = list(range(1, 5)) if getattr(arguments, 'all', False) else [arguments.slot]
    # Source locks and promotion evidence locks prevent concurrent replacement of either side.
    locks = set(numbers)
    if arguments.command == 'create' and arguments.seed.startswith('slot:'):
        source = slot_number(arguments.seed[5:])
        if source == arguments.slot: raise ValueError('Cannot seed a slot from itself.')
        locks.add(source)
    if arguments.command == 'promote': locks.update(range(1, 5))
    # Admit every source/destination before creating even the first lock or reading a slot.
    for number in sorted(locks): checked(number)
    if arguments.command == 'promote' and arguments.dry_run:
        promote(arguments, checked(arguments.slot))
        return
    with ExitStack() as stack:
        for number in sorted(locks): stack.enter_context(locked(number))
        for number in numbers:
            p = checked(number)
            if arguments.command == 'create': create(arguments, p)
            elif arguments.command == 'start': start(arguments, p)
            elif arguments.command == 'check': check(p)
            elif arguments.command == 'stop': stop(p)
            elif arguments.command == 'destroy': destroy(p)
            elif arguments.command == 'promote': promote(arguments, p)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, sqlite3.Error) as error:
        print('test_instances: ' + str(error), file=sys.stderr)
        sys.exit(1)
