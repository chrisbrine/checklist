#!/usr/bin/env python3
"""CL-444 launch controls: compare a new Checklist CLI process with other programs.

One run starts each kind in turn as a new process, so every kind meets the same
CPU load. It never starts a backup, a write command or a load generator.

  cli_call     CLI `call service_info '{}'` (a read on the selected service)
  cli_version  the same CLI, `version` (no service request)
  true         /usr/bin/true (exec, exit and reap only)
  c_min        a C program that reads the clock and exits
  swift_min    a Swift program with Foundation and an async main
  c_echo       the C program with two round trips to an idle local echo process
  c_cpu        the C program with a loop that uses --control-cpu-ms of CPU time

Example (one command; the output folder is new and outside the checkout):
  python3 script/measure_process_launch.py
    --cli /Applications/Checklist.app/Contents/MacOS/checklist
    --cwd /the/caller's/actual/workspace --output /outside/checkout/evidence

The launcher reads the uptime clock before and after posix_spawn and after wait4.
The CLI reports its entry to main and its end with CHECKLIST_TIMING=1. The control
programs report the same two stamps as a `ControlTiming` stderr line. wait4 gives
the CPU time and the context switches of each process. `os.getloadavg()` (the
kernel value behind `sysctl -n vm.loadavg`) is read before and after each process.
The summary gives the 1-, 5- and 15-minute ranges: a load value was seen to fall
to below 1 when it passed about 1024, and to stay too low for some minutes.
`--capture file` (default) sends stdout and stderr to files, so no process waits
for its reader. `--capture pipe` reads them through pipes, as an agent shell does.

Phases are disjoint wall intervals on one clock:
  spawn_to_main   launcher clock before posix_spawn -> first line of main
  client          work in main outside a request (all of main for a control)
  delivery        request send -> receipt in the other process, and reply -> waiter
  service         receipt -> reply ready in the other process
  exit_reap       last stamp in main -> wait4 returned in the launcher
`spawn_call` is the posix_spawn call alone (inside spawn_to_main). `cpu` is user
plus system CPU time of the process; `off_cpu` is total minus cpu.
Round 0 starts each kind once and stays out of the summary: the first start of a
new binary includes one-time system checks.

calls.jsonl holds one record per process (sizes of stdout and stderr, not their
content). summary.json and summary.md hold median, p95 and maximum per kind and
phase with the load range. Exit 1 means a failed start, reply, control or deadline.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

KINDS = ('cli_call', 'cli_version', 'true', 'c_min', 'swift_min', 'c_echo', 'c_cpu')
CLI_KINDS = ('cli_call', 'cli_version')
PHASES = ('total', 'spawn_call', 'spawn_to_main', 'client', 'delivery', 'service', 'exit_reap', 'cpu', 'off_cpu')
CLI_DETAIL = ('main_to_first_send', 'bootstrap_delivery', 'bootstrap_service', 'bootstrap_reply', 'between_requests',
              'call_delivery', 'call_service', 'call_reply', 'reply_to_main_end')

CONTROL_C = r'''
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static double now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static double cpu(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static int local(const char *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof *address);
    address->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof address->sun_path) return -1;
    strcpy(address->sun_path, path);
    return socket(AF_UNIX, SOCK_STREAM, 0);
}

static int transfer(int fd, void *buffer, size_t count, int writing) {
    char *bytes = buffer;
    while (count > 0) {
        ssize_t moved = writing ? write(fd, bytes, count) : read(fd, bytes, count);
        if (moved < 0 && errno == EINTR) continue;
        if (moved <= 0) return -1;
        bytes += moved;
        count -= (size_t)moved;
    }
    return 0;
}

int main(int argc, char **argv) {
    double entered = now(), cpu_entered = cpu();
    struct sockaddr_un address;
    /* sun_path holds about 100 bytes: enter the folder and use the socket's name. */
    if (argc == 5 && !strcmp(argv[1], "serve")) {
        /* An idle echo process. It ends by itself after argv[4] seconds. */
        int listener = chdir(argv[2]) ? -1 : local(argv[3], &address);
        alarm((unsigned)atoi(argv[4]));
        if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) || listen(listener, 16)) {
            perror("serve");
            return 2;
        }
        printf("ready\n");
        fflush(stdout);
        for (;;) {
            int peer = accept(listener, NULL, NULL);
            char byte;
            if (peer < 0) { if (errno == EINTR) continue; return 2; }
            while (transfer(peer, &byte, 1, 0) == 0) {
                double stamps[2];
                stamps[0] = now();
                stamps[1] = now();
                if (transfer(peer, stamps, sizeof stamps, 1)) break;
            }
            close(peer);
        }
    }
    double sent[2] = {0, 0}, received[2] = {0, 0}, replied[2] = {0, 0}, resumed[2] = {0, 0};
    int rounds = 0;
    if (argc == 4 && !strcmp(argv[1], "echo")) {
        /* One connection per request, like the CLI's bootstrap and command. */
        if (chdir(argv[2])) { perror("echo"); return 2; }
        for (; rounds < 2; rounds++) {
            double stamps[2];
            char byte = 1;
            int fd = local(argv[3], &address);
            if (fd < 0 || connect(fd, (struct sockaddr *)&address, sizeof address)) { perror("echo"); return 2; }
            sent[rounds] = now();
            if (transfer(fd, &byte, 1, 1) || transfer(fd, stamps, sizeof stamps, 0)) { perror("echo"); return 2; }
            resumed[rounds] = now();
            received[rounds] = stamps[0];
            replied[rounds] = stamps[1];
            close(fd);
        }
    } else if (argc == 3 && !strcmp(argv[1], "cpu")) {
        /* Use argv[2] milliseconds of CPU time in main, with no request and no wait. */
        double target = atof(argv[2]) / 1000.0;
        volatile unsigned long sink = 0;
        while (cpu() - cpu_entered < target)
            for (int i = 0; i < 20000; i++) sink += (unsigned long)i;
    } else if (argc != 1) {
        fprintf(stderr, "usage: control_c | control_c cpu MILLISECONDS | control_c echo FOLDER SOCKET | control_c serve FOLDER SOCKET SECONDS\n");
        return 2;
    }
    double ended = now();
    fprintf(stderr, "ControlTiming {\"scope\":\"control\",\"kind\":\"c\",\"main_entered_uptime_s\":%.9f,"
            "\"cpu_at_main_s\":%.6f,\"main_end_uptime_s\":%.9f,\"rounds\":[", entered, cpu_entered, ended);
    for (int i = 0; i < rounds; i++)
        fprintf(stderr, "%s{\"sent_uptime_s\":%.9f,\"received_uptime_s\":%.9f,\"reply_ready_uptime_s\":%.9f,"
                "\"waiter_resumed_uptime_s\":%.9f}", i ? "," : "", sent[i], received[i], replied[i], resumed[i]);
    fprintf(stderr, "]}\n");
    return 0;
}
'''

CONTROL_SWIFT = r'''
import Foundation

@main
struct Control {
    static func main() async {
        let entered = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        // Foundation work inside main, before the end stamp.
        let sample: [String: Any] = ["scope": "control", "values": [1, 2.5, "text"]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]), !bytes.isEmpty else { exit(2) }
        let ended = ProcessInfo.processInfo.systemUptime
        fputs("ControlTiming {\"scope\":\"control\",\"kind\":\"swift\",\"main_entered_uptime_s\":\(entered),"
            + "\"cpu_at_main_s\":\(cpu),\"main_end_uptime_s\":\(ended),\"rounds\":[]}\n", stderr)
    }
}
'''


def uptime():
    """The clock of ProcessInfo.systemUptime and CLOCK_UPTIME_RAW."""
    raw = getattr(time, 'CLOCK_UPTIME_RAW', None)
    return time.clock_gettime(raw) if raw is not None else time.monotonic()


def build_controls(directory, run=subprocess.run):
    """Write and compile both control programs in `directory`; return their paths."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'control.c').write_text(CONTROL_C)
    (directory / 'control.swift').write_text(CONTROL_SWIFT)
    commands = {'control_c': ['cc', '-O2', '-o', str(directory / 'control_c'), str(directory / 'control.c')],
                'control_swift': ['swiftc', '-O', '-parse-as-library', '-o', str(directory / 'control_swift'),
                                  str(directory / 'control.swift')]}
    for name, command in commands.items():
        done = run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
        if done.returncode != 0:
            raise OSError(f'{name} did not compile: ' + done.stdout.decode('utf-8', 'replace')[-2000:])
    return {name: str(directory / name) for name in commands}


