#!/usr/bin/env python3
"""Preview Checklist scratch cleanup; --apply moves eligible bytes to the Trash.

Logical byte counts are not a promise of recovered disk space (APFS/sparse files).
Session cleanup preserves unique evidence and Git metadata. Released fingerprinted
qualification runs retire whole after their evidence is preserved externally.
"""
import argparse
import ctypes
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from publication_lock import PublicationBusy, SCRATCH_WAIT_SECONDS, publication_lock
from retire_old_bundles import previous_timestamp

REPO = Path(__file__).resolve().parents[1]
BUILD_NAMES = {'.build', 'CompilationCache.noindex', 'CompilationCache', 'module-cache'}
QUIET_SECONDS = 45 * 60
UNMARKED_AGE_SECONDS = 7 * 24 * 60 * 60
WORKSPACE_MARKER = '.checklist-workspace.json'
BUILD_IDENTITY_NAMES = {'capture-manifest.json', 'build-info.json', 'source-manifest.json', WORKSPACE_MARKER}
RETIRING_NAME = re.compile(r'^\.(?:.*\.)?checklist-retiring-[0-9a-f]{32}$', re.DOTALL)
TICKET = re.compile(r'[A-Z][A-Z0-9]*-\d+')
# Status categories that end a ticket's work; its registered folders may retire (CL-359).
FINISHED = {'done', 'canceled', 'cancelled'}
DEFAULT_BUDGET_GB = 50.0
# Bound planning and preparation independently of the per-path move checks.
ITEM_BATCH_SIZE = 32
MOVE_BATCH_SIZE = 256
MOVE_BATCH_BYTES = 64 * 1024
# Preview plans items in threads: lstat/scandir/hash release the GIL (CL-359 speed).
PREVIEW_WORKERS = 8


class ScratchTrash:
    """Prepare same-volume Trash paths before validation and rename in process."""

    def __init__(self):
        self.test_directory = os.environ.get('CHECKLIST_TRASH_DIR')
        if self.test_directory == '':
            raise ValueError('CHECKLIST_TRASH_DIR must name a temporary Trash folder.')
        self.directories = {}
        self.rename = ctypes.CDLL(None, use_errno=True).renamex_np
        self.rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        self.rename.restype = ctypes.c_int

    def directory(self, path, directory, *, create=True):
        if self.test_directory is not None:
            result = Path(self.test_directory).expanduser().resolve()
            result.mkdir(parents=True, exist_ok=True)
            return result

        # Use the system Trash lookup so external volumes use their own Trash.
        # Resolve the destination before observing whether the move is safe.
        ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
        objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
        pointer = ctypes.c_void_p
        objc.objc_getClass.argtypes = objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.objc_getClass.restype = objc.sel_registerName.restype = pointer

        def message(receiver, selector, result, *arguments):
            types, values = zip(*arguments) if arguments else ((), ())
            send = ctypes.CFUNCTYPE(result, pointer, pointer, *types)(('objc_msgSend', objc))
            return send(receiver, objc.sel_registerName(selector), *values)

        pool_class = objc.objc_getClass(b'NSAutoreleasePool')
        pool = message(message(pool_class, b'alloc', pointer), b'init', pointer)
        try:
            url = message(objc.objc_getClass(b'NSURL'),
                          b'fileURLWithFileSystemRepresentation:isDirectory:relativeToURL:', pointer,
                          (ctypes.c_char_p, os.fsencode(path)), (ctypes.c_bool, directory), (pointer, None))
            manager = message(objc.objc_getClass(b'NSFileManager'), b'defaultManager', pointer)
            trash = message(manager, b'URLForDirectory:inDomain:appropriateForURL:create:error:', pointer,
                            (ctypes.c_ulong, 102), (ctypes.c_ulong, 1),  # NSTrashDirectory, NSUserDomainMask
                            (pointer, url), (ctypes.c_bool, create), (pointer, None))
            if not trash:
                raise OSError('could not locate Trash for ' + str(path))
            location = message(trash, b'fileSystemRepresentation', ctypes.c_char_p)
            if not location:
                raise OSError('Trash has no filesystem path for ' + str(path))
            return Path(os.fsdecode(location)).resolve()
        finally:
            message(pool, b'drain', None)

    def prepare(self, path, entry):
        device, _, mode = entry[:3]
        if device not in self.directories:
            directory = self.directory(path, stat.S_ISDIR(mode))
            if directory.stat().st_dev != device:
                raise ValueError('Trash is on a different volume; retained: ' + str(path))
            self.directories[device] = directory
        name = f'{path.stem}-{uuid.uuid4().hex}{path.suffix}'
        if len(os.fsencode(name)) > 255:
            name = uuid.uuid4().hex
        destination = self.directories[device] / name

        def move(source=path):
            self.rename_exclusive(source, destination)
            return destination

        return move

    def rename_exclusive(self, source, destination):
        # RENAME_EXCL | RENAME_NOFOLLOW_ANY. Neither replace a name nor follow
        # a substituted path component.
        if self.rename(os.fsencode(source), os.fsencode(destination), 0x04 | 0x10):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(source), None, str(destination))

    def stage(self, path):
        suffix = '.checklist-retiring-' + uuid.uuid4().hex
        name = '.' + path.name + suffix
        staged = path.with_name(name if len(os.fsencode(name)) <= 255 else suffix)
        self.rename_exclusive(path, staged)
        return staged


def move_batches(entries):
    batch, size = [], 0
    for entry in entries:
        length = len(os.fsencode(entry[1])) + 1
        if batch and (len(batch) >= MOVE_BATCH_SIZE or size + length > MOVE_BATCH_BYTES):
            yield batch
            batch, size = [], 0
        batch.append(entry)
        size += length
    if batch:
        yield batch


def within(path, parent):
    return path == parent or parent in path.parents


def overlap(left, right):
    return within(left, right) or within(right, left)


def git_objects(repo):
    # Only objects reachable in the retained repository count, never the private
    # copy's index, unpushed commits or a file name that merely looks tracked.
    output = subprocess.check_output(['git', '-C', str(repo), 'rev-list', '--objects', '--all'])
    return {line.split(b' ', 1)[0].decode('ascii') for line in output.splitlines()}


def blob_id(path):
    digest = hashlib.sha1()
    with path.open('rb') as source:
        digest.update(f'blob {os.fstat(source.fileno()).st_size}\0'.encode())
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def metadata_stamp(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)


def path_stamp(path, *, follow_symlinks=False):
    try:
        return metadata_stamp(os.stat(path, follow_symlinks=follow_symlinks))
    except FileNotFoundError:
        return None


def stamps_match(expected):
    return all(path_stamp(path) == value for path, value in expected.items())


def inventory(root):
    """lstat every entry, including directories; never walk through links.

    Pre-order with each directory's children sorted by name: the same keys,
    values and order as sorted(Path.iterdir()) recursion, but with os.scandir
    names and string paths (no pathlib sorting or per-call parsing; CL-359 speed).
    """
    result = {}
    lstat, scandir, is_dir = os.lstat, os.scandir, stat.S_ISDIR
    def visit(path, text):
        metadata = lstat(text)
        result[path] = metadata_stamp(metadata)
        if is_dir(metadata.st_mode):
            with scandir(text) as entries:
                names = sorted(entry.name for entry in entries)
            prefix = text if text.endswith('/') else text + '/'
            for name in names:
                visit(path / name, prefix + name)
    root = Path(root)
    visit(root, os.fspath(root))
    return result


def tree_summary(root):
    """(newest mtime/ctime in ns, logical bytes of non-directories) of a whole tree.

    The same values as from inventory(), without one path object and one dictionary
    row per entry (CL-376 speed). Links are never followed.
    """
    metadata = os.lstat(root)
    newest = max(metadata.st_mtime_ns, metadata.st_ctime_ns)
    if not stat.S_ISDIR(metadata.st_mode):
        return newest, metadata.st_size
    size, pending = 0, [os.fspath(root)]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                metadata = entry.stat(follow_symlinks=False)
                newest = max(newest, metadata.st_mtime_ns, metadata.st_ctime_ns)
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(entry.path)
                else:
                    size += metadata.st_size
    return newest, size


def running_paths():
    """Observe executable, cwd, open-file and absolute command argument paths.

    Failed process inspection refuses cleanup rather than treating unknown as idle.
    No process is launched, stopped or signaled by cleanup.
    """
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-u', str(os.getuid()), '-Fpn'],
                            capture_output=True, text=True)
    if result.returncode != 0 or result.stderr.strip():
        raise ValueError('process inspection incomplete: ' + result.stderr.strip())
    # lsof repeats shared executables/libraries for many processes. Resolve each
    # distinct path once; duplicates carry no extra use/protection information.
    paths = {line[1:] for line in result.stdout.splitlines() if line.startswith('n/')}
    commands = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    # Each distinct command line is parsed once (CL-376: many processes share one).
    for line in set(commands.splitlines()):
        for argument in command_arguments(line):
            value = argument.split('=', 1)[-1] if argument.startswith('-') else argument
            if value.startswith('/'):
                paths.add(value)
    return resolved_process_paths(paths)


