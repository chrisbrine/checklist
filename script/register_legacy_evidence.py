#!/usr/bin/env python3
"""Plan legacy evidence registration; --apply rechecks a saved, hash-bound plan.

The default is a read-only JSON listing. Only explicit direct metadata or an
inherited metadata owner supports registration. A folder with no declared owner
stays unresolved; when its report or notes file names tickets in the first 8
lines, its row also carries an attribution proposal that --apply never writes.
This command never retires files. It contacts Checklist only for the read-only
ticket statuses that --read-statuses or --status-file ask for; each row then says
what evidence cleanup would do with that folder.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from clean_builds import (FINISHED, MENTION, REPO, Cleaner, evidence_metadata_owners, owner_refusal, safe, sha256,
                          status_reader, status_refusal)
from clean_scratch import OWNER_RECORD, read_owner_record, write_owner_record

OPAQUE = {'managed', 'source-captures', 'source', 'src', '.build', 'base', 'tree', '.git', 'originals', '__pycache__'}
SOURCES = ('owner.json', 'files.json', 'cleanup.json', 'report.md', 'notes.md')
ATTRIBUTION_LINES = 8


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


def attribution(folder):
    """Ticket keys in the first lines of a folder's report and notes, with those lines; or None."""
    tickets, lines = set(), []
    for name in ('report.md', 'notes.md'):
        path = folder / name
        if path.is_symlink() or not path.is_file():
            continue
        for number, line in enumerate(path.read_text().splitlines()[:ATTRIBUTION_LINES], 1):
            found = MENTION.findall(line)
            if found:
                tickets.update(found)
                lines.append({'file': name, 'line': number, 'text': line[:160]})
    return {'tickets': sorted(tickets), 'lines': lines} if tickets else None


def discovered_handins(repo):
    """What evidence cleanup itself treats as hand-ins: {path: (keys, basis, problems)}, and any read errors."""
    root = safe(Path(repo) / '.local/evidence')
    cleaner = Cleaner(repo, Path(repo) / '.local/no-installed-app')
    errors = []
    for folder in sorted(root.iterdir()):
        try:
            cleaner.evidence_plan(folder)
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(f'{folder}: {error}')
    return cleaner.owners, errors


def cleanup_outcome(folder, handins, statuses, errors):
    """What clean_builds.py --apply --only evidence would do with this folder at these statuses."""
    covering = next((p for p in (folder, *folder.parents) if p in handins), None)
    if covering is None:
        below = sum(path.is_relative_to(folder) for path in handins)
        reason = (f'container retained; cleanup decides {below} hand-ins below it separately' if below else
                  'no owner cleanup can read; retained until it is registered')
        if errors: reason += '; inventory problems: ' + '; '.join(errors)
        return {'action': 'kept', 'reason': reason}
    keys, basis, problems = handins[covering]
    refusal = owner_refusal(keys, problems) or status_refusal(keys, basis, statuses)
    if refusal:
        return {'action': 'kept', 'item': str(covering), 'tickets': sorted(keys), 'reason': refusal}
    return {'action': 'moves_to_trash', 'item': str(covering), 'tickets': sorted(keys),
            'reason': 'all owning tickets are Done or canceled; clean_builds.py --apply --only evidence '
                      'posts a note on each ticket and moves the item to the Trash, unless a running '
                      'process or --keep retains it'}


def add_cleanup_outcomes(plan, repo, reader):
    handins, errors = discovered_handins(repo)
    keys = {key for owners in handins.values() for key in owners[0]}
    for row in plan['rows']:
        keys.update(row['tickets'], row.get('attribution', {}).get('tickets', []))
    statuses = reader(sorted(keys)) if keys else {}
    for row in plan['rows']:
        row['cleanup'] = cleanup_outcome(Path(row['path']), handins, statuses, errors)
        proposal = row.get('attribution')
        if proposal:
            unfinished = sorted(k for k in proposal['tickets'] if statuses.get(k) not in FINISHED)
            row['cleanup']['if_attribution_registered'] = (
                'kept; open or unknown ticket status: ' + ', '.join(unfinished) if unfinished else 'moves_to_trash')
    outcomes = [row['cleanup'] for row in plan['rows']]
    plan['cleanup_counts'] = {
        'moves_to_trash': sum(o['action'] == 'moves_to_trash' for o in outcomes),
        'kept': sum(o['action'] == 'kept' for o in outcomes),
        'moves_to_trash_if_attribution_registered': sum(
            o.get('if_attribution_registered') == 'moves_to_trash' for o in outcomes)}
    return plan


def registration_plan(repo, reader=None):
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
                proposal = attribution(folder) if not keys and not problems else None
                if proposal: row['attribution'] = proposal
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
    plan = {'version': 1, 'evidence_root': str(root), 'rows': rows,
            'proposed_count': sum(r['action'] == 'proposed' for r in rows),
            'unresolved_count': sum(r['action'] == 'unresolved' for r in rows),
            'attribution_proposed_count': sum('attribution' in r for r in rows),
            'unattributed_count': sum(r['action'] == 'unresolved' and 'attribution' not in r for r in rows)}
    return add_cleanup_outcomes(plan, repo, reader) if reader else plan


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
    parser.add_argument('--read-statuses', action='store_true', help='read ticket statuses (read-only) and say what cleanup would do')
    parser.add_argument('--status-file', type=Path, help='explicit project_id/tasks status list instead of the service')
    parser.add_argument('--cli', type=Path, default=Path('/Applications/Checklist.app/Contents/MacOS/checklist'))
    parser.add_argument('--project-id')
    args = parser.parse_args(argv)
    if args.apply:
        value = {'registrations': apply_plan(json.loads(args.apply.read_text()), args.repo)}
    else:
        reader = (status_reader(args.repo, args.cli, args.project_id, args.status_file)
                  if args.read_statuses or args.status_file else None)
        value = registration_plan(args.repo, reader)
    print(json.dumps(value, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('register_legacy_evidence: ' + str(error), file=sys.stderr)
        sys.exit(1)
