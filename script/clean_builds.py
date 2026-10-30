#!/usr/bin/env python3
"""Preview build, hand-in and idle-slot retirement. Apply moves bytes to the Trash.

Counts are logical bytes moved, not recovered APFS space. Unknown ownership/use
is retained. Preview is read-only; apply recomputes every decision.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

from clean_scratch import (DEFAULT_BUDGET_GB, FINISHED, OWNER_RECORD, SESSION_VARIABLES, WORKSPACE_MARKER, background_sizes, cli_status_reader, du_sizes, inventory, native_session, read_owner_record, release_finished, running_paths, storage_groups, storage_report, ticket_roots, within, workspace_protection)
from retire_old_bundles import trash, trash_many
from cleanup_service_wait import ServiceReadiness, error_code
import test_instances as slots

REPO = Path(__file__).resolve().parents[1]
FINGERPRINT = re.compile(r'[0-9a-f]{64}')
LANE = re.compile(r'lane-([0-9a-f]{20})')
SCRATCH = re.compile(r'swiftpm-([0-9a-f]{20})')
TICKET = re.compile(r'(?<![A-Za-z0-9])([A-Z][A-Z0-9]*-\d+)(?![A-Za-z0-9])')
# Only known regenerable children are retired. Unknown files and ALL receipts stay.
OUTPUTS = {'source', 'Checklist.app', '.build', 'bin', 'binaries', 'products',
           'ChecklistApp', 'ChecklistService', 'checklist'}
# Key files whose SHA-256 the evidence note records before the folder moves (CL-359).
KEY_FILES = {'notes.md', 'report.md'}


def safe(path):
    path = Path(path).absolute()
    if '..' in path.parts or any(p.is_symlink() for p in [path, *path.parents]):
        raise ValueError('symbolic link or parent traversal: ' + str(path))
    if path.exists() and path.stat().st_uid != os.getuid():
        raise ValueError('path is not owned by this user: ' + str(path))
    return path


def read_json(path):
    safe(path)
    return json.loads(path.read_text())


def fingerprint(info):
    value = info.get('source_fingerprint') if isinstance(info, dict) else None
    if not isinstance(value, str) or not FINGERPRINT.fullmatch(value):
        raise ValueError('missing or invalid source fingerprint')
    return value


def installation(build, installed):
    """Read bundle identities even when another checkout performed the install."""
    installed_id = fingerprint(read_json(installed / 'Contents/Resources/build-info.json'))
    # A matching receipt can prove that a newer predecessor is missing. Never
    # substitute an older surviving bundle in that case. A newer rollback bundle
    # supersedes the receipt even when the same source fingerprint was reinstalled.
    try:
        record = read_json(build / 'last-install.json')
        matches = (Path(record['installed']).resolve() == installed.resolve()
                   and fingerprint(record['build']) == installed_id)
    except (OSError, ValueError, KeyError, TypeError):
        record, matches = None, False
    previous = []
    for bundle in installed.parent.glob('.Checklist-previous-*.app'):
        match = re.fullmatch(r'\.Checklist-previous-(\d{8}T\d{6}Z)-\d+\.app', bundle.name)
        if not match:
            raise ValueError('previous bundle identity is unresolved; retain builds: ' + str(bundle))
        previous.append((match[1], bundle))
    if matches and record['previous_bundle'] is not None:
        recorded = safe(Path(record['previous_bundle']))
        match = re.fullmatch(r'\.Checklist-previous-(\d{8}T\d{6}Z)-\d+\.app', recorded.name)
        if recorded.parent != installed.parent or not match:
            raise ValueError('previous bundle identity is unresolved; retain builds')
        if not any(stamp > match[1] for stamp, _ in previous):
            fingerprint(read_json(recorded / 'Contents/Resources/build-info.json'))
    retained = {installed_id}
    bundles = [installed]
    if previous:
        latest = max(stamp for stamp, _ in previous)
        candidates = [bundle for stamp, bundle in previous if stamp == latest]
        if len(candidates) != 1:
            raise ValueError('immediate previous bundle is ambiguous; retain builds')
        bundle = candidates[0]
        retained.add(fingerprint(read_json(bundle / 'Contents/Resources/build-info.json')))
        bundles.append(bundle)
    else:
        # An absent rollback app is not proof of a first install. Only a matching
        # receipt explicitly recording no predecessor can establish that case.
        if not matches or record['previous_bundle'] is not None:
            raise ValueError('previous bundle identity is unresolved; retain builds')
    return retained, bundles


def running_bundle_builds(processes):
    retained = set()
    for bundle in processes:
        if bundle.suffix != '.app': continue
        known = (bundle.name == 'Checklist.app' or bundle.name.startswith('.Checklist-')
                 or re.fullmatch(r'Checklist Test [1-4]\.app', bundle.name)
                 or any(bundle/'Contents/MacOS'/name in processes
                        for name in ['ChecklistApp', 'ChecklistService', 'checklist']))
        if known or (bundle / 'Contents/MacOS/ChecklistApp').is_file():
            retained.add(fingerprint(read_json(bundle / 'Contents/Resources/build-info.json')))
    return retained


def size_of(entries):
    return sum(e[3] for e in entries.values() if not stat.S_ISDIR(e[2]))


def process_ancestors(paths):
    """Index once: matching a candidate must not rescan every open-file path."""
    return frozenset(parent for path in paths for parent in (path, *path.parents))


def protected_reason(path, entries, protected, processes, internal_links=False):
    if protection := workspace_protection(path, entries):
        return protection
    for target, label in protected:
        if slots.paths_overlap(path, target):
            return label
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        return 'unresolved cleanup path retained: ' + str(path) + ': ' + str(error)
    if resolved in processes:
        return 'running app, CLI or check uses this path'
    for entry, metadata in entries.items():
        if stat.S_ISLNK(metadata[2]) and internal_links:
            try:
                target = Path(os.path.abspath(entry.parent / os.readlink(entry)))
                if not within(target, resolved) or not within(entry.resolve(strict=True), resolved):
                    return 'external SwiftPM link retained: ' + str(entry)
            except (OSError, RuntimeError) as error:
                return 'unresolved SwiftPM link retained: ' + str(entry) + ': ' + str(error)
        elif not (stat.S_ISREG(metadata[2]) or stat.S_ISDIR(metadata[2])):
            return 'link or special file retained: ' + str(entry)
    if any(p.lstat().st_uid != os.getuid() for p in entries):
        return 'contains files owned by another user'
    return None


class Cleaner:
    def __init__(self, repo, installed, apply=False, process_reader=running_paths,
                 mover=trash, status_reader=None, keep=(), batch_mover=trash_many,
                 notes_path=None, note_poster=None, attachment_reader=None):
        self.repo = safe(repo)
        self.build = safe(self.repo / '.local/build')
        self.installed = safe(installed)
        self.apply = apply
        self.process_reader = process_reader
        self.mover = mover
        self.batch_mover = batch_mover
        self.pending = None
        self.process_snapshot = None
        self.preview_process_snapshot = None
        self.status_reader = status_reader
        self.keep = [safe(p) for p in keep]
        self.moved = 0
        self.failed = False
        # Evidence notes (CL-359): written to notes_path; posted only by apply.
        self.notes_path = notes_path
        self.note_poster = note_poster
        self.attachment_reader = attachment_reader
        self.reports = {}
        self.note_cache = {}
        self.owners = {}
        self.attachments = {}
        self.sizer = None
        self.protected_cache = None
        self.status_cache = None
        self.status_error = None
        # CL-359 item 0: folders with no owner record, listed in the summary.
        self.unregistered = []

    def protected(self):
        # Even when installation receipts are unavailable, no path may alias live
        # data, the installed app, a rollback app or an explicitly retained copy.
        # A preview lists them once per run; apply reads them fresh before each move.
        if not self.apply and self.protected_cache is not None: return self.protected_cache
        result = [(slots.live_root(), 'live store retained'),
                  (self.installed, 'installed app retained')]
        result += [(p, 'previous/incoming app retained') for p in
                   self.installed.parent.glob('.Checklist-*.app')]
        result += [(p, 'explicitly retained work/evidence') for p in self.keep]
        if not self.apply: self.protected_cache = result
        return result

    def processes(self):
        if self.process_snapshot is not None: return self.process_snapshot
        if self.preview_process_snapshot is None:
            self.preview_process_snapshot = process_ancestors(self.process_reader())
        return self.preview_process_snapshot

    def item(self, path, kind, reason=None, eligible=None, eligible_reason="eligible for Trash",
             internal_links=False, before_move=None, entries=None, extra=None):
        """Recheck identity, policy and use before each move; no cached apply plan."""
        if extra and extra.get('registration') == 'unregistered':
            self.unregistered.append(str(path))
        try:
            safe(path)
            before = inventory(path) if entries is None else entries
            # Retained containers and policy refusals need no process scan.
            why = reason or protected_reason(path, before, self.protected(), frozenset(), internal_links)
            if not why and eligible:
                why = eligible()
            if not why:
                why = protected_reason(path, before, self.protected(), self.processes(), internal_links)
            report = {'path': str(path), 'kind': kind, 'bytes': size_of(before),
                      'action': 'kept' if why else 'eligible',
                      'reason': why or eligible_reason}
            report.update(extra or {})
            self.reports[path] = report
            if not why and self.apply and self.pending is not None:
                self.pending.append((path, before, report, eligible, internal_links, before_move))
                return
            if not why and self.apply:
                if inventory(path) != before:
                    raise ValueError('item changed during inspection')
                why = protected_reason(path, before, self.protected(), process_ancestors(self.process_reader()), internal_links)
                if not why and eligible:
                    why = eligible()
                if why:
                    report.update(action='kept', reason=why)
                else:
                    if before_move: before_move()
                    report.update(action='trashed', trash=str(self.mover(path)))
                    self.moved += report['bytes']
            print(json.dumps(report, sort_keys=True))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            self.failed = True
            print(json.dumps({'path': str(path), 'kind': kind, 'action': 'kept_error', 'bytes': None, 'reason': str(error)}))

    def flush_builds(self, refresh=None):
        """One fresh process observation for the batch; builds also hold their lease."""
        try:
            processes = process_ancestors(self.process_reader())
            if refresh: refresh(processes)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.failed = True
            for _, _, report, *_ in self.pending:
                report.update(action='kept_error', reason=str(error))
                print(json.dumps(report, sort_keys=True))
            return
        selected = []
        for path, before, report, eligible, internal_links, before_move in self.pending:
            try:
                safe(path)
                if inventory(path) != before:
                    raise ValueError('item changed during inspection')
                why = protected_reason(path, before, self.protected(), processes, internal_links)
                if not why and eligible: why = eligible()
                if why:
                    report.update(action='kept', reason=why)
                    print(json.dumps(report, sort_keys=True))
                    continue
                if before_move: before_move()
                selected.append((path, before, report))
            except (OSError, ValueError, KeyError, TypeError) as error:
                self.failed = True
                report.update(action='kept_error', reason=str(error))
                print(json.dumps(report, sort_keys=True))
        if not selected: return
        # A same-volume Trash move needs write on the selected directory itself,
        # not its descendants. Keep only that descriptor open for chmod, never
        # follow links or change retained captures/parents. Restore failed moves.
        modes = {}
        try:
            for path, before, _ in selected:
                if stat.S_ISDIR(before[path][2]) and not before[path][2] & stat.S_IWUSR:
                    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                    try:
                        metadata = os.fstat(fd)
                        if (metadata.st_dev, metadata.st_ino) != before[path][:2]:
                            raise ValueError('item changed before permission adjustment: ' + str(path))
                        modes[path] = (stat.S_IMODE(metadata.st_mode), before[path][:2])
                        os.fchmod(fd, modes[path][0] | stat.S_IWUSR)
                    finally: os.close(fd)
            results = self.batch_mover([path for path, _, _ in selected])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            results = {path: error for path, _, _ in selected}
        finally:
            for path, (mode, identity) in modes.items():
                if path.exists():
                    # Never chmod a replacement or a link after a failed move.
                    metadata = path.lstat()
                    if (metadata.st_dev, metadata.st_ino) == identity and stat.S_ISDIR(metadata.st_mode):
                        path.chmod(mode, follow_symlinks=False)
        for path, _, report in selected:
            destination = results.get(path, ValueError('Trash did not report an outcome'))
            if isinstance(destination, Exception):
                self.failed = True
                report.update(action='kept_error', reason=str(destination))
            else:
                report.update(action='trashed', trash=str(destination))
                self.moved += report['bytes']
            print(json.dumps(report, sort_keys=True))

    def preserve_build_info(self, path, folder):
        info = path / 'Contents/Resources/build-info.json'
        if path.name != 'Checklist.app' or not info.exists(): return
        if fingerprint(read_json(info)) != folder.name:
            raise ValueError('staged build-info identity mismatch; retain app')
        receipt = folder / 'build-info.json'
        data = info.read_bytes()
        if receipt.exists():
            safe(receipt)
            if receipt.read_bytes() != data:
                raise ValueError('build-info receipts differ; retain app')
        else:
            with receipt.open('xb') as output: output.write(data)

    def builds(self):
        self.protected_cache = None
        retained, _ = installation(self.build, self.installed)
        processes = self.processes()
        running = running_bundle_builds(processes)
        def refresh(paths):
            nonlocal processes, running
            processes = paths
            running = running_bundle_builds(processes)
        def unchanged_install(folder=None):
            if installation(self.build, self.installed)[0] != retained:
                return 'installation changed; retain build'
            if folder is not None:
                if folder.name in running:
                    return 'running app bundle uses this capture'
                if folder.resolve() in processes:
                    return 'running app, CLI or check uses this capture'
            return None
        old_keep = self.keep
        self.keep = old_keep + [self.build / key for key in retained]
        self.pending = []
        try:
            self.process_snapshot = self.processes()
            for folder in sorted(self.build.iterdir()):
                if folder.name in {'test-impact-map.json', 'test-impact-index.json', 'index-inputs.json'}:
                    self.item(folder, 'test_selection_cache', reason='coverage/index selection evidence retained',
                              extra=SHARED)
                elif FINGERPRINT.fullmatch(folder.name):
                    owner = registration(folder)
                    if folder.name in retained:
                        self.item(folder, 'build', reason='installed/previous build retained', extra=owner)
                        continue
                    if why := unchanged_install(folder):
                        self.item(folder, 'build', reason=why, extra=owner)
                        continue
                    # A capture without a readable manifest (an old build-info-only
                    # folder) is kept and reported; it never stops the build pass.
                    try:
                        manifest = read_json(folder / 'capture-manifest.json')
                    except FileNotFoundError:
                        self.item(folder, 'build', reason='no capture manifest; retain build', extra=owner)
                        continue
                    except (OSError, ValueError) as error:
                        self.item(folder, 'build', reason='unreadable capture manifest; retain build: ' + str(error),
                                  extra=owner)
                        continue
                    if not isinstance(manifest, dict) or manifest.get('source_fingerprint') != folder.name:
                        self.item(folder, 'build', reason='capture identity mismatch', extra=owner)
                        continue
                    if owner['registration'] == 'unregistered':
                        self.unregistered.append(str(folder))
                    for child in sorted(folder.iterdir()):
                        scratch = bool(SCRATCH.fullmatch(child.name))
                        if child.name in OUTPUTS or scratch:
                            self.item(child, 'build_output', eligible=lambda f=folder: unchanged_install(f),
                                      internal_links=scratch or child.name == '.build',
                                      before_move=lambda p=child, f=folder: self.preserve_build_info(p, f),
                                      eligible_reason='obsolete copied build output; receipts retained',
                                      extra={'capture_registration': owner['registration'], 'tickets': owner['tickets']})
                elif SCRATCH.fullmatch(folder.name):
                    lane = self.build / ('lane-' + SCRATCH.fullmatch(folder.name)[1]) / 'source'
                    why = 'current persistent SwiftPM lane retained' if lane.is_dir() else None
                    self.item(folder, 'swiftpm_scratch', reason=why, eligible=unchanged_install,
                              internal_links=True, extra=SHARED,
                              eligible_reason='legacy SwiftPM scratch has no current persistent lane')
            if self.apply and self.pending: self.flush_builds(refresh)
        finally:
            self.pending = None
            self.process_snapshot = None
            self.preview_process_snapshot = None
            self.keep = old_keep

    def evidence_plan(self, folder):
        """Inventory one top-level tree once; aggregate container sizes bottom-up."""
        entries = inventory(folder)
        children, sizes, scoped, opaque = {}, {}, set(), set()
        for path, metadata in entries.items():
            children.setdefault(path.parent, []).append(path)
            sizes[path] = 0 if stat.S_ISDIR(metadata[2]) else metadata[3]
        for path in reversed(entries):
            names = {p.name for p in children.get(path, [])}
            if OWNER_RECORD not in names and (path.name in {'managed', 'source-captures', 'source', 'src', '.build'}
                                               or names & {'checklist.sqlite', 'database.sqlite'}):
                opaque.add(path)
            owns = bool(TICKET.search(path.name) or names & HANDIN_RECORDS or
                        (stat.S_ISDIR(entries[path][2]) and path not in opaque and names & {'report.md', 'notes.md'} and evidence_metadata_owners(path)[0]))
            if stat.S_ISDIR(entries[path][2]) and path not in opaque and (owns or any(p in scoped for p in children.get(path, []))):
                scoped.add(path)
            if path != folder: sizes[path.parent] += sizes[path]
        def subtree(path):
            yield path
            for child in children.get(path, []):
                yield from subtree(child)
        def walk(path):
            """('link'|'handin'|'container', path) in report order."""
            names = {p.name for p in children.get(path, [])}
            if stat.S_ISLNK(entries[path][2]):
                yield 'link', path
            elif stat.S_ISDIR(entries[path][2]) and path not in opaque and (TICKET.search(path.name) or names & HANDIN_RECORDS or (names & {'report.md', 'notes.md'} and evidence_metadata_owners(path)[0])):
                yield 'handin', path
            else:
                yield 'container', path
                if path in scoped:
                    for child in children.get(path, []):
                        if stat.S_ISDIR(entries[child][2]) or stat.S_ISLNK(entries[child][2]): yield from walk(child)
        steps = []
        for step, path in walk(folder):
            before = {p: entries[p] for p in subtree(path)} if step == 'handin' else None
            if step == 'handin': self.owners[path] = evidence_owners(path, before)
            steps.append((step, path, before))
        return entries, sizes, opaque, scoped, steps

    def evidence(self):
        root = safe(self.repo / '.local/evidence')
        if not root.exists(): return
        self.pending = [] if self.apply else None
        self.preview_process_snapshot = None
        self.protected_cache = None
        try:
            # Phase 1: inventory and owners for every hand-in, then one batched
            # status read for all keys (CL-359: no per-folder CLI round trip).
            plans = []
            for folder in sorted(root.iterdir()):
                try: plans.append((folder, self.evidence_plan(folder)))
                except (OSError, ValueError, KeyError, TypeError) as error: plans.append((folder, error))
            keys = sorted({k for owners in self.owners.values() for k in owners[0]})
            self.status_cache, self.status_error = {}, None
            if keys:
                try: self.status_cache = self.status_reader(keys)
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                    self.status_error = error
            self.prefetch_attachments()
            # Phase 2: report and, with --apply, select in the same order as before.
            for folder, plan in plans:
                try:
                    if isinstance(plan, Exception): raise plan
                    entries, sizes, opaque, scoped, steps = plan
                    for step, path, before in steps:
                        if step == 'link':
                            self.item(path, 'evidence', reason='symbolic link retained', entries={path: entries[path]})
                        elif step == 'handin':
                            post = ((lambda path=path, before=before: self.post_notes(path, before))
                                    if self.note_poster else None)
                            keys, basis, problems = self.owners.get(path, (set(), 'none', []))
                            self.item(path, 'evidence', eligible=self.evidence_check(path, before), entries=before,
                                      before_move=post, eligible_reason='all owning tickets are Done or canceled',
                                      extra={'registration': 'owner.json' if basis == OWNER_RECORD else
                                                             'invalid' if problems else 'unregistered',
                                             'tickets': sorted(keys), 'owner_basis': basis})
                        else:
                            directory = stat.S_ISDIR(entries[path][2])
                            state = 'container' if path in scoped else 'unregistered'
                            if state == 'unregistered': self.unregistered.append(str(path))
                            reason = ('store/source tree retained; no hand-in discovery' if path in opaque else
                                      'unscoped container retained; inspect ticket children' if path in scoped else
                                      'unscoped container retained; no ticket hand-ins' if directory else
                                      'unscoped evidence retained')
                            print(json.dumps({'path': str(path), 'kind': 'evidence_container' if directory else 'evidence',
                                              'bytes': sizes[path], 'action': 'kept', 'reason': reason,
                                              'registration': state}, sort_keys=True))
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                    self.failed = True
                    print(json.dumps({'path': str(folder), 'kind': 'evidence', 'action': 'kept_error', 'bytes': None, 'reason': str(error)}))
            if self.apply and self.pending: self.flush_builds()
        finally:
            self.pending = None
            self.preview_process_snapshot = None
            self.status_cache = None
            # Notes for every eligible folder, even when another folder failed.
            self.write_notes()

    def prefetch_attachments(self, workers=8):
        """Read attachment names for every ticket whose folder can retire, in parallel."""
        self.attachments = {}
        if not self.attachment_reader or self.status_error is not None or not self.status_cache: return
        keys = sorted({k for keys, _, problems in self.owners.values()
                       if keys and not problems and all(self.status_cache.get(k) in FINISHED for k in keys)
                       for k in keys})
        def read(key):
            try: return self.attachment_reader(key)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error: return error
        with ThreadPoolExecutor(max_workers=workers) as pool:
            self.attachments = dict(zip(keys, pool.map(read, keys)))

    def attached(self, key):
        if not self.attachment_reader: return None
        value = self.attachments[key] if key in self.attachments else self.attachment_reader(key)
        if isinstance(value, Exception): raise value
        return value

    def evidence_check(self, path, before):
        """Plan check reads the batched statuses; every later (pre-move) check reads fresh."""
        state = {'fresh': False}
        def eligible():
            keys, basis, problems = self.owners.get(path) or evidence_owners(path, before)
            if problems:
                return 'ownership record unreadable; retained: ' + '; '.join(problems)
            if not keys:
                return 'unknown owner: no ticket key in files.json, cleanup.json or folder name; retained'
            if state['fresh'] or self.status_cache is None:
                values = self.status_reader(keys)
            elif self.status_error is not None:
                raise ValueError('ticket status read failed: ' + str(self.status_error))
            else:
                values = self.status_cache
            state['fresh'] = True
            unresolved = sorted(k for k in keys if values.get(k) not in FINISHED)
            if unresolved:
                return ('name-only ownership requires every named and enclosing ticket Done or canceled; '
                        if 'names' in basis or basis.startswith('folder name') else '') + 'open or unknown ticket status: ' + ', '.join(unresolved)
            if self.notes_path is not None or self.note_poster:
                self.evidence_notes(path, before)
            return None
        return eligible

    def evidence_notes(self, path, entries):
        """Per-ticket note text: folder, size, owner basis, key-file SHA-256 and attached files."""
        if path in self.note_cache: return self.note_cache[path]
        keys, basis, _ = self.owners.get(path) or evidence_owners(path, entries)
        keys = sorted(keys)
        size = size_of(entries)
        count = sum(1 for e in entries.values() if not stat.S_ISDIR(e[2]))
        name = str(path.relative_to(self.repo / '.local/evidence'))
        hashes = [f'{p.relative_to(path)} sha256 {sha256(p)}' for p, e in sorted(entries.items())
                  if p.name in KEY_FILES and stat.S_ISREG(e[2])][:20]
        handed = sorted({row['path'] for p, e in entries.items() if p.name == 'files.json' and stat.S_ISREG(e[2])
                         for row in readable_rows(p) if isinstance(row.get('path'), str)})
        rows = []
        for key in keys:
            attached = self.attached(key)
            text = (f'Evidence cleanup for {key}: folder .local/evidence/{name} ({count} files, {size} bytes) '
                    f'moves to the Trash because all its tickets ({", ".join(keys)}) are Done or canceled.\n'
                    f'Owner basis: {basis}.\n'
                    f'Key files: {"; ".join(hashes) or "none"}.\n'
                    f'Hand-in files (files.json): {", ".join(handed[:50]) or "none"}'
                    f'{" and %d more" % (len(handed) - 50) if len(handed) > 50 else ""}.\n'
                    f'Files attached to {key}: '
                    f'{("none" if not attached else ", ".join(attached)) if attached is not None else "not read"}.')
            rows.append({'ticket': key, 'folder': str(path), 'bytes': size, 'owner_basis': basis,
                         'text': text, 'posted': False})
        self.note_cache[path] = rows
        return rows

    def post_notes(self, path, before):
        """Record each ticket note before the move; a failed note retains the evidence."""
        for row in self.evidence_notes(path, before):
            if row['posted']: continue
            try:
                self.note_poster(row['ticket'], row['text'])
            except (OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
                raise ValueError('evidence note not recorded; evidence retained: ' + str(error))
            row['posted'] = True

    def write_notes(self):
        if self.notes_path is None: return
        rows = [{**row, 'action': self.reports[path]['action']}
                for path, rows in self.note_cache.items() for row in rows
                if self.reports.get(path, {}).get('action') in ('eligible', 'trashed', 'kept_error')]
        with Path(self.notes_path).open('w') as output:
            for row in rows: output.write(json.dumps(row, sort_keys=True) + '\n')

    def test_slots(self):
        self.protected_cache = None
        for number in range(1, 5):
            p = slots.checked(number)
            if not p['folder'].exists(): continue
            def eligible():
                safe(slots.BASE)
                if (slots.BASE / f'.slot-{number}.lock').exists():
                    return 'slot command/check lock held; retain slot'
                slots.load(p)
                if slots.launch_state(p)['registered'] or any(slots.processes(p).values()):
                    return 'running or registered test slot retained'
                return None
            if not self.apply:
                # Preview fast path (CL-359): a marker-held slot reports from its
                # marker and one du size, with no full inventory.
                owner = slot_registration(p)
                held = held_slot_reason(p['folder'])
                if held:
                    if owner['registration'] == 'unregistered': self.unregistered.append(str(p['folder']))
                    size = (self.sizer or du_sizes)([p['folder']]).get(p['folder'])
                    print(json.dumps({'path': str(p['folder']), 'kind': 'test_slot', 'bytes': size,
                                      'action': 'kept', 'reason': held, **owner}, sort_keys=True))
                    continue
                self.item(p['folder'], 'test_slot', eligible=eligible, eligible_reason='idle slot; no app/check or registered job uses it',
                          extra=owner)
                continue
            # Preview decisions never authorize stopping an app. Acquire the same
            # lock used by create/start/check/promote, then destroy only if idle.
            why = eligible()
            if why:
                self.item(p['folder'], 'test_slot', reason=why)
                continue
            with slots.locked(number):
                def idle():
                    slots.stopped(p)
                    return None
                def destroy_idle(path):
                    slots.destroy(p, unused_only=True)
                    return 'see test_instances Destroy receipt'
                original = self.mover
                self.mover = destroy_idle
                try: self.item(p['folder'], 'test_slot', eligible=idle, eligible_reason='idle slot; no app/check or registered job uses it')
                finally: self.mover = original


def slot_registration(p):
    """CL-359: the tickets test_instances.py create records in slot.json."""
    try: tickets = slots.load(p).get('tickets')
    except (OSError, ValueError, KeyError, TypeError): tickets = None
    return ({'registration': 'slot.json', 'tickets': sorted(tickets)} if isinstance(tickets, list) and tickets
            else {'registration': 'unregistered', 'tickets': []})


def held_slot_reason(folder):
    """The persistent-marker reason when the folder or an ancestor holds it, else None."""
    if folder.is_symlink(): return None
    marker = folder / WORKSPACE_MARKER
    reason = workspace_protection(folder, {marker: None} if marker.is_file() else {})
    return reason if reason and reason.startswith('persistent workspace marker') else None


HANDIN_RECORDS = {'cleanup.json', 'files.json', OWNER_RECORD}
# Shared caches serve every ticket; they are never per-ticket registered.
SHARED = {'registration': 'shared_cache', 'tickets': []}


def registration(folder):
    """CL-359 report fields of a folder's owner.json: registered keys, 'unregistered' or 'invalid'."""
    try: record = read_owner_record(folder)
    except (OSError, ValueError): return {'registration': 'invalid', 'tickets': []}
    return ({'registration': OWNER_RECORD, 'tickets': record['tickets']} if record
            else {'registration': 'unregistered', 'tickets': []})


