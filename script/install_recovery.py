"""Replace Checklist and recover the previous bundle after a same-schema startup failure."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from uuid import uuid4

from verify_install import VerificationDeadlineExpired, deadline_seconds, failure_guidance, process_executables, verify


STARTUP_SECONDS = 60
RESTORE_SECONDS = 180
REGISTRATION_GRACE_SECONDS = 20
REGISTRATION_RETRIES = 2
SERVICE_LABEL = 'org.checklist.coordination'
TERM_GRACE_SECONDS = 5
KILL_GRACE_SECONDS = 5
SHUTDOWN_PASSES = 2
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework'
              '/Versions/Current/Support/lsregister')
INSTALL_ERRORS = (OSError, ValueError, KeyError, subprocess.SubprocessError)


def time_left(deadline, clock):
    remaining = deadline - clock()
    if remaining <= 0:
        raise TimeoutError('deadline expired')
    return remaining


def stop_checklist(root, destination, deadline, runner, processes, clock, sleep):
    """Stop this installation's app and the Checklist service holding its lock."""
    test_root = str(Path.home() / 'Library/Application Support/Checklist Test Instances') + os.sep
    executable = str(destination / 'Contents/MacOS/ChecklistApp')
    data = Path(os.environ.get('CHECKLIST_DATA_ROOT', str(Path.home() / 'Library/Application Support/Checklist')))
    lock = data / 'service.lock'
    service_pids = set()
    if lock.exists():
        owners = runner(['lsof', '-t', str(lock)], text=True, capture_output=True,
                        timeout=min(5, time_left(deadline, clock)))
        service_pids = set(map(int, owners.stdout.split()))
    targets = {pid for pid, path in processes(runner, min(5, time_left(deadline, clock)))
               if not path.startswith(test_root)
               and (path == executable
                    or (root is not None and path.startswith(str(root) + os.sep) and path.endswith('/ChecklistApp'))
                    or (pid in service_pids and path.endswith('/ChecklistService')))}
    for pid in targets:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    stop_deadline = min(deadline, clock() + 5)
    while targets:
        for pid in tuple(targets):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                targets.discard(pid)
        if targets:
            remaining = stop_deadline - clock()
            if remaining <= 0:
                raise TimeoutError('Checklist processes did not stop within five seconds: ' +
                                   ', '.join(map(str, sorted(targets))))
            sleep(min(0.05, remaining))


def identity(path):
    try:
        stat = path.lstat()
    except FileNotFoundError:
        return None
    return stat.st_dev, stat.st_ino


class ProcessUsage(ctypes.Structure):
    # Darwin's rusage_info_v0, selected by RUSAGE_INFO_V0 below.
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('counters', ctypes.c_uint64 * 8),
                ('start_abstime', ctypes.c_uint64), ('exit_abstime', ctypes.c_uint64)]


def process_identity(pid):
    """Read the executable path and kernel start time of one process instance."""
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    usage = ProcessUsage()

    def unavailable():
        error = ctypes.get_errno()
        if error not in (errno.ESRCH, errno.ENOENT):
            raise OSError(error, f'Could not inspect PID {pid}: {os.strerror(error)}')

    if library.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        unavailable()
        return None
    started = usage.start_abstime
    path = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, path, len(path)) <= 0:
        unavailable()
        return None
    # Do not bind a path from one PID instance to a start time from another.
    if library.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        unavailable()
        return None
    if usage.start_abstime == started:
        return os.fsdecode(path.value), started
    return None


def stop_candidate(destination, bundle, deadline, runner, processes, clock, sleep, *,
                   inspect=process_identity, send=os.kill):
    """Quiesce only the failed installed bundle before swapping it out."""
    _stop_bundle_processes(destination, bundle, deadline, runner, processes, clock, sleep,
                           ('ChecklistApp', 'ChecklistService'), 'candidate', inspect, send)


