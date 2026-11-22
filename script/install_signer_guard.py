#!/usr/bin/env python3
"""install_signer_guard.py INSTALLED_APP STAGE_APP -- refuse a signer change before an install stops anything (CL-513).

On 21 Nov 2026 an ad hoc stage replaced the Developer ID installation. The registered launch agent keeps
the installed team's launch constraint, so launchd refused the new service and Checklist was offline for
about 10.5 minutes. This guard compares the TeamIdentifier of both ChecklistService executables. A missing
installation passes. CHECKLIST_ALLOW_SIGNER_CHANGE=1 permits a deliberate signer change.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

UNSIGNED_TEAM = 'not set'


def team(executable):
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(executable)], capture_output=True, text=True)
    match = re.search(r'^TeamIdentifier=(.+)$', result.stderr, re.MULTILINE)
    return match.group(1).strip() if match else UNSIGNED_TEAM


def refusal(installed_app, stage_app, allow=False):
    """Return a refusal message, or None when the install may proceed."""
    installed = Path(installed_app) / 'Contents/MacOS/ChecklistService'
    if not installed.exists():
        return None
    installed_team = team(installed)
    stage_team = team(Path(stage_app) / 'Contents/MacOS/ChecklistService')
    if installed_team == stage_team or allow:
        return None
    return (f"Refusing to install: the stage is signed by team '{stage_team}', the installed service by "
            f"'{installed_team}'. launchd keeps the installed team's launch constraint, so the new service would "
            "not start. Stage with the installation's signing selection (.local/build/signing-identity); "
            "the installed bundle is untouched. CHECKLIST_ALLOW_SIGNER_CHANGE=1 permits a deliberate change.")


def stage_warning(installed_app):
    installed_app = Path(installed_app)
    if installed_app.is_dir() and team(installed_app) != UNSIGNED_TEAM:
        return ('Warning: this install-scope stage uses ad hoc signing but the installed Checklist app '
                'is team-signed. Set .local/build/signing-identity to the installation’s signing selection '
                'and stage again before installing.')
    return None


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.splitlines()[0])
    if sys.argv[1] == '--warn-stage':
        message = stage_warning(sys.argv[2])
        if message:
            print(message, file=sys.stderr)
        return
    message = refusal(sys.argv[1], sys.argv[2], os.environ.get('CHECKLIST_ALLOW_SIGNER_CHANGE') == '1')
    if message:
        raise SystemExit(message)
    print('Signing team matches the installed service.')


if __name__ == '__main__':
    main()
