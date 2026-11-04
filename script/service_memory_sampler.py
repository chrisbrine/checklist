#!/usr/bin/env python3
"""CL-409 bounded memory sampler for the installed Checklist service.

The sampler finds the live service process by its exact executable path. Every
``--interval`` seconds it records the time (UTC and local), ``phys_footprint`` and
``phys_footprint_peak`` from ``footprint -p PID -f bytes``, ``vm.loadavg`` and
the service write admission from ``checklist call service_info``. It writes one
JSON line for each sample to ``--out`` and flushes the file.

A backup is a period in which ``write_admission.backup_active`` is true, or
``locked`` is true with a reason that starts with ``backup``. For each backup
the sampler records the start, the end, the highest readings, the lifetime peak
before and after, and the load. After each backup ends and ``--retention-delay``
seconds pass, it calls ``backup_retention_status`` one time and stores the raw
reply in a side file.

If ``phys_footprint`` passes ``--alert-bytes``, the sampler saves one full
``footprint`` report and one 5 s ``sample`` of the service for each backup (or
for each period between backups). It runs no other command on the service.

The sampler stops after ``--backups`` complete backups and their retention
reads, after ``--max-hours``, when the service PID, start time or build changes,
when the service is not found, or on SIGTERM or SIGINT. On each stop it writes
a summary JSON file. It never writes the service, never reads the service's own
files and never deletes a file. An error in one sample is recorded, and the loop
continues.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

DEFAULT_EXECUTABLE = '/Applications/Checklist.app/Contents/MacOS/ChecklistService'
DEFAULT_CLI = '/Applications/Checklist.app/Contents/MacOS/checklist'
DEFAULT_PROJECT_DIR = str(Path.home() / 'Documents/Work/Checklist')
DEFAULT_PROJECT_ID = 'a3854aea-b62c-4fbc-b86b-40ce4a4f0cd6'
DEFAULT_ALERT_BYTES = 4 * 1024 ** 3
COMMAND_TIMEOUT = 60
SAMPLE_SECONDS = 5
MIB = 1024 * 1024

Runner = Callable[..., 'tuple[int, str, str]']


def run_command(command: list[str], cwd: str | None = None, timeout: float = COMMAND_TIMEOUT) -> tuple[int, str, str]:
    """Run one command and return (returncode, stdout, stderr)."""
    process = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                             timeout=timeout, stdin=subprocess.DEVNULL)
    return process.returncode, process.stdout, process.stderr


def _pidpath(pid: int) -> str | None:
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    buffer = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(pid, buffer, 4096) <= 0:
        return None
    return buffer.value.decode('utf-8', 'replace')


def find_processes(executable: str, runner: Runner = run_command) -> list[dict]:
    """Return each process whose executable path is exactly ``executable``.

    ``ps`` shows a relative command name for the service, so the sampler reads
    the exact path of each candidate with ``proc_pidpath``. Each record also has
    ``ppid``: the service is the launchd job (parent 1); a service child that runs
    the same executable (seen after a backup on build 290) is a helper.
    """
    code, out, err = runner(['ps', '-axo', 'pid=,ppid=,comm='])
    if code != 0:
        raise RuntimeError(f'ps failed: {err.strip()}')
    name = os.path.basename(executable)
    found = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or os.path.basename(parts[2]) != name:
            continue
        pid, ppid = int(parts[0]), int(parts[1])
        if _pidpath(pid) != executable:
            continue
        code, start, _ = runner(['ps', '-o', 'lstart=', '-p', str(pid)])
        found.append({'pid': pid, 'ppid': ppid, 'start_time': start.strip() if code == 0 else None})
    return found


def parse_footprint(text: str) -> dict:
    """Read ``phys_footprint`` and ``phys_footprint_peak`` (bytes) from ``footprint -f bytes``."""
    values = {}
    for line in text.splitlines():
        key, _, rest = line.strip().partition(':')
        if key in ('phys_footprint', 'phys_footprint_peak'):
            values[key] = int(rest.strip().split()[0])
    if 'phys_footprint' not in values or 'phys_footprint_peak' not in values:
        raise ValueError('footprint output has no phys_footprint or phys_footprint_peak line')
    return values


def parse_loadavg(text: str) -> list[float]:
    return [float(value) for value in text.replace('{', ' ').replace('}', ' ').split()[:3]]


def in_backup(admission: dict | None) -> bool:
    if not admission:
        return False
    if admission.get('backup_active'):
        return True
    return bool(admission.get('locked')) and str(admission.get('reason') or '').startswith('backup')


def time_fields(epoch: float) -> dict:
    utc = datetime.fromtimestamp(epoch, timezone.utc)
    fields = {'epoch': round(epoch, 3), 'utc': utc.strftime('%Y-%m-%dT%H:%M:%SZ')}
    # The Mac's own zone is the owner's clock (America/Vancouver, UTC-7 in November 2026).
    local = utc.astimezone()
    fields['local'] = local.strftime('%Y-%m-%d %H:%M:%S ') + (local.tzname() or local.strftime('%z'))
    return fields


def mib(value: int | None) -> float | None:
    return None if value is None else round(value / MIB, 1)


class Sampler:
    """One bounded sampler run. All outside calls go through injected functions."""

    def __init__(self, args, runner: Runner = run_command,
                 finder: Callable[[str], list[dict]] | None = None,
                 clock: Callable[[], float] = time.time,
                 monotonic: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] | None = None):
        self.args = args
        self.runner = runner
        self.finder = finder or (lambda executable: find_processes(executable, runner))
        self.clock = clock
        self.monotonic = monotonic
        self.wake = threading.Event()
        self.sleep = sleep or (lambda seconds: self.wake.wait(seconds))
        self.out = Path(args.out)
        self.summary_path = Path(args.summary or f'{args.out}.summary.json')
        self.samples = 0
        self.error_samples = 0
        self.backups: list[dict] = []
        self.current: dict | None = None
        self.alerts: list[dict] = []
        self.alert_keys: set[str] = set()
        self.highest = {'phys_footprint': None, 'phys_footprint_peak': None}
        self.last_peak: int | None = None
        self.last_load: list[float] | None = None
        self.stop_reason: str | None = None
        self.service: dict | None = None
        self.build: dict | None = None
        self.started = None

    # Signals -----------------------------------------------------------
    def request_stop(self, signum, _frame=None) -> None:
        if self.stop_reason is None:
            self.stop_reason = f'signal {signal.Signals(signum).name}'
        self.wake.set()

    # Outside reads -----------------------------------------------------
    def checklist_call(self, method: str, payload: dict) -> dict:
        code, out, err = self.runner([self.args.cli, 'call', method, json.dumps(payload)],
                                     cwd=self.args.project_dir)
        if code != 0:
            raise RuntimeError(f'checklist call {method} exit {code}: {(err or out).strip()[:300]}')
        return json.loads(out)

    def read_footprint(self, pid: int) -> dict:
        code, out, err = self.runner(['footprint', '-p', str(pid), '-f', 'bytes'])
        if code != 0:
            raise RuntimeError(f'footprint exit {code}: {err.strip()[:300]}')
        return parse_footprint(out)

    def read_load(self) -> list[float]:
        code, out, err = self.runner(['sysctl', '-n', 'vm.loadavg'])
        if code != 0:
            raise RuntimeError(f'sysctl exit {code}: {err.strip()[:300]}')
        return parse_loadavg(out)

    # Side files --------------------------------------------------------
    def side_path(self, suffix: str) -> Path:
        return self.out.parent / f'{self.out.name}.{suffix}'

    def capture_alert(self, pid: int, key: str, now: float) -> None:
        stamp = datetime.fromtimestamp(now, timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        report = self.side_path(f'alert-{key}-{stamp}.footprint.txt')
        stack = self.side_path(f'alert-{key}-{stamp}.sample.txt')
        record = {'key': key, 'time': time_fields(now), 'footprint_report': str(report), 'sample_file': str(stack)}
        try:
            code, out, err = self.runner(['footprint', '-p', str(pid)])
            report.write_text(out if code == 0 else f'exit {code}\n{err}')
            record['footprint_exit'] = code
        except Exception as error:  # recorded, not fatal
            record['footprint_error'] = repr(error)
        try:
            code, _, err = self.runner(['sample', str(pid), str(SAMPLE_SECONDS), '-file', str(stack)],
                                       timeout=SAMPLE_SECONDS + COMMAND_TIMEOUT)
            record['sample_exit'] = code
            if code != 0:
                record['sample_error'] = err.strip()[:300]
        except Exception as error:
            record['sample_error'] = repr(error)
        self.alerts.append(record)
        if self.current is not None:
            self.current.setdefault('alerts', []).append(record)

    def read_retention(self, backup: dict) -> None:
        backup['retention_read'] = True
        path = self.side_path(f'retention-{backup["index"]}.json')
        result: dict = {'file': str(path)}
        try:
            reply = self.checklist_call('backup_retention_status', {'project_id': self.args.project_id})
            path.write_text(json.dumps(reply, indent=2, sort_keys=True) + '\n')
            data = reply.get('data', reply) if isinstance(reply, dict) else {}
            last = data.get('last_result') or {}
            occurred = last.get('occurred_at')
            new_pass = bool(occurred) and occurred >= backup['started']['utc']
            result.update(last_result=last, new_pass=new_pass,
                          moved=bool(new_pass and (last.get('moved_count') or 0) > 0))
        except Exception as error:
            result.update(error=repr(error), moved=None)
        backup['retention'] = result

    # Loop --------------------------------------------------------------
    def identify(self) -> str | None:
        """Return a stop reason when the service is gone, changed or ambiguous."""
        found = self.finder(self.args.executable)
        # The service is the launchd job (parent 1). A record without ``ppid`` counts as a root.
        roots = [item for item in found if item.get('ppid', 1) == 1]
        if not roots:
            return 'service_not_found'
        if len(roots) > 1:
            return 'service_ambiguous: ' + ', '.join(str(item['pid']) for item in roots)
        root = roots[0]
        self.helpers = [item['pid'] for item in found if item.get('ppid') == root['pid']]
        if self.service is None:
            self.service = root
            return None
        if root['pid'] != self.service['pid'] or root['start_time'] != self.service['start_time']:
            return f'service_pid_changed: {self.service["pid"]} -> {root["pid"]}'
        return None

    def sample_once(self) -> str | None:
        now = self.clock()
        record: dict = {'time': time_fields(now), 'errors': []}
        try:
            reason = self.identify()
        except Exception as error:
            reason = None
            record['errors'].append(f'process lookup: {error!r}')
        if reason is not None:
            return reason
        if self.service is None:  # no identity yet: record the error and try again
            self.write_line(record)
            return None
        pid = self.service['pid']
        record['pid'] = pid
        footprint = None
        try:
            footprint = self.read_footprint(pid)
            record.update(footprint)
            for key in self.highest:
                best = self.highest[key]
                if best is None or footprint[key] > best['bytes']:
                    self.highest[key] = {'bytes': footprint[key], 'mib': mib(footprint[key]), 'time': record['time']}
        except Exception as error:
            record['errors'].append(f'footprint: {error!r}')
        helpers = []
        for helper in getattr(self, 'helpers', []):
            try:
                helpers.append({'pid': helper, **self.read_footprint(helper)})
            except Exception as error:
                helpers.append({'pid': helper, 'error': repr(error)})
        if helpers:
            record['helpers'] = helpers
        try:
            record['loadavg'] = self.read_load()
        except Exception as error:
            record['errors'].append(f'loadavg: {error!r}')
        admission = None
        try:
            info = self.checklist_call('service_info', {})
            data = info.get('data') or {}
            admission = info.get('write_admission') or data.get('write_admission') or {}
            record.update(build_id=data.get('build_id'), build_number=data.get('build_number'),
                          backup_active=admission.get('backup_active'), locked=admission.get('locked'),
                          reason=admission.get('reason'))
            build = {'build_id': data.get('build_id'), 'build_number': data.get('build_number')}
            if self.build is None:
                self.build = build
            elif build['build_id'] != self.build['build_id']:
                self.write_line(record)
                return f'build_changed: {self.build["build_id"]} -> {build["build_id"]}'
        except Exception as error:
            record['errors'].append(f'service_info: {error!r}')
        self.track_backup(record, admission, footprint, now)
        if footprint and footprint['phys_footprint'] > self.args.alert_bytes:
            key = f'backup-{self.current["index"]}' if self.current else f'idle-{len(self.backups)}'
            if key not in self.alert_keys:
                self.alert_keys.add(key)
                self.capture_alert(pid, key, now)
                record['alert_capture'] = key
        self.write_line(record)
        for backup in self.backups:
            if backup['complete'] and not backup.get('retention_read') and backup.get('ended') \
                    and now - backup['ended']['epoch'] >= self.args.retention_delay:
                self.read_retention(backup)
        return self.backups_done()

    def track_backup(self, record: dict, admission: dict | None, footprint: dict | None, now: float) -> None:
        if admission is None:  # unknown state: keep the current period as it is
            if footprint:
                self.last_peak = footprint['phys_footprint_peak']
            self.last_load = record.get('loadavg', self.last_load)
            return
        active = in_backup(admission)
        if active and self.current is None:
            self.current = {
                'index': len(self.backups) + 1, 'started': record['time'],
                'complete': self.samples > 0, 'reasons': [],
                'peak_before_bytes': self.last_peak, 'load_before': self.last_load,
                'load_start': record.get('loadavg'), 'max_footprint_bytes': None,
                'max_peak_bytes': None, 'active_samples': 0,
            }
            self.backups.append(self.current)
        if self.current is not None and active:
            backup = self.current
            backup['active_samples'] += 1
            reason = admission.get('reason')
            if reason and reason not in backup['reasons']:
                backup['reasons'].append(reason)
            if footprint:
                for key, field in (('phys_footprint', 'max_footprint_bytes'), ('phys_footprint_peak', 'max_peak_bytes')):
                    if backup[field] is None or footprint[key] > backup[field]:
                        backup[field] = footprint[key]
            backup['last_active'] = record['time']
            backup['load_last_active'] = record.get('loadavg')
            record['backup_index'] = backup['index']
        elif self.current is not None:
            backup = self.current
            backup['ended'] = record['time']
            backup['duration_seconds'] = round(now - backup['started']['epoch'], 1)
            backup['peak_after_bytes'] = footprint['phys_footprint_peak'] if footprint else None
            backup['footprint_after_bytes'] = footprint['phys_footprint'] if footprint else None
            backup['load_end'] = record.get('loadavg')
            for field in ('max_footprint_bytes', 'max_peak_bytes', 'peak_before_bytes', 'peak_after_bytes', 'footprint_after_bytes'):
                backup[field.replace('_bytes', '_mib')] = mib(backup[field])
            record['backup_ended'] = backup['index']
            self.current = None
        if footprint:
            self.last_peak = footprint['phys_footprint_peak']
        if record.get('loadavg') is not None:
            self.last_load = record['loadavg']

    def backups_done(self) -> str | None:
        complete = [backup for backup in self.backups if backup['complete'] and backup.get('ended')]
        if len(complete) >= self.args.backups and all(backup.get('retention_read') for backup in complete):
            return f'backups_complete: {len(complete)}'
        return None

    def write_line(self, record: dict) -> None:
        self.samples += 1
        if record['errors']:
            self.error_samples += 1
        self.handle.write(json.dumps(record, sort_keys=True) + '\n')
        self.handle.flush()

    def summary(self) -> dict:
        complete = [backup for backup in self.backups if backup['complete'] and backup.get('ended')]
        return {
            'ticket': 'CL-409', 'executable': self.args.executable, 'service': self.service,
            'build': self.build, 'started': self.started, 'stopped': time_fields(self.clock()),
            'stop_reason': self.stop_reason, 'sample_count': self.samples,
            'error_sample_count': self.error_samples, 'interval_seconds': self.args.interval,
            'highest': self.highest, 'alert_bytes': self.args.alert_bytes, 'alerts': self.alerts,
            'backups': self.backups, 'complete_backup_count': len(complete),
            'moved_snapshot_count': sum(1 for backup in complete if (backup.get('retention') or {}).get('moved')),
            'out': str(self.out), 'summary': str(self.summary_path),
        }

    def run(self) -> dict:
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.started = time_fields(self.clock())
        deadline = self.monotonic() + self.args.max_hours * 3600
        with self.out.open('a') as self.handle:
            while self.stop_reason is None:
                reason = self.sample_once()
                if reason is not None and self.stop_reason is None:
                    self.stop_reason = reason
                    break
                if self.stop_reason is not None:
                    break
                if self.monotonic() >= deadline:
                    self.stop_reason = f'max_hours: {self.args.max_hours}'
                    break
                self.sleep(self.args.interval)
        # A stop before --retention-delay passed still reads retention one time.
        for backup in self.backups:
            if backup['complete'] and backup.get('ended') and not backup.get('retention_read'):
                self.read_retention(backup)
                backup['retention']['read_early_at_stop'] = True
        result = self.summary()
        self.summary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        return result


def parse_args(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--out', required=True, help='JSONL file for the samples (appended)')
    parser.add_argument('--summary', help='summary JSON file (default: <out>.summary.json)')
    parser.add_argument('--interval', type=float, default=15, help='seconds between samples')
    parser.add_argument('--backups', type=int, default=3, help='stop after this many complete backups')
    parser.add_argument('--max-hours', type=float, default=10, help='stop after this many hours')
    parser.add_argument('--alert-bytes', type=int, default=DEFAULT_ALERT_BYTES, help='footprint that starts one capture per backup')
    parser.add_argument('--retention-delay', type=float, default=60, help='seconds after a backup ends before backup_retention_status')
    parser.add_argument('--executable', default=DEFAULT_EXECUTABLE, help='exact executable path of the service')
    parser.add_argument('--cli', default=DEFAULT_CLI, help='checklist CLI path')
    parser.add_argument('--project-dir', default=DEFAULT_PROJECT_DIR, help='cwd of each checklist call')
    parser.add_argument('--project-id', default=DEFAULT_PROJECT_ID, help='project for backup_retention_status')
    args = parser.parse_args(argv)
    if args.interval <= 0 or args.backups < 1 or args.max_hours <= 0 or args.alert_bytes <= 0 or args.retention_delay < 0:
        parser.error('interval, backups, max hours and alert bytes must be positive')
    return args


def main(argv: list[str] | None = None, **inject) -> int:
    args = parse_args(argv)
    sampler = Sampler(args, **inject)
    previous = {sig: signal.signal(sig, sampler.request_stop) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        result = sampler.run()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    print(json.dumps({key: result[key] for key in ('stop_reason', 'sample_count', 'error_sample_count',
                                                   'complete_backup_count', 'moved_snapshot_count', 'summary')}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
