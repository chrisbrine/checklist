#!/usr/bin/env python3
"""Plan legacy evidence registration; --apply rechecks a saved, hash-bound plan.

The default is a read-only JSON listing. Only explicit direct metadata or an
inherited metadata owner supports registration. Name-only evidence is listed for
an owner decision. This command never retires files or contacts Checklist.
"""
import argparse
import json
import os
from pathlib import Path
import sys

from clean_builds import (REPO, evidence_metadata_owners, safe, sha256)
from clean_scratch import OWNER_RECORD, read_owner_record, write_owner_record

OPAQUE = {'managed', 'source-captures', 'source', 'src', '.build', 'base', 'tree', '.git', 'originals', '__pycache__'}
SOURCES = ('owner.json', 'files.json', 'cleanup.json', 'report.md', 'notes.md')


def source_hashes(folder):
    result = {}
    for name in SOURCES:
        path = folder / name
        if path.exists() or path.is_symlink():
            safe(path)
            if not path.is_file():
                raise ValueError('ownership source is not a regular file: ' + str(path))
            result[str(path)] = sha256(path)
    return result


def registration_plan(repo):
    root = safe(Path(repo) / '.local/evidence')
    rows = []
    for current, dirs, files in os.walk(root, followlinks=False):
        folder = Path(current)
        dirs[:] = sorted(name for name in dirs if name not in OPAQUE and not (folder / name).is_symlink())
        if {'database.sqlite', 'checklist.sqlite'} & set(files):
            dirs[:] = []
            continue
        if not files and not dirs:
            continue
        try:
            if read_owner_record(folder):
                dirs[:] = []  # Registered enclosing ownership covers its tree.
                continue
            keys, basis, problems = evidence_metadata_owners(folder)
            if keys or problems or (set(files) & set(SOURCES)):
                row = {'path': str(folder), 'tickets': sorted(keys), 'owner_basis': basis,
                       'action': 'proposed' if keys and not problems else 'unresolved',
                       'problems': problems, 'sources': source_hashes(folder)}
                rows.append(row)
                if keys or problems:
                    dirs[:] = []  # One enclosing owner, never one child per fixture.
            elif files:
                rows.append({'path': str(folder), 'tickets': [], 'owner_basis': 'none',
                             'action': 'unresolved', 'problems': ['no explicit ownership declaration'],
                             'sources': {}})
        except (OSError, ValueError) as error:
            dirs[:] = []
            rows.append({'path': str(folder), 'tickets': [], 'owner_basis': 'none',
                         'action': 'unresolved', 'problems': [str(error)], 'sources': {}})
    return {'version': 1, 'evidence_root': str(root), 'rows': rows,
            'proposed_count': sum(r['action'] == 'proposed' for r in rows),
            'unresolved_count': sum(r['action'] == 'unresolved' for r in rows)}


def apply_plan(plan, repo):
    root = safe(Path(repo) / '.local/evidence')
    if plan.get('version') != 1 or plan.get('evidence_root') != str(root):
        raise ValueError('plan does not identify this evidence root')
    applied = []
    # Preflight every row before the first write; a changed report invalidates it.
    proposed = [row for row in plan['rows'] if row['action'] == 'proposed']
    for row in proposed:
        folder = safe(Path(row['path']))
        if folder == root or not folder.is_relative_to(root):
            raise ValueError('registration must be below the evidence root')
        if read_owner_record(folder):
            raise ValueError('folder is already registered; make a fresh plan: ' + str(folder))
        if source_hashes(folder) != row['sources']:
            raise ValueError('ownership sources changed; make a fresh plan: ' + str(folder))
        keys, basis, problems = evidence_metadata_owners(folder)
        if problems or sorted(keys) != row['tickets'] or basis != row['owner_basis'] or not keys:
            raise ValueError('ownership no longer agrees with plan: ' + str(folder))
    for row in proposed:
        folder = Path(row['path'])
        # Recheck immediately before each write as well as the batch preflight.
        if source_hashes(folder) != row['sources'] or read_owner_record(folder):
            raise ValueError('ownership sources changed before registration: ' + str(folder))
        value = write_owner_record(folder, row['tickets'], 'evidence',
                                   'Legacy registration from ' + row['owner_basis'])
        applied.append({'path': str(folder), 'action': 'registered', 'tickets': value['tickets']})
    return applied


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=REPO)
    parser.add_argument('--apply', type=Path, metavar='PLAN_JSON', help='explicitly write proposed owner.json records from a saved plan')
    args = parser.parse_args(argv)
    if args.apply:
        value = {'registrations': apply_plan(json.loads(args.apply.read_text()), args.repo)}
    else:
        value = registration_plan(args.repo)
    print(json.dumps(value, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('register_legacy_evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
