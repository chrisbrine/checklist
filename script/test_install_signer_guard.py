#!/usr/bin/env python3
"""CL-513: the installer refuses a signer change before it stops the live service.
Run: python3 -I script/test_install_signer_guard.py
The team-signed case copies the installed ChecklistService when that copy is team-signed; it is skipped otherwise.
No case reads the Keychain: ad hoc signing needs no identity.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_signer_guard as guard  # noqa: E402

INSTALLED = Path('/Applications/Checklist.app/Contents/MacOS/ChecklistService')


def app(root, name, source, ad_hoc):
    executable = Path(root) / name / 'Contents/MacOS/ChecklistService'
    executable.parent.mkdir(parents=True)
    shutil.copy2(source, executable)
    if ad_hoc:
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(executable)], check=True, capture_output=True)
    return executable.parents[2]


class InstallSignerGuardTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = self.folder.name
        self.source = sys.executable if not INSTALLED.exists() else INSTALLED

    def tearDown(self):
        self.folder.cleanup()

    def test_missing_installation_passes(self):
        stage = app(self.root, 'Stage.app', self.source, ad_hoc=True)
        self.assertIsNone(guard.refusal(Path(self.root) / 'Missing.app', stage))

    def test_equal_ad_hoc_teams_pass(self):
        installed = app(self.root, 'Installed.app', self.source, ad_hoc=True)
        stage = app(self.root, 'Stage.app', self.source, ad_hoc=True)
        self.assertIsNone(guard.refusal(installed, stage))

    @unittest.skipUnless(INSTALLED.exists() and guard.team(INSTALLED) != guard.UNSIGNED_TEAM, 'no team-signed installation to copy')
    def test_ad_hoc_stage_over_team_installation_is_refused_and_untouched(self):
        installed = app(self.root, 'Installed.app', INSTALLED, ad_hoc=False)
        stage = app(self.root, 'Stage.app', INSTALLED, ad_hoc=True)
        before = (installed / 'Contents/MacOS/ChecklistService').read_bytes()
        message = guard.refusal(installed, stage)
        self.assertIn('Refusing to install', message)
        self.assertIn("'not set'", message)
        self.assertEqual((installed / 'Contents/MacOS/ChecklistService').read_bytes(), before)
        self.assertIsNone(guard.refusal(installed, stage, allow=True), 'a deliberate signer change is allowed')

    @unittest.skipUnless(INSTALLED.exists() and guard.team(INSTALLED) != guard.UNSIGNED_TEAM, 'no team-signed installation to copy')
    def test_equal_team_passes(self):
        installed = app(self.root, 'Installed.app', INSTALLED, ad_hoc=False)
        stage = app(self.root, 'Stage.app', INSTALLED, ad_hoc=False)
        self.assertIsNone(guard.refusal(installed, stage))

    def test_command_line_exit_status(self):
        installed = app(self.root, 'Installed.app', self.source, ad_hoc=True)
        stage = app(self.root, 'Stage.app', self.source, ad_hoc=True)
        script = Path(__file__).resolve().parent / 'install_signer_guard.py'
        result = subprocess.run([sys.executable, '-I', str(script), str(installed), str(stage)], capture_output=True, text=True,
                                env=dict(os.environ, CHECKLIST_ALLOW_SIGNER_CHANGE=''))
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
