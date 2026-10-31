#!/usr/bin/env python3
"""Manage four disposable Checklist test slots. Never build or alter the live store."""
import argparse
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, ExitStack, closing
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
import tempfile
import threading
import unicodedata
from urllib.parse import unquote, urlsplit
import uuid

from clean_scratch import caller_session, mark_qualification, read_marker, requested_tickets, validate_fingerprint
from test_instance_restage import FRESH_COPY, backup_completion, reuse_proof
from verify_stage import sha, signing_teams, verify as verify_stage
from verify_install import describe_status, failure_guidance, status_still_starting, upgrading_message, upgrading_status

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

# A field name alone does not establish file authority. The inspector below
# distinguishes canonical managed descriptors, project references, captured names
# and inert replay history. Unclassified record text is not file authority.
PATH_FIELDS = frozenset({'path', 'preview_path', 'icon_path', 'root_path', 'source_root',
                        'snapshot_path', 'output_path', 'working_directory', 'workspace',
                        'workspace_path', 'canonical_key', 'mcp_executable', 'git_path',
                        'object_relative_path', 'relative_path', 'resolved_path', 'database_path'})
PATH_LIST_FIELDS = frozenset({'paths', 'additional_paths'})
# These retained descriptor spellings may be relative; preserve their existing
# absolute slot-containment check instead of inferring authority from all prose.
ABSOLUTE_PATH_FIELDS = frozenset({'stored_path', 'capture_path', 'cache_path', 'declared_path', 'link_target', 'root'})


def slot_number(value):
    if str(value) not in ['1', '2', '3', '4']:
        raise ValueError('Slot must be 1, 2, 3 or 4.')
    return int(value)


def seed_value(value):
    if value in ['empty', 'latest-backup'] or any(value.startswith(kind + ':') and value[len(kind) + 1:] for kind in ['backup', 'restored']): return value
    if value.startswith('slot:'):
        slot_number(value[5:]); return value
    raise ValueError('Seed must be empty, latest-backup, backup:PATH, restored:PATH or slot:M.')


def paths(number):
    number = slot_number(number)
    folder = BASE / f'slot-{number}'
    return {'folder': folder, 'data': folder / 'data', 'bundle': folder / f'Checklist Test {number}.app',
            'label': f'org.checklist.test{number}.coordination',
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


SCHEMA_SOURCE = 'Sources/ChecklistCore/SchemaMigrations.swift'


def storage_schema(path):
    """The current store schema of one source tree: SchemaMigrations.currentSchema.

    Stages built before that constant (schema 3) name their schema only as the
    highest migration target; when both exist they must agree.
    """
    text = Path(path).read_text()
    constant = re.findall(r'^\s*static let currentSchema = (\d+)\s*$', text, re.M)
    targets = [int(value) for value in re.findall(r'PRAGMA user_version=(\d+)', text)]
    if len(constant) > 1 or not targets or (constant and int(constant[0]) != max(targets)):
        raise ValueError('Cannot read one current store schema from ' + str(path) + '.')
    return int(constant[0]) if constant else max(targets)


def require_managed_path_support(capture, manifest):
    """Relaxed seeds run only with a verified stage that has the schema-3 managed-path migration.

    Returns that stage's current store schema, read from the verified captured source.
    """
    required = {'Sources/ChecklistCore/ManagedPaths.swift', SCHEMA_SOURCE}
    inputs = {entry['path']: entry for entry in manifest.get('inputs', [])}
    if not required <= inputs.keys():
        raise ValueError('Stage predates the instance-local managed-path contract; rebuild before seeding a slot.')
    migration = Path(capture) / 'source' / SCHEMA_SOURCE
    if sha(migration) != inputs[SCHEMA_SOURCE]['sha256'] or 'managedPathsLedger' not in migration.read_text() or storage_schema(migration) < 3:
        raise ValueError('Stage has no verified schema-3 managed-path migration; rebuild before seeding a slot.')
    return storage_schema(migration)


def supported_schema(schema, current_schema, kind):
    # A seed may be older (the stage migrates it at first start) but never newer than the stage.
    if type(schema) is not int or schema < 0:
        raise ValueError('Unsupported ' + kind + ' schema.')
    if schema > current_schema:
        raise ValueError(f'{kind.capitalize()} schema {schema} is newer than the staged build supports (schema {current_schema}); '
                         'stage a build that supports it.')


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
    raise ValueError('No complete verified stage. Run script/build_and_run.sh --stage --ticket KEY first.')


def relative_path(value):
    path = PurePosixPath(value)
    if not value or len(path.parts) < 2 or path.is_absolute() or '\0' in value or any(x in ['', '.', '..'] for x in value.split('/')):
        raise ValueError('Unsafe snapshot relative path: ' + value)
    if path.parts[0] not in ['objects', 'source-captures', 'staging', 'icons', 'source-executions', 'source-build-cache']:
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
                'identity': json.loads(identity[0]) if identity else None,
                'table_rows': {table: connection.execute('SELECT count(*) FROM ' + table).fetchone()[0]
                               for table in ['metadata', 'records', 'commands', 'events', 'cursors']}}
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