def ticket_values(value):
    """Valid ticket keys from a string, a list of strings or a list of {"key": ...} rows."""
    values = [value] if isinstance(value, (str, dict)) else value if isinstance(value, list) else []
    result = set()
    for item in values:
        if isinstance(item, dict): item = item.get('key')
        if isinstance(item, str) and TICKET.fullmatch(item): result.add(item)
    return result


def ownership_rows(data):
    """Entry rows and record-level keys of every hand-in files.json shape seen under .local/evidence:
    a list of entries, {"files": [...]}, a {name: {...}} map, or a top-level "ticket"/"tickets"."""
    keys, rows = set(), []
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict):
        keys = ticket_values(data.get('ticket')) | ticket_values(data.get('tickets'))
        files = data.get('files')
        rows = (files if isinstance(files, list) else list(files.values()) if isinstance(files, dict) else
                [value for value in data.values() if isinstance(value, dict)])
    return [row for row in rows if isinstance(row, dict)], keys


def readable_rows(path):
    try: return ownership_rows(read_json(path))[0]
    except (OSError, ValueError): return []


def report_owner_keys(path):
    """Read explicit legacy ownership headers, never arbitrary ticket mentions."""
    safe(path)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 2 * 1024 * 1024:
        raise ValueError('invalid or oversized evidence ownership report: ' + str(path))
    keys = set()
    for line in path.read_text().splitlines()[:30]:
        value = line.strip().strip('#').strip()
        declaration = re.match(r'(?i)(?:owning )?tickets?\s*:\s*(.+)$', value)
        if declaration:
            named = set(TICKET.findall(declaration[1]))
            remainder = TICKET.sub('', declaration[1]).strip(' ,;`*[]')
            if named and not remainder:
                keys |= named
        verdict = re.match(r'^(CL-\d+):\s*(?:\d+\s+)?(?:PASS|FAIL|NOT SHOWN|NOT RUN|PARTIAL)\b', value)
        if verdict:
            keys.add(verdict[1])
    return keys