def launch(argv, *, env, timeout, capture, files, clock=uptime):
    """Start one process with posix_spawn, bound its life, reap it with wait4.

    `files` are two open descriptors for `--capture file`. The alarm handler ends
    a process that passes `timeout`; wait4 and the pipe reads then return.
    """
    state = {'pid': None, 'timed_out': False}

    def expire(_signal, _frame):
        state['timed_out'] = True
        if state['pid'] is not None:
            try:
                os.kill(state['pid'], signal.SIGKILL)
            except ProcessLookupError:
                pass

    pipes = []
    if capture == 'pipe':
        pipes = [os.pipe(), os.pipe()]
        targets = [pipes[0][1], pipes[1][1]]
    else:
        for descriptor in files:
            os.ftruncate(descriptor, 0)
            os.lseek(descriptor, 0, os.SEEK_SET)
        targets = list(files)
    actions = [(os.POSIX_SPAWN_OPEN, 0, os.devnull, os.O_RDONLY, 0),
               (os.POSIX_SPAWN_DUP2, targets[0], 1), (os.POSIX_SPAWN_DUP2, targets[1], 2)]
    previous = signal.signal(signal.SIGALRM, expire)
    # The timer repeats, so a process whose ID arrives after the first expiry still ends.
    signal.setitimer(signal.ITIMER_REAL, timeout, 1)
    chunks = [[], []]
    write_ends_open = capture == 'pipe'
    result = {'argv': list(argv), 'load_start': list(os.getloadavg())}
    try:
        result['spawn_start_uptime_s'] = clock()
        state['pid'] = os.posix_spawn(argv[0], argv, env, file_actions=actions)
        result['spawn_return_uptime_s'] = clock()
        if capture == 'pipe':
            for _, write_end in pipes:
                os.close(write_end)
            write_ends_open = False
            open_ends = {pipes[0][0]: 0, pipes[1][0]: 1}
            while open_ends:
                ready, _, _ = select.select(list(open_ends), [], [])
                for descriptor in ready:
                    data = os.read(descriptor, 65536)
                    if data:
                        chunks[open_ends[descriptor]].append(data)
                    else:
                        del open_ends[descriptor]
            result['output_end_uptime_s'] = clock()
        _, status, usage = os.wait4(state['pid'], 0)
        result['reaped_uptime_s'] = clock()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        for read_end, write_end in pipes:
            os.close(read_end)
            if write_ends_open:
                os.close(write_end)
    if capture == 'file':
        for index, descriptor in enumerate(files):
            os.lseek(descriptor, 0, os.SEEK_SET)
            while True:
                data = os.read(descriptor, 1 << 20)
                if not data:
                    break
                chunks[index].append(data)
            os.ftruncate(descriptor, 0)
    result.update(pid=state['pid'], timed_out=state['timed_out'], returncode=os.waitstatus_to_exitcode(status),
                  capture=capture,
                  cpu_user_s=usage.ru_utime, cpu_system_s=usage.ru_stime, voluntary_switches=usage.ru_nvcsw,
                  involuntary_switches=usage.ru_nivcsw, stdout=b''.join(chunks[0]), stderr=b''.join(chunks[1]),
                  load_end=list(os.getloadavg()))
    return result


