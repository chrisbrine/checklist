"""Serialize local Checklist identity publication and scratch retirement."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import stat
import time


INHERITED_FD = 'CHECKLIST_PUBLICATION_FD'
SCRATCH_WAIT_SECONDS = 2.0


class PublicationBusy(ValueError):
    pass


def publication_path():
    return Path.home() / 'Library/Caches/ChecklistQualification/.checklist-publication.lock'


def prepare_path():
    path = publication_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def check_descriptor(fd, path):
    opened = os.fstat(fd)
    named = path.lstat()
    if (not stat.S_ISREG(named.st_mode) or named.st_uid != os.getuid()
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)):
        raise ValueError(f'Publication lock must be the caller-owned regular file at {path}.')


def open_lock(path):
    return os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)


def recorded_holder(fd):
    try:
        record = json.loads(os.pread(fd, 4096, 0))
        purpose, pid = record['purpose'], record['pid']
        if isinstance(purpose, str) and type(pid) is int:
            return f' Recorded holder: {purpose} (PID {pid}).'
    except (OSError, ValueError, TypeError, KeyError):
        pass
    return ''


def acquire(fd, path, purpose, pid, timeout):
    check_descriptor(fd, path)
    if timeout is None:
        fcntl.flock(fd, fcntl.LOCK_EX)
    else:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise PublicationBusy(
                        f'Checklist publication lock busy after {timeout:g} s at {path}.'
                        + recorded_holder(fd)) from None
                time.sleep(min(remaining, 0.05))
    check_descriptor(fd, path)
    record = json.dumps({'purpose': purpose, 'pid': pid}).encode()
    os.ftruncate(fd, 0)
    os.pwrite(fd, record, 0)


def borrow(fd, path):
    # A separate descriptor cannot join a held lock. The caller must pass the
    # already-locked open file description to the child, not just an environment value.
    if fd < 3:
        raise ValueError('Inherited publication lock needs a dedicated descriptor.')
    check_descriptor(fd, path)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    check_descriptor(fd, path)


def inherited_fd():
    value = os.environ.get(INHERITED_FD)
    return int(value) if value is not None else None


@contextmanager
def publication_lock(purpose, *, timeout=None, inherited=None):
    if inherited is not None:
        borrow(inherited, publication_path())
        yield inherited
        return
    path = prepare_path()
    fd = open_lock(path)
    try:
        acquire(fd, path, purpose, os.getpid(), timeout)
        yield fd
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--path', action='store_true')
    action.add_argument('--acquire', nargs=3, metavar=('FD', 'PURPOSE', 'PID'))
    action.add_argument('--borrow', type=int, metavar='FD')
    args = parser.parse_args()
    if args.path:
        path = prepare_path()
        fd = open_lock(path)
        try:
            check_descriptor(fd, path)
        finally:
            os.close(fd)
        print(path)
    elif args.acquire:
        fd, purpose, pid = args.acquire
        acquire(int(fd), publication_path(), purpose, int(pid), None)
    else:
        borrow(args.borrow, publication_path())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Checklist publication lock unavailable: {error}')