def evidence_metadata_owners(folder):
    """Direct authoritative metadata, excluding names and nested fixture records."""
    folder = Path(folder)
    keys, sources, problems = set(), [], []
    try:
        record = read_owner_record(folder)
    except (OSError, ValueError) as error:
        return set(), OWNER_RECORD, [f'{OWNER_RECORD}: {error}']
    if record:
        return set(record['tickets']), OWNER_RECORD, []
    for name in ('files.json', 'cleanup.json', 'report.md', 'notes.md'):
        path = folder / name
        if not path.exists() and not path.is_symlink():
            continue
        try:
            if name in ('report.md', 'notes.md'):
                found = report_owner_keys(path)
            else:
                data = read_json(path)
                if name == 'files.json':
                    rows, found = ownership_rows(data)
                    for row in rows:
                        found |= ticket_values(row.get('ticket')) | ticket_values(row.get('tickets'))
                else:
                    found = ticket_values(data.get('tickets')) if isinstance(data, dict) else set()
            if found:
                keys |= found
                sources.append(name)
        except (OSError, ValueError, UnicodeError) as error:
            problems.append(f'{name}: {error}')
    return keys, ', '.join(sources) or 'none', problems


def evidence_owners(folder, entries=None):
    """An enclosing evidence owner owns the whole tree; names cannot split it.

    Without authoritative metadata, all names in this tree and its enclosing
    folders contribute safety gates. A nested filename alone is never ownership.
    """
    folder = Path(folder)
    ancestors = []
    for parent in folder.parents:
        if parent.name == 'evidence' and parent.parent.name == '.local':
            break
        ancestors.append(parent)
    else:
        ancestors = []  # Standalone fixtures never inspect arbitrary parents.
    for parent in reversed(ancestors):
        keys, basis, problems = evidence_metadata_owners(parent)
        if keys or problems:
            return keys, 'enclosing ' + str(parent) + ': ' + basis, problems
    keys, basis, problems = evidence_metadata_owners(folder)
    if problems or basis == OWNER_RECORD or 'report.md' in basis or 'notes.md' in basis:
        return keys, basis, problems
    entries = inventory(folder) if entries is None else entries
    if keys:
        # Legacy manifests retain their conservative union with names; only an
        # explicit owner registration or a runner ownership header supersedes it.
        nested = {key for path in entries if path != folder for key in TICKET.findall(path.name)}
        own = set(TICKET.findall(folder.name))
        keys |= own | nested
        named = []
        if nested: named.append('file names')
        if own: named.append('folder name')
        if named: basis += ', ' + ' and '.join(named)
        return keys, basis, problems
    enclosing = {key for parent in ancestors for key in TICKET.findall(parent.name)}
    own = set(TICKET.findall(folder.name))
    if not own and not enclosing:
        return set(), 'none', []
    nested = {key for path in entries if path != folder for key in TICKET.findall(path.name)}
    keys = own | enclosing | nested
    named = []
    if nested: named.append('file names')
    if own: named.append('folder name')
    if enclosing: named.append('enclosing folder names')
    missing = 0
    record = folder / 'files.json'
    if record in entries:
        try:
            missing = sum(not (ticket_values(row.get('ticket')) | ticket_values(row.get('tickets')))
                          for row in ownership_rows(read_json(record))[0])
        except (OSError, ValueError): pass  # Direct record errors already returned above.
    label = ' and '.join(named)
    if missing: label += f' ({missing} files.json entries have no ticket key)'
    return keys, label, []

