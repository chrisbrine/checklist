"""Checklist version allocation and explicit, local production release preparation.

Build callers hold .local/build/.build-lock. This helper never installs or publishes.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

MAX_ORDINAL = 2147483647


def production(value):
    if not isinstance(value, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('VERSION must contain three nonnegative integers.')
    return value


def ordinal(value):
    if isinstance(value, bool) or not str(value).isdecimal() or not 0 <= int(value) <= MAX_ORDINAL:
        raise ValueError('Build ordinal is outside its supported integer range; preserve and reconcile history.')
    return int(value)


def next_version(base, prior=0, installed=None, previous=None):
    """The global ordinal never resets; the fourth component resets per series."""
    base = production(base)
    number = ordinal(prior)
    development = 0
    for info in [installed or {}, previous or {}]:
        number = max(number, ordinal(info.get('build_number', 0)))
        version = info.get('version', '')
        if isinstance(version, str) and re.fullmatch(re.escape(base) + r'\.[0-9]+', version):
            development = max(development, int(version.rsplit('.', 1)[1]))
    if number == MAX_ORDINAL:
        raise ValueError('Build ordinal exhausted; preserve installation history.')
    return {'production_version': base, 'version': f'{base}.{development + 1}', 'build_number': number + 1}


def installed_info(bundle):
    bundle = Path(bundle)
    plist = bundle / 'Contents/Info.plist'
    if not plist.exists(): return {}
    value = plistlib.loads(plist.read_bytes())
    number = ordinal(value.get('CFBundleVersion', 0))
    info_path = bundle / 'Contents/Resources/build-info.json'
    info = json.loads(info_path.read_text()) if info_path.exists() else {}
    if 'build_number' in info and ordinal(info['build_number']) != number:
        raise ValueError('Installed build ordinal differs from Info.plist.')
    return dict(info, build_number=number)


def allocate(root, build, installed=Path('/Applications/Checklist.app')):
    root, build = Path(root), Path(build)
    state = build / 'version-state.json'
    prior = build / 'build-ordinal'
    info = next_version((root / 'VERSION').read_text().strip(),
                        prior.read_text().strip() if prior.exists() else 0,
                        installed_info(installed), json.loads(state.read_text()) if state.exists() else {})
    # Reserve both counters together before updating the legacy ordinal file.
    # A crash between replacements leaves state ahead, so retries skip both.
    for path, content in [(state, json.dumps(info) + '\n'), (prior, str(info['build_number']) + '\n')]:
        temporary = path.with_name(path.name + '.' + str(os.getpid()))
        with temporary.open('w') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        temporary.replace(path)
        directory = os.open(build, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    return info


def stamp(capture, stage):
    import datetime
    capture, stage = Path(capture), Path(stage)
    manifest = json.loads((capture / 'capture-manifest.json').read_text())
    info = {key: manifest[key] for key in ['version', 'production_version', 'build_id', 'build_number', 'source_fingerprint', 'source_root', 'configuration', 'toolchain', 'captured_at', 'signing_identity_sha256']}
    info.update(built_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), profile='local-development', signing=manifest['signing_profile'], source_capture=str(capture / 'source'))
    path = stage / 'Contents/Info.plist'
    plist = plistlib.loads(path.read_bytes())
    # Apple version fields remain three-part/integer. The public four-part
    # version lives in ChecklistVersion and both JSON identity records.
    plist.update(CFBundleShortVersionString=info['production_version'], CFBundleVersion=str(info['build_number']), ChecklistVersion=info['version'], ChecklistBuildID=info['build_id'])
    path.write_bytes(plistlib.dumps(plist))
    resources = stage / 'Contents/Resources'
    (resources / 'build-info.json').write_text(json.dumps(info, indent=2) + '\n')
    (resources / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


def verify_bundle(bundle):
    bundle = Path(bundle)
    resources = bundle / 'Contents/Resources'
    info = json.loads((resources / 'build-info.json').read_text())
    manifest = json.loads((resources / 'source-manifest.json').read_text())
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    base = production(info['production_version'])
    if not re.fullmatch(re.escape(base) + r'\.[0-9]+', info['version']):
        raise ValueError('Invalid four-part Checklist version.')
    ordinal(info['build_number'])
    for key in ['version', 'production_version', 'build_number', 'build_id', 'source_fingerprint']:
        if info[key] != manifest[key]: raise ValueError('Bundle identity differs from source manifest: ' + key)
    expected = {'CFBundleShortVersionString': base, 'CFBundleVersion': str(info['build_number']),
                'ChecklistVersion': info['version'], 'ChecklistBuildID': info['build_id']}
    if any(plist.get(key) != value for key, value in expected.items()):
        raise ValueError('Info.plist version/build identity differs from build-info.json.')
    return info


def call(cli, method, params):
    reply = json.loads(subprocess.check_output([str(cli), 'call', method, json.dumps(params)], text=True))
    if 'error' in reply: raise ValueError('Cannot count open tickets: ' + str(reply['error']))
    return reply.get('data', reply)


def open_ticket_count(root, cli):
    resolved = call(cli, 'project_resolve', {'workspace_path': str(Path(root).resolve())})
    if resolved.get('state') != 'registered' or len(resolved.get('projects', [])) != 1:
        raise ValueError('Release requires one verified project for this workspace.')
    project = resolved['projects'][0]['id']
    params = {'project_id': project, 'fields': ['status_category'], 'archived': False, 'limit': 200}
    count = 0
    while True:
        page = call(cli, 'task_list', params)
        for task in page['tasks']:
            if task.get('status_category') not in ['queued', 'active', 'review', 'blocked', 'parked', 'done', 'canceled']:
                raise ValueError('Unknown ticket status category; release refused.')
            if task['status_category'] not in ['done', 'canceled']: count += 1
        if not page.get('has_more'): return count
        params['cursor'] = page['next_cursor']


def release(root, count, dry_run=False):
    root = Path(root)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()
    old = production((root / 'VERSION').read_text().strip())
    parts = list(map(int, old.split('.')));parts[2] += 1
    new = '.'.join(map(str, parts))
    print(f'Open tickets: {count}; production {old} -> {new}; development sequence restarts at {new}.1', flush=True)
    if count != 0: raise ValueError('Production release requires zero open tickets.')
    if git('status', '--porcelain'): raise ValueError('Release requires a clean checkout.')
    if git('branch', '--show-current') != 'main': raise ValueError('Release requires the existing main branch.')
    tag = 'v' + new
    if git('tag', '--list', tag): raise ValueError('Release tag already exists: ' + tag)
    if dry_run:
        print(f'Dry run: commit VERSION as Release {new}; tag {tag}; no files or refs changed.')
        return new
    (root / 'VERSION').write_text(new + '\n')
    subprocess.run(['git', '-C', str(root), 'add', '--', 'VERSION'], check=True)
    subprocess.run(['git', '-C', str(root), 'commit', '-m', 'Release ' + new, '--', 'VERSION'], check=True)
    subprocess.run(['git', '-C', str(root), 'tag', tag], check=True)
    return new


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--release', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--cli', type=Path, default=Path('/Applications/Checklist.app/Contents/MacOS/checklist'))
    parser.add_argument('--stamp', nargs=2, metavar=('CAPTURE', 'STAGE'))
    args = parser.parse_args()
    if args.stamp: stamp(*args.stamp)
    elif args.release: release(args.root, open_ticket_count(args.root, args.cli), args.dry_run)
    else: parser.error('choose --release [--dry-run] or --stamp CAPTURE STAGE')


if __name__ == '__main__':
    main()