def require_local_paths(database, destination, immutable=True, source_root=None,
                        summary_source_root=None, summary_source_paths=None):
    """Read-only seed inspection. Never open a stored managed absolute path.

    source_root is the verified snapshot manifest's origin or the stopped source
    slot's root. Legacy managed descriptors from that root are admitted for Core's
    protected relocation, not redirected by this harness. Other Checklist roots
    remain forbidden. Verified source manifests may admit display-only source
    summaries; startup restricts those to the exact recorded metadata fields.
    Counts are occurrences, including repeated project refs.
    """
    database = Path(database).absolute()
    destination = Path(os.path.normpath(destination)).absolute()
    source_root = Path(os.path.normpath(source_root)).absolute() if source_root is not None else None
    counts = dict.fromkeys(['managed_relative', 'managed_local_absolute', 'managed_origin_absolute',
                           'managed_unavailable_absolute', 'external_project_path_occurrences',
                           'relative_capture_paths', 'relative_evidence_paths', 'inert_history_path_occurrences', 'inert_metadata_path_occurrences',
                           'capture_git_provenance'], 0)
    mapping = ManagedPathMapping()
    summary_source_root = Path(summary_source_root) if summary_source_root is not None else None
    source_summaries = {}
    non_json = set()

    def decoded_json(value):
        # Most database leaves are field names, hashes and ordinary prose. Avoid
        # raising the same parser exception twice for every such occurrence.
        if value in non_json or value.lstrip()[:1] not in '"{[-0123456789tfnNI': return value
        try: return json.loads(value)
        except (ValueError, TypeError):
            if len(value) <= 512 and len(non_json) < 4096: non_json.add(value)
            return value

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
        if record_kind == 'backup_historical_catalog' and location == 'metadata.value':
            if key == 'path': return ('backup_catalog', None)
            if key == 'key_root': return ('catalog_provenance', None)
        if record_kind == 'backup_retention_settings' and location == 'metadata.value.owner_confirmation' and key == 'source_root':
            # Runtime binds this consent to root + incarnation and disables it
            # on a copy. The original root is provenance, never file authority.
            return ('catalog_provenance', None)
        if key == 'declared_path' and '.file_scopes[]' in location: return ('recursive_binding', None)
        if record_kind == 'storage_summary' and location == 'metadata.value' and key in {'path', 'source_root'}:
            return ('slot_summary', None)
        if key == 'path':
            if parent.get('mode') == 'managed': return ('managed', 'objects')
            # CL-298: a submitted check result names its report file relative
            # to the project root (for example TestResults/run.xml).
            if record_kind == 'manifest' and location.endswith('.evidence.checks[]'): return ('evidence_relative', None)
            # CL-339: submitters list the source files they changed (often in a
            # private scratch folder) with their digests. Core never opens them.
            if record_kind == 'manifest' and location.endswith('.evidence.source_files[]'): return ('inert_history', None)
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
        # CL-298: submit evidence keeps the submitter's project-relative
        # additional_paths verbatim (for example kind "artifact"). They name
        # files under the manifest project's root; Core never resolves them.
        if key == 'additional_paths' and record_kind == 'manifest' and location.endswith('.evidence'):
            return ('evidence_relative', parent.get('source_root'))
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
        # Human command examples are validated text, never executed by Core.
        # Retain this formerly strict field's blanket file-URL refusal.
        if key == 'working_directory' and record_kind == 'request' and location.endswith('.command'):
            return ('instruction', None)
        if key in PATH_FIELDS or key in PATH_LIST_FIELDS: return ('strict', None)
        if key in ABSOLUTE_PATH_FIELDS: return ('slot_absolute', None)
        # File authority is enumerated above. Other record scalars (including
        # Bug/Playtest starter fields) are text; structured children still get
        # their own path rules. Unknown metadata keeps its fail-closed fallback.
        if record_kind is not None and record_kind not in {'capture_bindings', 'storage_summary', 'backup_historical_catalog', 'backup_retention_settings'}:
            return ('text', None)
        if key in {'body', 'brief', 'reason', 'summary'}:
            return ('text', None)
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
            decoded = decoded_json(value)
            if has_file_url and kind not in {None, 'text'}: refuse(location, 'a stored file URL')
            if kind in {None, 'text'}:
                # Inspect serialized payloads at their leaves, not as quoted prose.
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
                if kind not in {None, 'text'} or value.startswith('/') or has_file_url:
                    counts['inert_metadata_path_occurrences' if inert == 'metadata' else 'inert_history_path_occurrences'] += 1
            elif kind == 'slot_summary':
                # Display-only copy observation: compare spelling, never inspect
                # the referenced backup/restore path or any symlink there.
                path = check_absolute(value, location)
                if not path.is_relative_to(destination.parent):
                    field = location.rsplit('.', 1)[-1]
                    source_summary = summary_source_root is not None and (
                        path == summary_source_root or path.is_relative_to(summary_source_root / 'backups'))
                    recorded = summary_source_paths is None or summary_source_paths.get(metadata_key, {}).get(field) == value
                    if not source_summary or not recorded:
                        refuse(location, 'a stored absolute path outside the destination slot root')
                    source_summaries.setdefault(metadata_key, {})[field] = value
                counts['inert_metadata_path_occurrences'] += 1
            elif kind == 'managed': check_managed(value, family, location)
            elif kind == 'backup_catalog':
                try: relative = relative_path(value)
                except ValueError: refuse(location, 'a malformed root-relative backup catalog path')
                if relative.parts[:2] != ('objects', 'backup-catalogs'):
                    refuse(location, 'a backup catalog path in the wrong family')
                check_managed(value, 'objects', location)
            elif kind == 'catalog_provenance':
                # Schema 5 freezes the old receipt's key normalization root.
                # It is not file authority and must never be resolved/opened.
                check_absolute(value, location)
                counts['inert_metadata_path_occurrences'] += 1
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
            elif kind == 'evidence_relative':
                # Same spelling safety as capture project-relative paths. A
                # leading slash keeps the slot-contained absolute rule; nothing
                # outside the slot is opened or resolved.
                if value.startswith('/'):
                    check_slot_absolute(value, location)
                elif '\0' in value or any(x in ['', '.', '..'] for x in value.split('/')):
                    refuse(location, 'a relative, malformed or traversing stored file path')
                elif isinstance(family, str):
                    check_binding(str(check_absolute(family, location) / value), location)
                else:
                    counts['relative_evidence_paths'] += 1
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
            elif kind == 'inert_history':
                # Submitter history: counted, never resolved, opened or rewritten.
                counts['inert_history_path_occurrences'] += 1
            elif kind in {'text', 'instruction'}:
                if value.startswith('/') or has_file_url:
                    counts['inert_history_path_occurrences'] += 1
            elif kind == 'strict' or value.startswith('/'):
                check_slot_absolute(value, location)
            elif has_file_url:
                counts['inert_history_path_occurrences'] += 1
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
                if metadata_key is not None and metadata_key.startswith('backup-historical-catalog:'):
                    record_kind = 'backup_historical_catalog'
                if metadata_key == 'backup-retention-settings': record_kind = 'backup_retention_settings'
                # Unlike older inert receipts below, summaries allow only their
                # top-level copy/source observations; other fields stay strict.
                if metadata_key is not None and metadata_key.startswith('storage-last-verified-'):
                    record_kind = 'storage_summary'
                for column, value in zip(columns, row):
                    inert = (table == 'commands' and column == 'result') or (table == 'events' and column == 'data')
                    if column == 'value' and metadata_key is not None and (metadata_key in {'preupgrade_snapshot', 'backup-protected-history', 'backup-automatic-prune-last'} or metadata_key.startswith(('backup-generation:', 'backup-automatic-prune-fenced:'))):
                        inert = 'metadata'
                    inspect(value, table + '.' + column, record_kind, policy(column, {}, table, record_kind), inert)
    except (UnicodeError, RecursionError) as error:
        raise ValueError('Seed values cannot be safely inspected. ' + RELOCATION_REQUIRED) from error
    finally:
        connection.close()
    if source_summaries: counts['source_summary_paths'] = source_summaries
    return counts


