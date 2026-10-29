#!/usr/bin/env python3
"""Guard default XCTest timings in round/hand-in commands; retain raw evidence.

`run --log PATH -- COMMAND ...` tees the command and writes PATH.json. SwiftPM
parallel output omits durations, so the wrapper also requests xUnit XML. When a
serial backend omits XML, a complete serial XCTest log supplies durations. `check`
can inspect an existing serial log or xUnit file, with independently measured
--elapsed seconds. Threshold breaches warn loudly unless --strict is supplied;
an incomplete run is never reported as a timing pass. Qualification is explicit.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

CASE = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (started\.|(passed|failed|skipped) \(([\d.]+) seconds\)\.)")
SUITE_END = re.compile(r"Test Suite '([^']+\.xctest)' (?:passed|failed) at ")
SUMMARY = re.compile(r'Executed (\d+) tests?, with .* in ([\d.]+) \(([\d.]+)\) seconds')
SUITE_FAILED = re.compile(r"Test Suite '([^']+)' failed at ")
FAILURE_SUMMARY = re.compile(r'Executed \d+ tests?, with (?:\d+ tests? skipped and )?(\d+) failures?')


def seconds(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError('duration must be finite and nonnegative')
    return result


def parse_log(text):
    """Parse serial XCTest output, rejecting truncated/duplicated case results."""
    tests, pending, problems = [], set(), []
    seen = set()
    ended, summaries, awaiting_summary = set(), {}, None
    for line in text.splitlines():
        failure = SUITE_FAILED.search(line)
        if failure:
            problems.append('XCTest suite failed: ' + failure[1])
        failure = FAILURE_SUMMARY.search(line)
        if failure and int(failure[1]):
            problems.append('XCTest summary reports ' + failure[1] + ' failures')
        match = CASE.search(line)
        if match:
            identifier = match[1] + '/' + match[2]
            if match[3] == 'started.':
                if identifier in pending or identifier in seen:
                    problems.append('Repeated test: ' + identifier)
                pending.add(identifier)
            else:
                if identifier not in pending:
                    problems.append('Result without start: ' + identifier)
                pending.discard(identifier)
                seen.add(identifier)
                tests.append({'id': identifier, 'seconds': seconds(match[5]), 'status': match[4],
                              'duration_kind': 'native XCTest method elapsed'})
        match = SUITE_END.search(line)
        if match:
            awaiting_summary = match[1].removesuffix('.xctest')
            ended.add(awaiting_summary)
        elif awaiting_summary:
            match = SUMMARY.search(line)
            if match:
                summaries[awaiting_summary] = {'count': int(match[1]), 'seconds': seconds(match[3])}
                awaiting_summary = None
    problems.extend('No terminal result: ' + identifier for identifier in sorted(pending))
    targets = {test['id'].split('.')[0] for test in tests}
    for target in sorted(targets):
        actual = sum(test['id'].split('.')[0] == target for test in tests)
        if target not in ended or target not in summaries:
            problems.append('No completed target summary: ' + target)
        elif summaries[target]['count'] != actual:
            problems.append(f'Target count mismatch: {target} summary={summaries[target]["count"]} cases={actual}')
    if not tests:
        problems.append('No XCTest case durations; parallel runs require xUnit XML')
    return tests, summaries, problems


def parse_xunit(path):
    """Use SwiftPM's completed XML rather than summing overlapping worker times."""
    tests, problems = [], []
    try:
        root = ET.parse(path).getroot()
        if root.tag not in ('testsuite', 'testsuites'):
            raise ValueError('expected testsuite/testsuites root')
        skip_attested = set()
        for suite in (node for node in root.iter() if node.tag in ('testsuite', 'testsuites')):
            cases = suite.findall('.//testcase')
            name = suite.get('name', suite.tag)
            counts = {}
            for key in ('tests', 'failures', 'errors', 'skipped'):
                if key not in suite.attrib:
                    continue
                value = suite.attrib[key]
                if not re.fullmatch(r'[0-9]+', value):
                    raise ValueError(f'xUnit {key} must be a nonnegative integer: {name}')
                counts[key] = int(value)
            if 'tests' in counts and counts['tests'] != len(cases):
                problems.append('xUnit suite count mismatch: ' + name)
            for key, marker in (('failures', 'failure'), ('errors', 'error'), ('skipped', 'skipped')):
                if key not in counts:
                    continue
                markers = sum(case.find(marker) is not None for case in cases)
                if key in ('failures', 'errors') and counts[key]:
                    problems.append(f'xUnit reports {counts[key]} {key}: {name}')
                if counts[key] != markers:
                    problems.append(f'xUnit {key} count mismatch: {name}')
                elif key == 'skipped':
                    skip_attested.update(id(case) for case in cases)
        for case in root.iter('testcase'):
            name, owner = case.get('name', ''), case.get('classname', '')
            identifier = owner + '/' + name if owner else name
            # SwiftPM names a case Target.Class/testMethod on some toolchains.
            if '/' in name and (not owner or name.startswith(owner + '/')):
                identifier = name
            if not identifier or '.' not in identifier or '/' not in identifier:
                raise ValueError('xUnit case lacks target/class/method identity')
            failed = case.find('failure') is not None or case.find('error') is not None
            skipped = case.find('skipped') is not None
            if failed and skipped:
                problems.append('xUnit contradictory skip/failure markers: ' + identifier)
            status = ('failed' if failed else 'skipped' if skipped else
                      'passed' if id(case) in skip_attested else 'reported')
            tests.append({'id': identifier, 'seconds': seconds(case.attrib['time']), 'status': status,
                          'duration_kind': 'xUnit runner/process elapsed'})
        if not tests:
            problems.append('No XCTest case durations in xUnit XML')
        if len({test['id'] for test in tests}) != len(tests):
            problems.append('Repeated xUnit test identifiers')
    except (OSError, ET.ParseError, KeyError, ValueError) as error:
        problems.append('Incomplete/invalid xUnit XML: ' + str(error))
    return tests, {}, problems