def evidence_keys(folder, entries=None):
    return evidence_owners(folder, entries)[0]


def status_rows(payload, project):
    if payload.get('project_id') != project:
        raise ValueError('status list project_id does not match')
    result = {}
    for row in payload['tasks']:
        key = row['key']
        if key in result: raise ValueError('ambiguous duplicate ticket key: ' + key)
        result[key] = row.get('status_category')
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''): digest.update(block)
    return digest.hexdigest()


def cli_call(repo, cli, method, arguments):
    result = subprocess.run([str(cli), 'call', method, json.dumps(arguments)],
                            cwd=repo, capture_output=True, text=True, check=True, timeout=60)
    return json.loads(result.stdout)['data']


def resolve_project(repo, cli, project):
    if project: return project
    projects = cli_call(repo, cli, 'project_resolve', {'workspace_path': str(repo)})['projects']
    if len(projects) != 1: raise ValueError('project scope ambiguous; supply --project-id')
    return projects[0]['id']


def task_id(repo, cli, project, key, ids=None):
    if ids and key in ids: return ids[key]
    data = cli_call(repo, cli, 'task_get', {'project_id': project, 'key': key})
    if data.get('key') != key: raise ValueError('task_get returned another ticket for ' + key)
    return data['id']


def attachment_reader(repo, cli, project, ids=None):
    """Read-only names of files attached to a ticket; ids from the status read skip task_get."""
    def read(key):
        rows = cli_call(repo, cli, 'attachment_list', {'project_id': project, 'task_id': task_id(repo, cli, project, key, ids),
                                                       'limit': 100})['attachments']
        return sorted(str(r.get('filename') or r.get('name') or r.get('id')) for r in rows)
    return read