def snapshot_objects(manifest):
    """Expand the versioned compact table without changing descriptor authority."""
    if manifest['format'] == 1:
        return manifest['objects']
    if manifest['format'] != 2:
        raise ValueError('Unsupported snapshot format.')
    table = manifest['objects']
    entries, contents, prefixes = table['entries'], table['contents'], table['strings']
    if len(entries) > 500_000 or len(contents) > len(entries) or len(prefixes) > 4_000_000:
        raise ValueError('Snapshot compact table exceeds capacity.')
    strings, previous, total = [], b'', 0
    for prefix in prefixes:
        if (len(prefix) != 2 or type(prefix[0]) is not int or not 0 <= prefix[0] <= len(previous)
                or not isinstance(prefix[1], str)):
            raise ValueError('Invalid snapshot string prefix.')
        previous = previous[:prefix[0]] + prefix[1].encode('utf-8')
        total += len(previous)
        if total > 512 * 1_048_576:
            raise ValueError('Snapshot expanded strings exceed capacity.')
        strings.append(previous.decode('utf-8'))
    def string(index):
        if type(index) is not int or not 0 <= index < len(strings):
            raise ValueError('Invalid snapshot string index.')
        return strings[index]
    result, used = [], set()
    for row in entries:
        if (len(row) < 7 or any(type(n) is not int for n in row) or row[3] < -1
                or row[4] not in [0, 1] or not 0 <= row[6] < len(contents)):
            raise ValueError('Invalid snapshot descriptor row.')
        content = contents[row[6]]
        if len(content) != 2 or type(content[1]) is not int or content[1] < 0:
            raise ValueError('Invalid snapshot content row.')
        descriptor = dict(relativePath=string(row[0]), kind=string(row[1]), executable=bool(row[4]),
                          authorities=[string(n) for n in row[7:]])
        for key, index in [('expectedSHA256', row[2]), ('linkTarget', row[5])]:
            if index != -1: descriptor[key] = string(index)
        if row[3] != -1: descriptor['expectedSize'] = row[3]
        result.append(dict(descriptor=descriptor, sha256=string(content[0]), size=content[1]))
        used.add(row[6])
    if len(used) != len(contents):
        raise ValueError('Snapshot has unused content rows.')
    return result


class SeedFileTree:
    """An anchored tree with bounded directory handles and per-pass inode proofs.

    Each path is opened without following links, including every directory below
    the root. A cached digest belongs only to the same open inode/size/timestamps
    during this pass; a destination uses a separate tree and hashes independently.
    Eight workers use fewer than 80 handles, including both copy trees.
    """
    def __init__(self, root):
        self.root = contained(root, root)
        self.lock = threading.Lock()
        self.directories = OrderedDict()
        self.bindings = {}
        self.digests = {}
        self.hashed_bytes = 0
        self.descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)

    def __enter__(self): return self

    def __exit__(self, error_type, *unused):
        try:
            if error_type is None:
                contained(self.root, self.root)
                if self.identity(self.root.stat())[:2] != self.identity(os.fstat(self.descriptor))[:2]:
                    raise ValueError('Seed root changed during verification.')
                # Reopen each encountered directory from the anchored root.
                # Cached handles must not conceal a moved/replaced path.
                for parent, identity in self.bindings.items():
                    descriptor = self.directory(PurePosixPath(parent).parts)
                    try:
                        if self.identity(os.fstat(descriptor))[:2] != identity:
                            raise ValueError('Seed directory changed during verification: ' + parent)
                    finally: os.close(descriptor)
        finally:
            for descriptor in self.directories.values(): os.close(descriptor)
            os.close(self.descriptor)

    def directory(self, parts, create=False):
        descriptor = os.dup(self.descriptor)
        try:
            for part in parts:
                if create:
                    try: os.mkdir(part, mode=0o700, dir_fd=descriptor)
                    except FileExistsError: pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                dir_fd=descriptor)
                os.close(descriptor); descriptor = child
            return descriptor
        except BaseException as error:
            os.close(descriptor)
            if isinstance(error, OSError):
                raise ValueError('Seed directory is unavailable or redirects through a link: ' + '/'.join(parts)) from error
            raise

    def parent(self, relative, create=False):
        path = PurePosixPath(relative)
        if path.is_absolute() or not path.parts or any(part in ['', '.', '..'] for part in relative.split('/')):
            raise ValueError('Unsafe seed entry path.')
        parent = path.parent.as_posix()
        with self.lock:
            if parent == '.': return os.dup(self.descriptor), path.name
            if parent in self.directories:
                descriptor = self.directories.pop(parent)
            else:
                descriptor = self.directory(path.parts[:-1], create)
                identity = self.identity(os.fstat(descriptor))[:2]
                if parent in self.bindings and self.bindings[parent] != identity:
                    os.close(descriptor)
                    raise ValueError('Seed directory changed during verification: ' + parent)
                self.bindings[parent] = identity
            self.directories[parent] = descriptor
            if len(self.directories) > 16: os.close(self.directories.popitem(last=False)[1])
            return os.dup(descriptor), path.name

    @staticmethod
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def open(self, relative):
        parent, name = self.parent(relative)
        try:
            descriptor = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        except OSError as error:
            raise ValueError('Seed file is unavailable or redirects through a link: ' + relative) from error
        finally: os.close(parent)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise ValueError('Snapshot entry is not a regular file.')
        return descriptor

    def digest(self, relative):
        descriptor = self.open(relative)
        try:
            before = self.identity(os.fstat(descriptor))
            with self.lock: digest = self.digests.get(before)
            if digest is None:
                value = hashlib.sha256()
                while block := os.read(descriptor, min(1_048_576, before[2] + 1)): value.update(block)
                digest = value.hexdigest()
                with self.lock:
                    self.digests[before] = digest
                    self.hashed_bytes += before[2]
            if before != self.identity(os.fstat(descriptor)):
                raise ValueError('Seed file changed while hashing: ' + relative)
            return digest, before[2]
        finally: os.close(descriptor)