def _stop_bundle_processes(destination, bundle, deadline, runner, processes, clock, sleep, names, role, inspect, send):
    """Stop processes at exact executable paths and guard against PID reuse."""
    executables = {str(destination / 'Contents/MacOS' / name) for name in names}

    def require_bundle():
        if identity(destination) != bundle:
            raise ValueError(f'{role.capitalize()} bundle changed during shutdown at {destination}.')

    def targets():
        require_bundle()
        found = {}
        for pid, path in processes(runner, min(5, time_left(deadline, clock))):
            if path in executables:
                instance = inspect(pid)
                if instance is not None and instance[0] == path:
                    found[pid] = instance
        require_bundle()
        return found

    def send_to_current(pending, sig):
        for pid, instance in pending.items():
            time_left(deadline, clock)
            require_bundle()
            if inspect(pid) == instance:
                try:
                    send(pid, sig)
                except ProcessLookupError:
                    pass
                else:
                    if sig == signal.SIGKILL:
                        print(f'Sent SIGKILL to {role} PID {pid} ({instance[0]}) after the '
                              f'{TERM_GRACE_SECONDS} s SIGTERM grace period.', file=sys.stderr, flush=True)

    def wait_for_exit(pending, grace):
        stop_by = min(deadline, clock() + grace)
        while pending:
            pending = {pid: instance for pid, instance in pending.items() if inspect(pid) == instance}
            remaining = stop_by - clock()
            if not pending or remaining <= 0:
                break
            sleep(min(0.05, remaining))
        return pending

    pending = targets()
    for attempt in range(SHUTDOWN_PASSES):
        if not pending:
            return
        if attempt:
            print(f'{role.capitalize()} processes started during shutdown; stopping the newly observed instances.',
                  file=sys.stderr, flush=True)
        send_to_current(pending, signal.SIGTERM)
        pending = wait_for_exit(pending, TERM_GRACE_SECONDS)
        if pending:
            send_to_current(pending, signal.SIGKILL)
            survivors = wait_for_exit(pending, KILL_GRACE_SECONDS)
            if survivors:
                details = ', '.join(f'PID {pid} ({path})' for pid, (path, _) in sorted(survivors.items()))
                raise TimeoutError(f'{role.capitalize()} processes survived SIGKILL after {KILL_GRACE_SECONDS} seconds: '
                                   f'{details}. Bundles were kept in place.')
        pending = targets()
    if pending:
        details = ', '.join(map(str, sorted(pending)))
        raise ValueError(f'{role.capitalize()} processes kept restarting during shutdown: {details}. Bundles were kept in place.')


def launch_job_state(deadline, runner, clock):
    target = f'gui/{os.getuid()}/{SERVICE_LABEL}'
    result = runner(['/bin/launchctl', 'print', target], text=True, capture_output=True,
                    timeout=min(5, time_left(deadline, clock)))
    if result.returncode:
        detail = (result.stderr or result.stdout or '').strip()
        if result.returncode == 113 or 'could not find service' in detail.lower():
            return 'absent'
        raise ValueError(f'launchctl print {target} exited {result.returncode}: {detail}')
    match = re.search(r'(?m)^[ \t]+state = ([^\n]+)', result.stdout)
    if match is None:
        raise ValueError(f'launchctl print {target} did not report a job state.')
    return match[1].strip()