def assess(tests, summaries, problems, *, elapsed=None, per_test=1.0,
           core_budget=180.0, budget=None, qualification=False, returncode=0):
    """Keep per-method CPU/elapsed samples separate from complete-run wall time."""
    warnings = list(problems)
    if returncode:
        warnings.append(f'Command exited {returncode}; timing evidence is not a passing test run')
    executed = [test for test in tests if test['status'] in ('passed', 'failed')]
    reported = [test for test in tests if test['status'] == 'reported']
    timed = executed + reported
    skipped_count = sum(test['status'] == 'skipped' for test in tests)
    limitations = []
    if reported:
        limitations.append('xUnit omits skip metadata: ' + str(len(reported)) +
                           ' invocation(s) have unknown execution/skip status. Durations are '
                           'runner/process elapsed time, not attested method execution time.')
    if not timed:
        warnings.append('No executed XCTest cases; timing limits are unverified')
    slow = [] if qualification else sorted((test for test in timed if test['seconds'] > per_test),
                                           key=lambda test: (-test['seconds'], test['id']))
    for test in slow:
        if test['status'] == 'reported':
            warnings.append(f'{test["id"]}: runner/process duration {test["seconds"]:.3f}s > '
                            f'{per_test:.3f}s; inspect process startup and fixture/setup cost; '
                            'execution/skip status is unknown')
            continue
        warnings.append(f'{test["id"]}: {test["seconds"]:.3f}s > {per_test:.3f}s; '
                        'move size/time measurement to qualification, or fix its unit fixture/setup')
    core = any(test['id'].startswith('ChecklistCoreTests.') for test in timed)
    limit = None if qualification else budget if budget is not None else core_budget if core else None
    # The serial Core target summary is valid without external wall metadata;
    # parallel XML durations overlap and must never be summed for a run budget.
    wall = elapsed
    wall_source = 'measured command wall time' if elapsed is not None else None
    if wall is None and core and 'ChecklistCoreTests' in summaries:
        wall = summaries['ChecklistCoreTests']['seconds']
        wall_source = 'serial ChecklistCoreTests target summary (excludes build/startup)'
    if limit is not None:
        if wall is None:
            warnings.append('Missing measured wall time; default run budget is unverified')
        elif wall > limit:
            warnings.append(f'Default run: {wall:.3f}s > {limit:.3f}s ({wall_source}); '
                            'inspect the named slow tests and fixture/setup cost')
    if any(test['status'] == 'failed' for test in tests):
        warnings.append('Failed XCTest cases present; timing evidence is not a passing test run')
    by_class = {}
    for test in timed:
        group = test['id'].split('/')[0]
        by_class.setdefault(group, []).append(test['seconds'])
    return {'mode': 'qualification' if qualification else 'default',
            'status': 'warning' if warnings else 'pass', 'warnings': warnings, 'limitations': limitations,
            'test_count': len(tests), 'invocation_count': len(tests),
            'executed_count': None if reported else len(executed),
            'skipped_count': None if reported else skipped_count,
            'known_executed_count': len(executed), 'known_skipped_count': skipped_count,
            'unknown_execution_count': len(reported), 'slow_tests': slow,
            'elapsed_seconds': wall, 'elapsed_source': wall_source, 'budget_seconds': limit,
            'per_test_budget_seconds': None if qualification else per_test,
            'class_seconds': {group: sum(values) for group, values in sorted(by_class.items())},
            'class_seconds_basis': 'sum of reported invocation durations; not class wall time',
            'tests': tests}


def report(result):
    for limitation in result['limitations']:
        print(f'*** TEST TIMING GUARD LIMITATION: {limitation}', file=sys.stderr)
    if result['warnings']:
        print(f'\n*** {result["mode"].upper()} TEST TIMING GUARD: WARNING ***', file=sys.stderr)
        for warning in result['warnings']:
            print('  ' + warning, file=sys.stderr)
    else:
        counts = (f'{result["invocation_count"]} invocations; execution/skip counts unknown'
                  if result['unknown_execution_count'] else
                  f'{result["executed_count"]} executed, {result["skipped_count"]} skipped')
        print(f'Test timing guard: {result["mode"]} pass ({counts}).')


