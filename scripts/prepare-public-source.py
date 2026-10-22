#!/usr/bin/env python3
"""Prepare an unpublished, history-free source directory from a reviewed inventory."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile

from public_source_privacy import PATTERNS, private_identifiers

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = 'scripts/public-source-files.json'


def inventory(root: Path) -> tuple[list[str], dict]:
    spec = json.loads((root / INVENTORY).read_text())
    paths = spec['files']
    if spec['format'] != 1 or not paths or paths != sorted(set(paths)):
        raise ValueError('Inventory must be nonempty, sorted and unique (format 1)')
    for name in paths:
        path = PurePosixPath(name)
        if path.is_absolute() or str(path) != name or '..' in path.parts:
            raise ValueError('Unsafe inventory path')
        if any(part in {'.git', '.local', '.checklist', '.build', '__pycache__'} for part in path.parts):
            raise ValueError('Private inventory path')
        if name.startswith(('docs/research/', 'docs/reviews/evidence/')) or path.suffix in {
            '.sqlite', '.key', '.pem', '.p12', '.log', '.pyc'
        }:
            raise ValueError('Private inventory file')
    exceptions = spec.get('synthetic_exceptions', {})
    for name, exception in exceptions.items():
        if name not in paths or not name.startswith('Tests/') or not exception.get('reason'):
            raise ValueError('Synthetic exceptions require a selected test and explanation')
        if not set(exception['patterns']) <= PATTERNS.keys():
            raise ValueError('Unknown synthetic exception pattern')
    return paths, exceptions


def read_source(root: Path, name: str, exceptions: dict) -> tuple[bytes, int]:
    path = root
    for part in PurePosixPath(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError('Symlink in selected source: ' + name)
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('Selected source is not a regular file: ' + name)
    data = path.read_bytes()
    exception = exceptions.get(name)
    digest = hashlib.sha256(data).hexdigest()
    if exception and exception['sha256'] != digest:
        raise ValueError('Synthetic exception needs renewed review: ' + name)
    # Only the four reviewed product images are binary inputs.
    images = {'Resources/AppIcon.icns', 'Resources/AppIcon/source.png',
              'docs/design/public-human-request.png', 'docs/design/public-task-workspace.png'}
    if name not in images:
        body = data.decode('utf-8')
        for label, match in private_identifiers(body):
            if not (exception and label in exception['patterns']):
                line = body.count('\n', 0, match.start()) + 1
                raise ValueError(f'Private identifier ({label}): {name}:{line}')
    return data, 0o755 if path.stat().st_mode & 0o111 else 0o644


def prepare(root: Path, destination: Path) -> dict:
    root = root.resolve()
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('Destination must not exist')
    if destination.resolve().is_relative_to(root):
        raise ValueError('Destination must be outside the source tree')
    paths, exceptions = inventory(root)
    # Read once, inspect and hash the exact bytes copied; never copy Git history.
    inputs = [(name, *read_source(root, name, exceptions)) for name in paths]
    with tempfile.TemporaryDirectory(prefix='.checklist-public-', dir=destination.parent) as temp:
        stage = Path(temp) / 'source'
        stage.mkdir()
        records = []
        for name, data, mode in inputs:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)
            records.append({'path': name, 'sha256': hashlib.sha256(data).hexdigest(), 'mode': f'{mode:06o}'})
        result = subprocess.run([sys.executable, str(stage / 'scripts/validate-plan.py')],
                                cwd=stage, text=True, capture_output=True, check=True)
        validation = json.loads(result.stdout)
        if validation['errors']:
            raise ValueError('Export planning validation failed')
        report = {'format': 1, 'scope': 'unpublished source; synthetic fixtures only; no Git history',
                  'files': records, 'planning_validation': validation}
        (stage / 'public-source-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
        # Recheck before publishing the local directory; do not replace a prior set.
        if destination.exists() or destination.is_symlink():
            raise ValueError('Destination appeared during preparation')
        os.rename(stage, destination)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='new directory outside the repository; parent must exist')
    args = parser.parse_args()
    try:
        report = prepare(ROOT, args.destination)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Subprocess errors intentionally omit captured output and private input bytes.
        print('Public preparation failed: ' + str(error), file=sys.stderr)
        return 1
    print(json.dumps({'files': len(report['files']), 'errors': report['planning_validation']['errors'],
                      'published': False}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
