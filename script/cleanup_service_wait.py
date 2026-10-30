#!/usr/bin/env python3
"""Bounded read-only service readiness at the post-install release boundary."""

import json
import subprocess
import time


READ_ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


class ServiceReadiness:
    """Retry the first complete status read while a newly installed service starts.

    The CLI reader must use ``call_timeout`` before *each* subprocess so a stuck
    call, project resolution and multiple ticket reads share the same deadline.
    Once one full read succeeds, ordinary status errors are returned immediately.
    This object never writes release markers or changes service data.
    """

    def __init__(self, timeout_seconds=60.0, retry_interval_seconds=1.0,
                 clock=time.monotonic, sleep=time.sleep, report=None):
        if timeout_seconds <= 0 or retry_interval_seconds <= 0:
            raise ValueError('service readiness timeout and retry interval must be positive')
        self.timeout_seconds = timeout_seconds
        self.retry_interval_seconds = retry_interval_seconds
        self.clock = clock
        self.sleep = sleep
        self.report = report or (lambda event: print(json.dumps(event, sort_keys=True), flush=True))
        self.started = None
        self.ready = False
        self.failure = None
        self.attempts = 0
        self.waited_seconds = 0.0

    def _remaining(self):
        return max(0.0, self.timeout_seconds - (self.clock() - self.started))

    def call_timeout(self):
        """The next CLI call's budget, including a shared startup deadline."""
        if self.ready:
            return 60.0
        if self.started is None:
            self.started = self.clock()
        remaining = self._remaining()
        if remaining <= 0:
            raise TimeoutError('new service did not become ready within '
                               f'{self.timeout_seconds:g} seconds')
        # A hung first CLI must leave time for another readiness attempt.
        return min(10.0, remaining)

    def _report(self, status, error=None):
        self.waited_seconds = max(0.0, self.clock() - self.started)
        event = {'action': 'release_done_service_wait', 'status': status,
                 'waited_seconds': round(self.waited_seconds, 3), 'attempts': self.attempts}
        if error is not None:
            event['reason'] = str(error)
        self.report(event)

    def read(self, reader, keys):
        if self.ready:
            return reader(keys)
        if self.failure is not None:
            raise self.failure
        if self.started is None:
            self.started = self.clock()
        while True:
            self.attempts += 1
            try:
                result = reader(keys)
            except READ_ERRORS as error:
                remaining = self._remaining()
                if remaining <= 0:
                    self.failure = TimeoutError('new service did not become ready within '
                                                f'{self.timeout_seconds:g} seconds: {error}')
                    self._report('unavailable', self.failure)
                    raise self.failure from error
                self.sleep(min(self.retry_interval_seconds, remaining))
                # Do not start another reader call after the deadline.
                if self._remaining() <= 0:
                    self.failure = TimeoutError('new service did not become ready within '
                                                f'{self.timeout_seconds:g} seconds: {error}')
                    self._report('unavailable', self.failure)
                    raise self.failure from error
            else:
                self.ready = True
                self._report('ready')
                return result