def unique_log(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    candidate, suffix = path, 0
    while True:
        try:
            return candidate, candidate.open('x')
        except FileExistsError:
            suffix += 1
            candidate = path.with_name(path.stem + f'-{suffix}' + path.suffix)


def run(args):
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise ValueError('run requires a command after --')
    log, stream = unique_log(args.log)
    xunit = None
    # Prefixes such as env and build-slot wrappers do not prevent recognizing
    # SwiftPM. Do not inject an argument into a non-Swift command.
    swift = next((index for index in range(len(command) - 1)
                  if Path(command[index]).name == 'swift' and command[index + 1] == 'test'), None)
    if swift is not None:
        if '--xunit-output' in command:
            xunit = Path(command[command.index('--xunit-output') + 1])
            # A stale caller-owned XML file cannot qualify this run.
            if xunit.exists():
                stream.close()
                raise ValueError('xUnit output already exists; choose a fresh path: ' + str(xunit))
        else:
            xunit = log.with_suffix(log.suffix + '.xml')
            command = command + ['--xunit-output', str(xunit)]
    started_at = datetime.now(timezone.utc).isoformat()
    load_start = list(os.getloadavg())
    started = time.monotonic()
    returncode = 127
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors='replace', bufsize=1)
        try:
            for line in process.stdout:
                stream.write(line)
                stream.flush()
                print(line, end='', flush=True)
            returncode = process.wait()
        except BaseException:
            process.terminate()
            process.wait()
            raise
    except OSError as error:
        stream.write(str(error) + '\n')
        print(error, file=sys.stderr)
    finally:
        elapsed = time.monotonic() - started
        load_end = list(os.getloadavg())
        stream.close()
    text = log.read_text()
    duration_source = 'xunit' if xunit is not None else 'serial-log'
    tests, summaries, problems = parse_xunit(xunit) if xunit is not None else parse_log(text)
    parallel = False
    for argument in command[swift + 2:] if swift is not None else ():
        if argument in ('--parallel', '--no-parallel'):
            parallel = argument == '--parallel'
    # Some SwiftPM backends accept --xunit-output but omit XML for serial runs.
    # Only a complete native serial transcript may replace that missing file;
    # malformed XML or parallel progress output must remain unverified.
    if xunit is not None and not xunit.exists() and not parallel:
        serial_tests, serial_summaries, serial_problems = parse_log(text)
        if serial_tests and not serial_problems:
            tests, summaries, problems = serial_tests, serial_summaries, []
            duration_source = 'serial-log (xUnit unavailable)'
        else:
            problems.extend(serial_problems)
    result = assess(tests, summaries, problems, elapsed=elapsed, per_test=args.per_test,
                    core_budget=args.core_budget, budget=args.budget,
                    qualification=args.qualification, returncode=returncode)
    result.update(command=command, started_at=started_at, load_start=load_start, load_end=load_end,
                  returncode=returncode, log=str(log), log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
                  xunit=str(xunit) if xunit is not None else None, duration_source=duration_source)
    log.with_suffix(log.suffix + '.json').write_text(json.dumps(result, indent=2) + '\n')
    report(result)
    # A warning never hides an original command failure.
    return returncode if returncode else 1 if args.strict and result['warnings'] else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='action', required=True)
    for action in ('run', 'check'):
        sub = subcommands.add_parser(action)
        sub.add_argument('--log', type=Path, required=action == 'run')
        sub.add_argument('--per-test', type=seconds, default=1.0)
        sub.add_argument('--core-budget', type=seconds, default=180.0)
        sub.add_argument('--budget', type=seconds, help='explicit total command wall budget')
        sub.add_argument('--qualification', action='store_true', help='opt-in run; omit default thresholds')
        sub.add_argument('--strict', action='store_true', help='fail on timing warnings')
        if action == 'run':
            sub.add_argument('command', nargs=argparse.REMAINDER)
        else:
            sub.add_argument('--xunit', type=Path)
            sub.add_argument('--elapsed', type=seconds, help='measured command wall time, never sum of worker times')
            sub.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.action == 'run':
            return run(args)
        if args.xunit:
            tests, summaries, problems = parse_xunit(args.xunit)
        elif args.log:
            tests, summaries, problems = parse_log(args.log.read_text())
        else:
            parser.error('check requires --log or --xunit')
        result = assess(tests, summaries, problems, elapsed=args.elapsed,
                        per_test=args.per_test, core_budget=args.core_budget,
                        budget=args.budget, qualification=args.qualification)
        report(result)
        if args.json:
            print(json.dumps(result, indent=2))
        return 1 if args.strict and result['warnings'] else 0
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