def note_poster(repo, cli, project):
    """Agent action: one ticket note through message_send (default handler route)."""
    def post(key, text):
        return cli_call(repo, cli, 'message_send', {'project_id': project, 'task_id': task_id(repo, cli, project, key),
                                                    'kind': 'note', 'body': text})
    return post


def status_reader(repo, cli, project, status_file=None, ids=None):
    def call(method, arguments):
        return cli_call(repo, cli, method, arguments)
    project = resolve_project(repo, cli, project)
    def read(keys):
        if status_file:
            # Reload on each check so a changed supplied list is not cached.
            return status_rows(read_json(status_file), project)
        rows = []
        ordered = sorted(keys)
        for offset in range(0, len(ordered), 100):
            arguments = {'project_id': project, 'keys': ordered[offset:offset+100],
                         'fields': ['status_category'], 'limit': 100}
            while True:
                data = call('task_list', arguments)
                rows.extend(data['tasks'])
                if ids is not None:
                    ids.update({r['key']: r['id'] for r in data['tasks'] if isinstance(r.get('id'), str)})
                if not data.get('has_more'): break
                cursor = data.get('next_cursor')
                if not cursor or cursor == arguments.get('cursor'): raise ValueError('incomplete ticket statuses')
                arguments['cursor'] = cursor
        return status_rows({'project_id': project, 'tasks': rows}, project)
    return read


