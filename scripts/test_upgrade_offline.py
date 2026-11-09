"""Installer qualification checks; never launch a real app or stop a service."""
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import upgrade_offline


class UpgradeOfflineTests(unittest.TestCase):
    def fixture(self, base):
        service = base / 'service';service.write_bytes(b'exact staged service')
        capture = base / 'capture';capture.mkdir()
        (capture / 'capture-manifest.json').write_text(json.dumps({'source_fingerprint': 'fingerprint'}))
        preparation = {'needs_upgrade': True, 'prepared': True, 'expected_offline_seconds': 90,
                       'source_schema': 3, 'target_schema': 4, 'logical_store_id': 'store', 'source_root': '/live'}
        measured = {'format': 1, 'kind': 'checklist-owned-copy-startup', 'first_start': True, 'live_snapshot': True,
                    'source_fingerprint': 'fingerprint', 'service_sha256': hashlib.sha256(service.read_bytes()).hexdigest(),
                    'source_schema': 3, 'target_schema': 4, 'logical_store_id': 'store', 'source_root': '/live',
                    'launch_to_healthy_seconds': 12.5, 'measured_at_unix': time.time(), 'load_start': '{ 20 21 22 }'}
        path = base / 'measurement.json';path.write_text(json.dumps(measured))
        return service, capture, preparation, measured, path

    def test_report_uses_real_copy_measurement_with_explicit_margin(self):
        with tempfile.TemporaryDirectory() as folder:
            service, capture, preparation, measured, path = self.fixture(Path(folder))
            output = io.StringIO()
            with redirect_stdout(output): upgrade_offline.report(preparation, capture, service, path)
            self.assertIn('about 26 s; measured copy first startup 12.500 s', output.getvalue())
            self.assertIn('load { 20 21 22 }', output.getvalue())

    def test_missing_mismatched_stale_and_non_upgrade_copies_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            service, capture, preparation, measured, path = self.fixture(Path(folder))
            with redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, '--offline-measurement'):
                upgrade_offline.report(preparation, capture, service)
            mutations = {'first_start': False, 'live_snapshot': False, 'source_fingerprint': 'other',
                         'service_sha256': 'wrong', 'source_schema': 4, 'target_schema': 5,
                         'logical_store_id': 'other', 'source_root': '/other', 'launch_to_healthy_seconds': 0,
                         'measured_at_unix': time.time() - 73 * 3600}
            for key, value in mutations.items():
                with self.subTest(key=key):
                    path.write_text(json.dumps(dict(measured, **{key: value})))
                    with self.assertRaises(ValueError): upgrade_offline.measured_window(path, capture, service, preparation)

    def test_no_upgrade_estimate_is_labeled_and_needs_no_measurement(self):
        output = io.StringIO()
        with redirect_stdout(output):
            upgrade_offline.report({'needs_upgrade': False, 'prepared': False, 'expected_offline_seconds': 30}, '/unused', '/unused')
        self.assertIn('no store upgrade is required (startup estimate)', output.getvalue())


if __name__ == '__main__': unittest.main()
