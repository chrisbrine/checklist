#!/usr/bin/env python3
"""CL-359: every script under script/ that creates a store copy registers it
with ticket keys (requested_tickets plus an owner-record write) first.

A store copy is a copy of database.sqlite/checklist.sqlite or of a managed/ tree,
or a call to a slot/stage store-copy helper (snapshot_seed, restored_seed, or any
script function that itself makes a store copy)."""
import ast
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'script'
sys.path.insert(0, str(SCRIPT))
import clean_scratch
import prepare_p321g_copy

COPY_FUNCTIONS = {'copyfile', 'copy', 'copy2', 'copytree', 'copyfileobj', 'clonefile', 'link', 'ditto'}
PROCESS_FUNCTIONS = {'run', 'call', 'check_call', 'check_output', 'Popen'}
COPY_COMMANDS = {'cp', '/bin/cp', 'ditto', '/usr/bin/ditto', 'rsync', '/usr/bin/rsync', 'clonefile'}
STORE_COPY_HELPERS = {'snapshot_seed', 'restored_seed'}
TICKET_CALLS = {'requested_tickets'}
OWNER_CALLS = {'write_owner_record', 'mark_qualification', 'write_marker'}
SHELL_COPY = re.compile(r'\b(cp|ditto|rsync)\b[^\n]*(database\.sqlite|checklist\.sqlite|managed(/|\b))')
SHELL_REGISTRATION = re.compile(r'requested_tickets|evidence_folder\.py["\']?\s+(new|register)')


def call_name(node):
    function = node.func
    if isinstance(function, ast.Attribute):
        return function.attr
    if isinstance(function, ast.Name):
        return function.id
    return None


def is_store_name(value):
    return ('database.sqlite' in value or 'checklist.sqlite' in value or value == 'managed'
            or value.startswith('managed/') or value.endswith('/managed') or '/managed/' in value)


def mentions_store(nodes):
    return any(isinstance(n, ast.Constant) and isinstance(n.value, str) and is_store_name(n.value)
               for node in nodes for n in ast.walk(node))


def direct_store_copy(call):
    name = call_name(call)
    arguments = list(call.args) + [keyword.value for keyword in call.keywords]
    if name in COPY_FUNCTIONS and mentions_store(arguments):
        return True
    if name in PROCESS_FUNCTIONS and call.args and isinstance(call.args[0], (ast.List, ast.Tuple)):
        command = call.args[0].elts
        if (command and isinstance(command[0], ast.Constant) and command[0].value in COPY_COMMANDS
                and mentions_store(command[1:])):
            return True
    return False