def resolved_process_paths(paths):
    """Reuse parent resolution within one observation, including aliased arguments."""
    parents = {}
    resolved = []
    for raw in sorted(paths):
        path = Path(raw)
        parent = path.parent
        if parent not in parents:
            parents[parent] = parent.resolve()
        canonical = parents[parent] / path.name
        if path.name == '..':
            canonical = canonical.parent.parent
        elif canonical.is_symlink():
            canonical = canonical.resolve()
        resolved.append(canonical)
    return resolved


_SHELL_SYNTAX = re.compile(r'[\'"\\]')
_SHELL_SPACE = re.compile(r'[ \t\r\n]+')


def command_arguments(line):
    """The words of one ps command line, as shlex.split gives them.

    A line with no quote and no backslash splits at shlex's own whitespace set;
    the result is the same and needs no per-character parse (CL-376 speed).
    """
    if not _SHELL_SYNTAX.search(line):
        return [word for word in _SHELL_SPACE.split(line) if word]
    try:
        return shlex.split(line)
    except ValueError:
        # An unmatched quote is possible in a process title; lsof still
        # supplies cwd/executable/open files. Preserve absolute fragments.
        return line.split()


def used_items(processes, items):
    """The candidate roots that hold an observed path (the root itself or a path below it).

    One prefix test per observed path, in C (CL-376 speed): no pathlib parent
    objects for each of many thousand paths.
    """
    roots = {os.fspath(item): item for item in items}
    prefixes = {root: root.rstrip('/') + '/' for root in roots}
    below_any = tuple(prefixes.values())
    used = set()
    for path in processes:
        text = os.fspath(path)
        if text in roots:
            used.add(roots[text])
        if text.startswith(below_any):
            used.update(item for root, item in roots.items() if text.startswith(prefixes[root]))
    return used


def children(path):
    return sorted(path.iterdir()) if path.is_dir() and not path.is_symlink() else []


def read_marker(root):
    """None means absent; malformed/linked markers refuse cleanup, never release it."""
    path = root / WORKSPACE_MARKER
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 16384:
        raise ValueError('invalid workspace marker: ' + str(path))
    # Do not follow a marker swapped to a link after lstat.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'r') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('invalid workspace marker: ' + str(path))
        value = json.loads(source.read(16385))
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1
            or not isinstance(value.get('session_id'), str) or not value['session_id'].strip()
            or not isinstance(value.get('purpose'), str) or not value['purpose'].strip()
            or type(value.get('released')) is not bool):
        raise ValueError('invalid workspace marker: ' + str(path))
    if 'source_fingerprint' in value:
        validate_fingerprint(value['source_fingerprint'])
    for field in ('tickets', 'released_for_tickets'):
        if field in value:
            validate_tickets(value[field])
    return value


def validate_tickets(values):
    if (not isinstance(values, list) or not values
            or any(not isinstance(v, str) or not TICKET.fullmatch(v) for v in values)):
        raise ValueError('ticket keys must be a nonempty list of keys such as CL-10')
    return sorted(set(values))


OWNER_RECORD = 'owner.json'
TICKETS_ENVIRONMENT = 'CHECKLIST_TICKETS'
OWNER_KINDS = {'evidence', 'build', 'slot', 'qualification', 'work'}


def requested_tickets(values=None, environ=None):
    """Ticket keys for a new folder (CL-359 item 0): --ticket values, else the
    CHECKLIST_TICKETS comma list. A creating tool refuses a folder without keys."""
    environ = os.environ if environ is None else environ
    keys = [key for key in (values or []) if key]
    if not keys:
        keys = [key.strip() for key in environ.get(TICKETS_ENVIRONMENT, '').split(',') if key.strip()]
    if not keys:
        raise ValueError('register the new folder with its tickets: pass --ticket KEY (repeatable) '
                         'or set CHECKLIST_TICKETS=CL-1,CL-2')
    return validate_tickets(keys)


def read_owner_record(folder):
    """The owner.json registration of a folder: None when absent. A linked,
    oversized or malformed record raises; cleanup then retains the folder."""
    path = Path(folder) / OWNER_RECORD
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65536:
        raise ValueError('invalid owner record: ' + str(path))
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'r') as source:
        value = json.loads(source.read(65537))
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1
            or value.get('kind') not in OWNER_KINDS):
        raise ValueError('invalid owner record: ' + str(path))
    value['tickets'] = validate_tickets(value.get('tickets'))
    return value


def write_owner_record(folder, tickets, kind, purpose=None, session_id=None):
    """Register an existing folder with its tickets in owner.json. A later
    registration of the same kind adds keys (a shared build capture); another
    kind is refused. The write is atomic."""
    folder = Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('owner record needs an existing directory, not a link: ' + str(folder))
    if kind not in OWNER_KINDS:
        raise ValueError('owner kind must be one of ' + ', '.join(sorted(OWNER_KINDS)))
    tickets = validate_tickets(list(tickets or []))
    previous = read_owner_record(folder)
    if previous and previous['kind'] != kind:
        raise ValueError(f'{folder} is registered as {previous["kind"]}, not {kind}')
    stamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    value = dict(previous or {'version': 1, 'kind': kind, 'created_at': stamp})
    value['tickets'] = validate_tickets(sorted(set(tickets) | set((previous or {}).get('tickets', []))))
    value['updated_at'] = stamp
    if purpose:
        value['purpose'] = purpose
    if session_id:
        value['session_id'] = session_id
    with tempfile.NamedTemporaryFile(mode='w', dir=folder, prefix=OWNER_RECORD + '.', delete=False) as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
        temporary = Path(output.name)
    os.replace(temporary, folder / OWNER_RECORD)
    return value