def seed_file_work(entries, work):
    # Small file batches amortize Python scheduling; retain at most 32 futures.
    def batch(items):
        for item in items: work(item)
    with ThreadPoolExecutor(max_workers=8) as workers:
        for offset in range(0, len(entries), 1024):
            list(workers.map(batch, [entries[i:min(i + 32, offset + 1024)]
                                    for i in range(offset, min(offset + 1024, len(entries)), 32)]))


def verify_snapshot_files(source, entries):
    """Verify regular manifest entries with independent byte and inode proofs."""
    with SeedFileTree(source) as tree:
        def verify(entry):
            name, digest, size, _ = entry
            if tree.digest(name) != (digest, size):
                raise ValueError('Snapshot entry hash/size mismatch: ' + name)
        seed_file_work(entries, verify)
        return {'entries': len(entries), 'hashed_bytes': tree.hashed_bytes, 'distinct_inodes': len(tree.digests), 'workers': 8}


def copy_snapshot_files(source, destination, entries):
    """Copy already verified regular entries, then independently hash the copy."""
    library = ctypes.CDLL(None, use_errno=True) if sys.platform == 'darwin' else None
    clone = getattr(library, 'fclonefileat', None)
    if clone is not None:
        clone.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        clone.restype = ctypes.c_int
    with SeedFileTree(source) as original, SeedFileTree(destination) as copied:
        def copy(entry):
            name, digest, size, descriptor = entry
            relative = descriptor['relativePath'] if descriptor else 'checklist.sqlite'
            parent, leaf = copied.parent(relative, create=True)
            source_file = None
            try:
                source_file = original.open(name)
                before = original.identity(os.fstat(source_file))
                cloned = clone is not None and clone(source_file, parent, os.fsencode(leaf), 0) == 0
                if not cloned:
                    output = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                                     0o600, dir_fd=parent)
                    with os.fdopen(output, 'wb') as target, os.fdopen(os.dup(source_file), 'rb') as stream:
                        info = os.fstat(output)
                        if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) == before[:2]:
                            raise ValueError('Copy target is not an independent regular file.')
                        os.ftruncate(output, 0)
                        shutil.copyfileobj(stream, target, 1_048_576)
                target = copied.open(relative)
                try: os.fchmod(target, 0o700 if descriptor and descriptor['executable'] else 0o600)
                finally: os.close(target)
                if before != original.identity(os.fstat(source_file)):
                    raise ValueError('Seed file changed while copying: ' + name)
                if copied.digest(relative) != (digest, size): raise ValueError('Copy verification failed.')
            finally:
                if source_file is not None: os.close(source_file)
                os.close(parent)
        seed_file_work(entries, copy)


def snapshot_seed(source, destination, destination_root=None, current_schema=None):
    """current_schema is the staged build's (create passes it); the default reads this source tree."""
    if current_schema is None: current_schema = storage_schema(REPO / SCHEMA_SOURCE)
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
    if manifest['format'] not in [1, 2] or manifest['kind'] != 'checklist-store-snapshot':
        raise ValueError('Unsupported snapshot format/schema.')
    supported_schema(manifest['schema'], current_schema, 'snapshot')
    uuid.UUID(manifest['storeID']); uuid.UUID(manifest['operationID'])
    contained(source / 'intent.json', source)
    intent = json.loads((source / 'intent.json').read_text())
    if intent != {'format': str(manifest['format']), 'kind': manifest['kind'], 'operation_id': manifest['operationID'],
                  'store_id': manifest['storeID'], 'source_root': manifest['sourceRoot']}:
        raise ValueError('Snapshot publication intent does not match its manifest.')
    expected = {'database.sqlite', 'intent.json', 'manifest.json'}
    entries = [('database.sqlite', manifest['databaseSHA256'], manifest['databaseSize'], None)]
    for entry in snapshot_objects(manifest):
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
    links, regular = {}, []
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
            if descriptor and descriptor['kind'] != 'file':
                raise ValueError('Snapshot entry is not a regular file.')
            regular.append((name, digest, size, descriptor))
            valid = True
        if not valid or (descriptor and (descriptor.get('expectedSHA256') not in [None, digest] or descriptor.get('expectedSize') not in [None, size])):
            raise ValueError('Snapshot entry hash/size mismatch: ' + name)
    for name in links:
        visited = set()
        while name in links:
            if name in visited or len(visited) >= 32: raise ValueError('Captured link cycle.')
            visited.add(name); name = links[name]
        if name not in expected: raise ValueError('Captured link target is absent.')
    verify_snapshot_files(source, regular)
    observation = database_observation(source / 'database.sqlite')
    if observation['quick_check'] != 'ok' or observation['schema'] != manifest['schema']:
        raise ValueError('Snapshot database integrity/schema mismatch.')
    if 'recordFamilies' in manifest:
        counts = manifest['recordFamilies']
        if not isinstance(counts, dict) or any(type(n) is not int or n < 0 for n in counts.values()) or {k: n for k, n in counts.items() if n} != observation['record_counts']:
            raise ValueError('Snapshot canonical family counts mismatch.')
    if 'tableRows' in manifest and manifest['tableRows'] != observation['table_rows']:
        raise ValueError('Snapshot table counts mismatch.')
    live_snapshot = is_live_snapshot(source, manifest['sourceRoot'])
    summary_source_root = manifest['sourceRoot'] if live_snapshot else None
    inspection = require_local_paths(source / 'database.sqlite', destination_root or destination,
                                     source_root=manifest['sourceRoot'], summary_source_root=summary_source_root)
    source_summary_paths = inspection.pop('source_summary_paths', {})
    # Verification finishes before any source byte is used in the new store.
    copy_snapshot_files(source, destination, regular)
    for name, digest, size, descriptor in entries[1:]:
        if descriptor['kind'] != 'symlink': continue
        target = destination / descriptor['relativePath']
        contained(target.parent, destination)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if descriptor['kind'] == 'symlink':
            target.symlink_to(descriptor['linkTarget'])
    require_local_paths(destination / 'checklist.sqlite', destination_root or destination,
                        source_root=manifest['sourceRoot'], summary_source_root=summary_source_root,
                        summary_source_paths=source_summary_paths)
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
            'live_snapshot': live_snapshot, 'path_inspection': inspection, 'source_summary_paths': source_summary_paths,
            'current_schema_no_migration': observation['schema'] == current_schema}