@contextmanager
def build_lock(build, apply):
    lock = safe(build / '.build-lock')
    if lock.exists(): raise ValueError('build lock held; retain build outputs')
    if not apply:
        yield
        return
    lock.mkdir()
    try: yield
    finally: lock.rmdir()


def finish(cleaner):
    # CL-359 item 0: folders without an owner record, for registration follow-up.
    print(json.dumps({'action': 'summary', 'bytes_removed': cleaner.moved,
                      'unregistered_count': len(cleaner.unregistered), 'unregistered': cleaner.unregistered[:200],
                      'meaning': 'logical bytes moved to Trash; disk space is not reclaimed until Trash is emptied'}))
    return 1 if cleaner.failed else 0


def release_workspace(repo, environ):
    """The registered project folder for the release status reads: CHECKLIST_WORKSPACE,
    else the local origin checkout of an integration copy (installs built from a clone),
    else the repo itself. The CLI binds its project scope to its working folder."""
    if environ.get('CHECKLIST_WORKSPACE'):
        return Path(environ['CHECKLIST_WORKSPACE']).resolve()
    try:
        origin = subprocess.run(['git', '-C', str(repo), 'remote', 'get-url', 'origin'],
                                capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        origin = ''
    if origin and os.path.isabs(origin) and (Path(origin) / '.git').exists():
        return Path(origin).resolve()
    return Path(repo).resolve()


def release_done(repo, environ=None, reader=None, sessions_root=None, qualification_root=None):
    """CL-359 item 1: each install is a round boundary. Run clean_scratch.py
    --release-done for the installing session: release its marked folders whose
    tickets are all Done or canceled. Release only changes the marker; the move
    happens at the next clean_scratch.py --apply, which still keeps a folder a
    running process uses. Folders of open tickets stay marked."""
    environ = os.environ if environ is None else environ
    session = native_session(environ)
    if not session or session in {'.', '..'} or '/' in session:
        print(json.dumps({'action': 'release_done', 'status': 'skipped',
                          'reason': 'no caller session exported; run clean_scratch.py --release-done'}), flush=True)
        print('WARNING: POST-INSTALL RELEASE SKIPPED: no caller session (' + ', '.join(SESSION_VARIABLES)
              + ') is exported; run clean_scratch.py --release-done.', file=sys.stderr, flush=True)
        return 2
    try:
        readiness = ServiceReadiness()
        reader = reader or cli_status_reader(Path('/Applications/Checklist.app/Contents/MacOS/checklist'),
                                             release_workspace(repo, environ), environ.get('CHECKLIST_PROJECT_ID'),
                                             timeout=readiness.call_timeout)
        roots = ticket_roots(Path(sessions_root or f'/private/tmp/claude-{os.getuid()}'),
                             Path(qualification_root or Path.home() / 'Library/Caches/ChecklistQualification'), session)
        status = release_finished(roots, session, lambda keys: readiness.read(reader, keys))
        if readiness.failure is not None:
            # The report and the installer's own output name the CLI's real error.
            print(json.dumps({'action': 'release_done', 'status': 'failed', 'code': error_code(readiness.failure) or error_code(readiness.failure.__cause__),
                              'reason': str(readiness.failure), 'attempts': readiness.attempts,
                              'waited_seconds': round(readiness.waited_seconds, 3)}), flush=True)
            print(f'WARNING: POST-INSTALL RELEASE FAILED: {readiness.failure}; markers kept; '
                  'run clean_scratch.py --release-done from the session.', file=sys.stderr, flush=True)
        return status
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({'action': 'release_done', 'status': 'failed', 'reason': str(error)}), flush=True)
        return 1


