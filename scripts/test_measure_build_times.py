"""Exercise the measurement runner without Swift builds or timing claims."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import measure_build_times as measure


class MeasurementTests(unittest.TestCase):
    def setUp(self):
        # Fixture marker ownership must not inherit the caller scratch session.
        self.temporary = tempfile.TemporaryDirectory(dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        caller = patch.dict(os.environ, {'CODEX_THREAD_ID': 'measurement-session', 'CLAUDE_SESSION_ID': '', 'CHECKLIST_SESSION_ID': '',
                                         'CHECKLIST_TICKETS': ''})
        caller.start();self.addCleanup(caller.stop)
        self.tickets = ['CL-359']
        self.root = Path(self.temporary.name).resolve()
        self.checkout = self.root / 'checkout'
        self.output = self.root / 'evidence'
        self.core = 'Sources/ChecklistCore/Store.swift'
        self.app = 'Sources/ChecklistApp/App/ChecklistApp.swift'
        for relative in [self.core, self.app]:
            path = self.checkout / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('// original ' + relative + '\n')
        script = self.checkout / 'script';script.mkdir()
        (script / 'build_and_run.sh').write_text('python3 "$(dirname "$0")/fixture.py" "$1"\n')
        (script / 'fixture.py').write_text('''import hashlib,json,os,pathlib,sys
root=pathlib.Path(__file__).resolve().parents[1]
inputs={str(p.relative_to(root)):p.read_text() for p in (root/'Sources').rglob('*.swift')}
with (root/'calls.jsonl').open('a') as stream:stream.write(json.dumps({'mode':sys.argv[1],'scope':os.environ.get('CHECKLIST_BUILD_SCOPE'),'tickets':os.environ.get('CHECKLIST_TICKETS'),'inputs':inputs})+'\\n')
if os.environ.get('FAIL_ON_EDIT') and any('measurement' in text for text in inputs.values()):raise SystemExit(7)
capture=root/'.local/build/fixture';(capture/'Checklist.app').mkdir(parents=True,exist_ok=True)
receipt={'timing':{'phases':{'compile':{'status':'skipped' if os.environ.get('SKIP_COMPILE') else 'completed'}}},'source_sha256':{p:hashlib.sha256(text.encode()).hexdigest() for p,text in inputs.items()}}
(capture/'build-verification.json').write_text(json.dumps(receipt))
(capture/'capture-manifest.json').write_text(json.dumps({'source_fingerprint':'fixture','configuration':'release','toolchain':'fixture','signing_profile':'ad-hoc','build_scope':'install' if os.environ.get('WRONG_SCOPE') else os.environ.get('CHECKLIST_BUILD_SCOPE'),'installable':False}))
print('Staged '+str(capture/'Checklist.app'))
''')

    def run_measurement(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return measure.measure(self.checkout, self.output, 'after-fixture', self.core, self.app, 'b' * 64,
                                   tickets=self.tickets)

    def test_four_cases_three_runs_raw_logs_loads_medians_and_source_restoration(self):
        original = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in [self.checkout/self.core, self.checkout/self.app]}
        report = self.run_measurement()
        self.assertEqual(len(report['runs']), 12)
        self.assertEqual(set(report['medians_seconds']), set(measure.CASES))
        self.assertEqual(report['source_sha256'], report['restored_source_sha256'])
        calls = [json.loads(line) for line in (self.checkout/'calls.jsonl').read_text().splitlines()]
        self.assertEqual(len(calls), 24)  # 12 warmups, 12 measured runs.
        self.assertEqual(sum(c['mode']=='--clean-stage' for c in calls), 3)
        # CL-359: every measured stage build is registered with the run's tickets.
        self.assertEqual({c['tickets'] for c in calls}, {'CL-359'})
        for case in measure.CASES:
            runs = [r for r in report['runs'] if r['case']==case]
            self.assertEqual([r['repetition'] for r in runs], [1,2,3])
            for record in runs:
                self.assertEqual(len(record['load_start']), 3)
                self.assertEqual(len(record['load_end']), 3)
                self.assertTrue((self.output/record['log']).is_file())
                self.assertTrue((self.output/record['warmup']['log']).is_file())
        for call in calls:
            self.assertEqual(call['scope'], 'measurement')
            changed=[p for p,text in call['inputs'].items() if 'measurement' in text]
            self.assertLessEqual(len(changed), 1)
        for path,(data,mtime) in original.items():
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(path.stat().st_mtime_ns, mtime)
        self.assertFalse((self.checkout/'.local/build/.measurement-lock').exists())

    def test_root_is_marked_before_first_build_and_failure_keeps_protection(self):
        original = measure.stage
        def stage(*args, **kwargs):
            marker = json.loads((self.output / '.checklist-workspace.json').read_text())
            self.assertEqual(marker['session_id'], 'measurement-session')
            self.assertEqual(marker['tickets'], ['CL-359'])
            self.assertEqual(marker['source_fingerprint'], 'b' * 64)
            self.assertFalse(marker['released'])
            return original(*args, **kwargs)
        with patch.object(measure, 'stage', side_effect=stage), patch.dict(os.environ, SKIP_COMPILE='1'):
            with self.assertRaisesRegex(RuntimeError, 'without compiling'):
                self.run_measurement()
        self.assertTrue((self.output / '.checklist-workspace.json').is_file())

    def test_missing_tickets_refuse_before_any_output_or_build(self):
        self.tickets = None
        with self.assertRaisesRegex(ValueError, 'register the new folder'):
            self.run_measurement()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.checkout/'calls.jsonl').exists())
        with patch.dict(os.environ, CHECKLIST_TICKETS='CL-1,CL-2'), patch.object(measure, 'mark_qualification',
                side_effect=RuntimeError('stop after registration')) as mark:
            with self.assertRaisesRegex(RuntimeError, 'stop after registration'):
                self.run_measurement()
        self.assertEqual(mark.call_args.kwargs['tickets'], ['CL-1', 'CL-2'])

    def test_invalid_owner_or_fingerprint_cannot_create_an_unmarked_output(self):
        with patch.dict(os.environ, {'CODEX_THREAD_ID': '', 'CLAUDE_SESSION_ID': '', 'CHECKLIST_SESSION_ID': ''}):
            with self.assertRaisesRegex(ValueError, 'session unknown'):
                self.run_measurement()
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            measure.measure(self.checkout, self.output, 'invalid', self.core, self.app, 'short')
        self.assertFalse(self.output.exists())

    def test_failure_retains_logs_and_restores_edited_source(self):
        with patch.dict(os.environ, FAIL_ON_EDIT='1'), self.assertRaisesRegex(RuntimeError, 'Build failed'):
            self.run_measurement()
        report = json.loads((self.output/'results.json').read_text())
        self.assertEqual(report['source_sha256'], report['restored_source_sha256'])
        self.assertNotIn('medians_seconds', report)
        self.assertTrue((self.output/'core-change-1.log').is_file())
        self.assertFalse((self.checkout/'.local/build/.measurement-lock').exists())

    def test_measurement_overrides_inherited_install_scope_and_rejects_wrong_receipt(self):
        with patch.dict(os.environ, CHECKLIST_BUILD_SCOPE='install', WRONG_SCOPE='1'):
            with self.assertRaisesRegex(RuntimeError, 'measurement-scope'):
                self.run_measurement()
        calls = [json.loads(line) for line in (self.checkout / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(calls[0]['scope'], 'measurement')

    def test_cached_stage_is_not_a_compile_measurement(self):
        with patch.dict(os.environ, SKIP_COMPILE='1'), self.assertRaisesRegex(RuntimeError, 'without compiling'):
            self.run_measurement()

    def test_existing_evidence_build_lock_and_outside_source_are_refused(self):
        self.output.mkdir();(self.output/'earlier.log').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'empty output'):
            self.run_measurement()
        (self.output/'earlier.log').unlink()
        lock=self.checkout/'.local/build/.build-lock';lock.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'already owns'):
            self.run_measurement()
        lock.rmdir()
        with self.assertRaisesRegex(ValueError, 'regular Swift'):
            measure.measure(self.checkout,self.output,'invalid','../outside.swift',self.app, 'b' * 64)


if __name__ == '__main__':
    unittest.main()
