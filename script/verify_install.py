"""Read-only installed app/service qualification shared by install modes."""
import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from version import require_installable, verify_bundle


SAFE_FAILURE_GUIDANCE = ('The installed bundle and the store were kept. Check checklist service status and the service log. '
                         'If the first start upgraded the store, a rollback is a restore of its protected pre-upgrade generation, '
                         'not the previous bundle.')


def failure_guidance(install_started, data_root=None):
    """Name a recent completed generation without opening the store or its manifest."""
    guidance = SAFE_FAILURE_GUIDANCE
    if install_started is None: return guidance
    root = Path(data_root) if data_root is not None else Path(os.environ.get('CHECKLIST_DATA_ROOT') or Path.home() / 'Library/Application Support/Checklist')
    candidates = []
    try:
        for snapshot in (root / 'backups').glob('snapshot-*'):
            if snapshot.is_symlink() or not (snapshot / 'manifest.json').is_file(): continue
            metadata = snapshot.stat()
            created = getattr(metadata, 'st_birthtime', None)
            if created is None: created = metadata.st_ctime
            if created >= install_started: candidates.append((created, str(snapshot)))
    except OSError:
        pass  # Diagnostics must not hide the verification failure.
    if candidates:
        guidance += ' Newest backups/snapshot-* created after install started: ' + max(candidates)[1] + '.'
    return guidance


def deadline_seconds():
    try: value = float(os.environ.get('CHECKLIST_VERIFY_DEADLINE_SECONDS', '2700'))
    except ValueError as error:
        raise ValueError('CHECKLIST_VERIFY_DEADLINE_SECONDS must be a finite number of seconds.') from error
    if not math.isfinite(value):
        raise ValueError('CHECKLIST_VERIFY_DEADLINE_SECONDS must be a finite number of seconds.')
    return max(60, value)


def healthy_status(payload):
    if not isinstance(payload, dict) or 'error' in payload: return False
    body = payload.get('data', payload)
    return (isinstance(body, dict) and 'error' not in body
            and body.get('state') in [None, 'ready', 'running', 'healthy']
            and body.get('name') == 'Checklist' and isinstance(body.get('version'), str) and bool(body['version'])
            and isinstance(body.get('capabilities'), list) and 'durable_store' in body['capabilities'])


def upgrading_status(payload):
    """Return the bounded startup progress supplied by the service/CLI."""
    if not isinstance(payload, dict): return None
    body = payload.get('data', payload)
    if not isinstance(body, dict): return None
    for value in [payload, body]:
        error = value.get('error')
        if isinstance(error, dict) and error.get('code') == 'STORAGE_UPGRADING':
            details = error.get('details')
            return details if isinstance(details, dict) else {'state': 'upgrading'}
    return body if body.get('state') == 'upgrading' else None


def upgrading_message(status):
    stage = status.get('stage', 'protected_startup')
    estimate = status.get('estimated_remaining_seconds')
    message = 'upgrading: ' + str(stage)
    if type(estimate) in [int, float] and math.isfinite(estimate) and estimate >= 0:
        message += f'; estimated remaining {estimate:g}s'
    if status.get('reason'): message += '; reason: ' + str(status['reason'])
    return message


# The CLI writes a failed call as "Checklist: CODE: message" on stderr, with empty stdout.
# These codes mean the service has not answered yet. Any other code is a real answer.
STARTING_CODES = frozenset(['OUTCOME_UNKNOWN', 'SERVICE_UNAVAILABLE', 'UNAVAILABLE', 'STORAGE_UPGRADING',
                            'STORAGE_NOT_READY', 'STORAGE_DRAINING', 'STORE_BUSY'])


def status_still_starting(result):
    """True when a status call that printed no JSON means no answer yet, not an invalid reply.

    `service status` has its own 10-second reply limit, shorter than the 30-second limit on each
    call here. A service that takes longer to start, or a job not yet registered, makes it exit 1
    with empty stdout and OUTCOME_UNKNOWN on stderr. The call is a read, so the next try is safe.
    A coded rejection or non-JSON output still fails.
    """
    stdout, stderr = result.stdout or '', result.stderr or ''
    if stdout.strip(): return bool(result.returncode) and 'unavailable' in (stdout + stderr).lower()
    code = re.match(r'\s*Checklist: ([A-Z][A-Z0-9_]*):', stderr)
    return code is None or code.group(1) in STARTING_CODES or 'unavailable' in stderr.lower()