def _build_cleanup(repo, capture):
    """Acquire our own lease after the installer handed its lease back."""
    cleaner = None
    try:
        cleaner = Cleaner(Path(repo), Path('/Applications/Checklist.app'), apply=True)
        with build_lock(cleaner.build, True):
            ids, _ = installation(cleaner.build, cleaner.installed)
            if fingerprint(read_json(Path(capture) / 'capture-manifest.json')) not in ids:
                raise ValueError('installed build changed before cleanup')
            cleaner.builds()
        status = finish(cleaner)
        return status, {'status': 'failed' if status else 'ok'}
    except Exception as error:  # report it; the release does not depend on it
        report = {'status': 'failed', 'reason': f'{type(error).__name__}: {error}'}
        print(json.dumps({'action': 'build_cleanup', **report}), flush=True)
        if cleaner is not None:
            finish(cleaner)  # bytes already moved before the failure, if any
        return 1, report


def _release(repo, release):
    try:
        return (release or release_done)(repo)
    except Exception as error:
        print(json.dumps({'action': 'release_done', 'status': 'failed',
                          'reason': f'{type(error).__name__}: {error}'}), flush=True)
        return 1


def _release_report(status):
    return {'status': {0: 'ok', 2: 'skipped'}.get(status, 'failed')}


