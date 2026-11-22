#!/usr/bin/env python3
"""CL-513 signer guard and stage warning with fake codesign results only."""
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_signer_guard as guard


class InstallSignerGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.installed = root / 'Installed.app'
        self.stage = root / 'Stage.app'
        self.teams = {}
        self.codesign = patch.object(guard.subprocess, 'run', side_effect=self.fake_codesign)
        self.codesign.start()
        self.addCleanup(self.codesign.stop)

    def bundle(self, path, team):
        service = path / 'Contents/MacOS/ChecklistService'
        service.parent.mkdir(parents=True)
        service.write_bytes(b'fake service')
        self.teams[str(path)] = self.teams[str(service)] = team
        return service

    def fake_codesign(self, command, **kwargs):
        self.assertEqual(command[:3], ['codesign', '-d', '--verbose=4'])
        return subprocess.CompletedProcess(command, 0, '', f'TeamIdentifier={self.teams[command[-1]]}\n')

    def test_missing_installation_passes(self):
        self.bundle(self.stage, team=guard.UNSIGNED_TEAM)
        self.assertIsNone(guard.refusal(self.installed, self.stage))

    def test_equal_ad_hoc_teams_pass(self):
        self.bundle(self.installed, team=guard.UNSIGNED_TEAM)
        self.bundle(self.stage, team=guard.UNSIGNED_TEAM)
        self.assertIsNone(guard.refusal(self.installed, self.stage))

    def test_ad_hoc_stage_over_team_installation_is_refused_and_untouched(self):
        installed = self.bundle(self.installed, team='TESTTEAM')
        self.bundle(self.stage, team=guard.UNSIGNED_TEAM)
        before = installed.read_bytes()
        message = guard.refusal(self.installed, self.stage)
        self.assertIn('Refusing to install', message)
        self.assertIn("'not set'", message)
        self.assertEqual(installed.read_bytes(), before)
        self.assertIsNone(guard.refusal(self.installed, self.stage, allow=True))

    def test_equal_team_passes(self):
        self.bundle(self.installed, team='TESTTEAM')
        self.bundle(self.stage, team='TESTTEAM')
        self.assertIsNone(guard.refusal(self.installed, self.stage))

    def test_command_line_accepts_equal_teams(self):
        self.bundle(self.installed, team='TESTTEAM')
        self.bundle(self.stage, team='TESTTEAM')
        output = io.StringIO()
        with (patch.object(sys, 'argv', ['install_signer_guard.py', str(self.installed), str(self.stage)]),
              patch.dict(os.environ, CHECKLIST_ALLOW_SIGNER_CHANGE=''), redirect_stdout(output)):
            guard.main()
        self.assertIn('Signing team matches', output.getvalue())

    def test_stage_warning_names_private_signing_selection(self):
        self.bundle(self.installed, team='TESTTEAM')
        errors = io.StringIO()
        with (patch.object(sys, 'argv', ['install_signer_guard.py', '--warn-stage', str(self.installed)]),
              redirect_stderr(errors)):
            guard.main()
        self.assertIn('Warning:', errors.getvalue())
        self.assertIn('.local/build/signing-identity', errors.getvalue())

    def test_stage_warning_is_silent_for_missing_or_ad_hoc_installation(self):
        self.assertIsNone(guard.stage_warning(self.installed))
        self.bundle(self.installed, team=guard.UNSIGNED_TEAM)
        self.assertIsNone(guard.stage_warning(self.installed))


class StageWarningRoutingTests(unittest.TestCase):
    def test_only_ad_hoc_install_stages_check_for_warning(self):
        script = Path(__file__).with_name('build_and_run.sh').read_text()
        start = script.index('export CHECKLIST_SIGN_IDENTITY="$SIGN_IDENTITY"')
        end = script.index('if [ "$MODE" = --install-stage ]', start)
        fake = 'set -euo pipefail\npython3() { printf "%s\\n" "$@"; }\n'
        cases = [(mode, 'install', '-', True) for mode in ('--stage', '--rebuild-stage', '--clean-stage')]
        cases += [('--stage', 'test', '-', False), ('--stage', 'private-copy', '-', False),
                  ('--stage', 'install', 'fixture selection', False), ('--verify', 'install', '-', False)]
        for mode, scope, selection, warns in cases:
            with self.subTest(mode=mode, scope=scope, warns=warns):
                result = subprocess.run(['bash', '-c', fake + script[start:end]], capture_output=True, text=True,
                                        env=dict(os.environ, MODE=mode, BUILD_SCOPE=scope, SIGN_IDENTITY=selection,
                                                 ROOT_DIR='/temporary fixture', DEST='/temporary installed app'),
                                        timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(),
                                 ['-I', '/temporary fixture/script/install_signer_guard.py', '--warn-stage',
                                  '/temporary installed app'] if warns else [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