def python_store_copies(tree):
    """Lines of store copies in one module, following module-local helper functions."""
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
    functions = {n.name: n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    helpers = set(STORE_COPY_HELPERS)
    changed = True
    while changed:  # a module function that makes a store copy is itself a copy helper
        changed = False
        for name, function in functions.items():
            if name in helpers:
                continue
            inner = [n for n in ast.walk(function) if isinstance(n, ast.Call)]
            if any(direct_store_copy(c) or call_name(c) in helpers for c in inner):
                helpers.add(name); changed = True
    return sorted({c.lineno for c in calls if direct_store_copy(c) or call_name(c) in helpers}), helpers


def audit_python(path, text=None):
    tree = ast.parse(path.read_text() if text is None else text, filename=str(path))
    copies, _ = python_store_copies(tree)
    names = {call_name(n) for n in ast.walk(tree) if isinstance(n, ast.Call)}
    missing = [part for part, calls in (('requested_tickets', TICKET_CALLS), ('owner record', OWNER_CALLS))
               if not names & calls]
    return copies, missing


def audit_shell(path, text=None):
    text = path.read_text() if text is None else text
    copies = [number for number, line in enumerate(text.splitlines(), 1) if SHELL_COPY.search(line)]
    return copies, [] if SHELL_REGISTRATION.search(text) else ['ticket registration']


def audit(path, text=None):
    return audit_python(path, text) if path.suffix == '.py' else audit_shell(path, text)


def audit_tree(root=SCRIPT):
    """{relative path: (copy lines, missing registration)} for every store-copying script."""
    found = {}
    for path in sorted(root.rglob('*')):
        if path.is_file() and path.suffix in {'.py', '.sh'}:
            copies, missing = audit(path)
            if copies:
                found[str(path.relative_to(root.parent))] = (copies, missing)
    return found


class StructuralTests(unittest.TestCase):
    def test_every_store_copying_script_registers_tickets(self):
        found = audit_tree()
        # The detector is not vacuous: both known store-copy tools are seen.
        self.assertIn('script/prepare_p321g_copy.py', found)
        self.assertIn('script/test_instances.py', found)
        unregistered = {path: value for path, value in found.items() if value[1]}
        self.assertEqual(unregistered, {}, 'store copy without requested_tickets/owner record: ' + json.dumps(unregistered))

    def test_detector_flags_unregistered_copies(self):
        cases = {
            'a.py': 'import shutil\ndef f(s, d):\n    shutil.copyfile(s / "database.sqlite", d)\n',
            'b.py': 'import subprocess\nsubprocess.run(["/bin/cp", "-cR", str(s / "managed") + "/.", d], check=True)\n',
            'c.py': 'import test_instances as slots\nslots.snapshot_seed(a, b)\n',
            'd.py': 'import shutil\ndef seed(s, d):\n    shutil.copytree(s / "managed", d)\ndef main():\n    seed(1, 2)\n',
            'e.sh': '#!/bin/sh\ncp -c "$SRC/checklist.sqlite" "$DST/"\n',
        }
        for name, text in cases.items():
            copies, missing = audit(Path(name), text)
            self.assertTrue(copies, name)
            self.assertTrue(missing, name)
        registered = ('from clean_scratch import requested_tickets, write_owner_record\n'
                      'import shutil\nt = requested_tickets(None)\nwrite_owner_record(d, t, "qualification")\n'
                      'shutil.copyfile(s / "database.sqlite", d / "checklist.sqlite")\n')
        self.assertEqual(audit(Path('ok.py'), registered)[1], [])
        # Only the ticket read, without an owner record, still fails.
        self.assertEqual(audit(Path('half.py'), 'requested_tickets(None)\nshutil.copy2("database.sqlite", d)\n')[1],
                         ['owner record'])
        # Copies of other files are not store copies.
        self.assertEqual(audit(Path('other.py'), 'import shutil\nshutil.copyfile("build-info.json", d)\n')[0], [])

    def test_base_round_59_prepare_script_is_flagged(self):
        base = subprocess.run(['git', '-C', str(ROOT), 'show', 'a4387c8:script/prepare_p321g_copy.py'],
                              capture_output=True, text=True)
        if base.returncode:
            self.skipTest('base commit a4387c8 not available')
        copies, missing = audit(Path('prepare_p321g_copy.py'), base.stdout)
        # cp at :31/:32 and main() at :56, which reaches them.
        self.assertEqual((copies, missing), ([31, 32, 56], ['requested_tickets', 'owner record']))


class PrepareP321gCopyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir='/private/tmp'); self.addCleanup(self.temp.cleanup)
        self.snapshot = Path(self.temp.name).resolve() / 'snapshot'; (self.snapshot / 'managed/objects').mkdir(parents=True)
        (self.snapshot / 'managed/objects/a.bin').write_bytes(b'object')
        database = self.snapshot / 'database.sqlite'
        with contextlib.closing(sqlite3.connect(database)) as connection:
            connection.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)')
            connection.execute("INSERT INTO metadata VALUES ('store_identity', ?)", (json.dumps({'state': 'ready'}),))
            connection.commit()
        digest = hashlib.sha256(database.read_bytes()).hexdigest()
        (self.snapshot / 'manifest.json').write_text(json.dumps({'databaseSHA256': digest}))
        self.runtime = self.snapshot / 'runtime'
        environment = patch.dict(os.environ, {'CHECKLIST_TICKETS': ''}); environment.start(); self.addCleanup(environment.stop)

    def run_main(self, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            prepare_p321g_copy.main([str(self.snapshot), str(self.runtime), *extra])
        return json.loads(output.getvalue())

    def test_refuses_without_ticket_keys_and_creates_nothing(self):
        with self.assertRaises(SystemExit):
            self.run_main()
        self.assertFalse(self.runtime.exists())
        with self.assertRaises(SystemExit):
            self.run_main('--ticket', 'not-a-key')
        self.assertFalse(self.runtime.exists())

    def test_owner_record_is_written_before_the_copy(self):
        seen = []
        real = subprocess.run
        def watched(command, *arguments, **options):
            if command[0] == '/bin/cp':
                seen.append(clean_scratch.read_owner_record(self.runtime))
            return real(command, *arguments, **options)
        with patch.object(prepare_p321g_copy.subprocess, 'run', side_effect=watched):
            marker = self.run_main('--ticket', 'CL-359', '--ticket', 'CL-321')
        self.assertEqual(len(seen), 2)
        self.assertTrue(all(r and r['kind'] == 'qualification' and r['tickets'] == ['CL-321', 'CL-359'] for r in seen))
        self.assertEqual(marker['tickets'], ['CL-321', 'CL-359'])
        self.assertEqual((self.runtime / 'objects/a.bin').read_bytes(), b'object')
        self.assertTrue((self.runtime / 'checklist.sqlite').is_file())
        self.assertEqual(clean_scratch.read_owner_record(self.runtime)['tickets'], ['CL-321', 'CL-359'])

    def test_environment_keys_and_owner_record_collision(self):
        with patch.dict(os.environ, {'CHECKLIST_TICKETS': 'CL-359'}):
            self.assertEqual(self.run_main()['tickets'], ['CL-359'])
        other = self.snapshot / 'runtime2'
        (self.snapshot / 'managed/owner.json').write_text('{}')
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            prepare_p321g_copy.main([str(self.snapshot), str(other), '--ticket', 'CL-359'])
        self.assertFalse(other.exists())


if __name__ == '__main__':
    unittest.main()