def restored_inventory(root):
    """Hash only owned candidate entries; never follow a link out of a capture."""
    inventory, links = [], {}
    fixed = {'checklist.sqlite', 'checklist-store.identity.json', 'restore-receipt.json'}
    for folder, directories, files in os.walk(root, followlinks=False):
        for name in sorted(directories + files):
            file = Path(folder) / name
            info = file.lstat()
            if info.st_uid != os.getuid(): raise ValueError('Restored root entries must belong to the current user.')
            relative = file.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                if relative.split('/')[0] not in ['objects', 'source-captures', 'staging', 'icons', 'source-executions', 'source-build-cache']:
                    raise ValueError('Unexpected restored directory: ' + relative)
                continue
            if relative not in fixed: relative_path(relative)
            if stat.S_ISLNK(info.st_mode):
                parts = PurePosixPath(relative).parts
                target = os.readlink(file)
                if len(parts) < 5 or parts[0] != 'source-captures' or parts[3] != 'source' or target.startswith('/'):
                    raise ValueError('Unsafe restored capture link: ' + relative)
                # Same confinement and terminal-file proof as snapshot seeds.
                resolved = list(parts[:-1])
                for part in target.split('/'):
                    if part == '..':
                        if len(resolved) <= 4: raise ValueError('Restored link escapes its capture.')
                        resolved.pop()
                    elif part not in ['', '.']: resolved.append(part)
                links[relative] = '/'.join(resolved)
                digest = hashlib.sha256(target.encode()).hexdigest()
                size = len(target.encode())
                kind = 'symlink'
            elif stat.S_ISREG(info.st_mode):
                digest, size, kind = None, info.st_size, 'file'
            else: raise ValueError('Restored root contains a special file.')
            inventory.append([relative, kind, digest, size, bool(info.st_mode & 0o111) if kind == 'file' else False])
    regular = {entry[0] for entry in inventory if entry[1] == 'file'}
    for name in links:
        visited = set()
        while name in links:
            if name in visited or len(visited) >= 32: raise ValueError('Restored capture link cycle.')
            visited.add(name); name = links[name]
        if name not in regular: raise ValueError('Restored capture link target is absent.')
    with SeedFileTree(root) as tree:
        def verify(entry):
            digest, size = tree.digest(entry[0])
            if size != entry[3]: raise ValueError('Restored file changed while hashing.')
            entry[2] = digest
        seed_file_work([entry for entry in inventory if entry[1] == 'file'], verify)
    return sorted(inventory)


def restored_source_manifest(source, receipt, schema):
    """Recover origin only from the exact manifest verified by the product restore.

    Format-1 restore receipts do not embed sourceRoot. Search only published
    backups of the restoring installation and the configured/default live root;
    neither database summaries nor stored managed paths choose a file to open.
    """
    for root in sorted({source.parent.parent, LIVE, DEFAULT_LIVE}):
        for pattern in ['snapshot-*/manifest.json', 'qualification-*/snapshot-*/manifest.json']:
            for file in sorted((root / 'backups').glob(pattern)):
                try:
                    contained(file, root / 'backups')
                    if not file.is_file() or file.stat().st_size > 128 * 1_048_576: continue
                    with file.open('rb') as stream: raw = stream.read(128 * 1_048_576 + 1)
                except (OSError, ValueError):
                    continue
                if len(raw) > 128 * 1_048_576 or hashlib.sha256(raw).hexdigest() != receipt['manifest_sha256']: continue
                manifest = json.loads(raw)
                origin = manifest.get('sourceRoot')
                if (manifest.get('format') not in [1, 2] or manifest.get('kind') != 'checklist-store-snapshot'
                        or manifest.get('schema') != schema or manifest.get('storeID') != receipt['source_store_id']
                        or not isinstance(origin, str) or not origin.startswith('/') or '\0' in origin
                        or any(part in ['', '.', '..'] for part in origin.split('/')[1:])):
                    raise ValueError('Restored source manifest does not match its validation receipt.')
                return file, origin
    return None, str(source)  # Preserve strict admission for self-contained legacy candidates.