def prefixed_json(stderr, prefix):
    values = []
    for line in stderr.splitlines():
        if line.startswith(prefix):
            try:
                value = json.loads(line[len(prefix):])
            except ValueError:
                continue
            if isinstance(value, dict):
                values.append(value)
    return values


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def rounds_of(record):
    """Request stamps in order: [{sent, received, reply_ready, waiter_resumed}]."""
    rounds = []
    if record['kind'] == 'cli_call':
        for line in record['timing']:
            service = line.get('service')
            if line.get('scope') == 'ipc' and isinstance(service, dict):
                rounds.append({'sent': line.get('sent_uptime_s'), 'received': service.get('received_uptime_s'),
                               'reply_ready': service.get('reply_ready_uptime_s'),
                               'waiter_resumed': line.get('waiter_resumed_uptime_s')})
    elif record.get('control'):
        for item in record['control'].get('rounds') or []:
            rounds.append({'sent': item.get('sent_uptime_s'), 'received': item.get('received_uptime_s'),
                           'reply_ready': item.get('reply_ready_uptime_s'),
                           'waiter_resumed': item.get('waiter_resumed_uptime_s')})
    return rounds


def phases(record):
    """Disjoint wall intervals of one process record, in seconds. Raises ValueError."""
    start, reaped = record['spawn_start_uptime_s'], record['reaped_uptime_s']
    cpu = record['cpu_user_s'] + record['cpu_system_s']
    result = {'total': reaped - start, 'spawn_call': record['spawn_return_uptime_s'] - start,
              'cpu': cpu, 'off_cpu': max(0.0, reaped - start - cpu)}
    if record['kind'] in CLI_KINDS:
        setup = next((t for t in record['timing'] if t.get('scope') == 'cli_setup'), None)
        whole = next((t for t in record['timing'] if t.get('scope') == 'cli'), None)
        if not setup or not whole or not number(setup.get('main_entered_uptime_s')) or not number(whole.get('total_ms')):
            raise ValueError('no cli_setup and cli timing lines')
        entered = setup['main_entered_uptime_s']
        ended = entered + whole['total_ms'] / 1000
    elif record['kind'] == 'true':
        return result
    else:
        control = record.get('control')
        if not control or not number(control.get('main_entered_uptime_s')) or not number(control.get('main_end_uptime_s')):
            raise ValueError('no ControlTiming line')
        entered, ended = control['main_entered_uptime_s'], control['main_end_uptime_s']
        if number(control.get('cpu_at_main_s')):
            result['cpu_before_main'] = control['cpu_at_main_s']
    rounds = rounds_of(record)
    expected = {'cli_call': 2, 'c_echo': 2}.get(record['kind'], 0)
    if len(rounds) != expected or any(not number(v) for r in rounds for v in r.values()):
        raise ValueError(f'expected {expected} complete request timings, found {len(rounds)}')
    result.update(spawn_to_main=entered - start, exit_reap=reaped - ended)
    result['client'] = ended - entered
    if rounds:
        delivery = sum((r['received'] - r['sent']) + (r['waiter_resumed'] - r['reply_ready']) for r in rounds)
        service = sum(r['reply_ready'] - r['received'] for r in rounds)
        result.update(client=(ended - entered) - delivery - service, delivery=delivery, service=service)
    if record['kind'] == 'cli_call':
        first, second = rounds
        result.update(main_to_first_send=first['sent'] - entered,
                      bootstrap_delivery=first['received'] - first['sent'],
                      bootstrap_service=first['reply_ready'] - first['received'],
                      bootstrap_reply=first['waiter_resumed'] - first['reply_ready'],
                      between_requests=second['sent'] - first['waiter_resumed'],
                      call_delivery=second['received'] - second['sent'],
                      call_service=second['reply_ready'] - second['received'],
                      call_reply=second['waiter_resumed'] - second['reply_ready'],
                      reply_to_main_end=ended - second['waiter_resumed'])
    return result


