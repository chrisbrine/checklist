#!/usr/bin/env python3
"""CL-408 round memory guard for startup and backup.

Runs ``StorageMemoryGuardTests`` with two separate ``swift test`` processes on an
already built scratch path:

1. ``testBuildSyntheticStore`` builds a synthetic store (ordinary commands, no
   real store copy) with older backups and owner-confirmed retention.
2. ``testStartupAndBackupStayBounded`` opens that store (startup) and makes one
   backup with automatic retention. Its process does nothing else, so the kernel
   lifetime peak footprint covers only XCTest, startup and that backup.

The check fails when the peak footprint passes the stated limit, or when the
test-only structural seam sees a whole-store record array or a whole read of a
manifest other than the new backup's own. ``--self-test`` proves both failure
kinds with deliberate regressions and passes only when each one fails.

The Swift test removes its own fixture folder. If a process stops early, this
script moves the remaining folder to the Trash; it never deletes a file.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_CLASS = 'ChecklistCoreTests.StorageMemoryGuardTests'
# Stated limit, measured on 3 November 2026 (CL-408) with the defaults below:
# checklist.sqlite 53.4 MB, normal peak footprint 72.8 to 72.9 MiB in 3 runs,
# the whole_store_json regression 128.3 MiB. 96 MiB is 23 MiB (32 %) over the
# normal peak and 32 MiB under that regression. Change it with the store size.
DEFAULT_LIMIT_MIB = 96
DEFAULT_TASKS = 6000
DEFAULT_BRIEF_BYTES = 8000
DEFAULT_BACKUPS = 3
SELF_TESTS = {'whole_store_json': 'footprint', 'whole_manifest': 'structural'}


def evaluate(report: dict | None, self_test: str | None, returncode: int) -> tuple[bool, str]:
    """Return (passed, reason) for one measure process."""
    if report is None:
        return False, 'no report: the measure process stopped before it wrote one'
    failures = list(report.get('failures') or [])
    if self_test is None:
        if returncode != 0 and not failures:
            return False, 'the measure test failed (backup or retention not complete)'
        if failures:
            return False, 'failed: ' + ', '.join(failures)
        return True, 'passed'
    expected = SELF_TESTS[self_test]
    if expected in failures and returncode != 0:
        return True, f'self-test {self_test} failed as expected ({expected})'
    return False, f'self-test {self_test} was not caught (failures: {failures or "none"})'


def default_parent() -> Path:
    return Path.home() / 'Library/Caches/ChecklistQualification/CL-408'


def swift_test(scratch: Path, method: str, env: dict[str, str], log) -> tuple[int, float]:
    command = ['swift', 'test', '--skip-build', '--scratch-path', str(scratch),
               '--filter', f'^{TEST_CLASS}/{method}$']
    started = time.monotonic()
    log.write(f'$ {" ".join(command)}\n')
    log.flush()
    process = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    return process.returncode, time.monotonic() - started


def trash_leftover(base: Path) -> str | None:
    if not base.exists() or os.environ.get('CHECKLIST_RETAIN_TEST_FIXTURES'):
        return str(base) if base.exists() else None
    target = Path.home() / '.Trash' / base.name
    shutil.move(str(base), str(target))
    return str(target)


def run_once(args, self_test: str | None, log) -> dict:
    parent = Path(args.parent).resolve()
    parent.mkdir(parents=True, exist_ok=True)
    base = parent / f'CL408-memory-guard-{uuid.uuid4()}'
    report_path = parent / f'{base.name}.report.json'
    env = dict(os.environ)
    env.update({
        'CHECKLIST_MEMORY_GUARD_ROOT': str(base),
        'CHECKLIST_MEMORY_GUARD_REPORT': str(report_path),
        'CHECKLIST_MEMORY_GUARD_LIMIT_MIB': str(args.limit_mib),
        'CHECKLIST_MEMORY_GUARD_TASKS': str(args.tasks),
        'CHECKLIST_MEMORY_GUARD_BRIEF_BYTES': str(args.brief_bytes),
        'CHECKLIST_MEMORY_GUARD_BACKUPS': str(args.backups),
        'CHECKLIST_MEMORY_GUARD_SELF_TEST': self_test or '',
    })
    result: dict = {'self_test': self_test, 'fixture': str(base)}
    code, seconds = swift_test(Path(args.scratch_path), 'testBuildSyntheticStore', env, log)
    result['fixture_seconds'] = round(seconds, 1)
    if code != 0:
        result.update(passed=False, reason='the synthetic store build failed', leftover=trash_leftover(base))
        return result
    code, seconds = swift_test(Path(args.scratch_path), 'testStartupAndBackupStayBounded', env, log)
    result['measure_seconds'] = round(seconds, 1)
    report = None
    if report_path.exists():
        report = json.loads(report_path.read_text())
        trash_leftover(report_path)
    passed, reason = evaluate(report, self_test, code)
    result.update(passed=passed, reason=reason, report=report, leftover=trash_leftover(base))
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--scratch-path', default=str(ROOT.parent / '.build'), help='built SwiftPM scratch path (tests already built)')
    parser.add_argument('--limit-mib', type=int, default=DEFAULT_LIMIT_MIB, help='stated peak footprint limit of the measure process')
    parser.add_argument('--tasks', type=int, default=DEFAULT_TASKS)
    parser.add_argument('--brief-bytes', type=int, default=DEFAULT_BRIEF_BYTES)
    parser.add_argument('--backups', type=int, default=DEFAULT_BACKUPS, help='older backups whose manifests retention hashes')
    parser.add_argument('--parent', default=str(default_parent()), help='folder for the owned fixture folders')
    parser.add_argument('--self-test', action='store_true', help='prove that each regression kind fails the guard')
    parser.add_argument('--log', help='raw swift test log (default: <parent>/memory-guard-<time>.log)')
    parser.add_argument('--output', help='write the JSON receipt to this path')
    args = parser.parse_args(argv)
    # swift test runs from the package root; resolve relative paths against the caller's folder.
    args.scratch_path = str(Path(args.scratch_path).resolve())
    if args.limit_mib <= 0 or args.tasks < 0 or args.brief_bytes <= 0 or args.backups < 1:
        parser.error('limits and sizes must be positive, with at least one older backup')
    Path(args.parent).mkdir(parents=True, exist_ok=True)
    log_path = Path(args.log) if args.log else Path(args.parent) / f'memory-guard-{time.strftime("%Y%m%d-%H%M%S")}.log'
    started = time.monotonic()
    with log_path.open('w') as log:
        modes = list(SELF_TESTS) if args.self_test else [None]
        runs = [run_once(args, mode, log) for mode in modes]
    receipt = {'ticket': 'CL-408', 'limit_mib': args.limit_mib, 'log': str(log_path),
               'wall_seconds': round(time.monotonic() - started, 1), 'runs': runs,
               'passed': all(run['passed'] for run in runs)}
    text = json.dumps(receipt, indent=2, sort_keys=True)
    if args.output:
        Path(args.output).write_text(text + '\n')
    print(text)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