def restored_seed(source, destination, destination_root=None, current_schema=None):
    """current_schema is the staged build's (create passes it); the default reads this source tree."""
    if current_schema is None: current_schema = storage_schema(REPO / SCHEMA_SOURCE)
    source = source.expanduser().absolute()
    contained(source, source)
    # Candidate bytes must be disposable; origin proof may read published backup manifests.
    if any(paths_overlap(source, live) for live in {LIVE, DEFAULT_LIVE}):
        raise ValueError('Restored seed must not overlap the live data root; use a disposable restore.')
    if source.parent.name != 'restore' or not re.fullmatch(r'restored-[0-9a-f]{32}', source.name):
        raise ValueError('Restored seed must be a product-published restore/restored-<job> folder.')
    receipt_file = contained(source / 'restore-receipt.json', source)
    if not receipt_file.is_file() or receipt_file.stat().st_size > 16_384:
        raise ValueError('Restored root has no complete product validation receipt.')
    receipt_bytes = receipt_file.read_bytes()
    try:
        receipt = json.loads(receipt_bytes)
        if receipt['format'] != 1 or receipt['state'] != 'complete' or receipt['dispatch'] != 'quarantined':
            raise ValueError('Restore validation receipt is not complete and quarantined.')
        for key in ['command_id', 'source_store_id', 'incarnation']: uuid.UUID(receipt[key])
        for key in ['intent_digest', 'manifest_sha256', 'database_sha256']:
            if not re.fullmatch(r'[0-9a-f]{64}', receipt[key]): raise ValueError('Invalid restore receipt hash.')
        if not receipt['principal'] or not receipt['restored_at']: raise ValueError('Incomplete restore receipt.')
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError('Invalid product restore validation receipt: ' + str(error)) from error
    before = restored_inventory(source)
    if not any(entry[0] == 'restore-receipt.json' and entry[2] == hashlib.sha256(receipt_bytes).hexdigest() for entry in before):
        raise ValueError('Restore validation receipt changed during inspection.')
    database = source / 'checklist.sqlite'
    if sha(database) != receipt['database_sha256']:
        raise ValueError('Restored database differs from its validation receipt.')
    observation = database_observation(database)
    identity_file = contained(source / 'checklist-store.identity.json', source)
    identity = json.loads(identity_file.read_bytes())
    # Product restores publish only the restoring build's schema; restore receipts and
    # instance-local managed paths exist from schema 3, so older candidates never occur.
    supported_schema(observation['schema'], current_schema, 'restored database')
    if (not isinstance(identity, dict) or observation['schema'] < 3 or observation['quick_check'] != 'ok' or observation['identity'] != identity
            or identity.get('format_version') != 1 or identity.get('state') != 'ready'
            or identity.get('schema_revision') != observation['schema'] or identity.get('database_generation') != 1
            or identity.get('logical_store_id') != receipt['source_store_id'] or identity.get('incarnation') != receipt['incarnation']):
        raise ValueError('Restored database/identity does not match its validation receipt.')
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro&immutable=1', uri=True)) as connection:
        connection.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
        values = dict(connection.execute("SELECT key,value FROM metadata WHERE key IN ('incarnation','restore_receipt')"))
    if (values.get('incarnation') != receipt['incarnation']
            or json.loads(values.get('restore_receipt', '{}')) != {k: v for k, v in receipt.items() if k != 'database_sha256'}):
        raise ValueError('Restored database has no matching authority-fencing receipt.')
    source_manifest, source_root = restored_source_manifest(source, receipt, observation['schema'])
    # Display-only summaries get the backup: seed's exception only from a live-origin snapshot.
    live_snapshot = source_manifest is not None and is_live_snapshot(source_manifest.parent, source_root)
    summary_source_root = source_root if live_snapshot else None
    inspection = require_local_paths(database, destination_root or destination, source_root=source_root,
                                     summary_source_root=summary_source_root)
    source_summary_paths = inspection.pop('source_summary_paths', {})
    shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)
    if restored_inventory(destination) != before or restored_inventory(source) != before:
        raise ValueError('Restored root copy verification failed or source changed.')
    require_local_paths(destination / 'checklist.sqlite', destination_root or destination, source_root=source_root,
                        summary_source_root=summary_source_root, summary_source_paths=source_summary_paths)
    return {'kind': 'restored', 'source': str(source), 'source_root': source_root,
            'source_manifest': str(source_manifest) if source_manifest is not None else None, 'live_snapshot': live_snapshot,
            'source_summary_paths': source_summary_paths,
            'restore_job': receipt['command_id'], 'manifest_sha256': receipt['manifest_sha256'],
            'database_sha256': receipt['database_sha256'], 'receipt_sha256': hashlib.sha256(receipt_bytes).hexdigest(),
            'source_hash': hashlib.sha256(json.dumps(before).encode()).hexdigest(),
            'age_seconds_at_create': max(0, time.time() - receipt_file.stat().st_mtime),
            'before_start': observation, 'path_inspection': inspection,
            'current_schema_no_migration': observation['schema'] == current_schema}


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
                    ignore=lambda folder, names: {'connections.json', 'OwnerPrivate'} if Path(folder) == source else set())
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
    session = caller_session(getattr(arguments, 'session_id', None))
    # CL-359: a slot store copy is registered with its tickets before anything changes.
    tickets = requested_tickets(getattr(arguments, 'tickets', None))
    stopped(p)
    if p['folder'].exists():
        if not arguments.replace: raise ValueError('Slot exists; use --replace after stopping it.')
        load(p)  # Do not replace unrelated directories.
    capture, manifest = stage_selection(arguments)
    identity = sign_identity(manifest)
    validate_fingerprint(manifest['source_fingerprint'])
    with ExitStack() as preparation:
        prepared = None
        if arguments.seed.startswith('restored:'):
            current_schema = require_managed_path_support(capture, manifest)
            # Keep the verified copy outside the replaced folder. Its source may
            # be that slot's own restore/ candidate; replacement must happen last.
            temporary = preparation.enter_context(tempfile.TemporaryDirectory(prefix='.restored-seed-', dir=BASE))
            prepared = Path(temporary) / 'data'; prepared.mkdir(mode=0o700)
            restored = restored_seed(Path(arguments.seed[9:]), prepared, p['data'], current_schema)
        if p['folder'].exists(): destroy(p)
        p['folder'].mkdir(mode=0o700)
        mark_qualification(p['folder'], manifest['source_fingerprint'],
                           'disposable test slot ' + str(arguments.slot), session, tickets=tickets)
        metadata = {'slot': arguments.slot, 'tickets': tickets, 'build_id': manifest['build_id'], 'source_fingerprint': manifest['source_fingerprint'],
                    'stage_path': str(capture), 'seed': {'kind': 'incomplete'}, 'created_at': now(), 'mode': 'incomplete', 'checks': None}
        save(p, metadata)
        pending = contained(p['folder'] / '.seed-data', p['folder'])
        if prepared is not None: prepared.rename(pending)
        else: pending.mkdir(mode=0o700)
        try:
            if arguments.seed != 'empty': current_schema = require_managed_path_support(capture, manifest)
            seed = {'kind': 'empty', 'source_hash': None, 'age_seconds_at_create': 0}
            if prepared is not None:
                seed = restored
            elif arguments.seed == 'latest-backup':
                seed = snapshot_seed(latest_backup(), pending, p['data'], current_schema)
            elif arguments.seed.startswith('backup:'):
                seed = snapshot_seed(Path(arguments.seed[7:]), pending, p['data'], current_schema)
            elif arguments.seed.startswith('slot:'):
                seed = slot_seed(checked(slot_number(arguments.seed[5:])), pending, p['data'])
            elif arguments.seed != 'empty': raise ValueError('Seed must be empty, latest-backup, backup:PATH, restored:PATH or slot:M.')
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


def restage_qualification(metadata, capture=None, manifest=None, commit=None, reply=None):
    previous = metadata.get('restage') or {}
    origin_path = previous.get('seeded_stage_path', metadata['stage_path'])
    origin_capture, origin_manifest = verify_stage(origin_path)
    if previous and (origin_manifest['build_id'] != previous['seeded_build_id']
                     or origin_manifest['source_fingerprint'] != previous['seeded_source_fingerprint']):
        raise ValueError('Original seeded stage identity changed. ' + FRESH_COPY)
    if capture is None: capture, manifest = verify_stage(metadata['stage_path'])
    completion = previous.get('seed_completion')
    if completion is None:
        if reply is None: raise ValueError('Reuse needs the saved backup_create reply for the seed; supply --backup-reply. ' + FRESH_COPY)
        completion = backup_completion(reply)
    return reuse_proof(REPO, LIVE, metadata['seed'], origin_capture, origin_manifest,
                       capture, manifest, previous.get('seeded_commit') or commit or origin_manifest.get('source_commit'),
                       completion, lambda: storage_schema(Path(capture) / 'source' / SCHEMA_SOURCE))