def validate_fingerprint(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise ValueError('qualification source fingerprint must be 64 lowercase hexadecimal characters')
    return value


# The caller's own native session, in host order. Claude Code exports
# CLAUDE_CODE_SESSION_ID (CL-359 review 40f793e6); CLAUDE_SESSION_ID is kept for older hosts.
SESSION_VARIABLES = ('CODEX_THREAD_ID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_SESSION_ID', 'CHECKLIST_SESSION_ID')


def native_session(environ=None):
    environ = os.environ if environ is None else environ
    return next((environ[name] for name in SESSION_VARIABLES if environ.get(name)), None)


def caller_session(session_id=None):
    native = native_session()
    if native and session_id and native != session_id:
        raise ValueError('--session-id cannot override the host caller')
    value = native or session_id
    if not value or value in {'.', '..'} or '/' in value or not value.strip():
        raise ValueError('caller session unknown/invalid; supply your actual --session-id')
    return value


def mark_qualification(root, fingerprint, purpose, session_id=None, tickets=None):
    owner = caller_session(session_id)
    fingerprint = validate_fingerprint(fingerprint)
    with publication_lock('qualification marker'):
        return write_marker(root, owner, purpose, source_fingerprint=fingerprint, tickets=tickets)


def write_marker(root, session_id, purpose=None, release=False, source_fingerprint=None,
                 tickets=None, released_for_tickets=None):
    """Only the recorded owner marks/releases a workspace; interrupted writes keep safe."""
    if root.is_symlink() or not root.is_dir():
        raise ValueError('workspace must be an existing directory, not a link')
    root = root.resolve()
    # A filesystem session binding takes precedence over a supplied marker owner.
    scratchpad = next((p for p in root.parents if p.name == 'scratchpad'), None)
    if scratchpad and scratchpad.parent.name != session_id:
        raise ValueError('workspace belongs to another scratch session')
    previous = read_marker(root)
    if previous and previous['session_id'] != session_id:
        raise ValueError('only the owning session can change this workspace marker')
    if release and previous is None:
        raise ValueError('mark the workspace before releasing it')
    if not release and (not purpose or not purpose.strip()):
        raise ValueError('--mark requires a nonblank --purpose')
    value = dict(previous or {})
    value.update(version=1, session_id=session_id, purpose=previous['purpose'] if release else purpose)
    if source_fingerprint is not None:
        value['source_fingerprint'] = validate_fingerprint(source_fingerprint)
    if tickets is not None:
        value['tickets'] = validate_tickets(tickets)
    if release and released_for_tickets is not None:
        value['released_for_tickets'] = validate_tickets(released_for_tickets)
    elif not release:
        # Re-marking makes the folder persistent again; an earlier ticket release ends.
        value.pop('released_for_tickets', None)
    value['released'] = release
    # Write beside the marker, then atomically publish. An interrupted temporary
    # file is preserved as unknown bytes; an existing protection stays in place.
    with tempfile.NamedTemporaryFile(mode='w', dir=root, prefix=WORKSPACE_MARKER + '.', delete=False) as output:
        json.dump(value, output, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
        temporary = Path(output.name)
    os.replace(temporary, root / WORKSPACE_MARKER)
    return value


def ticket_released(item):
    """A root released because all its registered tickets ended retires whole (CL-359)."""
    try:
        marker = None if item.is_symlink() else read_marker(item)
    except (OSError, ValueError):
        return False
    return bool(marker and marker['released'] and marker.get('tickets')
                and marker.get('released_for_tickets') == marker['tickets'])


def scratch_roots(sessions):
    """Scratchpads of every session below Checklist and spare-process hosts."""
    return [session / 'scratchpad' for host in children(sessions)
            if 'Checklist' in host.name or 'spare-' in host.name
            for session in children(host)
            if not session.is_symlink() and not (session / 'scratchpad').is_symlink()
            and (session / 'scratchpad').is_dir()]


def ticket_roots(sessions, qualification, session_id):
    """Marked roots in the caller's scratch (two levels) and qualification runs."""
    found = []
    for scratch in scratch_roots(sessions):
        if scratch.parent.name != session_id:
            continue
        for item in children(scratch):
            for path in (item, *children(item)):
                if path.is_dir() and not path.is_symlink() and os.path.lexists(path / WORKSPACE_MARKER):
                    found.append(path)
    found += [item for item in children(qualification)
              if item.is_dir() and not item.is_symlink() and os.path.lexists(item / WORKSPACE_MARKER)]
    return found


def release_finished(roots, session_id, read_status):
    """Release each caller-owned root whose registered tickets are all Done or canceled."""
    failed = False
    for root in roots:
        try:
            marker = read_marker(root)
            if not marker or marker['session_id'] != session_id:
                continue
            tickets = marker.get('tickets')
            report = {'path': str(root), 'tickets': tickets or []}
            if marker['released']:
                report.update(action='already_released')
            elif not tickets:
                report.update(action='kept', reason='no ticket registered; re-mark with --ticket or release by hand')
            else:
                statuses = read_status(tickets)
                unfinished = [key for key in tickets if statuses.get(key) not in FINISHED]
                if unfinished:
                    report.update(action='kept', reason='open or unknown ticket status: ' + ', '.join(unfinished))
                else:
                    write_marker(root, session_id, release=True, released_for_tickets=tickets)
                    report.update(action='released',
                                  reason='all tickets Done or canceled; the whole folder retires at the next apply')
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            report = {'path': str(root), 'action': 'kept_error', 'reason': str(error)}
            failed = True
        print(json.dumps(report, sort_keys=True), flush=True)
    return 1 if failed else 0


def cli_status_reader(cli, repo, project_id=None, timeout=60):
    """Read-only ticket statuses through the installed CLI, with cwd at the project folder."""
    from cleanup_service_wait import CLICallError, StatusRefusal
    project = project_id
    def call(method, arguments):
        try:
            result = subprocess.run([str(cli), 'call', method, json.dumps(arguments)], cwd=repo,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True,
                                    timeout=timeout() if callable(timeout) else timeout)
        except subprocess.CalledProcessError as error:
            # Keep the CLI's own code and text: the installer log must show them (CL-372).
            raise CLICallError(error.returncode, [str(cli), 'call', method], error.output, error.stderr) from error
        return json.loads(result.stdout)['data']
    def read(keys):
        nonlocal project
        if not project:
            projects = call('project_resolve', {'workspace_path': str(repo)})['projects']
            if len(projects) != 1:
                raise StatusRefusal('PROJECT_SCOPE_AMBIGUOUS', 'project scope ambiguous; supply --project-id')
            project = projects[0]['id']
        result = {}
        for key in keys:
            data = call('task_get', {'project_id': project, 'key': key})
            if data.get('key') != key:
                raise StatusRefusal('WRONG_TICKET', 'task_get returned another ticket for ' + key)
            result[key] = data.get('status_category')
        return result
    return read


def du_sizes(paths):
    """Allocated sizes from one du call (no hashing); missing roots are absent."""
    existing = [path for path in paths if os.path.lexists(path)]
    if not existing:
        return {}
    result = subprocess.run(['/usr/bin/du', '-sk', *map(str, existing)], capture_output=True, text=True)
    sizes = {}
    for line in result.stdout.splitlines():
        kilobytes, _, name = line.partition('\t')
        if kilobytes.isdigit():
            sizes[Path(name)] = int(kilobytes) * 1024
    return sizes


def background_sizes(groups, workers=16, chunk=16, targets=(), target_split=0):
    """Share one allocated-size scan between held rows and the size report."""
    from cleanup_sizes import background_sizes as shared_sizes
    return shared_sizes(groups, targets, size_reader=du_sizes, workers=workers, chunk=chunk,
                        target_split=target_split)


def storage_groups(sessions, qualification, repo):
    return {'scratch': scratch_roots(sessions), 'evidence': [repo / '.local/evidence'],
            'build': [repo / '.local/build'], 'qualification': [qualification]}


def storage_report(groups, budget_bytes, sizer=None):
    """Print one size line per run and warn loudly above the budget."""
    sizer = sizer or du_sizes
    totals = {label: sum(sizer(list(paths)).values()) for label, paths in groups.items()}
    total = sum(totals.values())
    report = {'action': 'size_report', 'groups': totals, 'total_bytes': total,
              'budget_bytes': int(budget_bytes), 'over_budget': total > budget_bytes,
              'size_method': 'du -sk (allocated bytes)',
              'trash_note': 'bytes moved to the Trash stay on disk until the owner empties the Trash'}
    print(json.dumps(report, sort_keys=True), flush=True)
    if total > budget_bytes:
        print('WARNING: CLEANUP BUDGET EXCEEDED: scratch, evidence, build and qualification folders use '
              f'{total / 1e9:.1f} GB, above the {budget_bytes / 1e9:.0f} GB budget. Run --release-done, '
              'then apply cleanup at this round boundary.', file=sys.stderr, flush=True)
    return report


def held_preview(item, kind, keep, sizer=None):
    """Preview a held root from its marker and a du size: no inventory or hashing."""
    if item.is_symlink():
        return None
    try:
        marker = read_marker(item)
    except (OSError, ValueError):
        return None
    if any(overlap(item, path) for path in keep):
        reason = 'explicitly retained qualified copy or persistent build slot'
    elif marker and not marker['released']:
        reason = 'persistent workspace marker; retained: ' + str(item)
    else:
        return None
    size = (sizer or du_sizes)([item]).get(item, 0)
    return {'path': str(item), 'kind': kind, 'action': 'preview', 'reason': reason,
            'total_bytes': size, 'kept_bytes': size, 'build_bytes': 0, 'git_redundant_source_bytes': 0,
            'qualification_bytes': 0, 'reasons': {reason: size}, 'retained_legacy_paths': [],
            'size_method': 'du -sk (allocated bytes)',
            'tickets': (marker or {}).get('tickets', []), 'eligible_paths': [], 'planned_move_count': 0}


def released_by(root, session_id=None):
    try:
        marker = read_marker(root)
        return bool(marker and marker['released'] and
                    (session_id is None or marker['session_id'] == session_id))
    except (OSError, ValueError):
        return False


def in_scope(item, kind, session_id, include_released=False):
    if kind in {'session', 'spare'}:
        scratchpad = next((p for p in item.parents if p.name == 'scratchpad'), None)
        if scratchpad is None:
            return False
        owner = scratchpad.parent.name
        return owner == session_id or (include_released and released_by(item, owner))
    # Qualification runs have no session path: their root marker supplies ownership.
    if item.is_symlink():
        return False
    try:
        marker = read_marker(item)
        return bool(marker and (marker['session_id'] == session_id or
                                (include_released and marker['released'])))
    except (OSError, ValueError):
        return False


def private_copy(path, *, allow_build_only=True):
    """Recognize layouts, not names; links never establish a container child."""
    if path.is_symlink() or not path.is_dir():
        return False
    return ((allow_build_only and (path / '.build').is_dir())
            or (path / '.git').exists() or (path / 'src/.git').exists()
            or (path / 'capture-manifest.json').is_file()
            or (path / 'source-manifest.json').is_file()
            or (path / 'build-info.json').is_file())


def session_items(item):
    # Inspect just one level into an unmarked container. Loose files and other
    # directories are not cleanup candidates. A marked root keeps its ordinary
    # whole-item protections (including malformed markers failing closed).
    try:
        if (RETIRING_NAME.fullmatch(item.name) or item.is_symlink() or not item.is_dir()
                or read_marker(item) is not None
                or re.fullmatch(r'ws[a-z]*\d+', item.name) or private_copy(item, allow_build_only=False)):
            return [item]
        # A round container can have its own .build. In that case only marked
        # children establish separate workspaces, and the remaining tree stays.
        if (item / '.build').is_dir():
            return [child for child in children(item) if not child.is_symlink() and child.is_dir()
                    and os.path.lexists(child / WORKSPACE_MARKER)] or [item]
        copies = [child for child in children(item)
                  if private_copy(child) or os.path.lexists(child / WORKSPACE_MARKER)]
        return copies or [item]
    except (OSError, ValueError):
        return [item]


def candidates(sessions, qualification, session_id, include_released=False):
    """Default scope is the caller's session, never another session's idle copies.

    --include-released admits foreign roots only with that session's release.
    Spare items still need their own retained Checklist package in plan().
    """
    for host in children(sessions):
        checklist = 'Checklist' in host.name
        if not checklist and 'spare-' not in host.name:
            continue
        for session in children(host):
            if session.is_symlink() or (session.name != session_id and not include_released):
                continue
            for item in children(session / 'scratchpad'):
                kind = 'session' if checklist else 'spare'
                if in_scope(item, kind, session_id, include_released):
                    # Foreign scope still requires the owner's root release;
                    # container discovery never expands that authorization.
                    for candidate in session_items(item) if session.name == session_id else [item]:
                        yield candidate, kind
    for item in children(qualification):
        if in_scope(item, 'qualification', session_id, include_released):
            yield item, 'qualification'


def legacy_workspaces(before):
    return [path for path, entry in before.items()
            if re.fullmatch(r'ws[a-z]*\d+', path.name) and stat.S_ISDIR(entry[2])
            and read_marker(path) is None]


def released_ancestor(path, item):
    scratchpad = next((p for p in item.parents if p.name == 'scratchpad'), None)
    owner = scratchpad.parent.name if scratchpad else (read_marker(item) or {}).get('session_id')
    return any(released_by(root, owner) for root in path.parents
               if within(root, item))


def workspace_protection(item, before):
    # Protect a marked workspace whether it is the scratch item, nested below it,
    # or an ancestor of it. A released outer marker never releases an inner one.
    roots = {p.parent for p in before if p.name == WORKSPACE_MARKER}
    roots.update(item.parents)
    for root in sorted(roots):
        try:
            marker = read_marker(root)
        except (OSError, ValueError):
            return 'invalid/unreadable workspace marker; retained: ' + str(root)
        if marker and not marker['released']:
            return 'persistent workspace marker; retained: ' + str(root)
    # Migration guard only: never infer release from the old naming convention.
    for path in legacy_workspaces(before):
        if path == item or not released_ancestor(path, item):
            return 'unmarked legacy persistent workspace; mark before retirement: ' + str(path)
    return None


def installed_fingerprint(path):
    try:
        value = json.loads(path.read_text())['source_fingerprint']
        return value if isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def rollback_directory(installed_info):
    installed_info = installed_info.absolute()
    if (installed_info.parts[-3:] == ('Contents', 'Resources', 'build-info.json')
            and installed_info.parents[2].suffix == '.app'):
        return installed_info.parents[3]
    return None


def rollback_receipt(directory):
    bundles = sorted((previous_timestamp(bundle) or '', bundle)
                     for bundle in directory.iterdir()
                     if bundle.name.startswith('.Checklist-previous-') and bundle.suffix == '.app')
    if not bundles:
        return None
    stamp, bundle = bundles[-1]
    if not bundles[0][0] or bundle.is_symlink() or (len(bundles) > 1 and bundles[-2][0] == stamp):
        raise ValueError('previous installed identity unavailable; qualified-copy retention unresolved')
    return bundle / 'Contents/Resources/build-info.json'


def observe_fingerprint(path, expected):
    stamp = expected[(path, False)] = path_stamp(path)
    if stamp is None:
        return None
    # Record both the link and the effective receipt. A link farther along the
    # chain can be redirected without changing the first link or old target.
    if stat.S_ISLNK(stamp[2]):
        stamp = expected[(path, True)] = path_stamp(path, follow_symlinks=True)
    return installed_fingerprint(path) if stamp and stat.S_ISREG(stamp[2]) else None


def installation_observation(installed_info):
    """Record receipt metadata and the directory that selects the rollback bundle."""
    expected = {}
    current = observe_fingerprint(installed_info, expected)
    previous = None
    directory = rollback_directory(installed_info)
    if current and directory is not None:
        stamp = expected[(directory, False)] = path_stamp(directory)
        if stamp and stat.S_ISLNK(stamp[2]):
            expected[(directory, True)] = path_stamp(directory, follow_symlinks=True)
        if receipt := rollback_receipt(directory):
            previous = observe_fingerprint(receipt, expected)
            if previous is None:
                raise ValueError('previous installed identity unavailable; qualified-copy retention unresolved')
    return current, previous, expected


def read_build_identity(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('not a regular build identity: ' + str(path))
        return source.read()


def build_identity_hold(paths, fingerprint, previous, contents=None):
    for path in paths:
        try:
            data = read_build_identity(path)
            if contents is not None:
                contents[path] = data
            value = json.loads(data.decode()).get('source_fingerprint')
        except (ValueError, AttributeError):
            # An unreadable receipt is not proof that a copy is obsolete.
            return 'unreadable build identity; qualified-copy retention unresolved'
        if value == fingerprint:
            return 'qualified copy of latest installed round (matching source fingerprint)'
        if previous is not None and value == previous:
            return 'qualified copy of previous installed round (matching source fingerprint)'
    return None


def shared_rounds(items):
    """Group the immediate workspace candidates split from a round container."""
    rounds = {}
    for item, kind in items:
        parent = item.parent
        if kind in {'session', 'spare'} and parent.name != 'scratchpad' and parent.parent.name == 'scratchpad':
            rounds.setdefault(parent, set()).add(os.fspath(item))
    return rounds


def shared_round_receipts(root, workspaces):
    """Observe shared directories and identity receipts outside independent workspaces."""
    pending = [os.fspath(root)]
    while pending:
        folder = pending.pop()
        stamp = path_stamp(folder)
        if stamp is None or not stat.S_ISDIR(stamp[2]):
            raise ValueError('shared round directory changed: ' + str(folder))
        yield folder, stamp
        with os.scandir(folder) as entries:
            for entry in entries:
                if entry.path in workspaces:
                    continue
                if entry.is_dir(follow_symlinks=False):
                    pending.append(entry.path)
                elif entry.name in BUILD_IDENTITY_NAMES and entry.is_file(follow_symlinks=False):
                    stamp = path_stamp(entry.path)
                    if stamp is None or not stat.S_ISREG(stamp[2]):
                        raise ValueError('shared round receipt changed: ' + entry.path)
                    yield entry.path, stamp


def shared_round_holds(rounds, fingerprint, previous, snapshots=None, contents=None):
    holds = {}
    if fingerprint is None:  # The normal planner already retains every uncertain item.
        return holds

    def receipts(parent, workspaces):
        for path, stamp in shared_round_receipts(parent, workspaces):
            if snapshots is not None:
                snapshots.setdefault(parent, {})[path] = stamp
            if stat.S_ISREG(stamp[2]):
                yield Path(path)

    for parent, workspaces in rounds.items():
        try:
            reason = build_identity_hold(receipts(parent, workspaces), fingerprint, previous,
                                         contents.setdefault(parent, {}) if contents is not None else None)
        except (OSError, ValueError) as error:
            reason = ValueError('unreadable shared round identity; retained: ' + str(error))
        if reason:
            holds[parent] = reason
    return holds


def plan(item, kind, objects, processes, fingerprint, keep=(), now=None, exhaustive=False,
         *, previous=None, round_hold=None):
    """exhaustive=True skips the item-wide-hold shortcut (tests prove both agree)."""
    before = inventory(item)
    below_item = os.fspath(item).rstrip('/') + '/'
    def relative_parts(path):
        """path.relative_to(item).parts from the path text (CL-376 speed: no pathlib parse per file)."""
        text = os.fspath(path)
        if text.startswith(below_item):
            return tuple(text[len(below_item):].split('/'))
        return path.relative_to(item).parts
    legacy = legacy_workspaces(before)
    files = {path: entry for path, entry in before.items() if not stat.S_ISDIR(entry[2])}
    size = sum(entry[3] for entry in files.values())
    reason = None
    # A root released for ended tickets retires whole: no per-file hashing (CL-359).
    ticket_retire = ticket_released(item)
    released_retire = released_by(item)
    recovery = next((path for path in before if RETIRING_NAME.fullmatch(path.name)), None)
    if recovery is not None:
        reason = 'interrupted retirement needs recovery; retained: ' + str(recovery)
    elif item.is_symlink():
        reason = 'symbolic link; never followed'
    elif kind == 'spare' and not ticket_retire and not any(
        path.name == 'Package.swift' and stat.S_ISREG(entry[2]) and
        blob_id(path) in objects and b'"Checklist"' in path.read_bytes()
        for path, entry in files.items()
    ):
        reason = 'spare item has no retained Checklist package identity'
    elif any(overlap(item, path) for path in keep):
        reason = 'explicitly retained qualified copy or persistent build slot'
    elif protection := workspace_protection(item, before):
        reason = protection
    elif fingerprint is None:
        reason = 'latest installed identity unavailable; qualified-copy retention unresolved'
    elif (kind == 'qualification' and (read_marker(item) or {}).get('source_fingerprint') == fingerprint):
        reason = 'qualified copy of latest installed round (matching root source fingerprint)'
    elif (kind == 'qualification' and previous is not None
          and (read_marker(item) or {}).get('source_fingerprint') == previous):
        reason = 'qualified copy of previous installed round (matching root source fingerprint)'
    elif isinstance(round_hold, ValueError):
        raise round_hold
    elif round_hold:
        reason = round_hold
    else:
        receipts = (path for path, entry in files.items()
                    if path.name in BUILD_IDENTITY_NAMES and stat.S_ISREG(entry[2]))
        reason = build_identity_hold(receipts, fingerprint, previous)
    if not reason and any(within(path, item) for path in processes):
        reason = 'running process uses this item'
    cutoff = (time.time() if now is None else now) - QUIET_SECONDS
    if not reason and any(entry[4] / 1e9 >= cutoff or entry[5] / 1e9 >= cutoff
                          for entry in before.values()):
        reason = 'files or directories changed in the last 45 minutes'

    # Explicit root release authorizes whole-folder retirement. Fingerprinted
    # qualification runs keep their additional links/Git guard unless ticket-released.
    retire_run = kind == 'qualification' and bool((read_marker(item) or {}).get('source_fingerprint'))
    whole = retire_run or released_retire
    if retire_run and not ticket_retire and not reason and any(
            not stat.S_ISREG(entry[2]) or '.git' in relative_parts(path)
            for path, entry in files.items()):
        reason = 'qualification run contains links, special files or Git metadata; retained'
    counts = Counter(build_bytes=0, git_redundant_source_bytes=0, qualification_bytes=0, kept_bytes=0)
    if ticket_retire:
        counts['ticket_bytes'] = 0
    if reason and not exhaustive:
        # An item-wide hold keeps every file under that one reason and selects no
        # move: the per-file classification below would reach the same result
        # (CL-359 speed; equality covered by test_item_wide_hold_matches_per_file_plan).
        counts['kept_bytes'] = size
        return {'path': str(item), 'kind': kind, **counts, 'total_bytes': size, 'reason': reason,
                'reasons': {reason: size} if files else {},
                'retained_legacy_paths': [str(p) for p in legacy], 'planned_move_count': 0,
                'move_bytes': {}, 'moves': [], 'inventory': before}
    if whole and not reason:
        # An owner's root release authorizes one rename of the checked tree.
        # Do not classify/hash its managed objects or split at Git/legacy paths:
        # nested unreleased markers, use, quiet time and installed identity were
        # checked above. Apply revalidates the recorded inventory before that rename.
        category = ('ticket_bytes' if ticket_retire else
                    'qualification_bytes' if retire_run else 'released_bytes')
        why = ('tickets Done or canceled; released folder retires whole' if ticket_retire else
               'released obsolete qualification run (including copied stores)' if retire_run else
               'owner released workspace; whole folder retires')
        counts[category] = size
        return {'path': str(item), 'kind': kind, **counts, 'total_bytes': size,
                'reason': why, 'reasons': {why: size},
                'retained_legacy_paths': [str(p) for p in legacy], 'planned_move_count': 1,
                'move_bytes': {item: size}, 'moves': [item], 'inventory': before}
    reasons = Counter()
    removable = set()
    for path, entry in files.items():
        parts = relative_parts(path)
        # Include the item's own name for an item that is itself a build folder.
        components = (item.name,) + parts
        why = reason
        category = 'kept_bytes'
        if not why and any(within(path, root) for root in legacy):
            why = 'unmarked legacy persistent workspace; mark before retirement'
        if not why:
            if ticket_retire:
                category, why = 'ticket_bytes', 'tickets Done or canceled; released folder retires whole'
            elif retire_run:
                category, why = 'qualification_bytes', 'released obsolete qualification run (including copied stores)'
            elif not stat.S_ISREG(entry[2]):
                why = 'link or special file; never followed or moved'
            elif path.name == WORKSPACE_MARKER:
                why = 'workspace ownership/release marker retained'
            elif '.git' in components:
                why = 'Git metadata retained; checkout retirement belongs to CL-194'
            elif any(name in BUILD_NAMES for name in components):
                category, why = 'build_bytes', 'rebuildable build output/cache'
            elif blob_id(path) in objects:
                category, why = 'git_redundant_source_bytes', 'exact bytes held by retained Git history'
            else:
                why = 'bytes not held by retained Git; preserve work, reports and evidence'
        counts[category] += entry[3]
        reasons[why] += entry[3]
        if category != 'kept_bytes':
            removable.add(path)

    # Coalesce only wholly removable subtrees, preserving unknown files/links.
    # Aggregate logical bytes in the same bottom-up pass, including empty
    # directories as zero bytes; never rescan a subtree for each move receipt.
    moves = []
    children_by_parent = {}
    removable_tree, tree_bytes = {}, {}
    for path, entry in reversed(list(before.items())):
        children_by_parent.setdefault(path.parent, []).append(path)
        tree_bytes[path] = (sum(tree_bytes[p] for p in children_by_parent.get(path, []))
                            if stat.S_ISDIR(entry[2]) else entry[3])
        # Empty folders can accompany an eligible tree, but never override an
        # item-wide hold or remove even empty Git metadata.
        removable_tree[path] = (not reason and not any(within(path, root) for root in legacy)
                                 and (whole or '.git' not in (item.name,) + relative_parts(path))
                                 and all(removable_tree[p] for p in children_by_parent.get(path, []))
                               ) if stat.S_ISDIR(entry[2]) else path in removable
    def select(path):
        entry = before[path]
        if not stat.S_ISDIR(entry[2]):
            if path in removable:
                moves.append(path)
            return
        if removable_tree[path]:
            moves.append(path)
        else:
            for child in sorted(children_by_parent.get(path, [])):
                select(child)
    select(item)
    return {'path': str(item), 'kind': kind, **counts, 'total_bytes': size,
            'reason': reason or 'eligible build/Git bytes only; other bytes retained',
            'reasons': dict(reasons), 'retained_legacy_paths': [str(p) for p in legacy],
            'planned_move_count': len(moves),
            'move_bytes': {path: tree_bytes[path] for path in moves},
            'moves': moves, 'inventory': before}


def preview_public(decision):
    public = {key: value for key, value in decision.items() if key not in {'inventory', 'moves', 'move_bytes'}}
    public['action'] = 'preview'
    public['eligible_paths'] = [str(path) for path in decision['moves']]
    return public


_PREVIEW_OBJECTS = set()


def _set_preview_objects(objects):
    """Process-pool initializer: retained Git object IDs are sent once per worker."""
    global _PREVIEW_OBJECTS
    _PREVIEW_OBJECTS = objects


def preview_one(item, kind, in_use, fingerprint, keep, now, session_id, include_released,
                objects=None, sizer=None, *, previous=None, round_hold=None):
    """One read-only preview decision; module-level so a process pool can run it."""
    # An old --preview is never an executable deletion plan.
    if not in_scope(item, kind, session_id, include_released):
        raise ValueError('workspace ownership/release changed; retained')
    # Preview reads a held root's marker and du size only (CL-359 speed).
    if held := held_preview(item, kind, keep, sizer):
        return held
    return preview_public(plan(item, kind, _PREVIEW_OBJECTS if objects is None else objects,
                               [item] if in_use else [], fingerprint, keep, now,
                               previous=previous, round_hold=round_hold))


def preview_executor(objects, workers=PREVIEW_WORKERS):
    """CLI preview pool: spawned processes give each item plan its own CPU share
    on a loaded host (threads share one interpreter lock). Spawn, not fork:
    background du threads may already run in the parent."""
    import multiprocessing
    from concurrent.futures import ProcessPoolExecutor
    return ProcessPoolExecutor(max_workers=max(1, workers), mp_context=multiprocessing.get_context('spawn'),
                               initializer=_set_preview_objects, initargs=(objects,))


def preview_items(items, objects, used, fingerprint, keep, clock, session_id, include_released,
                  workers=PREVIEW_WORKERS, executor=None, sizer=None, *, previous=None, round_holds=None):
    """Read-only preview: the same per-item decisions and output order as apply's
    planning, with held-root du sizes and item plans computed in parallel.

    The default pool is threads (tests patch module functions); the CLI passes a
    process pool from preview_executor()."""
    failed = False
    process_pool = executor is not None
    with (executor(objects) if process_pool else ThreadPoolExecutor(max_workers=max(1, workers))) as pool, \
            ThreadPoolExecutor(max_workers=max(1, workers)) as size_pool:
        futures = []
        for item, kind in items:
            round_hold = (round_holds or {}).get(item.parent)
            # Held roots use the very same background size futures as size_report;
            # do not make each process launch a duplicate du of that subtree.
            if sizer is not None and held_preview(item, kind, keep, lambda paths: {}):
                future = size_pool.submit(preview_one, item, kind, item in used, fingerprint, keep, clock(),
                                          session_id, include_released, objects, sizer,
                                          previous=previous, round_hold=round_hold)
            else:
                future = pool.submit(preview_one, item, kind, item in used, fingerprint, keep, clock(),
                                     session_id, include_released, None if process_pool else objects,
                                     previous=previous, round_hold=round_hold)
            futures.append((item, future))
        for item, future in futures:
            try:
                print(json.dumps(future.result(), sort_keys=True), flush=True)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                print(json.dumps({'path': str(item), 'action': 'kept_error', 'reason': str(error)}), flush=True)
                failed = True
    return failed


def move_error(decision, error, path=None, stop=False):
    decision['public'].update(action='kept_error', reason=str(error))
    decision['public'].setdefault('errors', []).append(
        {'source': str(path or decision['path']), 'reason': str(error)})
    if stop:
        decision['stopped'] = True


def permission_root(item, kind, session_id):
    if kind in {'session', 'spare'}:
        scratchpad = next((p for p in item.parents if p.name == 'scratchpad'), None)
        return scratchpad if scratchpad and scratchpad.parent.name == session_id else None
    return item if (read_marker(item) or {}).get('session_id') == session_id else None


def writable_directory(path, expected, root, modes):
    """Adjust only the selected folder or its parent, with a no-follow identity check."""
    metadata = path.lstat()
    expected_mode = expected[2] if expected else None
    if expected and path in modes:
        expected_mode |= stat.S_IWUSR
    if not stat.S_ISDIR(metadata.st_mode) or (expected and
            (metadata.st_dev, metadata.st_ino, metadata.st_mode) != (*expected[:2], expected_mode)):
        raise ValueError('directory changed before permission adjustment: ' + str(path))
    if metadata.st_mode & stat.S_IWUSR:
        return
    if expected is not None and metadata_stamp(metadata) != expected:
        raise ValueError('directory changed before permission adjustment: ' + str(path))
    if root is None or not within(path, root):
        raise PermissionError('read-only directory outside caller permission scope; retained: ' + str(path))
    # Do not traverse a linked ancestor while adjusting a directory's mode.
    for parent in (path, *path.parents):
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise ValueError('linked/non-directory permission ancestor: ' + str(parent))
        if parent == root:
            break
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        observed = os.fstat(descriptor)
        if metadata_stamp(observed) != metadata_stamp(metadata):
            raise ValueError('directory changed before permission adjustment: ' + str(path))
        modes.setdefault(path, (stat.S_IMODE(observed.st_mode), (observed.st_dev, observed.st_ino)))
        os.fchmod(descriptor, observed.st_mode | stat.S_IWUSR)
    finally:
        os.close(descriptor)


def restore_modes(modes, destinations):
    for source, (mode, identity) in modes.items():
        path = destinations.get(source, source)
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            metadata = os.fstat(descriptor)
            if (metadata.st_dev, metadata.st_ino) != identity:
                raise ValueError('directory changed before permission restoration: ' + str(path))
            os.fchmod(descriptor, mode)
        finally:
            os.close(descriptor)


def inventory_stamps_match(expected):
    # Check directory stamps after payload entries so a file added during the
    # payload checks can still invalidate its recorded parent.
    directories = {}
    for path, stamp in expected.items():
        if stat.S_ISDIR(stamp[2]):
            directories[path] = stamp
        elif path_stamp(path) != stamp:
            return False
    return all(path_stamp(path) == directories[path] for path in reversed(directories))


def validate_workspace_scope(decision, item, keep, session_id, include_released, *, source=None, staged=None):
    original = Path(decision['path'])
    if any(overlap(original, folder) or (staged is not None and overlap(staged, folder)) for folder in keep):
        raise ValueError('explicitly retained qualified copy or persistent build slot')
    markers = decision['markers']
    if staged is not None:
        markers = {staged_path(path, source, staged): stamp for path, stamp in markers.items()}
    if not in_scope(item, decision['kind'], session_id, include_released) or not stamps_match(markers):
        raise ValueError('workspace ownership/release changed; stopped')


def validate_move(decision, path, installations, shared, observed_shared, round_hold, keep,
                  session_id, include_released, modes):
    """Finish the filesystem and policy checks before the final process read."""
    item = Path(decision['path'])
    before = decision['inventory']
    inventory_unchanged = inventory_stamps_match(before)
    shared_unchanged = observed_shared == shared and inventory_stamps_match(shared)
    validate_workspace_scope(decision, item, keep, session_id, include_released)
    if not inventory_unchanged:
        raise ValueError('item changed during inspection/Trash moves; stopped')
    if round_hold:
        raise ValueError(str(round_hold) + '; stopped before Trash')
    if not shared_unchanged:
        raise ValueError('shared round contents changed during inspection; stopped')
    root = permission_root(item, decision['kind'], session_id)
    writable_directory(path.parent, before.get(path.parent) or shared.get(os.fspath(path.parent)), root, modes)
    if stat.S_ISDIR(before[path][2]):
        writable_directory(path, before[path], root, modes)
    expected = before[path]
    observed = path_stamp(path)
    if path in modes:
        # Our own chmod may change only mode and ctime.
        valid = observed is not None and observed[:5] == (*expected[:2], expected[2] | stat.S_IWUSR, *expected[3:5])
    else:
        valid = observed == expected
    if not valid:
        raise ValueError('item changed during inspection/Trash moves; stopped')

    # Permission preparation and its stat checks also precede the last policy
    # check and process observation.
    validate_workspace_scope(decision, item, keep, session_id, include_released)
    if any(path_stamp(file, follow_symlinks=follow) != stamp for (file, follow), stamp in installations.items()):
        raise ValueError('installed round changed; rerun preview with its qualified copy retained')


def staged_path(path, source, staged):
    return staged / path.relative_to(source) if within(path, source) else path


def validate_staged(decision, source, staged, modes, keep, session_id, include_released):
    """Validate the complete checkout under its new name against the plan."""
    def relocate(path):
        return staged_path(path, source, staged)

    item = relocate(Path(decision['path']))
    validate_workspace_scope(decision, item, keep, session_id, include_released, source=source, staged=staged)
    actual = inventory(item)
    expected = decision['inventory']
    if len(actual) != len(expected):
        raise ValueError('item changed during inspection/Trash moves; stopped')
    for path, stamp in expected.items():
        observed = actual.get(relocate(path))
        if path in modes:
            stamp = (*stamp[:2], stamp[2] | stat.S_IWUSR, *stamp[3:])
        # Staging changes source ctime and the direct parent's directory stamp.
        # The full walk still has to find exactly the same children in both.
        length = 5 if path == source else 3 if path == source.parent else len(stamp)
        if observed is None or observed[:length] != stamp[:length]:
            raise ValueError('item changed during inspection/Trash moves; stopped')
    if reason := workspace_protection(item, actual):
        raise ValueError(reason)
    return actual


def validate_staged_round(parent, workspaces, shared, contents, fingerprint, previous, staged, names, modes):
    if workspaces is None:
        return {}
    if names is not None:
        workspaces = workspaces | {os.fspath(staged)}
    observed, read_contents = {}, {}
    hold = shared_round_holds({parent: workspaces}, fingerprint, previous, observed, read_contents).get(parent)
    if hold:
        raise ValueError(str(hold) + '; stopped before Trash')
    actual = observed[parent]
    if names is not None:
        key = os.fspath(parent)
        device, inode, mode = shared[key][:3]
        if parent in modes:
            mode |= stat.S_IWUSR
        if set(os.listdir(parent)) != names or actual[key][:3] != (device, inode, mode):
            raise ValueError('shared round contents changed during inspection; stopped')
    if (read_contents.get(parent, {}) != contents or actual.keys() != shared.keys()
            or any(actual[path] != stamp for path, stamp in shared.items()
                   if names is None or path != os.fspath(parent))
            or not inventory_stamps_match(actual)):
        raise ValueError('shared round contents changed during inspection; stopped')
    return actual


def confirm_staged_round(observed, contents):
    # The staged walk recorded every shared directory. A new receipt or
    # directory changes its recorded parent's stamp, even at the round root.
    if (any(read_build_identity(path) != data for path, data in contents.items())
            or not inventory_stamps_match(observed)):
        raise ValueError('shared round contents changed during inspection; stopped')


def check_staged_policy(actual, installed_info, installations, fingerprint, previous):
    if installation_observation(installed_info) != (fingerprint, previous, installations):
        raise ValueError('installed round changed; rerun preview with its qualified copy retained')
    receipts = (path for path, stamp in actual.items()
                if path.name in BUILD_IDENTITY_NAMES and stat.S_ISREG(stamp[2]))
    if reason := build_identity_hold(receipts, fingerprint, previous):
        raise ValueError(reason + '; stopped before Trash')


def validate_staged_file(decision, path, staged):
    if path in decision['move_file_hashes'] and blob_id(staged) != decision['move_file_hashes'][path]:
        raise ValueError('item changed during inspection/Trash moves; stopped')


def restore_staged(trash, path, staged):
    try:
        trash.rename_exclusive(staged, path)
        return None
    except FileExistsError:
        return 'original name occupied; staged content retained at ' + str(staged)
    except OSError as error:
        return 'could not restore staged content at ' + str(staged) + ': ' + str(error)


def record_move(decision, path, destination):
    receipt = {'source': str(path), 'trash': str(destination), 'bytes': decision['move_bytes'][path]}
    decision['public']['destinations'].append(receipt)
    decision['public']['moved_count'] += 1
    decision['public']['moved_bytes'] += receipt['bytes']
    print(json.dumps({'action': 'trash_move', **receipt}), flush=True)


def note_directory_changes(expected, shared, directories):
    """Account for our own rename without adopting unplanned checkout entries."""
    for directory in directories:
        key = os.fspath(directory)
        if directory not in expected and key not in shared:
            continue
        current = path_stamp(directory)
        if directory in expected:
            names = {path.name for path in expected if path.parent == directory}
            if set(os.listdir(directory)) != names or path_stamp(directory) != current:
                raise ValueError('remaining files changed during Trash move; stopped')
        for observations, entry in ((expected, directory), (shared, key)):
            if entry not in observations:
                continue
            if current is None or current[:3] != observations[entry][:3]:
                raise ValueError('remaining directory changed during Trash move: ' + str(directory))
            observations[entry] = current


def apply_batch(batch, installations, fingerprint, process_reader, mover,
                session_id, include_released, *, installed_info, previous, rounds, shared_snapshots,
                shared_contents, keep, trash):
    batch = [(d, p) for d, p in batch if not d.get('stopped')]
    if not batch:
        return
    decisions = list({id(d): d for d, _ in batch}.values())
    prepared = {}
    if mover is None:
        for decision, path in batch:
            try:
                prepared[path] = trash.prepare(path, decision['inventory'][path])
            except (OSError, ValueError) as error:
                move_error(decision, error, path)
    first = True
    moved = {}
    retry = []
    for offset, (decision, path) in enumerate(batch):
        if decision.get('stopped') or (mover is None and path not in prepared):
            continue
        item = Path(decision['path'])
        parent = item.parent
        shared = shared_snapshots.get(parent, {})
        contents = shared_contents.get(parent, {})
        observed, read_contents = {}, {}
        names = None
        try:
            # The first path can stop early on a known process hold before
            # scanning receipts or inventory. In a split round, also observe
            # after the shared scan so a hold can avoid the inventory pass.
            preflight, first = first, False
            early_processes = list(process_reader()) if preflight else []
            if used_items(early_processes, (item,)):
                raise ValueError('running process began using item; stopped')
            # A fresh walk rediscovers receipts even when an earlier rename
            # updated the same directory's timestamp.
            round_roots = {parent: rounds[parent]} if parent in rounds else {}
            hold = shared_round_holds(round_roots, fingerprint, previous, observed, read_contents).get(parent)
            if preflight and round_roots and used_items(process_reader(), (item,)):
                raise ValueError('running process began using item; stopped')
            if path == item and round_roots:
                names = set(os.listdir(parent))
                if item.name not in names:
                    raise ValueError('item changed during inspection/Trash moves; stopped')
            if not hold and read_contents.get(parent, {}) != contents:
                raise ValueError('shared round contents changed during inspection; stopped')
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            move_error(decision, error, path, stop=True)
            continue
        modes = {}
        destination = None
        staged = None
        try:
            try:
                validate_move(decision, path, installations, shared, observed.get(parent, {}), hold, keep,
                              session_id, include_released, modes)
            except PermissionError as error:
                move_error(decision, error, path)
                continue
            except (OSError, ValueError) as error:
                move_error(decision, error, path, stop=True)
                continue
            try:
                if used_items(process_reader(), (item,)):
                    raise ValueError('running process began using item; stopped')
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                move_error(decision, error, path, stop=True)
                continue
            staged = trash.stage(path)
            try:
                if names is not None:
                    names = names - {path.name} | {staged.name}
                actual = validate_staged(decision, path, staged, modes, keep, session_id, include_released)
                staged_shared = validate_staged_round(parent, rounds.get(parent), shared, contents,
                                                      fingerprint, previous, staged, names, modes)
                check_staged_policy(actual, installed_info, installations, fingerprint, previous)
                if used_items(process_reader(), (item, staged)):
                    raise ValueError('running process began using item; stopped')

                # A walk and process observation both take time. Refresh the
                # policy and compare the observations before the Trash rename.
                if path_stamp(path) is not None:
                    raise ValueError('original name reappeared before Trash')
                staged_item = staged if path == item else item
                validate_workspace_scope(decision, staged_item, keep, session_id, include_released,
                                         source=path, staged=staged)
                check_staged_policy(actual, installed_info, installations, fingerprint, previous)
                validate_staged_file(decision, path, staged)
                if not inventory_stamps_match(actual):
                    raise ValueError('item changed during inspection/Trash moves; stopped')
                confirm_staged_round(staged_shared, contents)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                move_error(decision, error, path, stop=True)
                continue
            if mover is None:
                destination = prepared[path](staged)
            else:
                # Test adapters get both the receipt source and its physical name.
                receipts = iter(mover([path], staged=staged))
                receipt = next(receipts, None)
                if receipt is None:
                    raise ValueError('Trash receipts incomplete; inspect paths before retry')
                source, reported_destination = receipt
                if source != path:
                    raise ValueError('unexpected or duplicate Trash receipt; stopped')
                destination = reported_destination
        except (OSError, subprocess.SubprocessError) as error:
            move_error(decision, error, path)
            retry = batch[offset + 1:]
        except ValueError as error:
            move_error(decision, error, path, stop=True)
        finally:
            try:
                restore_path = destination
                if staged is not None and destination is None:
                    if error := restore_staged(trash, path, staged):
                        decision['public']['staged_path'] = str(staged)
                        move_error(decision, decision['public']['reason'] + '; ' + error, path, stop=True)
                        restore_path = staged
                restore_modes(modes, {path: restore_path} if restore_path is not None else {})
                changed_dirs = set(modes)
                expected = decision['inventory']
                if staged is not None:
                    changed_dirs.add(path.parent)
                    if destination is None and restore_path is None and not decision.get('stopped'):
                        current = path_stamp(path)
                        # A rolled-back backend failure changes the root's ctime.
                        if current is None or current[:5] != expected[path][:5]:
                            raise ValueError('staged source changed during Trash move; stopped')
                        expected[path] = current
                if destination is not None:
                    moved[id(decision)] = decision
                    changed_dirs.discard(path)
                if destination is not None:
                    if path == item:
                        expected.clear()
                        # The prior workspace no longer owns this name. If it
                        # reappears, scan it as part of the round's shared tree.
                        if parent in rounds:
                            rounds[parent].discard(os.fspath(item))
                    else:
                        prefix = os.fspath(path) + '/'
                        for entry in [entry for entry in expected if entry == path or os.fspath(entry).startswith(prefix)]:
                            del expected[entry]
                note_directory_changes(expected, shared, changed_dirs)
            except (OSError, ValueError) as error:
                move_error(decision, error, path, stop=True)
        if destination is not None:
            record_move(decision, path, destination)
            if mover is not None:
                try:
                    if next(receipts, None) is not None:
                        raise ValueError('unexpected or duplicate Trash receipt; stopped')
                except (OSError, subprocess.SubprocessError) as error:
                    move_error(decision, ValueError('Trash backend failed after confirmed moves: ' + str(error)), path)
                except ValueError as error:
                    move_error(decision, error, path, stop=True)
        if retry:
            break

    # Receipt reporting and post-move inventories stay outside the rename gate.
    for decision in moved.values():
        if decision.get('stopped'):
            continue
        item = Path(decision['path'])
        try:
            actual = inventory(item) if decision['inventory'] or path_stamp(item) is not None else {}
            if actual != decision['inventory']:
                raise ValueError('remaining files changed during Trash move; stopped')
        except (OSError, ValueError) as error:
            move_error(decision, error, stop=True)
    if retry:
        apply_batch(retry, installations, fingerprint, process_reader, mover, session_id, include_released,
                    installed_info=installed_info, previous=previous, rounds=rounds,
                    shared_snapshots=shared_snapshots, shared_contents=shared_contents, keep=keep, trash=trash)


def clean(sessions, qualification, repo, installed_info, keep=(), apply=False,
          process_reader=running_paths, mover=None, clock=time.time,
          session_id=None, include_released=False, after_inspection=None, preview_pool=None):
    if not session_id:
        raise ValueError('caller session unknown; supply --session-id for your own session')
    lease = publication_lock('scratch apply', timeout=SCRATCH_WAIT_SECONDS) if apply else nullcontext()
    with lease:
        return clean_candidates(sessions, qualification, repo, installed_info, keep, apply,
                                process_reader, mover, clock, session_id, include_released,
                                after_inspection, preview_pool)


def clean_candidates(sessions, qualification, repo, installed_info, keep, apply, process_reader,
                     mover, clock, session_id, include_released, after_inspection, preview_pool):
    failed = False
    # Unknown runs are visible for reconciliation, never inferred disposable.
    for item in children(qualification):
        if item.is_symlink() or not item.is_dir():
            continue
        try:
            if read_marker(item) is not None:
                continue
            newest, size = tree_summary(item)
            changed = newest / 1e9
            if clock() - changed >= UNMARKED_AGE_SECONDS:
                print(json.dumps({'path': str(item), 'kind': 'qualification',
                                  'action': 'unmarked_qualification', 'total_bytes': size,
                                  'age_seconds': clock() - changed, 'eligible_paths': [],
                                  'reason': 'unmarked qualification run older than 7 days; retained for owner reconciliation'}))
        except (OSError, ValueError) as error:
            print(json.dumps({'path': str(item), 'action': 'kept_error', 'reason': str(error)}))
            failed = True
    items = list(candidates(sessions, qualification, session_id, include_released))
    objects = git_objects(repo) if items else set()
    fingerprint, previous, installations = installation_observation(installed_info) if items else (None, None, {})
    rounds = shared_rounds(items)
    processes = process_reader() if items else []
    used = used_items(processes, (item for item, _ in items))
    shared_snapshots, shared_contents = ({}, {}) if apply else (None, None)
    round_holds = shared_round_holds(rounds, fingerprint, previous, shared_snapshots, shared_contents)
    if not apply:
        # Background du starts after process inspection so its own path arguments
        # are never observed as a process using an item.
        sizer = after_inspection() if after_inspection else None
        return 1 if preview_items(items, objects, used, fingerprint, keep, clock, session_id,
                                  include_released, executor=preview_pool, sizer=sizer,
                                  previous=previous, round_holds=round_holds) or failed else 0
    trash = None
    for offset in range(0, len(items), ITEM_BATCH_SIZE):
        pending = []
        for item, kind in items[offset:offset + ITEM_BATCH_SIZE]:
            try:
                # An old --preview is never an executable deletion plan.
                if not in_scope(item, kind, session_id, include_released):
                    raise ValueError('workspace ownership/release changed; retained')
                markers = {folder / WORKSPACE_MARKER: path_stamp(folder / WORKSPACE_MARKER)
                           for folder in (item, *item.parents)}
                decision = plan(item, kind, objects, [item] if item in used else [], fingerprint, keep, clock(),
                                previous=previous, round_hold=round_holds.get(item.parent))
                public = preview_public(decision)
                if decision['moves']:
                    public.update(action='trashed', destinations=[], moved_count=0, moved_bytes=0)
                    decision['public'] = public
                    decision['markers'] = markers
                    # A rename replaces the selected entry's ctime. Preserve
                    # proof of the bytes when the selected entry is a file.
                    decision['move_file_hashes'] = {
                        path: blob_id(path) for path in decision['moves']
                        if stat.S_ISREG(decision['inventory'][path][2])
                    }
                    # Use planned metadata for nested marker identity as well.
                    for path, stamp in decision['inventory'].items():
                        if path.name == WORKSPACE_MARKER:
                            markers.setdefault(path, stamp)
                    pending.append(decision)
                else:
                    print(json.dumps(public, sort_keys=True))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                print(json.dumps({'path': str(item), 'action': 'kept_error', 'reason': str(error)}))
                failed = True
        if pending and after_inspection:
            after_inspection()  # Optional synchronous sizing, before the pre-move observations.
            after_inspection = None
        for batch in move_batches((d, p) for d in pending for p in d['moves']):
            try:
                if trash is None:
                    trash = ScratchTrash()
                apply_batch(batch, installations, fingerprint, process_reader, mover, session_id, include_released,
                            installed_info=installed_info, previous=previous, rounds=rounds,
                            shared_snapshots=shared_snapshots, shared_contents=shared_contents, keep=keep, trash=trash)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                for decision in {id(d): d for d, _ in batch}.values():
                    move_error(decision, error, stop=True)
        for decision in pending:
            failed |= decision['public']['action'] == 'kept_error'
            print(json.dumps(decision['public'], sort_keys=True))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--mark', type=Path, help='protect a persistent workspace owned by this session')
    mode.add_argument('--release', type=Path, help='release your marked workspace for later cleanup')
    mode.add_argument('--release-ticket', action='append', metavar='KEY',
                      help='release every marked folder of yours whose tickets are all named here (repeatable)')
    mode.add_argument('--release-done', action='store_true',
                      help='release every marked folder of yours whose tickets are all Done or canceled (read-only status check)')
    mode.add_argument('--preview', action='store_true')
    mode.add_argument('--apply', action='store_true', help='move eligible paths to macOS Trash; never permanently delete')
    parser.add_argument('--purpose', help='workspace purpose; required with --mark')
    parser.add_argument('--ticket', action='append', metavar='KEY',
                        help='with --mark: owning ticket key (repeatable; or CHECKLIST_TICKETS=CL-1,CL-2); required for a new mark')
    parser.add_argument('--cli', type=Path, default=Path('/Applications/Checklist.app/Contents/MacOS/checklist'),
                        help='with --release-done: installed Checklist CLI used for read-only task_get calls')
    parser.add_argument('--project-id', help='with --release-done: project ID (default: resolved from --repo)')
    parser.add_argument('--budget-gb', type=float,
                        default=float(os.environ.get('CHECKLIST_CLEANUP_BUDGET_GB', DEFAULT_BUDGET_GB)),
                        help='warn when scratch, evidence, build and qualification folders exceed this size')
    parser.add_argument('--source-fingerprint', type=validate_fingerprint,
                        help='with --mark: bind a disposable qualification run to its exact build source fingerprint')
    parser.add_argument('--session-id', default=native_session(),
                        help='caller session (default: CODEX_THREAD_ID, CLAUDE_CODE_SESSION_ID, CLAUDE_SESSION_ID or CHECKLIST_SESSION_ID); never name another session')
    parser.add_argument('--include-released', action='store_true',
                        help='also inspect foreign roots explicitly released by their owning session')
    parser.add_argument('--sessions-root', type=Path, default=Path(f'/private/tmp/claude-{os.getuid()}'))
    parser.add_argument('--qualification-root', type=Path, default=Path.home() / 'Library/Caches/ChecklistQualification')
    parser.add_argument('--repo', type=Path, default=REPO, help='retained Checklist repository holding recoverable bytes')
    parser.add_argument('--installed-info', type=Path, default=Path('/Applications/Checklist.app/Contents/Resources/build-info.json'))
    parser.add_argument('--keep-qualified', type=Path, action='append', default=[],
                        help='also retain this exact qualified round or assigned persistent slot (repeatable)')
    args = parser.parse_args()
    host_session = native_session()
    if host_session and args.session_id != host_session:
        parser.error('--session-id cannot override the host caller; use --include-released for released foreign roots')
    if not args.session_id or args.session_id in {'.', '..'} or '/' in args.session_id or not args.session_id.strip():
        parser.error('caller session unknown/invalid; --session-id must name your own session')
    if args.source_fingerprint is not None and args.mark is None:
        parser.error('--source-fingerprint is only valid with --mark')
    if args.purpose is not None and args.mark is None:
        parser.error('--purpose is only valid with --mark')
    if args.ticket is not None and args.mark is None and not os.environ.get(TICKETS_ENVIRONMENT):
        parser.error('--ticket is only valid with --mark')
    if args.ticket is not None and any(not TICKET.fullmatch(key) for key in args.ticket):
        parser.error('--ticket must be a ticket key such as CL-10')
    if args.mark is not None and not args.ticket and os.environ.get(TICKETS_ENVIRONMENT, '').strip():
        args.ticket = requested_tickets()
    if args.mark is not None and not args.ticket:
        try:
            registered = (read_marker(args.mark.expanduser()) or {}).get('tickets')
        except (OSError, ValueError):
            registered = None
        if not registered:
            parser.error('--mark requires --ticket KEY (repeatable): register every new work folder with its tickets')
    sessions = args.sessions_root.expanduser()
    qualification = args.qualification_root.expanduser()
    if args.release_ticket is not None or args.release_done:
        if args.release_ticket is not None:
            if any(not TICKET.fullmatch(key) for key in args.release_ticket):
                parser.error('--release-ticket must be a ticket key such as CL-10')
            named = set(args.release_ticket)
            reader = lambda keys: {key: 'done' for key in keys if key in named}
        else:
            reader = cli_status_reader(args.cli.expanduser(), args.repo.expanduser().resolve(), args.project_id)
        return release_finished(ticket_roots(sessions, qualification, args.session_id), args.session_id, reader)
    if args.mark is not None or args.release is not None:
        root = (args.mark if args.mark is not None else args.release).expanduser()
        if args.source_fingerprint is not None:
            value = mark_qualification(root, args.source_fingerprint, args.purpose, args.session_id, args.ticket)
        else:
            value = write_marker(root, args.session_id, args.purpose, args.release is not None, tickets=args.ticket)
        print(json.dumps({'path': str(root.resolve()), 'action': 'released' if args.release else 'marked', **value}))
        return 0
    for root in [args.sessions_root.expanduser(), args.qualification_root.expanduser()]:
        if root.is_symlink():
            parser.error('scratch roots must not be symbolic links: ' + str(root))
    groups = storage_groups(sessions.resolve(), qualification.resolve(), args.repo.expanduser().resolve())
    # Preview sizes the folders in background du calls while it inspects items
    # (CL-359 speed), started after process inspection; apply sizes them after its moves.
    sizers = []
    def start_sizes():
        # Candidate boundaries also partition nested held workspaces. du never
        # walks their parent and then walks each held child again.
        targets = [item for item, _ in candidates(sessions.resolve(), qualification.resolve(),
                                                  args.session_id, args.include_released)]
        sizers.append(background_sizes(groups, targets=targets, target_split=2))
        return sizers[-1]
    try:
        result = clean(sessions.resolve(), qualification.resolve(), args.repo.expanduser().resolve(),
                       args.installed_info.expanduser(), [path.expanduser().resolve() for path in args.keep_qualified],
                       args.apply, session_id=args.session_id, include_released=args.include_released,
                       after_inspection=None if args.apply else start_sizes,
                       preview_pool=None if args.apply else preview_executor)
    except PublicationBusy as error:
        print(json.dumps({'action': 'kept_error', 'reason': str(error)}), flush=True)
        return 1
    storage_report(groups, args.budget_gb * 1e9, sizers[0] if sizers else None)
    return result


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Scratch cleanup refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
