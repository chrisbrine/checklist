"""Timing-guard behavior using synthetic output and fake commands, never Swift."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import check_test_timings as guard


def serial(cases=(('testFast', 0.25, 'passed'),), total=0.25, finish=True):
    lines = ["Test Suite 'ChecklistCoreTests.xctest' started at 2026-10-29 00:00:00.000."]
    for name, duration, status in cases:
        lines.extend([f"Test Case '-[ChecklistCoreTests.FixtureTests {name}]' started.",
                      f"Test Case '-[ChecklistCoreTests.FixtureTests {name}]' {status} ({duration:.3f} seconds)."])
    if finish:
        lines.extend(["Test Suite 'ChecklistCoreTests.xctest' passed at 2026-10-29 00:00:01.000.",
                      f'\t Executed {len(cases)} tests, with 0 failures (0 unexpected) in {total:.3f} ({total:.3f}) seconds'])
    return '\n'.join(lines) + '\n'


class TimingGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def assess(self, text, **options):
        return guard.assess(*guard.parse_log(text), **options)

    def xml(self, cases, *, count=None):
        path = self.root / 'results.xml'
        count = len(cases) if count is None else count
        path.write_text(f'<testsuites><testsuite name="Tests" tests="{count}">' +
                        ''.join(f'<testcase classname="ChecklistCoreTests.FixtureTests" '
                                f'name="{name}" time="{duration}">{child}</testcase>'
                                for name, duration, child in cases) + '</testsuite></testsuites>')
        return path

    def test_complete_serial_pass_has_case_class_and_target_time(self):
        result = self.assess(serial())
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['class_seconds'], {'ChecklistCoreTests.FixtureTests': 0.25})
        self.assertEqual(result['test_count'], 1)
        self.assertEqual(result['elapsed_seconds'], 0.25)
        self.assertIn('excludes build/startup', result['elapsed_source'])

    def test_slow_default_names_case_and_remediation(self):
        result = self.assess(serial((('testScale', 5.1, 'passed'),)), elapsed=6)
        self.assertEqual(result['slow_tests'][0]['id'], 'ChecklistCoreTests.FixtureTests/testScale')
        self.assertIn('qualification', result['warnings'][0])
        self.assertIn('5.100s > 1.000s', result['warnings'][0])

    def test_one_second_is_not_over_threshold_and_skips_do_not_warn(self):
        result = self.assess(serial((('testBoundary', 1.0, 'passed'), ('testSkip', 40, 'skipped'))))
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['executed_count'], 1)
        self.assertEqual(result['skipped_count'], 1)

    def test_qualification_retains_durations_but_does_not_apply_default_limits(self):
        result = self.assess(serial((('testScale', 200, 'passed'),), total=200), qualification=True)
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['mode'], 'qualification')
        self.assertEqual(result['slow_tests'], [])
        self.assertIsNone(result['budget_seconds'])
        self.assertIsNone(result['per_test_budget_seconds'])
        self.assertEqual(result['tests'][0]['seconds'], 200)

    def test_core_default_budget_is_180_and_boundary_is_inclusive(self):
        self.assertEqual(self.assess(serial(total=180))['status'], 'pass')
        result = self.assess(serial(total=180.001))
        self.assertEqual(result['budget_seconds'], 180)
        self.assertIn('Default run: 180.001s > 180.000s', result['warnings'][0])

    def test_explicit_wall_measurement_includes_overhead_and_overrides_serial_summary(self):
        result = self.assess(serial(total=0.25), elapsed=181)
        self.assertEqual(result['elapsed_seconds'], 181)
        self.assertEqual(result['elapsed_source'], 'measured command wall time')
        self.assertIn('Default run:', result['warnings'][0])

    def test_noncore_only_applies_total_budget_when_explicit(self):
        text = serial().replace('ChecklistCoreTests', 'ChecklistAppTests')
        self.assertEqual(self.assess(text, elapsed=200)['status'], 'pass')
        self.assertIn('Default run:', self.assess(text, elapsed=61, budget=60)['warnings'][0])

    def test_parallel_durations_are_never_summed_as_wall_time(self):
        path = self.xml([('testOne', 0.8, ''), ('testTwo', 0.8, '')])
        tests, summaries, problems = guard.parse_xunit(path)
        result = guard.assess(tests, summaries, problems, elapsed=0.9, budget=1)
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['class_seconds']['ChecklistCoreTests.FixtureTests'], 1.6)
        self.assertEqual(result['elapsed_seconds'], 0.9)
        unmeasured = guard.assess(tests, summaries, problems)
        self.assertIn('Missing measured wall time', unmeasured['warnings'][0])

    def test_parallel_xunit_without_skip_metadata_retains_invocations_with_unknown_counts(self):
        path = self.xml([('testUnit', 0.1, ''), ('testGated', 0.1, '')])
        result = guard.assess(*guard.parse_xunit(path), elapsed=0.2)
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['warnings'], [])
        self.assertEqual(result['invocation_count'], 2)
        self.assertIsNone(result['executed_count'])
        self.assertIsNone(result['skipped_count'])
        self.assertEqual(result['unknown_execution_count'], 2)
        self.assertEqual(result['known_executed_count'], 0)
        self.assertEqual({test['status'] for test in result['tests']}, {'reported'})
        self.assertEqual({test['duration_kind'] for test in result['tests']}, {'xUnit runner/process elapsed'})
        self.assertIn('unknown execution/skip', result['limitations'][0])
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            guard.report(result)
        self.assertIn('execution/skip counts unknown', output.getvalue())
        self.assertIn('TEST TIMING GUARD LIMITATION', errors.getvalue())

    def test_xunit_explicit_zero_skips_attests_executed_count(self):
        path = self.xml([('testUnit', 0.1, '')])
        path.write_text(path.read_text().replace('tests="1"', 'tests="1" skipped="0"'))
        result = guard.assess(*guard.parse_xunit(path), elapsed=0.1)
        self.assertEqual(result['executed_count'], 1)
        self.assertEqual(result['skipped_count'], 0)
        self.assertEqual(result['unknown_execution_count'], 0)
        self.assertEqual(result['limitations'], [])

    def test_unknown_xunit_duration_warning_does_not_claim_method_execution_or_failure(self):
        path = self.xml([('testGated', 1.5, '')])
        result = guard.assess(*guard.parse_xunit(path), elapsed=2)
        self.assertIn('runner/process duration', result['warnings'][0])
        self.assertIn('execution/skip status is unknown', result['warnings'][0])
        self.assertFalse(any('Failed XCTest' in warning for warning in result['warnings']))

    def test_xunit_nonzero_aggregate_failures_and_errors_cannot_pass_without_case_markers(self):
        for tag in ('testsuite', 'testsuites'):
            for key in ('failures', 'errors'):
                with self.subTest(tag=tag, key=key):
                    path = self.xml([('testUnit', 0.1, '')])
                    text = path.read_text()
                    opening = '<testsuites>' if tag == 'testsuites' else '<testsuite '
                    replacement = '<testsuites ' + key + '="1">' if tag == 'testsuites' else '<testsuite ' + key + '="1" '
                    text = text.replace(opening, replacement, 1)
                    path.write_text(text)
                    result = guard.assess(*guard.parse_xunit(path), elapsed=0.1)
                    self.assertEqual(result['status'], 'warning')
                    self.assertTrue(any('xUnit reports 1 ' + key in warning for warning in result['warnings']))
                    self.assertTrue(any(key + ' count mismatch' in warning for warning in result['warnings']))

    def test_xunit_aggregate_counts_require_nonnegative_integers_at_each_container(self):
        for tag in ('testsuite', 'testsuites'):
            for key in ('tests', 'failures', 'errors', 'skipped'):
                for value in ('-1', '1.5', 'invalid'):
                    with self.subTest(tag=tag, key=key, value=value):
                        path = self.xml([('testUnit', 0.1, '')])
                        text = path.read_text()
                        if tag == 'testsuite' and key == 'tests':
                            text = text.replace('tests="1"', f'tests="{value}"')
                        else:
                            text = text.replace('<' + tag + '>', '<' + tag + f' {key}="{value}">', 1) if tag == 'testsuites' else text.replace('<testsuite ', f'<testsuite {key}="{value}" ', 1)
                        path.write_text(text)
                        result = guard.assess(*guard.parse_xunit(path), elapsed=0.1)
                        self.assertEqual(result['status'], 'warning')
                        self.assertTrue(any('nonnegative integer' in warning for warning in result['warnings']))

    def test_xunit_root_total_and_zero_metadata_contradictions_are_not_ignored(self):
        path = self.xml([('testFail', 0.1, '<failure/>')])
        path.write_text(path.read_text().replace('<testsuites>', '<testsuites tests="2" failures="0">'))
        result = guard.assess(*guard.parse_xunit(path), elapsed=0.1)
        self.assertTrue(any('suite count mismatch: testsuites' in warning for warning in result['warnings']))
        self.assertTrue(any('failures count mismatch: testsuites' in warning for warning in result['warnings']))
        self.assertEqual(result['tests'][0]['status'], 'failed')

    def test_xunit_failure_dominates_contradictory_skip_marker(self):
        for marker in ('failure', 'error'):
            with self.subTest(marker=marker):
                path = self.xml([('testFail', 0.1, f'<skipped/><{marker}/>')])
                result = guard.assess(*guard.parse_xunit(path), elapsed=0.1)
                self.assertEqual(result['tests'][0]['status'], 'failed')
                self.assertEqual(result['executed_count'], 1)
                self.assertEqual(result['skipped_count'], 0)
                self.assertTrue(any('contradictory skip/failure' in warning for warning in result['warnings']))

    def test_serial_suite_and_summary_failure_cannot_pass_with_passing_cases(self):
        variants = [serial().replace("ChecklistCoreTests.xctest' passed", "ChecklistCoreTests.xctest' failed"),
                    serial().replace('with 0 failures', 'with 1 failure'),
                    serial().replace('with 0 failures', 'with 1 test skipped and 1 failure'),
                    serial() + "Test Suite 'FixtureTests' failed at now.\n"]
        for text in variants:
            with self.subTest(text=text):
                result = self.assess(text)
                self.assertEqual(result['status'], 'warning')
                self.assertTrue(any('XCTest suite failed' in warning or 'summary reports 1 failures' in warning
                                    for warning in result['warnings']))

    def test_xunit_full_case_name_is_not_duplicated(self):
        path = self.xml([('ChecklistCoreTests.FixtureTests/testOne', 0.1, '')])
        result = guard.parse_xunit(path)
        self.assertEqual(result[0][0]['id'], 'ChecklistCoreTests.FixtureTests/testOne')
        self.assertEqual(result[2], [])

    def test_xunit_skipped_and_failed_states_are_not_passes(self):
        path = self.xml([('testSkip', 5, '<skipped/>'), ('testFail', 0.1, '<failure message="bad"/>')])
        result = guard.assess(*guard.parse_xunit(path), elapsed=1)
        self.assertEqual(result['slow_tests'], [])
        self.assertEqual(result['skipped_count'], 1)
        self.assertIn('Failed XCTest cases', result['warnings'][0])

    def test_incomplete_serial_run_does_not_pass_from_previous_empty_bundles(self):
        empty = "Test Suite 'OtherTests.xctest' passed at now.\n Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n"
        result = self.assess(empty + serial(finish=False))
        self.assertIn('No completed target summary: ChecklistCoreTests', result['warnings'])
        unfinished = self.assess(serial() + "Test Case '-[ChecklistCoreTests.FixtureTests testNeverEnded]' started.\n")
        self.assertIn('No terminal result: ChecklistCoreTests.FixtureTests/testNeverEnded', unfinished['warnings'])

    def test_summary_count_mismatch_and_duplicate_test_are_flagged(self):
        result = self.assess(serial().replace('Executed 1 tests', 'Executed 2 tests'))
        self.assertTrue(any('Target count mismatch' in warning for warning in result['warnings']))
        result = self.assess(serial() + serial())
        self.assertTrue(any('Repeated test:' in warning for warning in result['warnings']))

    def test_result_without_start_is_incomplete(self):
        result = self.assess(serial().replace("Test Case '-[ChecklistCoreTests.FixtureTests testFast]' started.\n", ''))
        self.assertTrue(any('Result without start' in warning for warning in result['warnings']))

    def test_parallel_progress_only_log_requires_xunit_not_false_pass(self):
        result = self.assess('[1/1] Testing ChecklistCoreTests.FixtureTests/testOne\n')
        self.assertIn('parallel runs require xUnit XML', result['warnings'][0])

    def test_invalid_xunit_missing_time_count_mismatch_and_nonfinite_duration(self):
        path = self.xml([('testOne', 'nan', '')])
        self.assertIn('Incomplete/invalid xUnit', guard.parse_xunit(path)[2][0])
        path = self.xml([('testOne', 0.1, '')], count=2)
        self.assertIn('xUnit suite count mismatch', guard.parse_xunit(path)[2][0])
        path.write_text('<testsuites>')
        self.assertIn('Incomplete/invalid xUnit', guard.parse_xunit(path)[2][0])
        path.write_text('<testsuites><testsuite><testcase name="ChecklistCoreTests.FixtureTests/testOne"/></testsuite></testsuites>')
        self.assertIn('Incomplete/invalid xUnit', guard.parse_xunit(path)[2][0])

    def test_all_skipped_run_is_not_a_timing_pass(self):
        result = self.assess(serial((('testUnavailable', 0, 'skipped'),)))
        self.assertEqual(result['executed_count'], 0)
        self.assertIn('No executed XCTest cases; timing limits are unverified', result['warnings'])

    def test_no_tests_and_nonzero_command_are_unverified_even_in_qualification(self):
        result = guard.assess([], {}, ['No XCTest case durations'], qualification=True, returncode=7)
        self.assertEqual(result['status'], 'warning')
        self.assertIn('Command exited 7', result['warnings'][1])

    def command(self, text=None, exitcode=0, fake_swift=False, emit_xunit=True):
        executable = self.root / ('swift' if fake_swift else 'fake-test')
        code = ('#!' + sys.executable + '\nimport pathlib,sys\n' +
                ('pathlib.Path(sys.argv[sys.argv.index("--xunit-output")+1]).write_text(' +
                 repr('<testsuites><testsuite tests="1"><testcase classname="ChecklistCoreTests.FixtureTests" name="testSlow" time="1.1"/></testsuite></testsuites>') + ')\n'
                 if fake_swift and emit_xunit else '') +
                'print(' + repr(serial() if text is None else text) + ')\n' +
                f'sys.exit({exitcode})\n')
        executable.write_text(code)
        executable.chmod(0o755)
        return [str(executable), 'test'] if fake_swift else [str(executable)]

    def run_guard(self, command, *, strict=False, log=None):
        log = log or self.root / 'command.log'
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = guard.main(['run', '--log', str(log)] + (['--strict'] if strict else []) + ['--'] + command)
        return status, json.loads(log.with_suffix('.log.json').read_text())

    def test_wrapper_preserves_failure_and_captures_load_wall_command_hash_and_raw_log(self):
        command = self.command(exitcode=7)
        status, receipt = self.run_guard(command)
        self.assertEqual(status, 7)
        self.assertEqual(receipt['command'], command)
        self.assertEqual(len(receipt['load_start']), 3)
        self.assertEqual(len(receipt['load_end']), 3)
        self.assertGreater(receipt['elapsed_seconds'], 0)
        self.assertEqual(len(receipt['log_sha256']), 64)
        self.assertIn("Test Case '-[ChecklistCoreTests", (self.root / 'command.log').read_text())

    def test_wrapper_warns_by_default_strict_fails_and_retains_repeated_logs(self):
        command = self.command(serial((('testSlow', 1.1, 'passed'),)))
        status, receipt = self.run_guard(command)
        self.assertEqual(status, 0)
        self.assertEqual(receipt['status'], 'warning')
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = guard.main(['run', '--log', str(self.root / 'command.log'), '--strict', '--'] + command)
        self.assertEqual(status, 1)
        self.assertTrue((self.root / 'command-1.log.json').is_file())
        self.assertEqual((self.root / 'command.log').read_text(), (self.root / 'command-1.log').read_text())

    def test_swift_wrapper_requests_xunit_and_uses_its_parallel_case_time(self):
        status, receipt = self.run_guard(self.command('[1/1] Testing Fixture/testSlow', fake_swift=True))
        self.assertEqual(status, 0)
        self.assertIn('--xunit-output', receipt['command'])
        self.assertTrue(Path(receipt['xunit']).is_file())
        self.assertEqual(receipt['tests'][0]['seconds'], 1.1)
        self.assertEqual(receipt['slow_tests'][0]['id'], 'ChecklistCoreTests.FixtureTests/testSlow')

    def test_serial_backend_without_xml_uses_complete_native_log_and_preserves_skip(self):
        text = serial(tuple((f'testCase{number}', 0.02, 'skipped' if number == 5 else 'passed')
                            for number in range(6)), total=0.12)
        status, receipt = self.run_guard(self.command(text, fake_swift=True, emit_xunit=False), strict=True)
        self.assertEqual(status, 0)
        self.assertEqual(receipt['status'], 'pass')
        self.assertEqual(receipt['test_count'], 6)
        self.assertEqual(receipt['executed_count'], 5)
        self.assertEqual(receipt['skipped_count'], 1)
        self.assertEqual(receipt['duration_source'], 'serial-log (xUnit unavailable)')
        self.assertFalse(Path(receipt['xunit']).exists())

    def test_backend_without_xml_never_passes_parallel_progress_only_output(self):
        command = self.command('[1/1] Testing ChecklistCoreTests.FixtureTests/testOne',
                               fake_swift=True, emit_xunit=False) + ['--parallel']
        status, receipt = self.run_guard(command, strict=True)
        self.assertEqual(status, 1)
        self.assertEqual(receipt['executed_count'], 0)
        self.assertTrue(any('Incomplete/invalid xUnit' in warning for warning in receipt['warnings']))

    def test_backend_without_xml_never_passes_incomplete_serial_output(self):
        status, receipt = self.run_guard(self.command(serial(finish=False), fake_swift=True,
                                                     emit_xunit=False), strict=True)
        self.assertEqual(status, 1)
        self.assertTrue(any('No completed target summary' in warning for warning in receipt['warnings']))

    def test_malformed_xml_is_not_replaced_by_complete_serial_log(self):
        command = self.command(serial(), fake_swift=True)
        executable = Path(command[0])
        executable.write_text(executable.read_text().replace(
            repr('<testsuites><testsuite tests="1"><testcase classname="ChecklistCoreTests.FixtureTests" name="testSlow" time="1.1"/></testsuite></testsuites>'),
            repr('<testsuites>')))
        status, receipt = self.run_guard(command, strict=True)
        self.assertEqual(status, 1)
        self.assertEqual(receipt['duration_source'], 'xunit')
        self.assertTrue(any('Incomplete/invalid xUnit' in warning for warning in receipt['warnings']))

    def test_existing_xunit_is_refused_before_command_without_touching_it(self):
        path = self.xml([('testOld', 0.1, '')])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            guard.main(['run', '--log', str(self.root / 'refused.log'), '--'] +
                       self.command(fake_swift=True) + ['--xunit-output', str(path)])
        self.assertEqual(error.exception.code, 2)
        self.assertIn('testOld', path.read_text())

    def test_check_cli_is_strict_only_on_request_and_emits_json(self):
        log = self.root / 'existing.log'
        log.write_text(serial((('testSlow', 1.01, 'passed'),)))
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(guard.main(['check', '--log', str(log), '--json']), 0)
        self.assertEqual(json.loads(output.getvalue())['status'], 'warning')
        self.assertIn('DEFAULT TEST TIMING GUARD: WARNING', errors.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(guard.main(['check', '--log', str(log), '--strict']), 1)


if __name__ == '__main__':
    unittest.main()