def restage(arguments, p):
    session = caller_session(getattr(arguments, 'session_id', None))
    stopped(p)
    metadata = load(p)
    marker = read_marker(p['folder'])
    if not marker or marker['session_id'] != session or marker['released']:
        raise ValueError('Restage requires the active owning session of this slot.')
    if metadata['mode'] in ['incomplete', 'refused', 'restaging']:
        raise ValueError('Incomplete slot cannot be restaged. ' + FRESH_COPY)
    bundle_check(p, metadata)
    capture, manifest = stage_selection(arguments)
    require_managed_path_support(capture, manifest)
    reply = getattr(arguments, 'backup_reply', None)
    proof = restage_qualification(metadata, capture, manifest, getattr(arguments, 'seeded_commit', None), reply)
    identity = sign_identity(manifest)
    target = dict(metadata, build_id=manifest['build_id'], source_fingerprint=manifest['source_fingerprint'],
                  stage_path=str(capture), mode='stopped', checks=None, restage=proof, restaged_at=now())
    # Prepare and verify before publishing. Never copy, rewrite or remove data/.
    with tempfile.TemporaryDirectory(prefix='.restage-', dir=p['folder']) as temporary:
        incoming = Path(temporary) / p['bundle'].name
        run(['ditto', capture / 'Checklist.app', incoming])
        info_file = incoming / 'Contents/Info.plist'
        info_file.write_bytes(plistlib.dumps(rewrite_info(plistlib.loads(info_file.read_bytes()), arguments.slot)))
        agents = incoming / 'Contents/Library/LaunchAgents'
        if agents.exists(): shutil.rmtree(contained(agents, p['folder']))
        run(['codesign', '--force', '--sign', identity, '--timestamp=none', '--identifier', p['identifier'], incoming])
        bundle_check(dict(p, bundle=incoming), target)
        # Recheck freshness after potentially slow signing, before any publication.
        if restage_qualification(metadata, capture, manifest, proof['seeded_commit'], reply) != proof:
            raise ValueError('Restage qualification changed. ' + FRESH_COPY)
        save(p, dict(metadata, mode='restaging', checks=None))
        previous = Path(temporary) / 'previous.app'
        p['bundle'].rename(previous)
        try:
            incoming.rename(p['bundle'])
            mark_qualification(p['folder'], manifest['source_fingerprint'],
                               'disposable test slot ' + str(arguments.slot), session, tickets=marker['tickets'])
            save(p, target)
        except BaseException:
            # A failed metadata publication stays fenced as restaging, with no
            # passing checks; restore the old bundle for explicit reconciliation.
            if p['bundle'].exists(): p['bundle'].rename(incoming)
            previous.rename(p['bundle'])
            raise
    print('Restaged slot ' + str(arguments.slot) + ': ' + proof['reason'] + '; checks cleared.')


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
    last_upgrade = None;last_status = 'no status call finished'
    command = [p['bundle'] / 'Contents/MacOS/checklist', 'service', 'status']
    def expired():
        raise ValueError(f'Slot {number} startup deadline expired after {bound:g} seconds; '
                         'the slot service keeps running its protected startup. '
                         f'Run start --slot {number} again to keep waiting, '
                         f'or status --slot {number} to inspect it; '
                         'destroying the slot during a protected snapshot discards that work. '
                         'Last status: ' + last_status)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0: expired()
        try: result = run(command, timeout=min(30, remaining), check=False)
        except subprocess.TimeoutExpired as error:
            last_status = f'no reply within {error.timeout:g} seconds'
        else:
            last_status = describe_status(result)
            try: payload = json.loads(result.stdout)
            except (ValueError, TypeError):
                if not status_still_starting(result):
                    raise ValueError('Slot service returned invalid status: ' + last_status)
            else:
                body = payload.get('data', payload) if isinstance(payload, dict) else None
                if not isinstance(body, dict): raise ValueError('Slot service returned invalid status: ' + last_status)
                states = [payload.get('state'), body.get('state')]
                if any(state not in [None, 'ready', 'running', 'healthy', 'starting', 'unavailable', 'upgrading'] for state in states):
                    raise ValueError('Slot service reported an error state: ' + result.stdout)
                errors = [value['error'] for value in [payload, body] if 'error' in value]
                if any(not isinstance(error, dict) or error.get('code') not in ['SERVICE_UNAVAILABLE', 'UNAVAILABLE', 'STORAGE_UPGRADING'] for error in errors):
                    raise ValueError('Slot service returned an error status: ' + result.stdout)
                upgrade = upgrading_status(payload)
                if upgrade is not None:
                    message = upgrading_message(upgrade)
                    if message != last_upgrade:
                        print(f'slot {number}: {message}.', file=sys.stderr, flush=True)
                        last_upgrade = message
                if not errors and upgrade is None and not any(state in ['starting', 'unavailable', 'upgrading'] for state in states):
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
    if metadata['seed']['kind'] not in ['empty', 'backup', 'slot', 'restored'] or metadata['mode'] in ['incomplete', 'refused', 'restaging']:
        raise ValueError('Slot creation did not complete: ' + metadata['seed'].get('reason', 'incomplete seed'))
    manifest = bundle_check(p, metadata)
    if metadata['seed']['kind'] != 'empty':
        require_managed_path_support(Path(metadata['stage_path']), manifest)
        seed = metadata['seed']
        # Recorded paths only; a restored seed made before CL-276 r1 has no live_snapshot field.
        source_summaries = (seed['kind'] == 'backup' and seed.get('live_snapshot')) or (
            seed['kind'] == 'restored' and seed.get('source_manifest') is not None
            and is_live_snapshot(Path(seed['source_manifest']).parent, seed.get('source_root')))
        summary_source_root = seed.get('source_root') if source_summaries else None
        require_local_paths(p['data'] / 'checklist.sqlite', p['data'], immutable=False, source_root=seed.get('source_root'),
                            summary_source_root=summary_source_root, summary_source_paths=seed.get('source_summary_paths', {}))
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
        command = ['open', '-n', p['bundle']]
        if getattr(arguments, 'appearance', None):
            command += ['--args', '-ChecklistTestAppearance', arguments.appearance]
        run(command)
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


