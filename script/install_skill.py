#!/usr/bin/env python3
"""Install the bundled Checklist skill for Claude and Codex (CL-423).

Claude Code and Claude Desktop load `~/.claude/skills/checklist`; Codex loads
`~/.agents/skills/checklist`. This script copies the installed app's skill
there and writes a receipt with the source build and SHA-256 hashes.

Rules for each target folder:
- No folder: install.
- A receipt whose files still match it: replace (or `current` when the files
  already equal the source).
- A receipt whose files differ: the user changed the copy; skip and report.
- No receipt and `SKILL.md` front matter says `name: checklist`: replace,
  even if the copy was changed; the old copy goes to the Trash. The changed
  copy is kept rule applies once a receipt exists.
- An old folder moves to the Trash with a unique name; nothing is deleted.
  A read-only old folder gives a read-only new copy.

`--preview` reads only. `--apply` changes the targets. One JSON line per
target. Each skipped target warns on stderr. Leftover incoming folders are
reported on each preview/apply run, even if the source is refused, and kept.
Exit 0 when no target failed, 1 when a target failed, 2 for a bad source or usage.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid


DEFAULT_SOURCE = Path('/Applications/Checklist.app/Contents/Resources/skills/checklist')
RECEIPT = '.checklist-skill-receipt.json'
SKILL_NAME = 'checklist'
HOSTS = (('claude', Path('.claude/skills/checklist')), ('codex', Path('.agents/skills/checklist')))
IGNORED = {RECEIPT, '.DS_Store'}
TRASH_TOOL = Path('/usr/bin/trash')


class SkillError(Exception):
    pass


def tree_files(root):
    """Map each regular file (relative POSIX path) to its SHA-256; refuse links and odd files."""
    files = {}
    for directory, folders, names in os.walk(root, followlinks=False):
        folders.sort()
        base = Path(directory)
        for name in folders:
            if (base / name).is_symlink():
                raise SkillError('symbolic link in skill folder: ' + str(base / name))
        for name in sorted(names):
            path = base / name
            relative = path.relative_to(root).as_posix()
            if relative in IGNORED or name == '.DS_Store':
                continue
            mode = path.lstat().st_mode
            if not stat.S_ISREG(mode):
                raise SkillError('not a regular file in skill folder: ' + str(path))
            files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return files


def tree_hash(files):
    digest = hashlib.sha256()
    for relative in sorted(files):
        digest.update(relative.encode() + b'\0' + files[relative].encode() + b'\n')
    return digest.hexdigest()


def skill_name(folder):
    """The `name` value of the SKILL.md front matter, or None."""
    try:
        text = (folder / 'SKILL.md').read_text(errors='replace')
    except OSError:
        return None
    front = re.match(r'^---\r?\n(.*?)\r?\n---\r?\n', text, re.S)
    if not front:
        return None
    match = re.search(r'^name:\s*["\']?([^"\'\s#]+)', front.group(1), re.M)
    return match.group(1) if match else None


def source_build(source):
    info = source.parent.parent / 'build-info.json'
    try:
        value = json.loads(info.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict):
        return None
    return {key: value.get(key) for key in ('version', 'build_number', 'build_id', 'source_fingerprint')}


def difference(expected, actual):
    return {
        'changed': sorted(path for path in expected.keys() & actual.keys() if expected[path] != actual[path]),
        'missing': sorted(expected.keys() - actual.keys()),
        'added': sorted(actual.keys() - expected.keys()),
    }


def read_receipt(target):
    path = target / RECEIPT
    if not path.exists():
        return None
    value = json.loads(path.read_text())
    files = value.get('files') if isinstance(value, dict) else None
    if not isinstance(files, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in files.items()):
        raise ValueError('receipt has no file hash map')
    return value


def plan_target(host, target, source_files):
    """Decide one target without changing anything."""
    row = {'host': host, 'path': str(target), 'source_tree_sha256': tree_hash(source_files)}
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        return dict(row, action='skip', reason='the target is a link or not a folder; not managed by this script')
    if not target.exists():
        return dict(row, action='install', reason='no skill folder')
    try:
        current = tree_files(target)
    except (OSError, SkillError) as error:
        return dict(row, action='skip', reason='cannot read the target: ' + str(error))
    row['target_tree_sha256'] = tree_hash(current)
    row['read_only'] = not os.stat(target).st_mode & stat.S_IWUSR
    try:
        receipt = read_receipt(target)
    except (OSError, ValueError) as error:
        return dict(row, action='skip', reason='the receipt is unreadable (' + str(error) + '); not replaced')
    if receipt is not None:
        row['receipt_tree_sha256'] = tree_hash(receipt['files'])
        row['receipt_build'] = receipt.get('source_build')
        if current != receipt['files']:
            return dict(row, action='skip', difference=difference(receipt['files'], current),
                        reason='the files differ from the receipt (a user change); not replaced')
        if current == source_files:
            return dict(row, action='current', reason='the receipt matches and the files equal the source')
        return dict(row, action='replace', difference=difference(source_files, current),
                    reason='the receipt matches; the copy is stale')
    name = skill_name(target)
    if name != SKILL_NAME:
        return dict(row, action='skip', reason=f'no receipt and SKILL.md names {name!r}, not {SKILL_NAME!r}; not replaced')
    return dict(row, action='replace', difference=difference(source_files, current),
                reason='no receipt; SKILL.md names the checklist skill' +
                       ('' if current != source_files else ' (files already equal the source; adds a receipt)'))


def make_user_writable(root):
    for directory, folders, names in os.walk(root):
        for path in [Path(directory), *(Path(directory) / name for name in names)]:
            if not path.is_symlink():
                os.chmod(path, os.lstat(path).st_mode | stat.S_IWUSR)


def make_read_only(root):
    write_bits = stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH
    for directory, folders, names in os.walk(root, topdown=False):
        for path in [*(Path(directory) / name for name in names), Path(directory)]:
            if not path.is_symlink():
                os.chmod(path, os.lstat(path).st_mode & ~write_bits)


def native_trash(path):
    if TRASH_TOOL.exists():
        result = subprocess.run([str(TRASH_TOOL), '--stopOnError', '--verbose', str(path)],
                                text=True, capture_output=True, check=True, timeout=45)
        prefix = '# Moved "' + str(path) + '" to "'
        for line in result.stdout.splitlines():
            if line.startswith(prefix) and line.endswith('"'):
                return Path(line[len(prefix):-1])
        raise SkillError('the Trash move did not report a location: ' + result.stdout.strip())
    raise SkillError('no Trash route for ' + str(path))


def move_to_trash(path, host, home):
    """Rename into the Trash folder with a unique name; never delete."""
    test_trash = os.environ.get('CHECKLIST_TRASH_DIR')
    trash = Path(test_trash) if test_trash else home / '.Trash'
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    destination = trash / f'{path.name}-skill-{host}-{stamp}-{uuid.uuid4().hex[:8]}'
    try:
        trash.mkdir(parents=True, exist_ok=True)
        path.rename(destination)
        return destination
    except OSError:
        if test_trash:
            raise
        return native_trash(path)


def copy_skill(source, destination, source_files):
    destination.mkdir()
    for relative in source_files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
        os.chmod(target, 0o644)
    copied = tree_files(destination)
    if copied != source_files:
        raise SkillError('the copied files do not match the source hashes')


def discard(incoming, host, home):
    """Move an unused new copy to the Trash; report, never raise."""
    try:
        if incoming.exists():
            make_user_writable(incoming)
            return str(move_to_trash(incoming, host, home))
    except (OSError, SkillError, subprocess.SubprocessError) as error:
        return 'kept at ' + str(incoming) + ': ' + str(error)
    return None


def apply_target(row, source, source_files, build, home):
    target = Path(row['path'])
    incoming = target.parent / f'.{target.name}-incoming-{uuid.uuid4().hex[:8]}'
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        copy_skill(source, incoming, source_files)
        receipt = {'skill': SKILL_NAME, 'host': row['host'], 'source': str(source), 'source_build': build,
                   'installed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
                   'tree_sha256': tree_hash(source_files), 'files': source_files}
        (incoming / RECEIPT).write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    except (OSError, SkillError) as error:
        return dict(row, action='failed', reason='cannot prepare the new copy: ' + str(error),
                    discarded_copy=discard(incoming, row['host'], home))
    trashed = None
    if row['action'] == 'replace':
        try:
            make_user_writable(target)
            trashed = move_to_trash(target, row['host'], home)
        except (OSError, SkillError, subprocess.SubprocessError) as error:
            if row.get('read_only') and target.exists():
                make_read_only(target)
            return dict(row, action='failed', reason='cannot move the old copy to the Trash: ' + str(error),
                        discarded_copy=discard(incoming, row['host'], home))
    try:
        incoming.rename(target)
    except OSError as error:
        restored = False
        if trashed is not None and not target.exists():
            try:
                trashed.rename(target)
                restored = True
            except OSError:
                pass
        return dict(row, action='failed', trashed_to=str(trashed) if trashed else None,
                    reason=f'cannot put the new copy in place: {error}; old copy restored: {restored}; '
                           f'new copy kept at {incoming}')
    if row.get('read_only'):
        make_read_only(target)
    done = 'installed' if row['action'] == 'install' else 'replaced'
    return dict(row, action=done, target_tree_sha256=tree_hash(tree_files(target)),
                trashed_to=str(trashed) if trashed else None, source_build=build)


def report_leftover_incoming(host, target):
    incoming = [str(path) for path in sorted(target.parent.glob('.checklist-incoming-*'))
                if path.is_dir()]
    for path in incoming:
        print(f'Checklist skill for {host} has a leftover incoming folder; kept at {path}',
              file=sys.stderr, flush=True)
    return incoming


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preview', action='store_true', help='read only; print the plan')
    mode.add_argument('--apply', action='store_true', help='install or replace the targets')
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE, help='skill folder to copy')
    parser.add_argument('--home', type=Path, default=None, help='home folder (default: $HOME)')
    arguments = parser.parse_args(argv)
    source = arguments.source.expanduser().resolve()
    home = (arguments.home or Path.home()).expanduser()
    try:
        if not source.is_dir():
            raise SkillError('the source skill folder does not exist: ' + str(source))
        if skill_name(source) != SKILL_NAME:
            raise SkillError('the source SKILL.md does not name the checklist skill: ' + str(source))
        source_files = tree_files(source)
    except (OSError, SkillError) as error:
        for host, relative in HOSTS:
            report_leftover_incoming(host, home / relative)
        print(json.dumps({'action': 'refused', 'source': str(source), 'reason': str(error)}), flush=True)
        return 2
    build = source_build(source)
    failed = False
    for host, relative in HOSTS:
        row = plan_target(host, home / relative, source_files)
        row.update(source=str(source), source_build=build, applied=False)
        if arguments.apply and row['action'] in ('install', 'replace'):
            row = apply_target(row, source, source_files, build, home)
            row['applied'] = row['action'] != 'failed'
        if row['action'] == 'skip':
            print(f"Checklist skill for {host} not updated: {row['reason']}; {row['path']}",
                  file=sys.stderr, flush=True)
        incoming = report_leftover_incoming(host, home / relative)
        if incoming:
            row['leftover_incoming'] = incoming
        failed = failed or row['action'] == 'failed'
        print(json.dumps(row, sort_keys=True), flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
