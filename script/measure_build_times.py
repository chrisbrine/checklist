#!/usr/bin/env python3
"""Measure CL-173's four stage-build cases in an exclusive private checkout.

Run before and after in separate, already-warmed copies during a quiet window.
This deliberately edits two selected source files and cleans the helper's scratch
for the clean case; it never installs or opens an app. Source bytes are restored.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

from clean_scratch import caller_session, mark_qualification, validate_fingerprint

CASES = ('unchanged', 'core-change', 'app-change', 'clean')
REPETITIONS = 3


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(checkout, output, name, mode):
    command = ['bash', str(checkout / 'script/build_and_run.sh'), mode]
    log = output / (name + '.log')
    started = time.monotonic()
    record = {'command': command, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'load_start': list(os.getloadavg()), 'log': log.name}
    with log.open('w') as stream:
        stream.write(json.dumps(record) + '\n');stream.flush()
        result = subprocess.run(command, cwd=checkout, stdout=stream, stderr=subprocess.STDOUT,
                                env=dict(os.environ, CHECKLIST_BUILD_SCOPE='measurement'))
    record.update(seconds=time.monotonic() - started, load_end=list(os.getloadavg()), returncode=result.returncode)
    with log.open('a') as stream:
        stream.write(json.dumps({'result': record}) + '\n')
    if result.returncode:
        raise RuntimeError('Build failed; see ' + str(log))
    lines = log.read_text().splitlines()
    staged = next((line.removeprefix('Staged ') for line in reversed(lines) if line.startswith('Staged ')), None)
    if not staged:
        raise RuntimeError('Build did not report a verified stage; see ' + str(log))
    capture = Path(staged).parent.resolve()
    if not capture.is_relative_to(checkout / '.local/build'):
        raise RuntimeError('Stage escaped the selected checkout.')
    receipt = json.loads((capture / 'build-verification.json').read_text())
    if receipt['timing']['phases']['compile']['status'] != 'completed':
        raise RuntimeError('Measurement reused a stage without compiling.')
    manifest = json.loads((capture / 'capture-manifest.json').read_text())
    if manifest.get('build_scope') != 'measurement' or manifest.get('installable') is not False:
        raise RuntimeError('Measurement requires a non-installable measurement-scope stage.')
    record.update(capture=str(capture), verification=receipt,
                  build={key: manifest[key] for key in ('source_fingerprint', 'configuration', 'toolchain', 'signing_profile', 'build_scope', 'installable')})
    return record


def measure(checkout, output, label, core, app, source_fingerprint, session_id=None):
    checkout, output = Path(checkout).resolve(), Path(output).resolve()
    sources = {'core-change': checkout / core, 'app-change': checkout / app}
    originals = {}
    for case, path in sources.items():
        target = 'ChecklistCore' if case == 'core-change' else 'ChecklistApp'
        if path.is_symlink() or not path.resolve().is_relative_to(checkout / 'Sources' / target) or path.suffix != '.swift':
            raise ValueError('Select a regular Swift file in Sources/' + target)
        originals[path] = (path.read_bytes(), path.stat())
    if (checkout / '.local/build/.build-lock').exists():
        raise ValueError('A build already owns this checkout.')
    session = caller_session(session_id)
    validate_fingerprint(source_fingerprint)
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Use an empty output directory to preserve earlier evidence.')
    mark_qualification(output, source_fingerprint, 'build measurement ' + label, session)
    lock = checkout / '.local/build/.measurement-lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.mkdir()  # A second runner must not change these sources.
    for path, (data, _) in originals.items():
        saved = output / 'originals' / path.relative_to(checkout)
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(data)
    records = []
    report = {'label': label, 'checkout': str(checkout), 'repetitions': REPETITIONS,
              'configuration': os.environ.get('CHECKLIST_BUILD_CONFIGURATION', 'release'),
              'cpu_count': os.cpu_count(),
              'source_sha256': {str(p.relative_to(checkout)): digest(p) for p in originals}, 'runs': records}

    def restore():
        for path, (data, metadata) in originals.items():
            if path.read_bytes() != data:
                path.write_bytes(data)
            os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))

    try:
        for case in CASES:
            for repetition in range(1, REPETITIONS + 1):
                restore()
                name = f'{case}-{repetition}'
                # Establish the same warmed baseline before each measured edit.
                # Warmups are retained separately and excluded from the medians.
                warmup = stage(checkout, output, name + '-warmup', '--rebuild-stage')
                if case in sources:
                    path = sources[case]
                    path.write_bytes(originals[path][0] + f'\n// CL-173 measurement {case} {repetition}\n'.encode())
                record = stage(checkout, output, name, '--clean-stage' if case == 'clean' else '--rebuild-stage')
                record.update(case=case, repetition=repetition, warmup=warmup)
                records.append(record)
                (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
                print(f'{name}: {record["seconds"]:.3f}s', flush=True)
        report['medians_seconds'] = {case: statistics.median(r['seconds'] for r in records if r['case'] == case) for case in CASES}
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        restore()
        report['restored_source_sha256'] = {str(p.relative_to(checkout)): digest(p) for p in originals}
        (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        lock.rmdir()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout', type=Path, required=True, help='exclusive private, warmed checkout; never the shared working checkout')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-fingerprint', required=True, help='exact round fingerprint whose qualification copy this run retains')
    parser.add_argument('--session-id', help='actual owning session when no native host ID is exported')
    parser.add_argument('--label', required=True, help='before/after plus exact revision or source fingerprint')
    parser.add_argument('--core-file', default='Sources/ChecklistCore/Store.swift')
    parser.add_argument('--app-file', default='Sources/ChecklistApp/App/ChecklistApp.swift')
    parser.add_argument('--allow-source-edits-and-clean', action='store_true', help='acknowledge temporary edits and clean-stage builds in this private copy')
    args = parser.parse_args()
    if not args.allow_source_edits_and_clean:
        parser.error('Run only in an exclusive private copy; pass --allow-source-edits-and-clean to execute.')
    report = measure(args.checkout, args.output, args.label, args.core_file, args.app_file, args.source_fingerprint, args.session_id)
    print(json.dumps(report['medians_seconds'], indent=2))


if __name__ == '__main__':
    main()
