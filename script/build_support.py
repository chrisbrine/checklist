"""Stable build-lane inputs and phase records for the immutable build helper."""
import argparse
import datetime
import hashlib
import json
import stat
from pathlib import Path
import shutil
import subprocess
import time

PHASES = ('capture', 'compile', 'stage', 'sign', 'verify', 'install')


def captured_inventory(capture):
    capture = Path(capture)
    manifest = json.loads((capture / 'capture-manifest.json').read_text())
    helper = capture / 'source/script/build_input_inventory.py'
    entry = next(e for e in manifest['inputs'] if e['path'] == 'script/build_input_inventory.py')
    if helper.is_symlink():
        raise ValueError('Captured inventory helper must be a regular file.')
    helper_source = helper.read_bytes()
    if hashlib.sha256(helper_source).hexdigest() != entry['sha256']:
        raise ValueError('Captured inventory helper differs from manifest.')
    namespace = {'__name__': 'checklist_lane_inventory', '__file__': str(helper)}
    exec(compile(helper_source, str(helper), 'exec'), namespace)
    inventory = namespace['inventory']
    if inventory(capture / 'source') != manifest['inputs']:
        raise ValueError('Immutable source capture differs from manifest.')
    return manifest, inventory


def verify_source(capture, source):
    manifest, inventory = captured_inventory(capture)
    source = Path(source)
    try:
        matches = not source.is_symlink() and inventory(source) == manifest['inputs']
    except (OSError, RuntimeError) as error:
        raise ValueError('Stable build source differs from the immutable capture.') from error
    if not matches:
        raise ValueError('Stable build source differs from the immutable capture.')
    # Inventory deliberately omits unrelated checkout metadata. A build lane has
    # no checkout metadata: reject extra files that could influence SwiftPM too.
    expected = {e['path'] for e in manifest['inputs']}
    actual = set()
    for p in source.rglob('*'):
        if p.is_symlink():
            raise ValueError('Stable build source contains a symlink.')
        if p.is_file():
            actual.add(str(p.relative_to(source)))
    if actual != expected:
        raise ValueError('Stable build source contains unexpected inputs.')
    return manifest


def sync_source(capture, source):
    manifest, _ = captured_inventory(capture)
    capture, source = Path(capture), Path(source)
    if source.is_symlink():
        raise ValueError('Stable build source must be a regular directory.')
    source.mkdir(parents=True, exist_ok=True)
    expected = {e['path']: e for e in manifest['inputs']}
    # Remove stale inputs, never follow lane symlinks. Preserve unchanged bytes
    # and mtimes so the compiler can reuse its dependency graph and object files.
    for p in sorted(source.rglob('*'), key=lambda p: len(p.parts), reverse=True):
        relative = str(p.relative_to(source))
        if p.is_symlink():
            p.unlink()
        elif p.is_file() and relative not in expected:
            p.unlink()
        elif p.is_dir() and not any(p.iterdir()):
            p.rmdir()
    for relative, entry in expected.items():
        destination = source / relative
        if destination.is_dir():
            shutil.rmtree(destination)
        if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != entry['sha256']:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(capture / 'source' / relative, destination)
        mode = 0o755 if entry['executable'] else 0o644
        if stat.S_IMODE(destination.stat().st_mode) != mode:
            destination.chmod(mode)
    verify_source(capture, source)


def clean_products(binary_directory, scratch):
    directory, scratch = Path(binary_directory).resolve(), Path(scratch).resolve()
    if directory == scratch or not directory.is_relative_to(scratch):
        raise ValueError('Binary output directory must stay inside this build scratch path.')
    # Keep object files and dependency/module caches. Remove only final products
    # so a changed aggregate/manifest cannot publish a previous build's outputs.
    for name in ['ChecklistApp', 'ChecklistService', 'checklist']:
        (directory / name).unlink(missing_ok=True)
    for bundle in directory.glob('*.bundle'):
        if bundle.is_symlink(): bundle.unlink()
        elif bundle.is_dir(): shutil.rmtree(bundle)


def load_average():
    return subprocess.check_output(['sysctl', '-n', 'vm.loadavg'], text=True).strip()


def timing(path, action, phase=None):
    path = Path(path)
    now = time.monotonic()
    if action == 'init':
        record = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'started_monotonic': now, 'load_start': load_average(),
                  'phases': {p: {'seconds': 0.0, 'status': 'skipped', 'load_start': None, 'load_end': None} for p in PHASES}}
    else:
        record = json.loads(path.read_text())
        if action == 'start':
            record['phases'][phase] = {'started_monotonic': now, 'load_start': load_average(), 'status': 'running'}
        elif action == 'stop':
            item = record['phases'][phase]
            item.update(seconds=now - item.pop('started_monotonic'), load_end=load_average(), status='completed')
        elif action == 'finish':
            record.update(seconds=now - record['started_monotonic'], load_end=load_average())
    path.write_text(json.dumps(record, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['sync', 'verify', 'clean-products', 'timing'])
    parser.add_argument('arguments', nargs='+')
    args = parser.parse_args()
    if args.action == 'sync':
        sync_source(*args.arguments)
    elif args.action == 'verify':
        verify_source(*args.arguments)
    elif args.action == 'clean-products':
        clean_products(*args.arguments)
    else:
        timing(*args.arguments)


if __name__ == '__main__':
    main()
