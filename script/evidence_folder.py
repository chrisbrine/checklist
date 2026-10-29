#!/usr/bin/env python3
"""Create and register ticket-owned folders (CL-359 item 0).

  new --ticket KEY [--ticket KEY] [--purpose TEXT] NAME
      create .local/evidence/NAME (NAME may hold subfolders, never '..')
      and write its owner.json; refuse without a ticket key.
  register --kind KIND [--ticket KEY] [--purpose TEXT] PATH
      write or extend owner.json in an existing folder (build stages use
      this from build_and_run.sh).
  tickets [--ticket KEY]
      print the validated comma list, or refuse when none is given.

Every --ticket falls back to CHECKLIST_TICKETS=CL-1,CL-2. clean_builds.py
reads owner.json before files.json and the folder-name fallback.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import sys

from clean_scratch import OWNER_KINDS, REPO, native_session, requested_tickets, write_owner_record


def caller():
    return native_session()


def new_evidence(repo, name, tickets, purpose=None, existing=False):
    """Create one evidence folder under repo/.local/evidence with its owner record."""
    tickets = requested_tickets(tickets)
    relative = PurePosixPath(name)
    if not name or relative.is_absolute() or any(part in {'', '.', '..'} for part in relative.parts):
        raise ValueError('NAME must be a relative path below .local/evidence without . or ..')
    root = Path(repo) / '.local/evidence'
    root.mkdir(parents=True, exist_ok=True)
    folder = root.joinpath(*relative.parts)
    for parent in [root, *reversed(folder.parents)]:
        if parent.is_relative_to(root) and parent.is_symlink():
            raise ValueError('evidence path must not pass through a link: ' + str(parent))
    folder.parent.mkdir(parents=True, exist_ok=True)
    try:
        folder.mkdir()
    except FileExistsError:
        if not existing:
            raise ValueError(f'{folder} exists; pass --existing to register it') from None
    return folder, write_owner_record(folder, tickets, 'evidence', purpose, caller())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['new', 'register', 'tickets']:
        command = commands.add_parser(name)
        command.add_argument('--ticket', dest='tickets', action='append', metavar='KEY')
        if name != 'tickets':
            command.add_argument('--purpose')
        if name == 'new':
            command.add_argument('--repo', type=Path, default=REPO)
            command.add_argument('--existing', action='store_true', help='register an existing folder instead of refusing')
            command.add_argument('name')
        if name == 'register':
            command.add_argument('--kind', required=True, choices=sorted(OWNER_KINDS))
            command.add_argument('path', type=Path)
    args = parser.parse_args(argv)
    if args.command == 'tickets':
        print(','.join(requested_tickets(args.tickets)))
        return 0
    if args.command == 'new':
        folder, value = new_evidence(args.repo.expanduser(), args.name, args.tickets, args.purpose, args.existing)
    else:
        folder = args.path.expanduser()
        value = write_owner_record(folder, requested_tickets(args.tickets), args.kind, args.purpose, caller())
    print(json.dumps({'path': str(folder.resolve()), 'action': 'registered', **value}, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print('evidence_folder: ' + str(error), file=sys.stderr)
        sys.exit(1)