def validate(record):
    if record['timed_out']:
        return 'process passed the call timeout and was ended'
    if record['returncode'] != 0:
        return f"exit status {record['returncode']}"
    stdout = record.pop('stdout_text')
    if record['kind'] == 'cli_call':
        try:
            reply = json.loads(stdout)
        except ValueError as error:
            return 'invalid JSON reply: ' + str(error)
        data = reply.get('data') if isinstance(reply, dict) else None
        if not isinstance(data, dict) or reply.get('error') or not isinstance(data.get('build_id'), str) or not data['build_id']:
            return 'service_info reply has no data.build_id'
        record['build_id'] = data['build_id']
        admission = reply.get('write_admission')
        record['backup_active'] = admission.get('backup_active') if isinstance(admission, dict) else None
    elif record['kind'] == 'cli_version':
        if not stdout.startswith('Checklist '):
            return 'version output does not start with "Checklist "'
        record['version_line'] = stdout.strip()[:200]
    return None


def quantile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def summarize(records, limit_seconds):
    kinds = {}
    for kind in KINDS:
        rows = [r for r in records if r['kind'] == kind and r.get('phases') and not r.get('warmup')]
        if not rows:
            continue
        table = {}
        names = [n for n in PHASES + ('cpu_before_main',) + CLI_DETAIL if any(n in r['phases'] for r in rows)]
        for name in names:
            values = [r['phases'][name] for r in rows if name in r['phases']]
            table[name] = {'count': len(values), 'median': quantile(values, .5), 'p95': quantile(values, .95), 'max': max(values)}
        totals = [r['phases']['total'] for r in rows]
        ratios = [r['phases']['total'] / r['phases']['cpu'] for r in rows if r['phases']['cpu'] > 0]
        kinds[kind] = {'count': len(rows), 'phases_seconds': table,
                       'over_limit': sum(1 for value in totals if value > limit_seconds),
                       'wall_per_cpu_median': quantile(ratios, .5) if ratios else None,
                       'involuntary_switches_median': quantile([r['involuntary_switches'] for r in rows], .5),
                       'stdout_bytes_median': quantile([r['stdout_bytes'] for r in rows], .5)}
    measured = [r for r in records if 'load_start' in r and 'load_end' in r]
    result = {'kinds': kinds, 'builds': sorted({r['build_id'] for r in records if r.get('build_id')}),
              'backup_active_calls': sum(1 for r in records if r.get('backup_active') is True and not r.get('warmup'))}
    if measured:
        # A kernel load value wraps near 1024; the slower averages reach that point later.
        for position, name in enumerate(('load_1min', 'load_5min', 'load_15min')):
            loads = [r[key][position] for r in measured for key in ('load_start', 'load_end')]
            result[name] = {'min': min(loads), 'median': quantile(loads, .5), 'max': max(loads)}
        result['load_first'] = measured[0]['load_start']
        result['load_last'] = measured[-1]['load_end']
    return result