def describe_status(result, limit=1000):
    """The real output of one status call, for a failure message."""
    def text(value):
        value = (value or '').strip()
        return repr(value if len(value) <= limit else value[:limit] + '...')
    return f'exit {result.returncode}; stdout {text(result.stdout)}; stderr {text(result.stderr)}'


def executable_paths():
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    for line in subprocess.check_output(['ps', '-axo', 'pid='], text=True).splitlines():
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(line.strip()), buffer, len(buffer)) > 0:
            yield os.fsdecode(buffer.value)


def verify(destination, paths=None, runner=subprocess.run, *, clock=time.monotonic, sleep=time.sleep,
           progress=None, install_started=None):
    destination = Path(destination)
    require_installable(verify_bundle(destination))
    executable = destination / 'Contents/MacOS/ChecklistApp'
    if paths is not None: paths = tuple(paths)
    progress = progress or (lambda line: print(line, file=sys.stderr, flush=True))
    def fail(message):
        raise ValueError(message + '\n' + failure_guidance(install_started))
    bound = deadline_seconds();started = clock();deadline = started + bound;next_progress = started + 60
    last_upgrade = None;last_status = 'no status call finished'
    command = [str(destination / 'Contents/MacOS/checklist'), 'service', 'status']
    def expired():
        fail(f'The installed Checklist service is still starting after {bound:g} seconds; verification deadline expired. '
             'Last status: ' + last_status)
    while True:
        if str(executable) not in (executable_paths() if paths is None else paths):
            fail('The exact installed Checklist app process is not running.')
        remaining = deadline - clock()
        if remaining <= 0: expired()
        try:
            result = runner(command, text=True, capture_output=True, timeout=min(30, remaining))
        except subprocess.TimeoutExpired as error:
            last_status = f'no reply within {error.timeout:g} seconds'  # The protected backup/migration may still be running.
        else:
            last_status = describe_status(result)
            try: payload = json.loads(result.stdout)
            except (ValueError, TypeError):
                if not status_still_starting(result):
                    fail('The installed Checklist service returned invalid status: ' + last_status)
            else:
                body = payload.get('data', payload) if isinstance(payload, dict) else None
                if not isinstance(body, dict): fail('The installed Checklist service returned invalid status: ' + last_status)
                state = body.get('state')
                states = [payload.get('state'), state]
                for value in states:
                    if value not in [None, 'ready', 'running', 'healthy', 'starting', 'unavailable', 'upgrading']:
                        fail('The installed Checklist service reported state ' + str(value) + '.')
                errors = [value['error'] for value in [payload, body] if 'error' in value]
                if any(not isinstance(error, dict) or error.get('code') not in ['SERVICE_UNAVAILABLE', 'UNAVAILABLE', 'STORAGE_UPGRADING'] for error in errors):
                    fail('The installed Checklist service returned an error status.')
                upgrade = upgrading_status(payload)
                if upgrade is not None:
                    message = upgrading_message(upgrade)
                    if message != last_upgrade:
                        progress('Installed Checklist service ' + message + '.')
                        last_upgrade = message
                if not errors and upgrade is None and not any(value in ['starting', 'unavailable', 'upgrading'] for value in states):
                    if result.returncode or not healthy_status(payload):
                        fail('The installed Checklist service is not healthy (status command failed or invalid status).')
                    identity = verify_bundle(destination)
                    for key in ['version', 'build_id', 'build_number']:
                        if body.get(key) != identity[key]: fail('Running service differs from installed bundle: ' + key)
                    return {'installed_app': str(executable), 'service_state': 'healthy'}
        now = clock()
        if now >= deadline: expired()
        if now >= next_progress:
            progress(f'Installed Checklist service still starting ({now - started:.0f}s elapsed; {deadline - now:.0f}s remaining).')
            next_progress = now + 60
        sleep(min(5, deadline - now))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, nargs='?')
    parser.add_argument('--install-started', type=float)
    parser.add_argument('--failure-guidance', action='store_true')
    arguments = parser.parse_args()
    if arguments.failure_guidance:
        print(failure_guidance(arguments.install_started))
        return 0
    if arguments.destination is None: parser.error('destination is required for verification')
    try:
        print(json.dumps(verify(arguments.destination, install_started=arguments.install_started)))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Installed verification failed: ' + str(error), file=sys.stderr)
        if SAFE_FAILURE_GUIDANCE not in str(error): print(failure_guidance(arguments.install_started), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
