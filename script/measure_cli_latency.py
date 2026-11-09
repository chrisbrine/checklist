#!/usr/bin/env python3
"""Bounded CL-375 new-process latency checks; never starts service writes.

Examples (select the exact slot/installed executable and real native workspace):
  python3 script/measure_cli_latency.py --cli /absolute/checklist --cwd /workspace \
    --project-id UUID --task-id UUID --output /outside/checkout/evidence --mode calls
  # Start an authorized slot backup separately, then require it throughout 50 calls:
  ... --mode calls --require-backup [--backup-operation-id UUID]
  # One burst of 10 cleanup reads and the two latency probes:
  ... --mode burst

Every CLI invocation inherits the native host environment, adds CHECKLIST_TIMING=1,
and starts a fresh process. Complete stdout/stderr, monotonic process lifetimes,
parsed timing diagnostics, and start/end `sysctl -n vm.loadavg` replies are saved.
The backup check brackets the calls with active backup admission or the same
running backup_create operation. It never initiates a backup or waits for load.
Each call also has load reads before and after its timed process interval.
The latency limit applies to the 50-call series and the two foreground burst
probes. Cleanup timings are retained; a successful slow cleanup does not fail
the foreground latency gate. Every reply/load/timeout/overlap error is fatal.
Exit 1 means a latency, reply, load, timeout, backup or burst-overlap failure.
Process overlap and service overlap are reported separately. Burst qualification
requires each probe's process lifetime to overlap all 10 cleanup processes at
once. Instrumented replies must also show each probe overlapping at least one
cleanup request in the service. A baseline without timing has process evidence
only, identified explicitly in the overlap report.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import threading
import time


def execute(command, *, cwd, env, timeout):
    """Capture the actual PID and streams; kill and reap the CLI after a timeout."""
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return process.returncode, stdout, stderr, False, process.pid
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        return process.returncode, stdout, stderr, True, process.pid


def text(value):
    return value.decode('utf-8', 'replace') if isinstance(value, bytes) else value


def timing_lines(stderr):
    records = []
    for line in stderr.splitlines():
        if line.startswith('ChecklistTiming '):
            try:
                value = json.loads(line[len('ChecklistTiming '):])
                if isinstance(value, dict):
                    records.append(value)
            except ValueError:
                pass  # Original diagnostics remain in stderr, including malformed lines.
    return records


def validate_reply(method, reply, project_id, task_id, operation_id=None):
    if not isinstance(reply, dict) or reply.get('error') or reply.get('ok') is False or reply.get('isError') is True:
        return 'error or non-object reply'
    if reply.get('command_outcome') in ('accepted', 'queued', 'unknown'):
        return 'read did not return its completed result'
    data = reply.get('data')
    if not isinstance(data, dict) or data.get('error'):
        return 'missing data object or data contains an error'
    if method == 'service_info':
        if not isinstance(data.get('build_id'), str) or not data['build_id']:
            return 'service_info has no build_id'
    elif method == 'task_get':
        if str(data.get('id', '')).lower() != task_id.lower():
            return 'task_get returned a different or missing task id'
        if data.get('project_id') is not None and str(data['project_id']).lower() != project_id.lower():
            return 'task_get returned a different project'
    elif method == 'cleanup_job_list':
        count = data.get('total_count')
        if not isinstance(data.get('cleanup_jobs'), list) or type(count) is not int or count < 0 or type(data.get('complete')) is not bool:
            return 'cleanup_job_list has invalid list/count/completeness fields'
    elif method == 'operation_get':
        if data.get('operation_id') != operation_id or data.get('method') != 'backup_create':
            return 'operation_get did not identify the requested backup_create'
        if data.get('state') not in ('queued', 'running', 'succeeded', 'failed'):
            return 'operation_get has no valid operation state'
    return None


def overlap(records):
    cleanup = [r for r in records if r['method'] == 'cleanup_job_list']
    probes = [r for r in records if r['method'] in ('service_info', 'task_get')]
    start = max((r['start_monotonic_s'] for r in cleanup), default=math.inf)
    end = min((r['end_monotonic_s'] for r in cleanup), default=-math.inf)
    probe_overlap = {r['method']: start < end and r['start_monotonic_s'] < end and r['end_monotonic_s'] > start for r in probes}
    result = {'cleanup_count': len(cleanup), 'cleanup_common_interval_s': [start, end] if cleanup else None,
              'probes_overlap_all_cleanup_processes': probe_overlap,
              'complete': len(cleanup) == 10 and len(probes) == 2 and all(probe_overlap.values()),
              'evidence_kind': 'client process lifetimes; includes bootstrap and reply handling'}
    # When available, absolute systemUptime markers prove service receipt/reply overlap.
    intervals = []
    service_timing_seen = False
    for record in records:
        candidates = [t.get('service') for t in record['timing'] if t.get('scope') == 'ipc' and t.get('method') == record['method']]
        new_boundaries = {'received_uptime_s', 'coordinator_dequeued_uptime_s', 'reply_ready_uptime_s'}
        service_timing_seen = service_timing_seen or any(isinstance(s, dict) and new_boundaries.intersection(s) for s in candidates)
        service = next((s for s in candidates if isinstance(s, dict) and 'received_uptime_s' in s and 'reply_ready_uptime_s' in s), None)
        if service:
            intervals.append({'method': record['method'], 'start_monotonic_s': service['received_uptime_s'], 'end_monotonic_s': service['reply_ready_uptime_s']})
    result['service_timing_available_count'] = len(intervals)
    result['service_overlap_required'] = service_timing_seen
    result['service_overlap_complete'] = False
    result['service_evidence_kind'] = ('receipt/reply boundaries' if len(intervals) == 12 else
                                       'incomplete receipt/reply boundaries' if service_timing_seen else
                                       'process-only baseline; no service boundary timestamps advertised')
    if len(intervals) == 12:
        service_cleanup = [r for r in intervals if r['method'] == 'cleanup_job_list']
        first = max(r['start_monotonic_s'] for r in service_cleanup)
        last = min(r['end_monotonic_s'] for r in service_cleanup)
        result['service_intervals'] = intervals
        result['probes_overlap_all_cleanup_service_requests'] = {r['method']: first < last and r['start_monotonic_s'] < last and r['end_monotonic_s'] > first for r in intervals if r['method'] != 'cleanup_job_list'}
        result['probes_overlap_any_cleanup_service_request'] = {
            r['method']: any(r['start_monotonic_s'] < c['end_monotonic_s'] and r['end_monotonic_s'] > c['start_monotonic_s'] for c in service_cleanup)
            for r in intervals if r['method'] != 'cleanup_job_list'}
        result['service_overlap_complete'] = all(result['probes_overlap_any_cleanup_service_request'].values())
    return result


class Measurement:
    def __init__(self, args, runner=execute):
        self.args, self.runner = args, runner
        self.output = Path(args.output).resolve()
        self.env = dict(os.environ, CHECKLIST_TIMING='1')
        self.lock = threading.Lock()
        self.deadline = time.monotonic() + args.max_seconds
        self.records, self.issues = [], []

    def command(self, command, label):
        started = time.monotonic()
        record = {'label': label, 'command': command, 'cwd': str(self.args.cwd),
                  'started_utc': datetime.now(timezone.utc).isoformat(), 'start_monotonic_s': started}
        try:
            remaining = self.deadline - started
            if remaining <= 0:
                raise TimeoutError('overall measurement deadline reached')
            code, stdout, stderr, timed_out, pid = self.runner(command, cwd=self.args.cwd, env=self.env,
                                                              timeout=min(self.args.call_timeout, remaining))
            record.update(returncode=code, stdout=text(stdout), stderr=text(stderr), timed_out=timed_out, pid=pid)
        except Exception as error:
            record.update(returncode=None, stdout='', stderr='', timed_out=isinstance(error, TimeoutError), execution_error=repr(error))
        record['end_monotonic_s'] = time.monotonic()
        record['wall_seconds'] = record['end_monotonic_s'] - started
        return record

    def save(self, record):
        with self.lock:
            self.records.append(record)
            with (self.output / 'calls.jsonl').open('a') as stream:
                stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + '\n')
                stream.flush()
        return record

    def load(self, label, save=True):
        record = self.command(['sysctl', '-n', 'vm.loadavg'], label)
        try:
            values = record['stdout'].replace('{', ' ').replace('}', ' ').split()
            record['loadavg'] = [float(v) for v in values]
            if record['returncode'] != 0 or record['timed_out'] or len(record['loadavg']) != 3 or not all(math.isfinite(v) and v >= 0 for v in record['loadavg']):
                raise ValueError('expected three finite load averages and successful sysctl')
        except (ValueError, TypeError) as error:
            record.pop('loadavg', None)
            record['validation_error'] = str(error)
        return self.save(record) if save else record

    def call(self, method, label, barrier=None):
        load_start = self.load(label + '-load-start', save=False)
        barrier_error = None
        if barrier:
            try:
                barrier.wait(timeout=max(.001, min(self.args.call_timeout, self.deadline - time.monotonic())))
            except threading.BrokenBarrierError as error:
                barrier_error = repr(error)
        params = {'project_id': self.args.project_id}
        if method in ('task_get', 'cleanup_job_list'):
            params['task_id'] = self.args.task_id
        if method == 'operation_get':
            params['operation_id'] = self.args.backup_operation_id
        command = [self.args.cli, 'call', method, json.dumps(params, sort_keys=True)]
        if barrier_error:
            now = time.monotonic()
            record = {'label': label, 'command': command, 'returncode': None, 'stdout': '', 'stderr': '',
                      'start_monotonic_s': now, 'end_monotonic_s': now, 'wall_seconds': 0,
                      'timed_out': True, 'execution_error': 'burst synchronization failed: ' + barrier_error}
        else:
            record = self.command(command, label)
        record.update(method=method, timing=timing_lines(record['stderr']))
        record.update(load_start=load_start, load_end=self.load(label + '-load-end', save=False))
        try:
            record['reply'] = json.loads(record['stdout'])
            error = validate_reply(method, record['reply'], self.args.project_id, self.args.task_id, self.args.backup_operation_id)
            if error:
                record['validation_error'] = error
        except (ValueError, TypeError) as error:
            record['validation_error'] = 'invalid JSON reply: ' + str(error)
        return self.save(record)

    def backup(self, label):
        method = 'operation_get' if self.args.backup_operation_id else 'service_info'
        record = self.call(method, label)
        reply = record.get('reply') or {}
        data = reply.get('data') if isinstance(reply, dict) else None
        data = data if isinstance(data, dict) else {}
        admission = (reply.get('write_admission') or data.get('write_admission')) if isinstance(reply, dict) else None
        admission = admission if isinstance(admission, dict) else {}
        active = data.get('state') == 'running' if method == 'operation_get' else admission.get('backup_active') is True
        return {'label': label, 'active': bool(active and not record.get('validation_error') and record['returncode'] == 0),
                'record_label': record['label'], 'method': method}

    def run(self):
        if self.output.is_relative_to(Path(__file__).resolve().parents[1]):
            raise ValueError('Evidence output must be outside the source checkout')
        self.output.mkdir(parents=True, exist_ok=False)
        summary = {'ticket': 'CL-375', 'arguments': vars(self.args).copy(), 'phases': {}, 'issues': self.issues,
                   'environment_policy': 'native identity inherited unchanged; CHECKLIST_TIMING=1 added'}
        try:
            if self.args.mode in ('calls', 'all'):
                phase = summary['phases']['calls'] = {'load_start': self.load('calls-load-start')}
                if self.args.require_backup or self.args.backup_operation_id:
                    phase['backup_before'] = self.backup('backup-before')
                calls = []
                for i in range(self.args.count):
                    if time.monotonic() >= self.deadline:
                        self.issues.append('overall deadline reached before all new-process calls completed')
                        break
                    calls.append(self.call(self.args.method, f'new-process-{i + 1:03}'))
                phase['count'] = len(calls)
                times = sorted(r['wall_seconds'] for r in calls)
                if times:
                    phase['latency_seconds'] = {'p50': times[math.ceil(len(times) * .50) - 1], 'p95': times[math.ceil(len(times) * .95) - 1], 'max': max(times)}
                if self.args.require_backup or self.args.backup_operation_id:
                    phase['backup_after'] = self.backup('backup-after')
                    if not (phase['backup_before']['active'] and phase['backup_after']['active']):
                        self.issues.append('backup was not observed active at both call-series boundaries')
                phase['load_end'] = self.load('calls-load-end')
            if self.args.mode in ('burst', 'all'):
                phase = summary['phases']['burst'] = {'load_start': self.load('burst-load-start')}
                barrier = threading.Barrier(12)
                methods = ['cleanup_job_list'] * 10 + ['service_info', 'task_get']
                with ThreadPoolExecutor(max_workers=12) as pool:
                    futures = [pool.submit(self.call, method, f'burst-{i + 1:02}-{method}', barrier) for i, method in enumerate(methods)]
                    calls = [future.result() for future in futures]
                phase['overlap'] = overlap(calls)
                if not phase['overlap']['complete']:
                    self.issues.append('burst did not establish both probes overlapping all 10 cleanup processes')
                if phase['overlap']['service_overlap_required'] and not phase['overlap']['service_overlap_complete']:
                    self.issues.append('instrumented burst did not establish each probe overlapping a cleanup request in the service')
                phase['load_end'] = self.load('burst-load-end')
        except Exception as error:
            self.issues.append(repr(error))
        finally:
            for record in self.records:
                if record.get('execution_error') or record.get('validation_error') or record['returncode'] != 0 or record['timed_out']:
                    self.issues.append(record['label'] + ': failed or invalid reply (see calls.jsonl)')
                for boundary in ('load_start', 'load_end'):
                    load = record.get(boundary)
                    if load and (load.get('validation_error') or load.get('execution_error') or load['returncode'] != 0 or load['timed_out']):
                        self.issues.append(record['label'] + ': ' + boundary + ' failed (see calls.jsonl)')
                latency_probe = record['label'].startswith('new-process-') or (
                    record['label'].startswith('burst-') and record.get('method') in ('service_info', 'task_get'))
                if latency_probe and record['wall_seconds'] > self.args.limit_seconds:
                    self.issues.append(f"{record['label']}: {record['wall_seconds']:.6f}s exceeds {self.args.limit_seconds:.6f}s")
            summary.update(passed=not self.issues, record_count=len(self.records), finished_utc=datetime.now(timezone.utc).isoformat())
            (self.output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + '\n')
        return summary


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ('cli', 'cwd', 'project-id', 'task-id', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--mode', choices=('calls', 'burst', 'all'), default='all')
    parser.add_argument('--method', choices=('task_get', 'service_info'), default='task_get')
    parser.add_argument('--count', type=int, default=50)
    parser.add_argument('--require-backup', action='store_true')
    parser.add_argument('--backup-operation-id', help='existing backup_create operation; never starts a backup')
    parser.add_argument('--limit-seconds', type=float, default=1)
    parser.add_argument('--call-timeout', type=float, default=15)
    parser.add_argument('--max-seconds', type=float, default=900)
    args = parser.parse_args(argv)
    if args.count < 50:
        parser.error('--count must be at least 50')
    if args.mode == 'burst' and (args.require_backup or args.backup_operation_id):
        parser.error('backup bracketing requires --mode calls or all')
    for name in ('limit_seconds', 'call_timeout', 'max_seconds'):
        if not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0:
            parser.error('--' + name.replace('_', '-') + ' must be finite and positive')
    return args


def main(argv=None):
    args = arguments(argv)
    try:
        summary = Measurement(args).run()
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps({'passed': summary['passed'], 'issues': summary['issues'], 'summary': str(Path(args.output) / 'summary.json')}, sort_keys=True))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
