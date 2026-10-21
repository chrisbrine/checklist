"""Read-only installed app/service qualification shared by install modes."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys


def healthy_status(payload):
    if not isinstance(payload, dict) or 'error' in payload: return False
    body = payload.get('data', payload)
    return (isinstance(body, dict) and 'error' not in body
            and body.get('state') in [None, 'ready', 'running', 'healthy']
            and body.get('name') == 'Checklist' and isinstance(body.get('version'), str) and bool(body['version'])
            and isinstance(body.get('capabilities'), list) and 'durable_store' in body['capabilities'])


def executable_paths():
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    for line in subprocess.check_output(['ps', '-axo', 'pid='], text=True).splitlines():
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(int(line.strip()), buffer, len(buffer)) > 0:
            yield os.fsdecode(buffer.value)


def verify(destination, paths=None, runner=subprocess.run):
    destination = Path(destination)
    executable = destination / 'Contents/MacOS/ChecklistApp'
    if str(executable) not in (executable_paths() if paths is None else paths):
        raise ValueError('The exact installed Checklist app process is not running.')
    result = runner([str(destination / 'Contents/MacOS/checklist'), 'service', 'status'],
                    text=True, capture_output=True, timeout=360)
    if result.returncode:
        raise ValueError('The installed Checklist service is unavailable (status command failed).')
    try: payload = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise ValueError('The installed Checklist service returned invalid status.') from error
    if not healthy_status(payload):
        raise ValueError('The installed Checklist service is not healthy (recovery, unavailable or error status).')
    return {'installed_app': str(executable), 'service_state': 'healthy'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    arguments = parser.parse_args()
    print(json.dumps(verify(arguments.destination)))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Installed verification failed: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
