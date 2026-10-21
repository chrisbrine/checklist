"""Verify a complete captured live stage without building or installing it."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def signing_teams(bundle, profile):
    teams = []
    for path in [bundle, bundle / 'Contents/MacOS/ChecklistService', bundle / 'Contents/MacOS/checklist']:
        result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True, check=True)
        match = re.search(r'^TeamIdentifier=(.+)$', result.stderr, re.MULTILINE)
        teams.append(match.group(1) if match else None)
    if len(set(teams)) != 1 or (profile != 'ad-hoc' and teams[0] in [None, 'not set']):
        raise ValueError('App and helpers must have one signing team matching the signing profile.')


def verify(capture):
    capture = Path(capture).expanduser().resolve(strict=True)
    manifest = json.loads((capture / 'capture-manifest.json').read_text())
    helper = capture / 'source/script/build_input_inventory.py'
    entry = next(e for e in manifest['inputs'] if e['path'] == 'script/build_input_inventory.py')
    if helper.is_symlink():
        raise ValueError('Captured inventory helper must be a regular file.')
    helper_source = helper.read_bytes()
    if hashlib.sha256(helper_source).hexdigest() != entry['sha256']:
        raise ValueError('Captured inventory helper differs from manifest.')
    namespace = {'__name__': 'checklist_stage_inventory', '__file__': str(helper)}
    exec(compile(helper_source, str(helper), 'exec'), namespace)
    if namespace['inventory'](capture / 'source') != manifest['inputs']:
        raise ValueError('Captured source differs from manifest.')
    canonical = json.dumps({key: manifest[key] for key in ['inputs', 'toolchain', 'configuration']}, sort_keys=True, separators=(',', ':')).encode()
    fingerprint = hashlib.sha256(canonical).hexdigest()
    if manifest['source_fingerprint'] != fingerprint or manifest['build_id'] != fingerprint[:16]:
        raise ValueError('Capture fingerprint/build ID mismatch.')
    bundle = capture / 'Checklist.app'
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if plist.get('CFBundleIdentifier') != 'org.checklist.app' or plist.get('CFBundleExecutable') != 'ChecklistApp' or 'ChecklistInstanceSlot' in plist:
        raise ValueError('Only the original live stage may be promoted.')
    resources = bundle / 'Contents/Resources'
    if json.loads((resources / 'source-manifest.json').read_text()) != manifest:
        raise ValueError('Bundled source manifest differs from capture.')
    info = json.loads((resources / 'build-info.json').read_text())
    for key in ['build_id', 'source_fingerprint', 'build_number', 'signing_identity_sha256']:
        if info[key] != manifest[key]:
            raise ValueError('Bundled build identity differs from capture: ' + key)
    if plist.get('CFBundleVersion') != str(manifest['build_number']):
        raise ValueError('Bundled version differs from capture.')
    receipt = json.loads((capture / 'build-verification.json').read_text())
    if receipt.get('captured_source_verified') is not True or receipt.get('source_fingerprint') != fingerprint or receipt.get('build_id') != manifest['build_id']:
        raise ValueError('No matching completed build verification receipt.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    signing_teams(bundle, manifest['signing_profile'])
    return capture, manifest
