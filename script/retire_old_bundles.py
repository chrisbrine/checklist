#!/usr/bin/env python3
"""Move unused Checklist rollback and qualification bundles to the Trash."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


REPO = Path(__file__).resolve().parents[1]
TRASH_TOOL = Path('/usr/bin/trash')
TRASH_SCRIPT = """ObjC.import('Foundation');
function run(argv) {
    const destination = Ref(), error = Ref();
    const source = $.NSURL.fileURLWithPath(argv[0]);
    if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(source, destination, error))
        throw Error(ObjC.unwrap(error[0].localizedDescription));
    return ObjC.unwrap(destination[0].path);
}
"""


def executable_paths():
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid='], text=True).splitlines():
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(line.strip()), buffer, len(buffer)) > 0:
            yield Path(os.fsdecode(buffer.value)).resolve()


def application_path(value, applications):
    path = Path(value).expanduser().absolute()
    if path.parent.resolve() != applications:
        raise ValueError('Bundle must be directly in the applications folder: ' + str(path))
    return applications / path.name


def previous_timestamp(bundle):
    match = re.fullmatch(r'\.Checklist-previous-(\d{8}T\d{6}Z)-\d+\.app', bundle.name)
    return match.group(1) if match else None


def latest_previous(build_root):
    records = list(build_root.rglob('last-install.json'))
    if not records: raise ValueError('No last-install.json found under ' + str(build_root))
    record = max(records, key=lambda path: (path.stat().st_mtime_ns, str(path)))
    payload = json.loads(record.read_text())
    if not isinstance(payload, dict) or 'previous_bundle' not in payload:
        raise ValueError('Missing previous_bundle in ' + str(record))
    value = payload['previous_bundle']
    if value is not None and (not isinstance(value, str) or not value):
        raise ValueError('Invalid previous_bundle in ' + str(record))
    return value, record


def bundle_size(path):
    if path.is_symlink() or not path.is_dir(): return path.lstat().st_size
    return sum(bundle_size(child) for child in path.iterdir())


def trash(bundle):
    test_trash = os.environ.get('CHECKLIST_TRASH_DIR')
    if test_trash is not None:
        if not test_trash: raise ValueError('CHECKLIST_TRASH_DIR must name a temporary Trash folder.')
        destination = Path(test_trash).expanduser().resolve()
        destination.mkdir(parents=True, exist_ok=True)
        destination = destination / (bundle.stem + '-' + uuid.uuid4().hex + bundle.suffix)
        bundle.rename(destination)
        return destination
    return native_trash(bundle)


def native_trash(bundle):
    if TRASH_TOOL.exists():
        result = subprocess.run([str(TRASH_TOOL), '--stopOnError', '--verbose', str(bundle)],
                                text=True, capture_output=True, check=True)
        prefix = '# Moved "' + str(bundle) + '" to "'
        for line in result.stdout.splitlines():
            if line.startswith(prefix) and line.endswith('"'): return Path(line[len(prefix):-1])
        raise ValueError('Trash move succeeded but its location was not reported: ' + result.stdout.strip())
    result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', TRASH_SCRIPT, str(bundle)],
                            text=True, capture_output=True, check=True)
    location = result.stdout.strip()
    if not location: raise ValueError('Trash move succeeded but its location was not reported.')
    return Path(location)


def trash_many(paths):
    """One native Trash process; retain successful receipts even on partial failure."""
    paths = list(paths)
    if not paths: return {}
    if os.environ.get('CHECKLIST_TRASH_DIR') is not None:
        results = {}
        for path in paths:
            try: results[path] = trash(path)
            except (OSError, ValueError) as error: results[path] = error
        return results
    if not TRASH_TOOL.exists():
        # Old macOS fallback: one Foundation host, one result per requested path.
        script = """ObjC.import('Foundation');