def markdown(summary):
    lines = [f"# New process launch controls ({summary['ticket']})", '',
             f"Started {summary['started_utc']}, finished {summary['finished_utc']}. Capture: {summary['arguments']['capture']}.",
             f"Load (1, 5, 15 min) first {summary.get('load_first')}, last {summary.get('load_last')}. CPUs: {summary['cpu_count']}.",
             f"1-minute range {summary.get('load_1min')}; 5-minute range {summary.get('load_5min')}.", '',
             'Milliseconds: median / p95 / maximum. wall/cpu: median of total divided by cpu.', '',
             f"Service builds seen: {summary.get('builds')}; calls with a backup active: {summary.get('backup_active_calls')}.", '',
             '| Kind | n | ' + ' | '.join(PHASES) + ' | wall/cpu | above limit |',
             '| --- | ---: | ' + ' | '.join('---:' for _ in PHASES) + ' | ---: | ---: |']

    def cell(table, name):
        if name not in table:
            return '-'
        return ' / '.join(f"{table[name][key] * 1000:.1f}" for key in ('median', 'p95', 'max'))

    for kind, value in summary['kinds'].items():
        table = value['phases_seconds']
        ratio = value.get('wall_per_cpu_median')
        lines.append(f"| {kind} | {value['count']} | " + ' | '.join(cell(table, name) for name in PHASES)
                     + f" | {'-' if ratio is None else format(ratio, '.1f')} | {value['over_limit']} |")
    detail = summary['kinds'].get('cli_call', {}).get('phases_seconds', {})
    if any(name in detail for name in CLI_DETAIL):
        lines += ['', '| cli_call interval | median | p95 | max |', '| --- | ---: | ---: | ---: |']
        lines += [f"| {name} | " + ' | '.join(f"{detail[name][key] * 1000:.1f}" for key in ('median', 'p95', 'max')) + ' |'
                  for name in CLI_DETAIL if name in detail]
    lines += ['', 'Issues: ' + ('; '.join(summary['issues']) if summary['issues'] else 'none'), '']
    return '\n'.join(lines)