def destroy(p, *, unused_only=False):
    match = re.fullmatch(r'slot-([1-4])', p['folder'].name)
    if not match or p != paths(int(match[1])):
        raise ValueError('Refusing mismatched slot cleanup identity.')
    number = int(match[1])
    def require_unused():
        from clean_scratch import running_paths, within
        stopped(p)
        if any(within(path, p['folder'].resolve()) for path in running_paths()):
            raise ValueError('Slot is used by a running app or check; retain it.')
    if unused_only: require_unused()
    else: stop(p)
    if p['folder'].exists(): load(p)

    preferences = Path.home() / 'Library/Preferences'
    contained(preferences, preferences)
    window_uuid = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    domain_rule = re.compile(fr'(?:org\.checklist\.app\.test{number}|Checklist\.Test{number}\.Workspace\.{window_uuid})')
    domains = {p['identifier']}  # Also delete a cached standard domain with no plist yet.
    # Only this slot's own suites match; no other domain's file is opened or changed (CL-379).
    domains.update(file.stem for file in preferences.glob(f'Checklist.Test{number}.Workspace.*.plist')
                   if domain_rule.fullmatch(file.stem))
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

    # CL-379: destroy makes no Keychain call. Slots keep credentials in private files in the slot folder.
    receipt = {'slot': number, 'keychain': 'not touched; a leftover item of an older slot is ignored',
               'preference_domains_removed': [],
               'preference_domains_missing': [], 'trashed': []}
    if unused_only: require_unused()
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
            if unused_only: require_unused()
            trash(folder, root)
            receipt['trashed'].append(str(folder))
    receipt['preference_domains_removed_count'] = len(receipt['preference_domains_removed'])
    receipt['trashed_count'] = len(receipt['trashed'])
    print('Destroy receipt: ' + json.dumps(receipt, sort_keys=True))
    return receipt


def promotion_gates(selected, slots):
    def passed(value):
        checks = value.get('checks') or {}
        return value.get('mode') not in ['incomplete', 'refused', 'restaging'] and value.get('seed', {}).get('kind') not in ['incomplete', 'refused'] and checks.get('passed') is True and checks.get('build_id') == selected['build_id'] and checks.get('source_fingerprint') == selected['source_fingerprint'] and value.get('build_id') == selected['build_id'] and value.get('source_fingerprint') == selected['source_fingerprint']
    def live_qualified(value):
        if not (passed(value) and value.get('seed', {}).get('kind') == 'backup' and value['seed'].get('live_snapshot') is True): return False
        if value.get('restage') is not None:
            try:
                proof = restage_qualification(value)
                if proof != value['restage']: return False
                print('Restaged live-backup qualification: ' + proof['reason'] + '. Proof: ' + json.dumps(proof, sort_keys=True))
            except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
                print('Restaged live-backup qualification refused: ' + str(error))
                return False
        return True
    return {'selected_build_check': passed(selected),
            'live_snapshot_check_same_build': any(live_qualified(value) for value in slots)}


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
    for gate, passed in gates.items(): print(f'{gate}: {"PASS" if passed else "FAIL"}', flush=True)
    command = [str(REPO / 'script/build_and_run.sh'), '--install-stage', selected['stage_path']]
    print('Planned action: ' + json.dumps(command), flush=True)
    if not gates['live_snapshot_check_same_build']:
        print('Missing live-backup qualification: run a same-build live-backup-seeded slot check.')
    if not all(gates.values()): raise ValueError('Promotion refused: all gates must pass, including a live-backup-seeded check of this build. ' + RELOCATION_REQUIRED)
    if not arguments.dry_run:
        print('Promotion: installer will print the expected offline window before stopping the service and the measured window after its first healthy answer.', flush=True)
        install_started = time.time()
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as error:
            raise ValueError('Promotion: install ran; installed verification failed.\n' + failure_guidance(install_started)) from error
        print('Promoted build ' + selected['build_id'] + '; installed app and service verification passed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['create', 'restage', 'start', 'status', 'check', 'stop', 'destroy', 'promote']:
        command = commands.add_parser(name)
        command.add_argument('--slot', type=slot_number, required=name in ['create', 'restage', 'start', 'check', 'promote'])
        if name in ['stop', 'destroy']: command.add_argument('--all', action='store_true')
        if name == 'status': command.add_argument('--json', action='store_true')
        if name == 'restage':
            command.add_argument('--stage', type=Path, required=True)
            command.add_argument('--session-id', help='actual owning session')
            command.add_argument('--seeded-commit', help='full known commit of original seeded capture (verified against all inputs)')
            command.add_argument('--backup-reply', type=Path, help="saved backup_create or operation_get reply for the slot's seed; needed on the first restage of a slot")
        if name == 'create':
            source = command.add_mutually_exclusive_group()
            source.add_argument('--stage', type=Path); source.add_argument('--latest-stage', action='store_true')
            command.add_argument('--session-id', help='actual owning session when no native host ID is exported')
            command.add_argument('--ticket', dest='tickets', action='append', metavar='KEY',
                                 help='owning ticket key (repeatable; or CHECKLIST_TICKETS=CL-1,CL-2); required')
            command.add_argument('--seed', type=seed_value, default='empty'); command.add_argument('--replace', action='store_true')
        if name == 'check':
            command.add_argument('--destroy-after-check', action='store_true',
                                 help='bounded owned check: print evidence, then stop and destroy this slot even on failure')
        if name == 'start':
            mode = command.add_mutually_exclusive_group()
            mode.add_argument('--headless', action='store_true'); mode.add_argument('--gui', action='store_true')
            command.add_argument('--appearance', choices=['dark', 'light'], help='force test app appearance (requires --gui)')
        if name == 'promote': command.add_argument('--dry-run', action='store_true')
    arguments = parser.parse_args()
    if arguments.command == 'start' and arguments.appearance and not arguments.gui:
        parser.error('--appearance requires --gui.')
    if arguments.command == 'restage':
        arguments.session_id = caller_session(arguments.session_id)
    if arguments.command == 'create':
        # Identity first, then every source/destination's live-root admission, then locks/changes.
        arguments.session_id = caller_session(arguments.session_id)
        arguments.tickets = requested_tickets(arguments.tickets)
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
            elif arguments.command == 'restage': restage(arguments, p)
            elif arguments.command == 'start': start(arguments, p)
            elif arguments.command == 'check':
                try: check(p)
                finally:
                    if arguments.destroy_after_check:
                        print('Bounded check evidence: ' + json.dumps(load(p), sort_keys=True))
                        destroy(p)
            elif arguments.command == 'stop': stop(p)
            elif arguments.command == 'destroy': destroy(p)
            elif arguments.command == 'promote': promote(arguments, p)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, sqlite3.Error) as error:
        print('test_instances: ' + str(error), file=sys.stderr)
        sys.exit(1)