function run(argv) {
    return JSON.stringify(argv.map(function(path) {
        const destination = Ref(), error = Ref();
        if ($.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(
            $.NSURL.fileURLWithPath(path), destination, error))
            return {path: path, destination: ObjC.unwrap(destination[0].path)};
        return {path: path, error: ObjC.unwrap(error[0].localizedDescription)};
    }));
}
"""
        result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script,
                                 *map(str, paths)], text=True, capture_output=True, check=True, timeout=45)
        return {Path(row['path']): Path(row['destination']) if 'destination' in row else
                ValueError(row['error']) for row in json.loads(result.stdout)}
    try:
        result = subprocess.run([str(TRASH_TOOL), '--verbose', *map(str, paths)],
                                text=True, capture_output=True, timeout=45)
    except subprocess.TimeoutExpired as error:
        # subprocess kills/waits for the timed-out tool. Its earlier successful
        # move receipts are still authoritative; never retry the whole batch.
        def decoded(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
        result = subprocess.CompletedProcess([], 1, decoded(error.stdout),
                                             'Trash timed out: ' + decoded(error.stderr))
    results = {}
    for path in paths:
        prefix = '# Moved "' + str(path) + '" to "'
        locations = [line[len(prefix):-1] for line in result.stdout.splitlines()
                     if line.startswith(prefix) and line.endswith('"')]
        results[path] = Path(locations[0]) if len(locations) == 1 else ValueError(
            'Trash move unconfirmed for ' + str(path) + ': ' + (result.stderr.strip() or result.stdout.strip()))
    return results


def retire(bundles, keep=None):
    # Resolve aliases for process matching, but move the applications entry itself.
    paths = tuple(executable_paths())
    kept_timestamp = previous_timestamp(keep) if keep else None
    moved = 0;failed = False
    for bundle in bundles:
        reason = None
        if bundle.name.startswith('.Checklist-incoming-'):
            print('skipped: ' + str(bundle) + ' (install can be in progress)')
            continue
        if bundle == keep: reason = 'immediate previous bundle'
        timestamp = previous_timestamp(bundle)
        if not reason and kept_timestamp and timestamp and timestamp > kept_timestamp:
            reason = 'previous bundle from a later concurrent install'
        if not reason and any(bundle.resolve() in path.parents for path in paths):
            reason = 'running process uses this bundle'
        if reason:
            print('kept: ' + str(bundle) + ' (' + reason + ')')
            continue
        if not bundle.exists() and not bundle.is_symlink():
            print('skipped: ' + str(bundle) + ' (bundle is already absent)')
            continue
        try:
            size = bundle_size(bundle)
            destination = trash(bundle)
            moved += size
            print('moved: ' + str(bundle) + ' -> ' + str(destination))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
            print('failed: ' + str(bundle) + ' (' + detail + ')', file=sys.stderr)
            failed = True
    print(f'Total size moved: {moved} bytes')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--after-install', action='store_true', help='retire older unused copies after a successful install')
    modes.add_argument('--retire-previous', nargs='?', const='', metavar='PATH',
                       help='retire the previous bundle only after the installed checks pass; default: newest last-install.json under .local/build/')
    parser.add_argument('--keep', metavar='PATH', help='immediate previous bundle to retain; pass an empty string if none')
    parser.add_argument('--applications-root', type=Path, default=Path('/Applications'), help='applications folder (default: /Applications)')
    args = parser.parse_args()
    if args.after_install and args.keep is None: parser.error('--after-install requires --keep (or an empty string)')
    if not args.after_install and args.keep is not None: parser.error('--keep requires --after-install')
    applications = args.applications_root.expanduser().resolve()
    if not applications.is_dir(): raise ValueError('Applications folder does not exist: ' + str(applications))
    if args.after_install:
        keep = application_path(args.keep, applications) if args.keep else None
        if keep and not (keep.name.startswith('.Checklist-previous-') and keep.name.endswith('.app')):
            raise ValueError('--keep must name a .Checklist-previous-*.app bundle in the applications folder.')
        bundles = sorted(path for path in applications.iterdir() if path.name.startswith('.Checklist-') and path.name.endswith('.app'))
        return retire(bundles, keep)
    value = args.retire_previous
    if not value:
        value, record = latest_previous(REPO / '.local/build')
        if value is None:
            print('skipped: no previous bundle recorded in ' + str(record))
            print('Total size moved: 0 bytes')
            return 0
    bundle = application_path(value, applications)
    if not (bundle.name.startswith('.Checklist-previous-') and bundle.name.endswith('.app')):
        raise ValueError('--retire-previous requires a .Checklist-previous-*.app bundle in the applications folder.')
    return retire([bundle])


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Bundle retirement failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
