"""Canonical immutable-build inputs; no build, install or source mutation effects."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess


INPUT_ROOTS = [
    'VERSION', 'Package.swift', 'Package.resolved', 'Sources', 'Tests', 'Resources',
    'Packages', 'skills', 'plugins', 'templates', 'script/build_and_run.sh',
    'script/version.py', 'script/build_input_inventory.py', 'script/build_support.py', 'script/verify_stage.py', 'script/verify_install.py',
]
# Exact tooling/private metadata names, not generic names such as cache or build.
PACKAGE_METADATA = {'.build', '.swiftpm', '.local', '__pycache__'}


def _package_paths(base, package):
    if (base / '.git').exists():
        def git(*args):
            result = subprocess.run(
                ['/usr/bin/git', '-c', 'core.fsmonitor=false', '-C', str(base), *args],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if result.returncode:
                raise RuntimeError('Cannot inventory Packages with Git; reconcile the complete repository root before building.')
            return result.stdout

        top = Path(os.fsdecode(git('rev-parse', '--show-toplevel')).strip()).resolve()
        if top != base.resolve():
            raise RuntimeError('Packages must be captured from the complete repository root.')
        if any(entry.startswith(b'160000 ') for entry in git('ls-files', '--stage', '-z', '--', 'Packages').split(b'\0')):
            raise RuntimeError('Packages contains a submodule; vendor its complete local inputs before building.')
        # Git supplies tracked files even when later ignored, and honors ignored
        # exceptions for untracked files. Do not approximate .gitignore syntax.
        for raw in sorted(set(filter(None, git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'Packages').split(b'\0')))):
            path = base / os.fsdecode(raw)
            if not raw.startswith(b'Packages/'):
                raise RuntimeError('Packages inventory escaped its supported input root.')
            if path.is_dir() and not path.is_symlink():
                raise RuntimeError('Packages contains an embedded repository or incomplete directory input: ' + str(path.relative_to(base)))
            yield path
    else:
        # The immutable copy intentionally has no .git. Its exact membership is
        # checked against the manifest after the same exclusions and hashing.
        for folder, directories, files in os.walk(package, followlinks=False):
            folder = Path(folder)
            if '.git' in directories or '.git' in files:
                raise RuntimeError('Packages contains an embedded repository; vendor its complete local inputs before building.')
            directories[:] = sorted(name for name in directories if name not in PACKAGE_METADATA)
            for name in directories:
                path = folder / name
                if path.is_symlink():
                    yield path  # The shared inventory rejects it without traversal.
            for name in sorted(files):
                yield folder / name


def inventory(base):
    base = Path(base)
    paths = []
    for item in INPUT_ROOTS:
        path = base / item
        if path.is_symlink():
            raise RuntimeError('Build input root symlinks require explicit packaging support: ' + item)
        if not path.exists():
            continue
        if item == 'Packages':
            if not path.is_dir():
                raise RuntimeError('Packages must be a directory of complete local packages.')
            paths.extend(_package_paths(base, path))
        else:
            paths.extend([path] if path.is_file() else sorted(path.rglob('*')))
    result = []
    for path in sorted(set(paths)):
        relative = path.relative_to(base)
        if relative.parts[0] == 'Packages' and any(part in PACKAGE_METADATA for part in relative.parts[1:]):
            continue
        if path.name == '.DS_Store' or '__pycache__' in relative.parts:
            continue
        if path.is_symlink():
            raise RuntimeError('Build input symlinks require explicit packaging support: ' + str(relative))
        if not path.is_file():
            continue
        data = path.read_bytes()
        result.append({'path': str(relative), 'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data), 'executable': bool(path.stat().st_mode & stat.S_IXUSR)})
    return sorted(result, key=lambda entry: entry['path'])