def post_install_build(repo, capture):
    """The install hook's background step (under nohup). It holds the build lease and calls no CLI."""
    status, report = _build_cleanup(repo, capture)
    print(json.dumps({'action': 'post_install_build', 'build_cleanup': report}), flush=True)
    return status


def post_install_release(repo, release=None):
    """The install hook's foreground step (CL-372). The CLI finds its native session
    through its parent processes, so this runs while the installer is still alive:
    after the installer exits, a reparented process gets a refusal, not a status."""
    status = _release(repo, release)
    print(json.dumps({'action': 'post_install_release', 'release_done': _release_report(status)}), flush=True)
    return status


def post_install(repo, capture, release=None):
    """Both steps for a run by hand from a session. A failed or refused build cleanup
    still runs the release (CL-359), and the result line reports both."""
    build_status, build_report = _build_cleanup(repo, capture)
    # The release runs after the build lease ends; a failure never undoes the build cleanup.
    release_status = _release(repo, release)
    print(json.dumps({'action': 'post_install', 'build_cleanup': build_report,
                      'release_done': _release_report(release_status)}), flush=True)
    return 1 if (build_status or release_status == 1) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preview', action='store_true')
    mode.add_argument('--apply', action='store_true')
    parser.add_argument('--only', choices=['all', 'builds', 'evidence', 'slots'], default='all')
    parser.add_argument('--repo', type=Path, default=REPO)
    parser.add_argument('--installed-app', type=Path, default=Path('/Applications/Checklist.app'))
    parser.add_argument('--cli', type=Path, default=Path('/Applications/Checklist.app/Contents/MacOS/checklist'))
    parser.add_argument('--project-id')
    parser.add_argument('--status-file', type=Path, help='explicit project_id/tasks status list, with status_category per key')
    parser.add_argument('--keep', type=Path, action='append', default=[], help='retain assigned slots, hand-ins or qualified copies (repeatable)')
    parser.add_argument('--evidence-notes', type=Path,
                        help='write one note per owning ticket (folder, size, SHA-256 of notes.md/report.md, attached files) for evidence that retires')
    parser.add_argument('--post-notes', action='store_true',
                        help='with --apply and --evidence-notes: send each note with message_send before the folder moves')
    parser.add_argument('--sessions-root', type=Path, default=Path(f'/private/tmp/claude-{os.getuid()}'))
    parser.add_argument('--qualification-root', type=Path, default=Path.home() / 'Library/Caches/ChecklistQualification')
    parser.add_argument('--budget-gb', type=float,
                        default=float(os.environ.get('CHECKLIST_CLEANUP_BUDGET_GB', DEFAULT_BUDGET_GB)),
                        help='warn when scratch, evidence, build and qualification folders exceed this size')
    args = parser.parse_args()
    if args.post_notes and not (args.apply and args.evidence_notes):
        parser.error('--post-notes requires --apply and --evidence-notes')
    cleaner = Cleaner(args.repo, args.installed_app, args.apply, keep=args.keep, notes_path=args.evidence_notes)
    # Report the folders this run covers; the default run covers all four groups.
    groups = storage_groups(args.sessions_root.expanduser(), args.qualification_root.expanduser(), cleaner.repo)
    if args.only != 'all':
        groups = {name: paths for name, paths in groups.items() if name == {'builds': 'build'}.get(args.only, args.only)}
    # Preview sizes the folders while it inspects them (CL-359: du was most of the
    # real 72 s preview). Apply sizes after its moves.
    slot_folders = []
    if args.only in ['all', 'slots'] and not args.apply:
        try: slot_folders = [f for f in (slots.checked(n)['folder'] for n in range(1, 5)) if f.exists()]
        except (OSError, ValueError): slot_folders = []
    sizer = background_sizes({**groups, 'slots': slot_folders}) if groups and not args.apply else None
    cleaner.sizer = sizer
    if args.only in ['all', 'builds'] and cleaner.build.exists():
        try:
            with build_lock(cleaner.build, args.apply): cleaner.builds()
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            cleaner.failed = True
            print(json.dumps({'kind': 'builds', 'action': 'kept_error', 'bytes': None, 'reason': str(error)}))
    if args.only in ['all', 'evidence']:
        ids = {}
        project = resolve_project(cleaner.repo, args.cli, args.project_id)
        cleaner.status_reader = status_reader(cleaner.repo, args.cli, project, args.status_file, ids)
        if args.evidence_notes and not args.status_file:
            cleaner.attachment_reader = attachment_reader(cleaner.repo, args.cli, project, ids)
            if args.post_notes: cleaner.note_poster = note_poster(cleaner.repo, args.cli, project)
        elif args.post_notes:
            parser.error('--post-notes needs the installed CLI; omit --status-file')
        cleaner.evidence()
    if args.only in ['all', 'slots']: cleaner.test_slots()
    if groups: storage_report(groups, args.budget_gb * 1e9, sizer)
    return finish(cleaner)


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Cleanup refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
