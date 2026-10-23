#!/usr/bin/env python3
"""Preview build, hand-in and idle-slot retirement. Apply moves bytes to the Trash.

Counts are logical bytes moved, not recovered APFS space. Unknown ownership/use
is retained. Preview is read-only; apply recomputes every decision.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

from clean_scratch import inventory, running_paths, within
from retire_old_bundles import trash, trash_many
import test_instances as slots

REPO = Path(__file__).resolve().parents[1]
FINGERPRINT = re.compile(r'[0-9a-f]{64}')
LANE = re.compile(r'lane-([0-9a-f]{20})')
SCRATCH = re.compile(r'swiftpm-([0-9a-f]{20})')
TICKET = re.compile(r'(?<![A-Za-z0-9])([A-Z][A-Z0-9]*-\d+)(?![A-Za-z0-9])')
# Only known regenerable children are retired. Unknown files and ALL receipts stay.
OUTPUTS = {'source', 'Checklist.app', '.build', 'bin', 'binaries', 'products',
           'ChecklistApp', 'ChecklistService', 'checklist'}


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
    value = info.get('source_fingerprint')
    if not isinstance(value, str) or not FINGERPRINT.fullmatch(value):
        raise ValueError('missing or invalid source fingerprint')
    return value


def installation(build, installed):
    """Bind retention to the actual installed and recorded immediate previous app."""
    info = installed / 'Contents/Resources/build-info.json'
    installed_id = fingerprint(read_json(info))
    record = read_json(build / 'last-install.json')
    if Path(record['installed']).resolve() != installed.resolve() or fingerprint(record['build']) != installed_id:
        raise ValueError('last-install does not match the installed app; retain builds')
    retained = {installed_id}
    bundles = [installed]
    previous = record['previous_bundle']
    if previous is not None:
        previous = safe(Path(previous))
        if previous.parent.resolve() != installed.parent.resolve() or not re.fullmatch(
                r'\.Checklist-previous-\d{8}T\d{6}Z-\d+\.app', previous.name):
            raise ValueError('previous bundle identity is unresolved; retain builds')
        # A previous bundle retired after qualification may already be in Trash.
        # Without its identity we cannot prove which capture to retain.
        retained.add(fingerprint(read_json(previous / 'Contents/Resources/build-info.json')))
        bundles.append(previous)
    return retained, bundles


def size_of(entries):
    return sum(e[3] for e in entries.values() if not stat.S_ISDIR(e[2]))


def process_ancestors(paths):
    """Index once: matching a candidate must not rescan every open-file path."""
    return frozenset(parent for path in paths for parent in (path, *path.parents))


def protected_reason(path, entries, protected, processes, internal_links=False):
    for target, label in protected:
        if slots.paths_overlap(path, target):
            return label
    resolved = path.resolve()
    if resolved in processes:
        return 'running app, CLI or check uses this path'
    for entry, metadata in entries.items():
        if stat.S_ISLNK(metadata[2]) and internal_links:
            try:
                target = Path(os.path.abspath(entry.parent / os.readlink(entry)))
                if not within(target, resolved) or not within(entry.resolve(), resolved):
                    return 'external SwiftPM link retained: ' + str(entry)
            except (OSError, RuntimeError):
                return 'unresolved SwiftPM link retained: ' + str(entry)
        elif not (stat.S_ISREG(metadata[2]) or stat.S_ISDIR(metadata[2])):
            return 'link or special file retained: ' + str(entry)
    if any(p.lstat().st_uid != os.getuid() for p in entries):
        return 'contains files owned by another user'
    return None


class Cleaner:
    def __init__(self, repo, installed, apply=False, process_reader=running_paths,
                 mover=trash, status_reader=None, keep=(), batch_mover=trash_many):
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

    def protected(self):
        # Even when installation receipts are unavailable, no path may alias live
        # data, the installed app, a rollback app or an explicitly retained copy.
        result = [(slots.live_root(), 'live store retained'),
                  (self.installed, 'installed app retained')]
        result += [(p, 'previous/incoming app retained') for p in
                   self.installed.parent.glob('.Checklist-*.app')]
        result += [(p, 'explicitly retained work/evidence') for p in self.keep]
        return result

    def processes(self):
        if self.process_snapshot is not None: return self.process_snapshot
        if self.apply: return process_ancestors(self.process_reader())
        if self.preview_process_snapshot is None:
            self.preview_process_snapshot = process_ancestors(self.process_reader())
        return self.preview_process_snapshot

    def item(self, path, kind, reason=None, eligible=None, eligible_reason="eligible for Trash",
             internal_links=False, before_move=None):
        """Recheck identity, policy and use before each move; no cached apply plan."""
        try:
            safe(path)
            before = inventory(path)
            protected = self.protected()
            processes = self.processes()
            why = reason or protected_reason(path, before, protected, processes, internal_links)
            if not why and eligible:
                why = eligible()
            report = {'path': str(path), 'kind': kind, 'bytes': size_of(before),
                      'action': 'kept' if why else 'eligible',
                      'reason': why or eligible_reason}
            if not why and self.apply and self.pending is not None:
                self.pending.append((path, before, report, eligible, internal_links, before_move))
                return
            if not why and self.apply:
                if inventory(path) != before:
                    raise ValueError('item changed during inspection')
                why = protected_reason(path, before, self.protected(), process_ancestors(self.process_reader()))
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

    def flush_builds(self):
        """One fresh process observation for the whole batch, under the build lease."""
        try:
            processes = process_ancestors(self.process_reader())
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
        retained, _ = installation(self.build, self.installed)
        def unchanged_install():
            return None if installation(self.build, self.installed)[0] == retained else 'installation changed; retain build'
        old_keep = self.keep
        self.keep = old_keep + [self.build / key for key in retained]
        self.pending = []
        try:
            self.process_snapshot = self.processes()
            for folder in sorted(self.build.iterdir()):
                if FINGERPRINT.fullmatch(folder.name):
                    if folder.name in retained:
                        self.item(folder, 'build', reason='installed/previous build retained')
                        continue
                    manifest = read_json(folder / 'capture-manifest.json')
                    if fingerprint(manifest) != folder.name:
                        self.item(folder, 'build', reason='capture identity mismatch')
                        continue
                    for child in sorted(folder.iterdir()):
                        scratch = bool(SCRATCH.fullmatch(child.name))
                        if child.name in OUTPUTS or scratch:
                            self.item(child, 'build_output', eligible=unchanged_install,
                                      internal_links=scratch or child.name == '.build',
                                      before_move=lambda p=child, f=folder: self.preserve_build_info(p, f),
                                      eligible_reason='obsolete copied build output; receipts retained')
                elif SCRATCH.fullmatch(folder.name):
                    lane = self.build / ('lane-' + SCRATCH.fullmatch(folder.name)[1]) / 'source'
                    why = 'current persistent SwiftPM lane retained' if lane.is_dir() else None
                    self.item(folder, 'swiftpm_scratch', reason=why, eligible=unchanged_install,
                              internal_links=True,
                              eligible_reason='legacy SwiftPM scratch has no current persistent lane')
            if self.apply and self.pending: self.flush_builds()
        finally:
            self.pending = None
            self.process_snapshot = None
            self.keep = old_keep

    def evidence(self):
        root = safe(self.repo / '.local/evidence')
        if not root.exists(): return
        def visit(folder):
            if folder.is_symlink():
                self.item(folder, 'evidence', reason='symbolic link retained')
                return
            # Untagged round containers are not presumed to own every log. Walk
            # their ticket hand-ins independently and retain the container.
            if TICKET.search(folder.name) or (folder / 'cleanup.json').exists() or (folder / 'files.json').exists():
                def eligible():
                    keys = evidence_keys(folder)
                    values = self.status_reader(keys)
                    unresolved = sorted(k for k in keys if values.get(k) != 'done')
                    return 'open or unknown ticket status: ' + ', '.join(unresolved) if unresolved else None
                self.item(folder, 'evidence', eligible=eligible,
                          eligible_reason='all owning tickets are Done')
            else:
                self.item(folder, 'evidence_container', reason='unscoped container retained; inspect ticket children')
                for child in sorted(folder.iterdir()):
                    if child.is_dir() and not child.is_symlink(): visit(child)
        for folder in sorted(root.iterdir()):
            if folder.is_dir() or folder.is_symlink(): visit(folder)
            else: self.item(folder, 'evidence', reason='unscoped evidence retained')

    def test_slots(self):
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
                self.item(p['folder'], 'test_slot', eligible=eligible, eligible_reason='idle slot; no app/check or registered job uses it')
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


def evidence_keys(folder):
    keys = set()
    for path, entry in inventory(folder).items():
        keys.update(TICKET.findall(path.name))
        if path.name == 'files.json':
            records = read_json(path)
            if not isinstance(records, list) or not records:
                raise ValueError('invalid hand-in files.json ownership')
            for row in records:
                value = row.get('ticket')
                if not isinstance(value, str) or not TICKET.fullmatch(value):
                    raise ValueError('hand-in entry lacks a ticket key')
                keys.add(value)
        elif path.name == 'cleanup.json':
            values = read_json(path)['tickets']
            if not isinstance(values, list) or not values or any(
                    not isinstance(k, str) or not TICKET.fullmatch(k) for k in values):
                raise ValueError('cleanup.json must list every owning ticket key')
            keys.update(values)
    if not keys: raise ValueError('evidence ticket ownership unknown')
    return keys


def status_rows(payload, project):
    if payload.get('project_id') != project:
        raise ValueError('status list project_id does not match')
    result = {}
    for row in payload['tasks']:
        key = row['key']
        if key in result: raise ValueError('ambiguous duplicate ticket key: ' + key)
        result[key] = row.get('status_category')
    return result


def status_reader(repo, cli, project, status_file=None):
    def call(method, arguments):
        result = subprocess.run([str(cli), 'call', method, json.dumps(arguments)],
                                cwd=repo, capture_output=True, text=True, check=True, timeout=60)
        return json.loads(result.stdout)['data']
    if not project:
        projects = call('project_resolve', {'workspace_path': str(repo)})['projects']
        if len(projects) != 1: raise ValueError('project scope ambiguous; supply --project-id')
        project = projects[0]['id']
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
    print(json.dumps({'action': 'summary', 'bytes_removed': cleaner.moved,
                      'meaning': 'logical bytes moved to Trash; disk space is not reclaimed until Trash is emptied'}))
    return 1 if cleaner.failed else 0


def post_install(repo, capture):
    """Explicit background install step; acquire our own lease after installer exit."""
    cleaner = Cleaner(Path(repo), Path('/Applications/Checklist.app'), apply=True)
    with build_lock(cleaner.build, True):
        ids, _ = installation(cleaner.build, cleaner.installed)
        if fingerprint(read_json(Path(capture) / 'capture-manifest.json')) not in ids:
            raise ValueError('installed build changed before cleanup')
        cleaner.builds()
    return finish(cleaner)


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
    args = parser.parse_args()
    cleaner = Cleaner(args.repo, args.installed_app, args.apply, keep=args.keep)
    if args.only in ['all', 'builds'] and cleaner.build.exists():
        try:
            with build_lock(cleaner.build, args.apply): cleaner.builds()
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            cleaner.failed = True
            print(json.dumps({'kind': 'builds', 'action': 'kept_error', 'bytes': None, 'reason': str(error)}))
    if args.only in ['all', 'evidence']:
        cleaner.status_reader = status_reader(cleaner.repo, args.cli, args.project_id, args.status_file)
        cleaner.evidence()
    if args.only in ['all', 'slots']: cleaner.test_slots()
    return finish(cleaner)


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('Cleanup refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