class Measurement:
    def __init__(self, args, launcher=launch, builder=build_controls, clock=uptime):
        self.args, self.launcher, self.builder, self.clock = args, launcher, builder, clock
        self.output = Path(args.output).resolve()
        self.records, self.issues = [], []
        self.server = None

    def commands(self, controls, socket_name):
        cli = self.args.cli
        return {'cli_call': [cli, 'call', 'service_info', '{}'], 'cli_version': [cli, 'version'],
                'true': ['/usr/bin/true'], 'c_min': [controls['control_c']],
                'swift_min': [controls['control_swift']],
                'c_echo': [controls['control_c'], 'echo', str(self.output), socket_name],
                'c_cpu': [controls['control_c'], 'cpu', format(self.args.control_cpu_ms, 'g')]}

    def start_server(self, controls, socket_name):
        self.server = subprocess.Popen([controls['control_c'], 'serve', str(self.output), socket_name, str(int(self.args.max_seconds) + 60)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ready, _, _ = select.select([self.server.stdout], [], [], 10)
        if not ready or self.server.stdout.readline().strip() != b'ready':
            raise OSError('the echo control process did not start')

    def stop_server(self):
        if self.server is None:
            return
        self.server.terminate()
        try:
            self.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait()
        self.server.stdout.close()

    def one(self, kind, index, command, files):
        env = dict(os.environ, CHECKLIST_TIMING='1') if kind in CLI_KINDS else dict(os.environ)
        record = {'kind': kind, 'index': index, 'utc': datetime.now(timezone.utc).isoformat()}
        if index == 0:
            record['warmup'] = True
        try:
            record.update(self.launcher(command, env=env, timeout=self.args.call_timeout, capture=self.args.capture, files=files))
            stdout, stderr = record.pop('stdout'), record.pop('stderr').decode('utf-8', 'replace')
            record.update(stdout_bytes=len(stdout), stderr_bytes=len(stderr), stdout_text=stdout.decode('utf-8', 'replace'),
                          timing=prefixed_json(stderr, 'ChecklistTiming '))
            control = prefixed_json(stderr, 'ControlTiming ')
            record['control'] = control[0] if control else None
            error = validate(record)
            if error:
                record['validation_error'] = error
            else:
                record['phases'] = phases(record)
        except (OSError, ValueError, KeyError) as error:
            record.pop('stdout', None), record.pop('stderr', None), record.pop('stdout_text', None)
            record['validation_error'] = repr(error)
        self.records.append(record)
        with (self.output / 'calls.jsonl').open('a') as stream:
            stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + '\n')
        return record

    def run(self):
        if self.output.is_relative_to(Path(__file__).resolve().parents[1]):
            raise ValueError('Evidence output must be outside the source checkout')
        self.output.mkdir(parents=True, exist_ok=False)
        kinds = list(self.args.kinds)
        summary = {'ticket': 'CL-444', 'arguments': vars(self.args).copy(), 'issues': self.issues, 'kinds': {},
                   'cpu_count': os.cpu_count(), 'started_utc': datetime.now(timezone.utc).isoformat(),
                   'environment_policy': 'native identity inherited unchanged; CHECKLIST_TIMING=1 added for the CLI kinds'}
        files = []
        try:
            controls = self.args.controls and {name: str(Path(self.args.controls) / name) for name in ('control_c', 'control_swift')}
            if not controls and any(kind in kinds for kind in ('c_min', 'swift_min', 'c_echo', 'c_cpu')):
                controls = self.builder(self.output / 'controls')
            controls = controls or {'control_c': '', 'control_swift': ''}
            # The socket stays in the new evidence folder; nothing is deleted.
            socket_name = 'control.sock'
            if 'c_echo' in kinds:
                self.start_server(controls, socket_name)
            commands = self.commands(controls, socket_name)
            files = [os.open(self.output / name, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600) for name in ('capture.stdout', 'capture.stderr')]
            os.chdir(self.args.cwd)
            deadline = self.clock() + self.args.max_seconds
            # Round 0 starts each kind once and stays out of the summary: the
            # first start of a new binary includes its one-time system checks.
            for kind in kinds:
                self.one(kind, 0, commands[kind], files)
            for index in range(self.args.count):
                if self.clock() >= deadline:
                    self.issues.append(f'overall deadline reached after {index} of {self.args.count} rounds')
                    break
                # Rotate the order, so no kind always follows the same neighbour.
                for offset in range(len(kinds)):
                    kind = kinds[(index + offset) % len(kinds)]
                    self.one(kind, index + 1, commands[kind], files)
        except Exception as error:
            self.issues.append(repr(error))
        finally:
            self.stop_server()
            for descriptor in files:
                os.close(descriptor)
            for record in self.records:
                if record.get('validation_error'):
                    self.issues.append(f"{record['kind']} {record['index']}: {record['validation_error']}")
            summary.update(summarize(self.records, self.args.limit_seconds))
            summary.update(passed=not self.issues, record_count=len(self.records), finished_utc=datetime.now(timezone.utc).isoformat())
            (self.output / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + '\n')
            (self.output / 'summary.md').write_text(markdown(summary))
        return summary


def arguments(argv=None, minimum_count=50):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cli', help='absolute path of the checklist executable (needed for cli_call and cli_version)')
    parser.add_argument('--cwd', required=True, help="the caller's actual workspace; every process starts there")
    parser.add_argument('--output', required=True, help='new evidence folder outside the source checkout')
    parser.add_argument('--kinds', default=','.join(KINDS), help='comma list from: ' + ', '.join(KINDS))
    parser.add_argument('--controls', help='folder with control_c and control_swift built earlier; default: build in OUTPUT/controls')
    parser.add_argument('--control-cpu-ms', type=float, default=100, help='CPU time that c_cpu uses in main')
    parser.add_argument('--count', type=int, default=50, help='rounds; each round starts every kind once')
    parser.add_argument('--capture', choices=('file', 'pipe'), default='file')
    parser.add_argument('--limit-seconds', type=float, default=1, help='reported as "above limit"; not a failure')
    parser.add_argument('--call-timeout', type=float, default=15)
    parser.add_argument('--max-seconds', type=float, default=280)
    args = parser.parse_args(argv)
    args.kinds = [kind for kind in args.kinds.split(',') if kind]
    if not args.kinds or len(set(args.kinds)) != len(args.kinds) or any(kind not in KINDS for kind in args.kinds):
        parser.error('--kinds takes distinct names from: ' + ', '.join(KINDS))
    if any(kind in CLI_KINDS for kind in args.kinds) and not (args.cli and os.path.isabs(args.cli)):
        parser.error('--cli must be an absolute path for cli_call and cli_version')
    if args.count < minimum_count:
        parser.error(f'--count must be at least {minimum_count}')
    if not os.path.isdir(args.cwd):
        parser.error('--cwd must be an existing folder')
    args.cwd = os.path.abspath(args.cwd)
    for name in ('limit_seconds', 'call_timeout', 'max_seconds', 'control_cpu_ms'):
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
    print(markdown(summary))
    print(json.dumps({'passed': summary['passed'], 'issues': summary['issues'],
                      'summary': str(Path(args.output).resolve() / 'summary.json')}, sort_keys=True))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
