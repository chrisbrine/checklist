#!/usr/bin/env python3
"""Bounded read-only service readiness at the post-install release boundary."""

import json
import re
import subprocess
import time


READ_ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)

# CLI error codes that mean the service is not ready yet (CL-372). Every other code
# is a definite answer: another attempt gets the same one, so it stops the wait.
UNREADY_CODES = frozenset({
    'SERVICE_UNAVAILABLE', 'SERVICE_NOT_READY', 'NOT_READY', 'STORAGE_UPGRADING', 'STORAGE_DRAINING',
    'STORAGE_NOT_READY', 'STORE_BUSY', 'OUTCOME_UNKNOWN', 'INVALID_RESPONSE', 'COMMAND_FAILED'})
# Service wait plus the status reads after it: the installer waits for this in the foreground.
TOTAL_READ_SECONDS = 90.0
_ERROR_LINE = re.compile(r'^(?:Checklist:\s*)?([A-Z][A-Z0-9_]{2,}):\s*(.*)$')
_NAMED_SECRET = re.compile(r'(?i)\b(token|secret|password|credential|api[_-]?key)\b(\s*[=:]\s*)\S+')
_LONG_SECRET = re.compile(r'[A-Za-z0-9_-]{40,}')


def public_text(text, limit=300):
    """One bounded log line: never a token, a credential or a whole stderr."""
    return _LONG_SECRET.sub('[redacted]', _NAMED_SECRET.sub(r'\1\2[redacted]', text))[:limit]


class CLICallError(subprocess.CalledProcessError):
    """A failed CLI call that keeps the CLI's own code and text from stderr. The text
    of a plain CalledProcessError names only the command and its exit status."""

    def __init__(self, returncode, cmd, output=None, stderr=None):
        super().__init__(returncode, cmd, output=output, stderr=stderr)
        lines = [line.strip() for line in (stderr or '').splitlines() if line.strip()]
        matches = [match for match in map(_ERROR_LINE.match, lines) if match]
        self.code = matches[0].group(1) if matches else None
        self.text = public_text(matches[0].group(2) if matches else (lines[0] if lines else ''))

    def __str__(self):
        return f'{self.code}: {self.text}' if self.code else f'CLI exit status {self.returncode}: {self.text}'


class StatusRefusal(ValueError):
    """The service answered, and the answer cannot produce a status. Do not retry."""

    def __init__(self, code, text):
        super().__init__(text)
        self.code = code


def error_code(error):
    return getattr(error, 'code', None) if isinstance(error, (CLICallError, StatusRefusal)) else None


def is_refusal(error):
    """True for a definite answer. A missing code (a killed CLI, a timeout, a bad reply) can still be startup."""
    code = error_code(error)
    return bool(code) and code not in UNREADY_CODES


class ServiceReadiness:
    """Retry the first complete status read while a newly installed service starts.

    The CLI reader must use ``call_timeout`` before *each* subprocess so a stuck
    call, project resolution and multiple ticket reads share the same deadline.
    Only an unready service is retried: a definite refusal stops at once (CL-372).
    Once one full read succeeds, ordinary status errors are returned immediately,
    and all reads share ``total_seconds``, because the installer waits for them.
    This object never writes release markers or changes service data.
    """

    def __init__(self, timeout_seconds=60.0, retry_interval_seconds=1.0,
                 clock=time.monotonic, sleep=time.sleep, report=None, total_seconds=None):
        if timeout_seconds <= 0 or retry_interval_seconds <= 0:
            raise ValueError('service readiness timeout and retry interval must be positive')
        self.timeout_seconds = timeout_seconds
        self.total_seconds = timeout_seconds + (TOTAL_READ_SECONDS - 60.0) if total_seconds is None else total_seconds
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

    def _total_remaining(self):
        return max(0.0, self.total_seconds - (self.clock() - self.started))

    def _budget_error(self):
        return TimeoutError(f'status reads did not finish within {self.total_seconds:g} seconds')

    def call_timeout(self):
        """The next CLI call's budget, including a shared startup deadline."""
        if self.ready:
            remaining = self._total_remaining()
            if remaining <= 0:
                raise self._budget_error()
            return min(60.0, remaining)
        if self.started is None:
            self.started = self.clock()
        remaining = self._remaining()
        if remaining <= 0:
            raise TimeoutError('new service did not become ready within '
                               f'{self.timeout_seconds:g} seconds')
        # A hung first CLI must leave time for another readiness attempt.
        return min(10.0, remaining)

    def _report(self, status, error=None, code=None):
        self.waited_seconds = max(0.0, self.clock() - self.started)
        event = {'action': 'release_done_service_wait', 'status': status,
                 'waited_seconds': round(self.waited_seconds, 3), 'attempts': self.attempts}
        if error is not None:
            event['reason'] = str(error)
        if code:
            event['code'] = code
        self.report(event)

    def read(self, reader, keys):
        if self.failure is not None:
            raise self.failure
        if self.ready:
            if self._total_remaining() <= 0:
                self.failure = self._budget_error()
                self._report('read_budget_exhausted', self.failure)
                raise self.failure
            return reader(keys)
        if self.started is None:
            self.started = self.clock()
        while True:
            self.attempts += 1
            try:
                result = reader(keys)
            except READ_ERRORS as error:
                if is_refusal(error):
                    self.failure = error
                    self._report('refused', error, error_code(error))
                    raise
                remaining = self._remaining()
                if remaining <= 0:
                    self.failure = TimeoutError('new service did not become ready within '
                                                f'{self.timeout_seconds:g} seconds: {error}')
                    self._report('unavailable', self.failure, error_code(error))
                    raise self.failure from error
                self.sleep(min(self.retry_interval_seconds, remaining))
                # Do not start another reader call after the deadline.
                if self._remaining() <= 0:
                    self.failure = TimeoutError('new service did not become ready within '
                                                f'{self.timeout_seconds:g} seconds: {error}')
                    self._report('unavailable', self.failure, error_code(error))
                    raise self.failure from error
            else:
                self.ready = True
                self._report('ready')
                return result
