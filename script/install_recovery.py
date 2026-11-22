"""Replace Checklist and recover the previous bundle after a same-schema startup failure."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from verify_install import deadline_seconds, failure_guidance, process_executables, verify


STARTUP_SECONDS = 60
RESTORE_SECONDS = 180
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


def install(root, destination, incoming, previous, rejected, preparation, install_started, *,
            replace_only=False, runner=subprocess.run, processes=process_executables, stop=stop_checklist,
            clock=time.monotonic, sleep=time.sleep):
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
            if launch_attempted:
                stop(None, destination, restore_deadline, runner, processes, clock, sleep)
            if identity(destination) != current or identity(previous) != old or identity(rejected) is not None:
                raise ValueError('Bundle paths changed during the stop; refusing to overwrite them.')
            time_left(restore_deadline, clock)
            if current == new:
                destination.rename(rejected)
            previous.rename(destination)
            # The restored native app owns SMAppService registration. Force its
            # build-change check even if the unsuccessful launch left the old value.
            for command in ([LSREGISTER, '-f', str(destination)],
                            ['/usr/bin/defaults', 'write', 'org.checklist.app',
                             'registeredServiceBuild', '-string', 'installer-rollback']):
                try:
                    run(command, restore_deadline)
                except INSTALL_ERRORS as error:
                    print('Warning: could not prepare restored app registration: ' + str(error),
                          file=sys.stderr, flush=True)
        run(['/usr/bin/open', '-g', str(destination)], restore_deadline)
        healthy(old, restore_deadline)
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