def install(root, destination, incoming, previous, rejected, preparation, install_started, *,
            replace_only=False, runner=subprocess.run, processes=process_executables, stop=stop_checklist,
            stop_replacement=stop_candidate, clock=time.monotonic, sleep=time.sleep):
    needs_upgrade = preparation.get('needs_upgrade') if isinstance(preparation, dict) else None
    if type(needs_upgrade) is not bool:
        raise ValueError('Invalid store-upgrade preparation receipt; the installed app is untouched.')
    old = identity(destination)
    new = identity(incoming)
    if new is None or any(identity(path) is not None for path in (previous, rejected)):
        raise ValueError('Install paths changed before replacement; the installed app is untouched.')

    def run(command, deadline, limit=15):
        runner(command, check=True, timeout=min(limit, time_left(deadline, clock)))

    upgrade_seen = needs_upgrade

    def mark_upgrade():
        nonlocal upgrade_seen
        if not upgrade_seen:
            upgrade_seen = True
            return clock() + deadline_seconds()

    def healthy(expected, deadline=None, on_upgrade=None):
        def paths(remaining):
            return (path for _, path in processes(runner, min(5, remaining)))
        sleep(2 if deadline is None else min(2, time_left(deadline, clock)))
        result = verify(destination, paths, runner, clock=clock, sleep=sleep, deadline=deadline,
                        include_failure_guidance=False, on_upgrade=on_upgrade)
        if identity(destination) != expected:
            raise ValueError('Installed bundle changed during verification.')
        return result

    def require_restored_bundle():
        if identity(destination) != old:
            raise ValueError(f'Restored bundle changed at {destination}.')

    def reopen_restored(refresh_registration):
        require_restored_bundle()
        if refresh_registration:
            # The restored native app owns SMAppService registration.
            sentinel = f'installer-rollback-{uuid4().hex}'
            for step, command in (
                ('Refreshing Launch Services registration', [LSREGISTER, '-f', str(destination)]),
                ('Writing a fresh service registration sentinel', ['/usr/bin/defaults', 'write', 'org.checklist.app',
                                                                   'registeredServiceBuild', '-string', sentinel]),
            ):
                require_restored_bundle()
                print(f'{step} for {destination}.', file=sys.stderr, flush=True)
                try:
                    run(command, restore_deadline)
                except INSTALL_ERRORS as error:
                    print(f'Warning: {step} failed: {error}', file=sys.stderr, flush=True)
        require_restored_bundle()
        print(f'Reopening restored app at {destination}.', file=sys.stderr, flush=True)
        run(['/usr/bin/open', '-g', str(destination)], restore_deadline)

    def verify_restored():
        for retry in range(1, REGISTRATION_RETRIES + 1):
            probe_deadline = min(restore_deadline, clock() + REGISTRATION_GRACE_SECONDS)
            try:
                # The health request also asks launchd to start this on-demand job.
                healthy(old, probe_deadline)
                return
            except VerificationDeadlineExpired:
                pass
            try:
                state = launch_job_state(restore_deadline, runner, clock)
            except INSTALL_ERRORS as error:
                print(f'Could not inspect restored service job: {error}', file=sys.stderr, flush=True)
                break
            print(f'Restored service job {SERVICE_LABEL} state: {state}.', file=sys.stderr, flush=True)
            if state == 'running':
                break
            require_restored_bundle()
            print(f'Registration retry {retry} of {REGISTRATION_RETRIES}: quitting restored app at {destination}.',
                  file=sys.stderr, flush=True)
            _stop_bundle_processes(destination, old, restore_deadline, runner, processes, clock, sleep,
                                   ('ChecklistApp',), 'restored app', process_identity, os.kill)
            reopen_restored(refresh_registration=True)
        # Allow launchd's throttle interval and service startup after the last reopen.
        healthy(old, restore_deadline)

    def measured(answer=None):
        elapsed = clock() - started
        if answer:
            print(f'Measured service offline window: {elapsed:.1f} s (stop request to first healthy service answer{answer}).',
                  flush=True)
        else:
            print(f'Measured service offline window: at least {elapsed:.1f} s (no healthy service answer observed).',
                  file=sys.stderr, flush=True)

    if needs_upgrade and not replace_only:
        deadline_seconds()  # Check the existing verification setting before stopping.
    if not (replace_only or needs_upgrade):
        print(f'New service must answer within {STARTUP_SECONDS} s of the stop request. '
              f'The previous bundle, when present, has a separate {RESTORE_SECONDS} s recovery budget.', flush=True)
    started = clock()
    deadline = started + STARTUP_SECONDS
    launch_attempted = False
    try:
        stop(root, destination, deadline, runner, processes, clock, sleep)
        if identity(destination) != old or identity(incoming) != new:
            raise ValueError('Installed or incoming bundle changed during the stop.')
        time_left(deadline, clock)
        if old is not None:
            destination.rename(previous)
        incoming.rename(destination)
        run(['codesign', '--verify', '--deep', '--strict', str(destination)], deadline, STARTUP_SECONDS)
        if replace_only:
            return True
        launch_attempted = True  # Even a failed open can have started the app.
        run(['/usr/bin/open', '-n', str(destination)], deadline)
        verified = healthy(new, None if needs_upgrade else deadline, mark_upgrade)
    except INSTALL_ERRORS as error:
        print('Installed verification failed: ' + str(error), file=sys.stderr, flush=True)
        # The previous bundle is safe before any new app launch. After launch,
        # a prepared or observed upgrade may already have committed.
        if old is None or (upgrade_seen and launch_attempted):
            if old is None and not launch_attempted and identity(destination) == new:
                try:
                    if identity(rejected) is not None:
                        raise ValueError('Rejected bundle path already exists.')
                    destination.rename(rejected)
                    print(f'Rejected bundle kept at {rejected}.', file=sys.stderr)
                except (OSError, ValueError) as quarantine_error:
                    print(f'Could not move the rejected bundle at {destination}: {quarantine_error}', file=sys.stderr)
            if upgrade_seen:
                print(failure_guidance(install_started), file=sys.stderr)
                print('Follow the protected-generation restore procedure in docs/database-storage.md '
                      'and docs/self-hosting.md.', file=sys.stderr)
            if old is not None:
                print(f'Previous bundle kept at {previous}.', file=sys.stderr)
            measured()
            return False
    else:
        print(json.dumps(verified), flush=True)
        measured(' from the new build')
        return True

    print(f'Restoring the previous Checklist service (up to {RESTORE_SECONDS} s).', file=sys.stderr, flush=True)
    restore_deadline = clock() + RESTORE_SECONDS
    try:
        current = identity(destination)
        if current != old:
            if current not in (None, new) or identity(previous) != old or identity(rejected) is not None:
                raise ValueError('Bundle paths changed; refusing to overwrite them.')
            if launch_attempted and current == new:
                stop_replacement(destination, current, restore_deadline, runner, processes, clock, sleep)
            if identity(destination) != current or identity(previous) != old or identity(rejected) is not None:
                raise ValueError('Bundle paths changed during the stop; refusing to overwrite them.')
            time_left(restore_deadline, clock)
            if current == new:
                destination.rename(rejected)
            previous.rename(destination)
        reopen_restored(refresh_registration=current != old)
        verify_restored()
    except INSTALL_ERRORS as error:
        print(f'Restore failed: {error}. Check {destination}, {previous} and {rejected}.',
              file=sys.stderr, flush=True)
        measured()
    else:
        print(f'Restored the previous Checklist bundle and verified its service at {destination}.', flush=True)
        measured(' from the restored build')
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'destination', 'incoming', 'previous', 'rejected'):
        parser.add_argument(name, type=Path)
    parser.add_argument('preparation', type=json.loads)
    parser.add_argument('install_started', type=float)
    parser.add_argument('--replace-only', action='store_true')
    try:
        return 0 if install(**vars(parser.parse_args())) else 1
    except INSTALL_ERRORS as error:
        print(f'Install failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
