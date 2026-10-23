#!/usr/bin/env python3
"""Preview Checklist scratch cleanup; --apply moves eligible bytes to the Trash.

Logical byte counts are not a promise of recovered disk space (APFS/sparse files).
No checkout, global compiler cache, evidence record or Git metadata is deleted.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time

from retire_old_bundles import trash

REPO = Path(__file__).resolve().parents[1]
BUILD_NAMES = {'.build', 'CompilationCache.noindex', 'CompilationCache', 'module-cache'}
QUIET_SECONDS = 45 * 60


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


def inventory(root):
    """lstat every entry, including directories; never walk through links."""
    result = {}
    def visit(path):
        metadata = path.lstat()
        result[path] = (metadata.st_dev, metadata.st_ino, metadata.st_mode,
                        metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)
        if stat.S_ISDIR(metadata.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
    visit(root)
    return result


def running_paths():
    """Observe executable, cwd, open-file and absolute command argument paths.

    Failed process inspection refuses cleanup rather than treating unknown as idle.
    No process is launched, stopped or signaled by cleanup.
    """
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-u', str(os.getuid()), '-Fpn'],
                            capture_output=True, text=True)
    if result.returncode != 0 or result.stderr.strip():
        raise ValueError('process inspection incomplete: ' + result.stderr.strip())
    paths = [Path(line[1:]).resolve() for line in result.stdout.splitlines()
             if line.startswith('n/')]
    commands = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    for line in commands.splitlines():
        try:
            arguments = shlex.split(line)
        except ValueError:
            # An unmatched quote is possible in a process title; lsof still
            # supplies cwd/executable/open files. Preserve absolute fragments.
            arguments = line.split()
        for argument in arguments:
            value = argument.split('=', 1)[-1] if argument.startswith('-') else argument
            if value.startswith('/'):
                paths.append(Path(value).resolve())
    return paths


def children(path):
    return sorted(path.iterdir()) if path.is_dir() and not path.is_symlink() else []


def candidates(sessions, qualification):
    """Only session scratchpad entries and direct qualification runs are in scope.

    A spare process is not inherently a Checklist session. Its individual items
    must contain a Checklist manifest held by the retained repository.
    """
    for host in children(sessions):
        checklist = 'Checklist' in host.name
        if not checklist and 'spare-' not in host.name:
            continue
        for session in children(host):
            for item in children(session / 'scratchpad'):
                yield item, 'session' if checklist else 'spare'
    for item in children(qualification):
        yield item, 'qualification'


def installed_fingerprint(path):
    try:
        value = json.loads(path.read_text())['source_fingerprint']
        return value if isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def plan(item, kind, objects, processes, fingerprint, keep=(), now=None):
    before = inventory(item)
    files = {path: entry for path, entry in before.items() if not stat.S_ISDIR(entry[2])}
    size = sum(entry[3] for entry in files.values())
    reason = None
    if item.is_symlink():
        reason = 'symbolic link; never followed'
    elif kind == 'spare' and not any(
        path.name == 'Package.swift' and stat.S_ISREG(entry[2]) and
        blob_id(path) in objects and b'"Checklist"' in path.read_bytes()
        for path, entry in files.items()
    ):
        reason = 'spare item has no retained Checklist package identity'
    elif any(overlap(item, path) for path in keep):
        reason = 'explicitly retained qualified copy or persistent build slot'
    elif any(re.fullmatch(r'ws[a-z]*\d+', path.name) and
             stat.S_ISDIR(entry[2]) and path / 'src' in before and
             stat.S_ISDIR(before[path / 'src'][2]) for path, entry in before.items()):
        reason = 'persistent build slot; reuse its source and warm .build'
    elif fingerprint is None:
        reason = 'latest installed identity unavailable; qualified-copy retention unresolved'
    else:
        for path, entry in files.items():
            if path.name not in {'capture-manifest.json', 'build-info.json', 'source-manifest.json'}:
                continue
            if not stat.S_ISREG(entry[2]):
                continue
            try:
                if json.loads(path.read_text()).get('source_fingerprint') == fingerprint:
                    reason = 'qualified copy of latest installed round (matching source fingerprint)'
                    break
            except (ValueError, AttributeError):
                # An unreadable receipt is not proof that a copy is obsolete.
                reason = 'unreadable build identity; qualified-copy retention unresolved'
                break
    if not reason and any(within(path, item) for path in processes):
        reason = 'running process uses this item'
    cutoff = (time.time() if now is None else now) - QUIET_SECONDS
    if not reason and any(entry[4] / 1e9 >= cutoff or entry[5] / 1e9 >= cutoff
                          for entry in before.values()):
        reason = 'files or directories changed in the last 45 minutes'

    counts = Counter(build_bytes=0, git_redundant_source_bytes=0, kept_bytes=0)
    reasons = Counter()
    removable = set()
    for path, entry in files.items():
        parts = path.relative_to(item).parts
        # Include the item's own name for an item that is itself a build folder.
        components = (item.name,) + parts
        why = reason
        category = 'kept_bytes'
        if not why:
            if not stat.S_ISREG(entry[2]):
                why = 'link or special file; never followed or moved'
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
    moves = []
    children_by_parent = {}
    removable_tree = {}
    for path, entry in reversed(list(before.items())):
        children_by_parent.setdefault(path.parent, []).append(path)
        removable_tree[path] = (all(removable_tree[p] for p in children_by_parent.get(path, []))
                                 and bool(children_by_parent.get(path))) if stat.S_ISDIR(entry[2]) else path in removable
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
            'reasons': dict(reasons), 'moves': moves, 'inventory': before}


def clean(sessions, qualification, repo, installed_info, keep=(), apply=False,
          process_reader=running_paths, mover=trash, clock=time.time):
    objects = git_objects(repo)
    fingerprint = installed_fingerprint(installed_info)
    items = list(candidates(sessions, qualification))
    processes = process_reader() if items else []
    # The retained installation must not change underneath a cleanup pass.
    initial_fingerprint = fingerprint
    failed = False
    for item, kind in items:
        try:
            # An old --preview is never an executable deletion plan.
            # Apply also refreshes process use immediately before moving.
            decision = plan(item, kind, objects, processes, fingerprint, keep, clock())
            public = {key: value for key, value in decision.items() if key not in {'inventory', 'moves'}}
            public['action'] = 'preview'
            public['eligible_paths'] = [str(path) for path in decision['moves']]
            if apply and decision['moves']:
                if inventory(item) != decision['inventory']:
                    raise ValueError('item changed during inspection; rerun preview')
                if any(within(path, item) for path in process_reader()):
                    raise ValueError('running process began using item; rerun preview')
                public['action'] = 'trashed'
                public['destinations'] = []
                for path in decision['moves']:
                    if installed_fingerprint(installed_info) != initial_fingerprint:
                        raise ValueError('installed round changed; rerun preview with its qualified copy retained')
                    if any(within(p, item) for p in process_reader()):
                        raise ValueError('running process began using item; stopped')
                    # Check all remaining bytes, not just this leaf; stop if an
                    # actor changes the item between Trash operations.
                    current = inventory(item)
                    if current != decision['inventory']:
                        raise ValueError('item changed during Trash moves; stopped')
                    destination = mover(path)
                    public['destinations'].append({'source': str(path), 'trash': str(destination)})
                    print(json.dumps({'action': 'trash_move', **public['destinations'][-1]}))
                    # Moving a child updates parent timestamps; take the new
                    # baseline only after confirming remaining file identities.
                    remaining = {p: e for p, e in current.items() if not within(p, path)}
                    if item == path:
                        decision['inventory'] = {}
                    else:
                        after = inventory(item)
                        if set(after) != set(remaining) or any(
                            after[p] != e for p, e in remaining.items() if not stat.S_ISDIR(e[2])
                        ):
                            raise ValueError('remaining files changed during Trash move; stopped')
                        decision['inventory'] = after
            print(json.dumps(public, sort_keys=True))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(json.dumps({'path': str(item), 'action': 'kept_error', 'reason': str(error)}))
            failed = True
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preview', action='store_true')
    mode.add_argument('--apply', action='store_true', help='move eligible paths to macOS Trash; never permanently delete')
    parser.add_argument('--sessions-root', type=Path, default=Path('/private/tmp/claude-501'))
    parser.add_argument('--qualification-root', type=Path, default=Path.home() / 'Library/Caches/ChecklistQualification')
    parser.add_argument('--repo', type=Path, default=REPO, help='retained Checklist repository holding recoverable bytes')
    parser.add_argument('--installed-info', type=Path, default=Path('/Applications/Checklist.app/Contents/Resources/build-info.json'))
    parser.add_argument('--keep-qualified', type=Path, action='append', default=[],
                        help='also retain this exact qualified round or assigned persistent slot (repeatable)')
    args = parser.parse_args()
    for root in [args.sessions_root.expanduser(), args.qualification_root.expanduser()]:
        if root.is_symlink():
            parser.error('scratch roots must not be symbolic links: ' + str(root))
    return clean(args.sessions_root.expanduser().resolve(), args.qualification_root.expanduser().resolve(),
                 args.repo.expanduser().resolve(), args.installed_info.expanduser(),
                 [path.expanduser().resolve() for path in args.keep_qualified], args.apply)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Scratch cleanup refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
