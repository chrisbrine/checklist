"""Pure-logic checks for bounded test slots; no installed app or service is touched."""
import importlib.util
import io
from contextlib import redirect_stdout, closing, ExitStack, contextmanager
import itertools
import os
import sqlite3
from types import SimpleNamespace
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
spec = importlib.util.spec_from_file_location('test_instances', Path(__file__).resolve().parents[1] / 'script/test_instances.py')
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
import verify_install


def store_fixture(path, schema=0, records=()):
    # Exact table definitions used by SchemaMigrations.baselineSQL/currentSQL.
    sql = """CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE records(id TEXT PRIMARY KEY, project_id TEXT, type TEXT NOT NULL, revision INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE INDEX records_scope ON records(project_id,type);
    CREATE TABLE commands(principal TEXT NOT NULL, command_id TEXT NOT NULL, digest TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(principal,command_id));
    CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, project_id TEXT, entity_id TEXT, actor TEXT NOT NULL, kind TEXT NOT NULL, occurred_at TEXT NOT NULL, data TEXT NOT NULL);
    CREATE INDEX events_scope ON events(project_id,entity_id,seq);
    CREATE TABLE cursors(token TEXT PRIMARY KEY, principal TEXT NOT NULL, scope TEXT NOT NULL, sequence INTEGER NOT NULL, incarnation TEXT NOT NULL, created_at REAL NOT NULL);"""
    if schema >= 2: sql = sql.replace(' TEXT', ' TEXT COLLATE checklist_storage_v2')
    identity = {'format_version': 1, 'logical_store_id': '20000000-0000-4000-8000-000000000002',
                'incarnation': '30000000-0000-4000-8000-000000000003', 'database_generation': 1,
                'schema_revision': schema, 'state': 'ready'}
    with closing(sqlite3.connect(path)) as db, db:
        db.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
        db.executescript(sql + f'PRAGMA user_version={schema};')
        if schema: db.execute('INSERT INTO metadata VALUES (?,?)', ('store_identity', json.dumps(identity)))
        for kind, record in records:
            db.execute('INSERT INTO records VALUES (?,?,?,?,?)', (record['id'], record.get('project_id'), kind, record.get('revision', 1), json.dumps(record)))
    return identity


def attachment(path):
    # Shape produced by the actual attachment importer, including retained paths.
    return {'id': 'attachment', 'artifact_id': 'attachment', 'project_id': 'project', 'task_id': 'ticket',
            'name': 'fixture', 'description': '', 'mode': 'managed', 'path': str(path), 'sha256': 'a' * 64,
            'size': 7, 'availability': 'available', 'keep_original': False, 'unlinked': False,
            'revision': 1, 'created_at': '2026-10-20T00:00:00Z', 'author': 'owner:fixture', 'origin': 'human_ui'}


class TestInstancesTests(unittest.TestCase):
    def test_slot_range(self):
        for number in range(1, 5):
            self.assertEqual(harness.slot_number(str(number)), number)
        for invalid in [0, 5, -1, '01', 'x', '', None, True, 1.0]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError): harness.slot_number(invalid)

    def test_seed_arguments_are_validated_before_slot_changes(self):
        for value in ['empty', 'latest-backup', 'backup:/owned/snapshot', 'slot:1', 'slot:4']:
            self.assertEqual(harness.seed_value(value), value)
        for value in ['backup:', 'slot:0', 'slot:5', 'slot:01', 'other']:
            with self.subTest(value=value), self.assertRaises(ValueError): harness.seed_value(value)

    def test_exact_paths_and_names(self):
        for number in range(1, 5):
            p = harness.paths(number)
            self.assertEqual(p['folder'], harness.BASE / f'slot-{number}')
            self.assertEqual(p['data'], p['folder'] / 'data')
            self.assertEqual(p['bundle'], p['folder'] / f'Checklist Test {number}.app')
            self.assertEqual(p['label'], f'org.checklist.test{number}.coordination')
            self.assertEqual(p['identifier'], f'org.checklist.app.test{number}')
            self.assertEqual(p['keychain'], f'org.checklist.test{number}.enrollments')
            self.assertNotEqual(p['data'], harness.LIVE)

    def test_plist_rewrite_preserves_build(self):
        original = {'CFBundleIdentifier': 'org.checklist.app', 'CFBundleVersion': '94', 'CFBundleExecutable': 'ChecklistApp'}
        for number in range(1, 5):
            rewritten = plistlib.loads(plistlib.dumps(harness.rewrite_info(original, number)))
            self.assertEqual(rewritten['ChecklistInstanceSlot'], number)
            self.assertEqual(rewritten['CFBundleIdentifier'], f'org.checklist.app.test{number}')
            self.assertEqual(rewritten['CFBundleName'], f'Checklist Test {number}')
            self.assertEqual(rewritten['CFBundleDisplayName'], f'Checklist Test {number}')
            self.assertEqual(rewritten['CFBundleVersion'], '94')
        self.assertNotIn('ChecklistInstanceSlot', original)

    def test_refuses_outside_slot_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / 'slot-1'; root.mkdir()
            outside = root.parent / 'live'; outside.mkdir()
            self.assertEqual(harness.contained(root / 'data', root), root / 'data')
            for value in [outside, root / '..' / 'live', root.parent / 'slot-10/data']:
                with self.assertRaises(ValueError): harness.contained(value, root)
            (root / 'data').symlink_to(outside)
            with self.assertRaises(ValueError): harness.contained(root / 'data/file', root)

    def test_refuses_symlinked_slot_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            (base / 'real').mkdir(); (base / 'alias').symlink_to(base / 'real')
            with self.assertRaises(ValueError): harness.contained(base / 'alias/slot-1', base / 'alias')

    def test_relative_snapshot_paths(self):
        for value in ['objects/a', 'icons/a.png', 'source-captures/a/b/source/c', 'staging/attachment-imports/a', 'source-executions/a']:
            self.assertEqual(str(harness.relative_path(value)), value)
        for value in ['/etc/passwd', '../a', 'objects/../../x', 'objects//x', 'objects/./x', 'connections.json', '', 'objects/a\0b']:
            with self.subTest(value=value), self.assertRaises(ValueError): harness.relative_path(value)

    def selected(self):
        return {'build_id': 'build-a', 'source_fingerprint': 'fingerprint-a',
                'checks': {'build_id': 'build-a', 'source_fingerprint': 'fingerprint-a', 'passed': True}}

    def backup(self):
        return dict(self.selected(), seed={'kind': 'backup', 'live_snapshot': True})

    def test_promotion_requires_both_checks(self):
        selected = self.selected()
        self.assertEqual(harness.promotion_gates(selected, [self.backup()]),
                         {'selected_build_check': True, 'live_snapshot_check_same_build': True})
        self.assertFalse(harness.promotion_gates(selected, [selected])['live_snapshot_check_same_build'])
        selected['checks']['passed'] = False
        self.assertFalse(harness.promotion_gates(selected, [self.backup()])['selected_build_check'])

    def test_promotion_refuses_stale_or_foreign_snapshot_evidence(self):
        for field, value in [('build_id', 'old'), ('source_fingerprint', 'old'), ('passed', False)]:
            backup = self.backup(); backup['checks'][field] = value
            self.assertFalse(harness.promotion_gates(self.selected(), [backup])['live_snapshot_check_same_build'])
        for seed in [{'kind': 'slot', 'live_snapshot': True}, {'kind': 'backup', 'live_snapshot': False}]:
            self.assertFalse(harness.promotion_gates(self.selected(), [dict(self.backup(), seed=seed)])['live_snapshot_check_same_build'])

    def test_no_check_is_not_pass(self):
        for checks in [None, {}, {'passed': True}]:
            self.assertFalse(harness.promotion_gates(dict(self.selected(), checks=checks), [])['selected_build_check'])

    def test_live_seed_root_is_never_read(self):
        for source in [harness.LIVE, harness.LIVE / 'objects', harness.LIVE / 'checklist.sqlite']:
            with self.assertRaises(ValueError): harness.snapshot_seed(source, Path('unused'))

    def test_lock_is_per_slot_and_never_removed_on_contention(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            with harness.locked(1):
                with self.assertRaises(ValueError):
                    with harness.locked(1): pass
                with harness.locked(2): self.assertTrue((harness.BASE / '.slot-1.lock').exists())
            self.assertFalse((harness.BASE / '.slot-1.lock').exists())

    def test_metadata_cannot_select_another_slot(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            p = harness.checked(1); p['folder'].mkdir()
            (p['folder'] / 'slot.json').write_text(json.dumps({'slot': 2}))
            with self.assertRaises(ValueError): harness.load(p)

class AdditionalGuardsTests(unittest.TestCase):
    def test_old_stages_cannot_produce_test_bundles(self):
        with self.assertRaises(ValueError): harness.require_instance_support({'inputs': []})
        harness.require_instance_support({'inputs': [{'path': 'Sources/ChecklistIPC/ChecklistInstance.swift'}]})

    def test_dry_run_never_acquires_a_lock(self):
        with patch.object(sys, 'argv', ['test_instances.py', 'promote', '--slot', '1', '--dry-run']), \
             patch.object(harness, 'promote') as promote, patch.object(harness, 'locked') as locked:
            harness.main()
            promote.assert_called_once()
            locked.assert_not_called()

    def test_stop_refuses_a_foreign_service_pid(self):
        p = harness.paths(1)
        with patch.object(harness, 'processes', return_value={'app': [], 'service': [], 'cli': []}), \
             patch.object(harness, 'launch_state', return_value={'registered': True, 'pid': 5923}), \
             patch.object(harness, 'process_path', return_value='/Applications/Checklist.app/Contents/MacOS/ChecklistApp'), \
             patch.object(harness, 'run') as run:
            with self.assertRaises(ValueError): harness.stop(p)
            run.assert_not_called()

    def test_launchd_program_cannot_point_to_live_app(self):
        p = harness.paths(1)
        result = subprocess.CompletedProcess([], 0, stdout=' state = waiting\n program = /Applications/Checklist.app/Contents/MacOS/ChecklistService\n', stderr='')
        with patch.object(harness, 'run', return_value=result):
            with self.assertRaises(ValueError): harness.launch_state(p)

    def test_slot_seed_refuses_an_aliased_data_root(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            other = harness.checked(2); other['folder'].mkdir()
            outside = harness.BASE / 'outside'; outside.mkdir()
            other['data'].symlink_to(outside)
            harness.save(other, {'slot': 2, 'build_id': 'fixture'})
            with patch.object(harness, 'stopped'):
                with self.assertRaises(ValueError): harness.slot_seed(other, harness.BASE / 'destination')

    def test_slot_seed_copies_bytes_and_excludes_connections(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            other = harness.checked(2); other['data'].mkdir(parents=True)
            (other['data'] / 'connections.json').write_text('credential-reference')
            store_fixture(other['data'] / 'checklist.sqlite', schema=2)
            harness.save(other, {'slot': 2, 'build_id': 'fixture'})
            destination = harness.BASE / 'destination'; destination.mkdir()
            with patch.object(harness, 'stopped'):
                seed = harness.slot_seed(other, destination)
            self.assertEqual(harness.sha(destination / 'checklist.sqlite'), harness.sha(other['data'] / 'checklist.sqlite'))
            self.assertFalse((destination / 'connections.json').exists())
            self.assertEqual(seed['source_build_id'], 'fixture')

    def test_log_alias_is_refused_before_bootstrap(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            p = harness.checked(1); (p['folder'] / 'logs').mkdir(parents=True)
            (p['folder'] / 'logs/service.stdout.log').symlink_to(harness.BASE / 'outside')
            with patch.object(harness, 'load', return_value={'seed': {'kind': 'empty'}, 'mode': 'stopped'}), patch.object(harness, 'bundle_check'), patch.object(harness, 'run') as run:
                with self.assertRaises(ValueError): harness.start(SimpleNamespace(gui=False, slot=1), p)
                run.assert_not_called()


class StopWaitTests(unittest.TestCase):
    @contextmanager
    def stopping(self, launches, observations):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            stack.enter_context(patch.object(harness, 'BASE', Path(directory).resolve()))
            p = harness.paths(4); p['folder'].mkdir()
            (p['folder'] / 'slot.json').write_text(json.dumps({'slot': 4, 'mode': 'headless'}))
            state = SimpleNamespace(p=p, elapsed=0.0)
            def sleep(seconds):
                self.assertGreater(seconds, 0); self.assertLessEqual(seconds, .1)
                state.elapsed += seconds
            state.launch = stack.enter_context(patch.object(harness, 'launch_state', side_effect=launches))
            state.processes = stack.enter_context(patch.object(harness, 'processes', side_effect=observations))
            state.path = stack.enter_context(patch.object(harness, 'process_path', return_value=''))
            state.kill = stack.enter_context(patch.object(harness.os, 'kill'))
            state.run = stack.enter_context(patch.object(harness, 'run'))
            state.load = stack.enter_context(patch.object(harness, 'load', return_value={'slot': 4, 'mode': 'headless'}))
            state.save = stack.enter_context(patch.object(harness, 'save'))
            state.sleep = stack.enter_context(patch.object(harness.time, 'sleep', side_effect=sleep))
            stack.enter_context(patch.object(harness.time, 'monotonic', side_effect=lambda: state.elapsed))
            yield state

    def test_stop_waits_for_asynchronous_launchd_removal(self):
        empty = {'app': [], 'service': [], 'cli': []}
        registered = {'registered': True, 'state': 'removing', 'pid': None}
        absent = {'registered': False, 'state': 'absent', 'pid': None}
        with self.stopping([registered] * 4 + [absent], [empty] * 5) as state:
            harness.stop(state.p)
            self.assertEqual(state.sleep.call_count, 3)
            state.run.assert_called_once_with(['launchctl', 'bootout', f'gui/{os.getuid()}/{state.p["label"]}'])
            state.kill.assert_not_called(); state.path.assert_not_called()
            self.assertEqual(state.save.call_args.args[1]['mode'], 'stopped')

    def test_stop_waits_for_exiting_cli_without_signaling_it(self):
        cli = {'app': [], 'service': [], 'cli': [7493]}
        empty = {'app': [], 'service': [], 'cli': []}
        absent = {'registered': False, 'state': 'absent', 'pid': None}
        with self.stopping(itertools.repeat(absent), [cli, cli, cli, empty]) as state:
            harness.stop(state.p)
            self.assertEqual(state.sleep.call_count, 2)
            state.kill.assert_not_called(); state.path.assert_not_called(); state.run.assert_not_called()
            self.assertEqual(state.save.call_args.args[1]['mode'], 'stopped')

    def test_stop_timeout_reports_remaining_pids_and_launchd_without_marking_stopped(self):
        before = {'app': [7451], 'service': [7452], 'cli': [7453]}
        remaining = {'app': [], 'service': [7452], 'cli': [7453]}
        registered = {'registered': True, 'state': 'removing', 'pid': 7452}
        observations = itertools.chain([before], itertools.repeat(remaining))
        with self.stopping(itertools.repeat(registered), observations) as state:
            state.path.side_effect = lambda pid: str(state.p['bundle'] / 'Contents/MacOS' /
                                                    {7451: 'ChecklistApp', 7452: 'ChecklistService'}[pid])
            with self.assertRaises(ValueError) as failure: harness.stop(state.p)
            message = str(failure.exception)
            self.assertIn('Slot still has a running process; preserve it for reconciliation.', message)
            for value in ['7452', '7453', 'removing', 'registered']: self.assertIn(value, message)
            self.assertAlmostEqual(state.elapsed, 10)
            state.kill.assert_called_once_with(7451, harness.signal.SIGTERM)
            state.run.assert_called_once_with(['launchctl', 'bootout', f'gui/{os.getuid()}/{state.p["label"]}'])
            state.load.assert_not_called(); state.save.assert_not_called()
            self.assertEqual(json.loads((state.p['folder'] / 'slot.json').read_text())['mode'], 'headless')


class SnapshotLogicTests(unittest.TestCase):
    def fixture(self, base, schema=0, records=()):
        source = base / 'snapshot-fixture'; source.mkdir()
        (source / 'managed/objects').mkdir(parents=True)
        store_fixture(source / 'database.sqlite', schema=schema, records=records)
        (source / 'managed/objects/file').write_bytes(b'managed')
        manifest = {'format': 1, 'kind': 'checklist-store-snapshot', 'operationID': '10000000-0000-4000-8000-000000000001',
                    'storeID': '20000000-0000-4000-8000-000000000002', 'sourceRoot': '/owned/source', 'schema': schema,
                    'databaseSHA256': harness.sha(source / 'database.sqlite'), 'databaseSize': (source / 'database.sqlite').stat().st_size,
                    'objects': [{'sha256': harness.sha(source / 'managed/objects/file'), 'size': 7,
                                 'descriptor': {'kind': 'file', 'relativePath': 'objects/file', 'executable': False}}]}
        (source / 'manifest.json').write_text(json.dumps(manifest))
        (source / 'intent.json').write_text(json.dumps({'format': '1', 'kind': manifest['kind'],
            'operation_id': manifest['operationID'], 'store_id': manifest['storeID'], 'source_root': manifest['sourceRoot']}))
        destination = base / 'data'; destination.mkdir()
        return source, destination, manifest

    def test_verified_snapshot_maps_layout_without_editing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination, manifest = self.fixture(Path(directory).resolve())
            seed = harness.snapshot_seed(source, destination)
            self.assertEqual((destination / 'checklist.sqlite').read_bytes(), (source / 'database.sqlite').read_bytes())
            self.assertEqual((destination / 'objects/file').read_bytes(), b'managed')
            self.assertEqual(seed['source_hash'], harness.sha(source / 'manifest.json'))
            self.assertFalse(seed['live_snapshot'])
            self.assertFalse((destination / 'checklist-store.identity.json').exists())

    def test_bad_hash_and_extra_file_refuse_before_materialization(self):
        for fault in ['hash', 'extra']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                source, destination, manifest = self.fixture(Path(directory).resolve())
                if fault == 'hash': (source / 'managed/objects/file').write_bytes(b'changed')
                else: (source / 'connections.json').write_text('must not copy')
                with self.assertRaises(ValueError): harness.snapshot_seed(source, destination)
                self.assertEqual(list(destination.iterdir()), [])

    def test_current_identity_comes_from_copied_database(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination, manifest = self.fixture(Path(directory).resolve(), schema=2)
            identity = harness.database_observation(source / 'database.sqlite')['identity']
            harness.snapshot_seed(source, destination)
            self.assertEqual(json.loads((destination / 'checklist-store.identity.json').read_text()), identity)


class SeedIsolationTests(unittest.TestCase):
    fixture = SnapshotLogicTests.fixture

    def inspect(self, base, records, source_root=None):
        database = base / 'fixture.sqlite'
        store_fixture(database, 2, records)
        return harness.require_local_paths(database, base / 'data', source_root=source_root)

    def test_traversing_managed_attachment_refuses_snapshot_and_slot_copy_without_rewriting(self):
        for schema in [0, 2, 3]:
            with self.subTest(schema=schema), tempfile.TemporaryDirectory() as directory:
                source, destination, _ = self.fixture(Path(directory).resolve(), schema,
                    [('attachment', attachment('../../private/synthetic-outside/file'))])
                before = harness.sha(source / 'database.sqlite')
                with self.assertRaisesRegex(ValueError, 'root-relative managed path.*records.data.path'):
                    harness.snapshot_seed(source, destination)
                self.assertEqual(list(destination.iterdir()), [])
                self.assertEqual(harness.sha(source / 'database.sqlite'), before)
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            source = harness.checked(2);source['data'].mkdir(parents=True)
            store_fixture(source['data'] / 'checklist.sqlite', 2, [('attachment', attachment('../../outside/file'))])
            harness.save(source, {'slot': 2, 'build_id': 'fixture'})
            with patch.object(harness, 'stopped'), self.assertRaisesRegex(ValueError, 'root-relative managed path'):
                harness.slot_seed(source, harness.BASE / 'copy')

    def test_unknown_file_fields_keep_absolute_local_requirement(self):
        fields = ['path', 'preview_path', 'icon_path', 'snapshot_path', 'output_path', 'working_directory',
                  'mcp_executable', 'git_path', 'resolved_path', 'database_path']
        cases = [{field: value} for field in fields for value in ['', 'objects/file', '../file', '/outside/file']]
        cases += [{'root_path': '../file'}, {'paths': ['../file']}, {'additional_paths': ['src/file']},
                  {'path_sha256': {'../file': 'digest'}}]
        for record in cases:
            with self.subTest(record=record), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    self.inspect(Path(directory).resolve(), [('fixture', dict(record, id='fixture'))])

    def test_relative_managed_families_capture_names_and_instruction_refs_are_allowed(self):
        capture = {'id': 'capture', 'snapshot_path': 'source-captures/project/capture/source',
                   'files': [{'path': 'src/file.swift', 'kind': 'file'},
                             {'path': 'links/file', 'kind': 'symlink', 'target': '../src/file.swift'}],
                   'git_path': '/usr/bin/git'}
        records = [('attachment', dict(attachment('objects/project/file'), preview_path='objects/project/preview')),
                   ('project', {'id': 'project', 'icon_path': 'icons/project.png'}),
                   ('source_capture', capture),
                   ('manifest', {'id': 'manifest', 'evidence': {'source_capture': dict(capture, id='capture-copy')}}),
                   ('source_execution', {'id': 'execution', 'output_path': 'source-executions/execution/output.log',
                                         'working_directory': 'source-captures/project/capture/source'}),
                   ('storage_job', {'id': 'job', 'object_relative_path': 'objects/new', 'relative_path': 'objects/old',
                                    'objects': [{'representation': 'original', 'stage': 'staging/import/new', 'final': 'objects/new'}]}),
                   ('review', {'id': 'review', 'review_assessment': {
                       'contract': {'project_instruction_refs': [{'path': 'AGENTS.md', 'resolved_path': 'docs/AGENTS.md',
                           'link_chain': [{'path': 'AGENTS.md', 'target': 'docs/AGENTS.md', 'sha256': 'hash'}]}]},
                       'instruction_coverage': [{'path': 'AGENTS.md'}]}})]
        with tempfile.TemporaryDirectory() as directory:
            counts = self.inspect(Path(directory).resolve(), records)
            self.assertEqual(counts['managed_relative'], 11)
            self.assertEqual(counts['capture_git_provenance'], 2)
            self.assertEqual(counts['managed_origin_absolute'], 0)
            self.assertGreater(counts['relative_capture_paths'], 8)

    def test_managed_relative_paths_keep_family_traversal_and_nul_refusals(self):
        for value in ['icons/file', 'objects/../file', 'objects//file', 'objects/./file', 'objects/file\0bad', 'objects']:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    self.inspect(Path(directory).resolve(), [('attachment', attachment(value))])
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'wrong family'):
                self.inspect(Path(directory).resolve(), [('attachment', attachment('/owned/source/icons/file'))], '/owned/source')

    def test_file_urls_are_refused_in_text_history_and_json_dictionary_keys(self):
        for value in ['file:///outside/file', 'FILE:///outside/file', 'File:///outside/file', 'See FILE:///outside/file']:
            for table in ['records', 'commands', 'events']:
                with self.subTest(value=value, table=table), tempfile.TemporaryDirectory() as directory:
                    base = Path(directory).resolve();database = base / 'fixture.sqlite'
                    store_fixture(database, 2, [('ticket', {'id': 'ticket', 'body': value})] if table == 'records' else [])
                    if table != 'records':
                        with closing(sqlite3.connect(database)) as db, db:
                            db.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
                            if table == 'commands': db.execute('INSERT INTO commands VALUES (?,?,?,?)', ('fixture', 'command', 'digest', json.dumps({value: 'text'})))
                            else: db.execute('INSERT INTO events(id,actor,kind,occurred_at,data) VALUES (?,?,?,?,?)', ('event', 'fixture', 'fixture', 'now', json.dumps({'text': value})))
                    with self.assertRaisesRegex(ValueError, 'file URL'): harness.require_local_paths(database, base / 'data')
        with tempfile.TemporaryDirectory() as directory:
            self.inspect(Path(directory).resolve(), [('ticket', {'id': 'ticket', 'body': 'Explain ../ and ../../src; do not open them.', 'stage': 'acknowledged'})])

    def test_schema_zero_two_and_three_seeds_preserve_database_bytes(self):
        for schema in [0, 2, 3]:
            with self.subTest(schema=schema), tempfile.TemporaryDirectory() as directory:
                value = 'objects/file' if schema == 3 else '/owned/source/objects/file'
                source, destination, _ = self.fixture(Path(directory).resolve(), schema, [('attachment', attachment(value))])
                before = harness.sha(source / 'database.sqlite')
                seed = harness.snapshot_seed(source, destination)
                self.assertEqual(harness.sha(destination / 'checklist.sqlite'), before)
                self.assertEqual(harness.sha(source / 'database.sqlite'), before)
                category = 'managed_relative' if schema == 3 else 'managed_origin_absolute'
                self.assertEqual(seed['path_inspection'][category], 1)
                if schema:
                    self.assertEqual(json.loads((destination / 'checklist-store.identity.json').read_text())['schema_revision'], schema)

    def test_only_verified_origin_managed_paths_can_name_a_checklist_root(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();live = base / 'Checklist';slots = base / 'Checklist Test Instances'
            destination = slots / 'slot-1/data';origin = slots / 'slot-2/data'
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', live), patch.object(harness, 'BASE', slots):
                for number, (path, source_root, allowed) in enumerate([
                    (live / 'objects/file', live, True), (origin / 'objects/file', origin, True),
                    (live / 'objects/file', origin, False), (origin / 'objects/file', live, False),
                    (slots / 'arbitrary/objects/file', live, False), (live / 'icons/file', live, False)]):
                    database = base / f'fixture-{number}.sqlite';store_fixture(database, 2, [('attachment', attachment(path))])
                    if allowed:
                        result = harness.require_local_paths(database, destination, source_root=source_root)
                        self.assertEqual(result['managed_origin_absolute'], 1)
                    else:
                        with self.assertRaises(ValueError): harness.require_local_paths(database, destination, source_root=source_root)

    def test_unproved_outside_managed_descriptor_is_never_inspected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();outside = base / 'outside/objects/file';outside.parent.mkdir(parents=True)
            outside.write_bytes(b'sentinel')
            database = base / 'fixture.sqlite';store_fixture(database, 2, [('attachment', attachment(outside))])
            before = (outside.read_bytes(), outside.stat())
            original_lstat, original_stat = os.lstat, os.stat
            def guard(function):
                def checked(path, *args, **kwargs):
                    self.assertNotEqual(Path(path), outside, str(path))
                    return function(path, *args, **kwargs)
                return checked
            with patch.object(os, 'lstat', side_effect=guard(original_lstat)), patch.object(os, 'stat', side_effect=guard(original_stat)):
                result = harness.require_local_paths(database, base / 'data', source_root='/some/origin')
            self.assertEqual(result['managed_unavailable_absolute'], 1)
            after = (outside.read_bytes(), outside.stat())
            self.assertEqual(before[0], after[0]);self.assertEqual(before[1].st_ino, after[1].st_ino)
            self.assertEqual(before[1].st_mtime_ns, after[1].st_mtime_ns)

    def test_project_bindings_are_counted_and_checklist_roots_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();live = base / 'Checklist';slots = base / 'Checklist Test Instances';project = base / 'project'
            records = [('project', {'id': 'project', 'root_path': str(project)}),
                       ('session', {'id': 'session', 'workspace': str(project)}),
                       ('session', {'id': 'absent-workspace', 'workspace': ''}),
                       ('attempt', {'id': 'attempt', 'file_scopes': [{'path': str(project / 'README.md'), 'canonical_key': str(project / 'README.md').lower()}]}),
                       ('source_capture', {'id': 'capture', 'source_root': str(project), 'additional_paths': ['extras']}),
                       ('request', {'id': 'request', 'responses': [{'files': [{'paths': [str(project / 'README.md')], 'path_sha256': {str(project / 'README.md'): 'hash'}}]}]})]
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', live), patch.object(harness, 'BASE', slots):
                self.assertEqual(self.inspect(base, records)['external_project_path_occurrences'], 8)
                for number, path in enumerate([live, live / 'objects/file', slots, slots / 'slot-2/data/objects/file', Path(str(live).lower())]):
                    database = base / f'bad-{number}.sqlite';store_fixture(database, 2, [('project', {'id': 'project', 'root_path': str(path)})])
                    with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                        harness.require_local_paths(database, slots / 'slot-1/data', source_root=live)
                alias = base / 'alias';alias.symlink_to(live)
                database = base / 'alias.sqlite';store_fixture(database, 2, [('project', {'id': 'project', 'root_path': str(alias)})])
                with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                    harness.require_local_paths(database, slots / 'slot-1/data')

    def test_recursive_bindings_refuse_ancestors_and_descendants_of_each_checklist_root(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();live = base / 'live';default = base / 'default';slots = base / 'slots'
            for root in [live, default, slots]: root.mkdir()
            records = [lambda value: ('project', {'id': 'project', 'root_path': value}),
                       lambda value: ('source_capture', {'id': 'capture', 'source_root': value}),
                       lambda value: ('session', {'id': 'session', 'workspace': value}),
                       lambda value: ('session', {'id': 'session', 'workspace_path': value}),
                       lambda value: ('attempt', {'id': 'attempt', 'file_scopes': [{'path': value}]}),
                       lambda value: ('attempt', {'id': 'attempt', 'file_scopes': [{'canonical_key': value}]}),
                       lambda value: ('batch', {'id': 'batch', 'members': [{'file_scopes': [{'path': value}]}]}),
                       lambda value: ('fixture', {'id': 'fixture', 'additional_paths': [value]})]
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', default), patch.object(harness, 'BASE', slots):
                for root_number, root in enumerate([live, default, slots]):
                    for value_number, value in enumerate([root.parent, root, root / 'objects/missing']):
                        for number, record in enumerate(records):
                            with self.subTest(root=root, value=value, record=number):
                                database = base / f'overlap-{root_number}-{value_number}-{number}.sqlite'
                                store_fixture(database, 2, [record(str(value))])
                                with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                                    harness.require_local_paths(database, slots / 'slot-1/data')

    def test_project_relative_additions_refuse_aliases_to_ancestors_and_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();project = base / 'project';project.mkdir()
            live = base / 'store-parent/Checklist';live.mkdir(parents=True)
            (project / 'alias').symlink_to(live.parent)
            with patch.object(harness, 'LIVE', live):
                for number, value in enumerate(['alias', 'alias/Checklist', 'alias/Checklist/objects/missing']):
                    for nested in [False, True]:
                        with self.subTest(value=value, nested=nested):
                            capture = {'id': 'capture', 'source_root': str(project), 'additional_paths': [value]}
                            record = ('manifest', {'id': 'manifest', 'evidence': {'source_capture': capture}}) if nested else ('source_capture', capture)
                            database = base / f'additional-alias-{number}-{nested}.sqlite';store_fixture(database, 2, [record])
                            with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                                harness.require_local_paths(database, base / 'slots/slot-1/data')

    def test_unicode_filesystem_aliases_refuse_roots_and_managed_values(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();parent = base / 'Caf\u00e9';live = parent / 'Checklist';live.mkdir(parents=True)
            alias_parent = base / unicodedata.normalize('NFD', parent.name)
            self.assertNotEqual(str(alias_parent).encode(), str(parent).encode())
            # APFS supplies the reviewer's real inode alias. On a normalization-
            # sensitive filesystem, missing suffix comparison still fails closed.
            if alias_parent.exists(): self.assertTrue(alias_parent.samefile(parent))
            slots = base / 'slots'
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', live), patch.object(harness, 'BASE', slots):
                for number, value in enumerate([alias_parent, alias_parent / 'Checklist', alias_parent / 'Checklist/missing']):
                    database = base / f'unicode-binding-{number}.sqlite';store_fixture(database, 2, [('project', {'id': 'project', 'root_path': str(value)})])
                    with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                        harness.require_local_paths(database, slots / 'slot-1/data')
                database = base / 'unicode-managed.sqlite'
                store_fixture(database, 2, [('attachment', attachment(alias_parent / 'Checklist/objects/missing'))])
                with self.assertRaisesRegex(ValueError, 'different Checklist data root'):
                    harness.require_local_paths(database, slots / 'slot-1/data', source_root=base / 'other-origin')
                result = harness.require_local_paths(database, slots / 'slot-1/data', source_root=live)
                self.assertEqual(result['managed_origin_absolute'], 1)
                database = base / 'unicode-wrong-family.sqlite'
                store_fixture(database, 2, [('attachment', attachment(alias_parent / 'Checklist/icons/missing'))])
                with self.assertRaisesRegex(ValueError, 'wrong family'):
                    harness.require_local_paths(database, slots / 'slot-1/data', source_root=live)

    def test_symlink_and_system_directory_aliases_preserve_managed_origin_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();origin = base / 'origin';origin.mkdir();slots = base / 'slots'
            foreign = slots / 'slot-2/data';(foreign / 'objects').mkdir(parents=True)
            (base / 'origin-alias').symlink_to(origin)
            (origin / 'objects').mkdir()
            database = base / 'origin-alias.sqlite';store_fixture(database, 2, [('attachment', attachment(base / 'origin-alias/objects/missing'))])
            with patch.object(harness, 'BASE', slots):
                self.assertEqual(harness.require_local_paths(database, slots / 'slot-1/data', source_root=origin)['managed_origin_absolute'], 1)
                (origin / 'objects').rmdir();(origin / 'objects').symlink_to(foreign / 'objects')
                with self.assertRaisesRegex(ValueError, 'different Checklist data root'):
                    harness.require_local_paths(database, slots / 'slot-1/data', source_root=origin)
            for number, (alias, physical) in enumerate([('/tmp', '/private/tmp'), ('/var', '/private/var')]):
                if not Path(alias).exists() or not Path(physical).exists() or not Path(alias).samefile(physical): continue
                for managed in [False, True]:
                    with self.subTest(alias=alias, managed=managed):
                        record = ('attachment', attachment(Path(alias) / 'objects/cl170-nonexistent')) if managed else ('project', {'id': 'project', 'root_path': alias})
                        database = base / f'system-alias-{number}-{managed}.sqlite';store_fixture(database, 2, [record])
                        with patch.object(harness, 'LIVE', Path(physical)), self.assertRaises(ValueError):
                            harness.require_local_paths(database, slots / 'slot-1/data', source_root=base / 'unrelated')

    def test_missing_case_and_nfd_binding_paths_use_cl169_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();slots = base / 'slots'
            for number, (live, alias) in enumerate([(base / 'Checklist', base / 'checklist'),
                    (base / 'Missing-Caf\u00e9', base / unicodedata.normalize('NFD', 'Missing-Caf\u00e9')),
                    (base / 'Stra\u00dfe/Child', base / 'STRASSE/child')]):
                database = base / f'folded-binding-{number}.sqlite';store_fixture(database, 2, [('project', {'id': 'project', 'root_path': str(alias)})])
                with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', live), patch.object(harness, 'BASE', slots), \
                     patch.object(harness, 'checklist_root_overlap', wraps=harness.checklist_root_overlap) as overlap:
                    with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                        harness.require_local_paths(database, slots / 'slot-1/data')
                    overlap.assert_any_call(alias)

    def test_binding_refusals_call_the_shared_overlap_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();live = base / 'Checklist';live.mkdir();slots = base / 'slots'
            values = [('project', {'id': 'project', 'root_path': str(base)}),
                      ('attachment', dict(attachment(live / 'objects/missing'), mode='external_reference')),
                      ('request', {'id': 'request', 'responses': [{'files': [{'paths': [str(live / 'objects/missing')]}]}]})]
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'BASE', slots):
                for number, record in enumerate(values):
                    database = base / f'shared-binding-{number}.sqlite';store_fixture(database, 2, [record])
                    with patch.object(harness, 'checklist_root_overlap', wraps=harness.checklist_root_overlap) as overlap, \
                         patch.object(harness, 'paths_overlap', wraps=harness.paths_overlap) as paths_overlap:
                        with self.assertRaisesRegex(ValueError, 'project reference into a Checklist data root'):
                            harness.require_local_paths(database, slots / 'slot-1/data')
                        overlap.assert_any_call(base if number == 0 else live / 'objects/missing')
                        self.assertTrue(paths_overlap.called)

    def test_normal_outside_roots_and_regular_file_bindings_remain_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();live = base / 'Checklist';live.mkdir();slots = base / 'slots'
            project = base / 'project';project.mkdir();leaf = base / 'README.md';leaf.write_text('outside')
            records = [('project', {'id': 'project', 'root_path': str(project)}),
                       ('attachment', dict(attachment(leaf), mode='external_reference')),
                       ('request', {'id': 'request', 'responses': [{'files': [{'paths': [str(leaf)], 'path_sha256': {str(leaf): 'hash'}}]}]})]
            with patch.object(harness, 'LIVE', live), patch.object(harness, 'DEFAULT_LIVE', live), patch.object(harness, 'BASE', slots):
                self.assertEqual(self.inspect(base, records)['external_project_path_occurrences'], 4)
                database = base / 'normalization-sibling.sqlite'
                store_fixture(database, 2, [('project', {'id': 'project', 'root_path': str(base / 'Checklist-elsewhere')} )])
                self.assertEqual(harness.require_local_paths(database, slots / 'slot-1/data')['external_project_path_occurrences'], 1)

    def test_path_comparison_failure_refuses_the_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            with patch.object(harness, 'LIVE', base / 'Checklist'), patch.object(harness, 'checklist_root_overlap', side_effect=OSError('unavailable')):
                with self.assertRaisesRegex(ValueError, 'filesystem ancestry cannot be safely compared'):
                    self.inspect(base, [('project', {'id': 'project', 'root_path': str(base / 'outside')})])

    def test_inert_command_and_event_paths_are_not_file_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();database = base / 'fixture.sqlite';store_fixture(database, 2)
            payload = {'path': str(harness.LIVE / 'objects/file'), 'workspace': '/project',
                       'files': [{'path': 'src/file'}], 'root_path': '../../old'}
            with closing(sqlite3.connect(database)) as db, db:
                db.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
                db.execute('INSERT INTO commands VALUES (?,?,?,?)', ('fixture', 'command', 'digest', json.dumps(payload)))
                db.execute('INSERT INTO events(id,actor,kind,occurred_at,data) VALUES (?,?,?,?,?)', ('event', 'fixture', 'fixture', 'now', json.dumps(payload)))
            before = harness.sha(database)
            result = harness.require_local_paths(database, base / 'data')
            self.assertEqual(result['inert_history_path_occurrences'], 8)
            self.assertEqual(harness.sha(database), before)

    def test_local_stored_path_cannot_follow_a_symlink_in_pending_or_published_data(self):
        for relative in [False, True, 'origin', 'destination-alias']:
            with tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve();destination = base / 'data';outside = base / 'outside';outside.mkdir()
                alias = base / 'destination-alias';alias.symlink_to(destination)
                for name in ['.seed-data', 'data']:
                    copy = base / name;copy.mkdir();(copy / 'objects').symlink_to(outside)
                    database = copy / 'checklist.sqlite'
                    store_fixture(database, 2, [('attachment', attachment('/origin/objects/file' if relative == 'origin' else alias / 'objects/file' if relative == 'destination-alias' else 'objects/file' if relative else destination / 'objects/file'))])
                    with self.assertRaisesRegex(ValueError, 'symlink'):
                        harness.require_local_paths(database, destination, source_root='/origin')

    def test_source_additional_paths_are_project_relative_and_refuse_checklist_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();project = base / 'project';project.mkdir();live = base / 'live';live.mkdir()
            (project / 'alias').symlink_to(live)
            for number, value in enumerate(['../live/file', '/outside/file', 'alias/file']):
                database = base / f'additional-{number}.sqlite'
                store_fixture(database, 2, [('source_capture', {'id': 'capture', 'source_root': str(project), 'additional_paths': [value]})])
                with patch.object(harness, 'LIVE', live), self.assertRaises(ValueError):
                    harness.require_local_paths(database, base / 'data')
            database = base / 'nested.sqlite'
            store_fixture(database, 2, [('manifest', {'id': 'manifest', 'evidence': {'source_capture': {'source_root': str(project), 'additional_paths': ['src/file']}}})])
            self.assertEqual(harness.require_local_paths(database, base / 'data')['external_project_path_occurrences'], 2)

    def test_captured_links_cannot_escape_the_captured_tree(self):
        for value in ['../../outside', '/outside', 'file\0bad']:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    self.inspect(Path(directory).resolve(), [('source_capture', {'id': 'capture', 'files': [{'kind': 'symlink', 'path': 'dir/link', 'target': value}]})])

    def test_unknown_external_references_are_still_refused(self):
        for kind, record in [('project', {'id': 'project', 'icon': {'path': '/outside/icons/icon.png'}}),
                             ('source_capture', {'id': 'capture', 'root': '/outside/source-captures/one/source'})]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(ValueError, 'stored absolute path outside'):
                    self.inspect(Path(directory).resolve(), [(kind, record)])

    def test_slot_copy_inspection_includes_committed_wal_for_allowed_and_refused_paths(self):
        for bad in [False, True]:
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
                source = harness.checked(2);source['data'].mkdir(parents=True)
                database = source['data'] / 'checklist.sqlite';store_fixture(database, 2)
                harness.save(source, {'slot': 2, 'build_id': 'fixture'})
                connection = sqlite3.connect(database)
                connection.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
                try:
                    connection.execute('PRAGMA journal_mode=WAL');connection.execute('PRAGMA wal_autocheckpoint=0')
                    value = harness.BASE / ('slot-3' if bad else 'slot-2') / 'data/objects/file'
                    connection.execute('INSERT INTO records VALUES (?,?,?,?,?)', ('attachment', 'project', 'attachment', 1, json.dumps(attachment(value))));connection.commit()
                    destination = harness.BASE / 'copy';destination.mkdir()
                    with patch.object(harness, 'stopped'):
                        if bad:
                            with self.assertRaisesRegex(ValueError, 'different Checklist data root'): harness.slot_seed(source, destination)
                        else:
                            result = harness.slot_seed(source, destination)
                            self.assertEqual(result['path_inspection']['managed_origin_absolute'], 1)
                finally: connection.close()

    def test_refused_create_publishes_neither_data_nor_app_and_cannot_start(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            base = harness.BASE;source, _, _ = self.fixture(base, 2, [('attachment', attachment('../../external/objects/file'))])
            p = harness.checked(1)
            manifest = {'build_id': 'fixture', 'source_fingerprint': 'fingerprint'}
            args = SimpleNamespace(slot=1, replace=False, seed='backup:' + str(source))
            with patch.object(harness, 'stopped'), patch.object(harness, 'stage_selection', return_value=(base, manifest)), patch.object(harness, 'sign_identity', return_value='-'), patch.object(harness, 'require_managed_path_support'), patch.object(harness, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'managed.path contract'): harness.create(args, p)
                self.assertFalse(p['data'].exists());self.assertFalse(p['bundle'].exists())
                self.assertEqual(harness.load(p)['mode'], 'refused')
                with self.assertRaisesRegex(ValueError, 'managed.path contract'): harness.start(SimpleNamespace(gui=False, slot=1), p)
                run.assert_not_called()

    def test_refused_seed_still_exposes_the_promotion_gate(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()):
            selected = {'slot': 1, 'build_id': 'build', 'source_fingerprint': 'fingerprint', 'stage_path': '/synthetic/stage',
                        'seed': {'kind': 'empty'}, 'checks': {'build_id': 'build', 'source_fingerprint': 'fingerprint', 'passed': True}}
            other = harness.checked(2);other['folder'].mkdir()
            harness.save(other, dict(selected, slot=2, seed={'kind': 'refused', 'reason': harness.RELOCATION_REQUIRED}))
            original_load = harness.load
            def load(p): return selected if p['folder'] == harness.checked(1)['folder'] else original_load(p)
            output = io.StringIO()
            with patch.object(harness, 'load', side_effect=load), patch.object(harness, 'bundle_check') as bundle, redirect_stdout(output):
                with self.assertRaisesRegex(ValueError, 'all gates must pass'):
                    harness.promote(SimpleNamespace(dry_run=True), harness.checked(1))
                bundle.assert_called_once_with(harness.checked(1), selected)
            self.assertIn('selected_build_check: PASS', output.getvalue())
            self.assertIn('live_snapshot_check_same_build: FAIL', output.getvalue())

    def test_schema_three_copy_accepts_inert_receipts_and_local_capture_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve()
            source, destination, manifest = self.fixture(base, 3)
            with closing(sqlite3.connect(source / 'database.sqlite')) as db, db:
                db.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
                for key, value in [
                    ('preupgrade_snapshot', {'path': str(harness.LIVE / 'backups/snapshot-old'), 'protected': True}),
                    ('backup-generation:old', {'state': 'complete', 'objects': [{'path': str(harness.LIVE / 'objects/file'), 'sha256': 'a' * 64, 'size': 7}]}),
                    ('managed-capture-paths-v3', [{'stored': str(harness.LIVE / 'source-captures/project/capture/source'), 'relative': 'source-captures/project/capture/source'}])]:
                    db.execute('INSERT INTO metadata VALUES (?,?)', (key, json.dumps(value)))
            manifest.update(databaseSHA256=harness.sha(source / 'database.sqlite'), databaseSize=(source / 'database.sqlite').stat().st_size)
            (source / 'manifest.json').write_text(json.dumps(manifest))
            seed = harness.snapshot_seed(source, destination)
            self.assertEqual(seed['path_inspection']['inert_metadata_path_occurrences'], 3)
            self.assertEqual(seed['path_inspection']['managed_relative'], 1)
            self.assertEqual(harness.sha(destination / 'checklist.sqlite'), manifest['databaseSHA256'])

    def test_capture_lookup_local_targets_and_unknown_metadata_keep_refusals(self):
        for number, (key, value) in enumerate([
            ('managed-capture-paths-v3', [{'stored': '/old/source-captures/project/capture/source', 'relative': str(harness.LIVE / 'source-captures/project/capture/source')}]),
            ('managed-capture-paths-v3', [{'stored': '/old/source-captures/project/capture/source', 'relative': 'source-captures/../outside'}]),
            ('managed-capture-paths-v3', [{'stored': '/old/source-captures/project/capture/source', 'relative': 'icons/wrong-family'}]),
            ('managed-capture-paths-v3', [{'stored': 'file:///old/source-captures/project/capture/source', 'relative': 'source-captures/project/capture/source'}]),
            ('unknown', {'path': str(harness.LIVE / 'objects/file')}),
            ('preupgrade_snapshot', {'path': 'file:///old/backups/snapshot'}),
            ('backup-generation:old', {'objects': [{'path': 'FILE:///old/objects/file'}]})]):
            with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve();database = base / 'fixture.sqlite';store_fixture(database, 3)
                with closing(sqlite3.connect(database)) as db, db:
                    db.create_collation('checklist_storage_v2', lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
                    db.execute('INSERT INTO metadata VALUES (?,?)', (key, json.dumps(value)))
                with self.assertRaises(ValueError): harness.require_local_paths(database, base / 'data', source_root='/owned/source')

    def test_old_staged_binary_cannot_start_a_relaxed_seed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();p = harness.paths(1)
            metadata = {'seed': {'kind': 'backup', 'source_root': str(harness.LIVE)}, 'mode': 'stopped', 'stage_path': str(base)}
            with patch.object(harness, 'load', return_value=metadata), patch.object(harness, 'bundle_check', return_value={'inputs': []}), patch.object(harness, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'predates.*managed.path contract'):
                    harness.start(SimpleNamespace(gui=False, slot=1), p)
                run.assert_not_called()

    def test_seed_requires_hash_bound_schema_three_migration_in_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();migration = base / 'source/Sources/ChecklistCore/SchemaMigrations.swift'
            migration.parent.mkdir(parents=True);migration.write_text('static var managedPathsLedger = "schema3"')
            manifest = {'inputs': [{'path': 'Sources/ChecklistCore/ManagedPaths.swift', 'sha256': 'resolver'},
                                   {'path': 'Sources/ChecklistCore/SchemaMigrations.swift', 'sha256': harness.sha(migration)}]}
            harness.require_managed_path_support(base, manifest)
            migration.write_text('schema2')
            with self.assertRaisesRegex(ValueError, 'verified schema-3'): harness.require_managed_path_support(base, manifest)
            manifest['inputs'][1]['sha256'] = harness.sha(migration)
            with self.assertRaisesRegex(ValueError, 'verified schema-3'): harness.require_managed_path_support(base, manifest)


class LiveRootTests(unittest.TestCase):
    def test_checked_refuses_another_slots_aliased_root(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory).resolve()
            with patch.object(harness, 'BASE', fixture / 'instances'), patch.object(harness, 'LIVE', fixture / 'live'):
                first, second = harness.paths(1), harness.paths(2)
                first['data'].mkdir(parents=True); second['folder'].mkdir()
                second['data'].symlink_to(first['data'])
                with self.assertRaisesRegex(ValueError, 'Checklist root slot-2'): harness.checked(1)
                with self.assertRaisesRegex(ValueError, 'Checklist root slot-1'): harness.checked(2)

    def test_checklist_root_overlap_labels_and_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory).resolve()
            with patch.object(harness, 'BASE', fixture / 'Café/Test Instances'), patch.object(harness, 'LIVE', fixture / 'Live'):
                harness.LIVE.mkdir()
                for number in range(1, 5): harness.paths(number)['data'].mkdir(parents=True)
                self.assertEqual(harness.checklist_root_overlap(harness.LIVE), 'live')
                for number in range(1, 5):
                    for key in ['folder', 'data']:
                        p = harness.paths(number)[key]
                        self.assertEqual(harness.checklist_root_overlap(p), f'slot-{number}')
                        self.assertEqual(harness.checklist_root_overlap(p, exclude=(f'slot-{number}',)), 'test-base')
                        self.assertIsNone(harness.checklist_root_overlap(p, exclude=(f'slot-{number}', 'test-base')))
                self.assertEqual(harness.checklist_root_overlap(harness.BASE / 'other'), 'test-base')
                self.assertIsNone(harness.checklist_root_overlap(fixture / 'unrelated'))
                with patch.object(harness, 'LIVE', harness.paths(1)['data']):
                    self.assertEqual(harness.checklist_root_overlap(harness.paths(1)['data']), 'live')
                    self.assertEqual(harness.checklist_root_overlap(harness.paths(1)['data'], exclude=('live',)), 'slot-1')

    def test_slot_commands_refuse_folded_live_aliases_before_actions(self):
        commands = [['create', '--replace'], ['create', '--seed', 'slot:2'], ['start'], ['stop'],
                    ['destroy'], ['check'], ['promote'], ['promote', '--dry-run'], ['status']]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / 'Café/Library/Application Support/Checklist Test Instances'
            data = base / 'slot-1/data'; data.mkdir(parents=True)
            variants = [Path(str(data).lower()), Path(unicodedata.normalize('NFD', str(data))),
                        Path(unicodedata.normalize('NFD', str(data).lower())) / 'FÛTURE/child']
            for live in variants:
                for command in commands:
                    with self.subTest(live=live, command=command), ExitStack() as stack:
                        stack.enter_context(patch.object(harness, 'BASE', base))
                        stack.enter_context(patch.object(harness, 'LIVE', live))
                        stack.enter_context(patch.object(sys, 'argv', ['test_instances.py', *command, '--slot', '1']))
                        actions = [stack.enter_context(patch.object(harness, name))
                                   for name in ['locked', 'run', 'load', 'save', 'trash', 'processes', 'launch_state', 'stage_selection', 'slot_seed']]
                        with self.assertRaisesRegex(ValueError, 'effective live root'): harness.checked(1)
                        with self.assertRaisesRegex(ValueError, 'effective live root'): harness.main()
                        for action in actions: action.assert_not_called()
                        self.assertTrue(data.is_dir())

    def test_shared_path_overlap_vectors(self):
        table = json.loads((harness.REPO / 'Tests/Fixtures/path-overlap-vectors.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for path in table['directories']: (fixture / path).mkdir(parents=True, exist_ok=True)
            for link in table['symlinks']: (fixture / link['path']).symlink_to(link['target'])
            missing = 'checklist-overlap-' + fixture.name
            def path(value): return fixture / value.replace('{missing}', missing)
            for vector in table['vectors']:
                with self.subTest(vector=vector['id']):
                    if vector.get('requires_firmlink') and not Path('/System/Volumes/Data/Users').exists():
                        self.skipTest('/System/Volumes/Data/Users firmlink alias is absent on this machine.')
                    a, b = path(vector['a']), path(vector['b'])
                    self.assertEqual(harness.paths_overlap(a, b), vector['overlap'])
                    self.assertEqual(harness.paths_overlap(b, a), vector['overlap'])

    def overlaps(self, base, number=1):
        folder = base / f'slot-{number}'
        alias = base.parent / f'live-alias-{number}'
        alias.symlink_to(folder / 'data', target_is_directory=True)
        return [base.parent, base, folder, folder / 'data', folder / 'data/nested', folder / 'other',
                folder / 'data/../data', alias, alias / 'nested']

    def test_checked_reviewer_probe_refuses_every_canonical_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / 'Library/Application Support/Checklist Test Instances'
            for number in range(1, 5):
                (base / f'slot-{number}/data').mkdir(parents=True)
                for live in self.overlaps(base, number):
                    environment = {'CHECKLIST_DATA_ROOT': str(live)}
                    with self.subTest(slot=number, live=live), patch.object(harness, 'BASE', base), \
                         patch.object(harness, 'LIVE', harness.live_root(environment)):
                        with self.assertRaisesRegex(ValueError, 'effective live root'): harness.checked(number)

    def test_slot_subcommands_refuse_overlap_before_any_action(self):
        commands = [['create', '--replace'], ['create', '--seed', 'slot:2'], ['start'], ['stop'],
                    ['destroy'], ['check'], ['promote'], ['promote', '--dry-run'], ['status']]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / 'Library/Application Support/Checklist Test Instances'
            data = base / 'slot-1/data'; data.mkdir(parents=True)
            (data / 'live-sentinel').write_bytes(b'never move or modify')
            (data.parent / 'slot.json').write_text(json.dumps({'slot': 1}))
            for live in self.overlaps(base):
                for command in commands:
                    with self.subTest(live=live, command=command), ExitStack() as stack:
                        stack.enter_context(patch.object(harness, 'BASE', base))
                        stack.enter_context(patch.object(harness, 'LIVE', live))
                        stack.enter_context(patch.object(sys, 'argv', ['test_instances.py', *command, '--slot', '1']))
                        actions = [stack.enter_context(patch.object(harness, name))
                                   for name in ['run', 'load', 'save', 'trash', 'processes', 'launch_state', 'stage_selection', 'slot_seed']]
                        with self.assertRaisesRegex(ValueError, 'effective live root'): harness.main()
                        for action in actions: action.assert_not_called()
                        self.assertEqual((data / 'live-sentinel').read_bytes(), b'never move or modify')
                        self.assertEqual(json.loads((data.parent / 'slot.json').read_text()), {'slot': 1})
                        self.assertEqual(list(base.glob('.slot-*.lock')), [])

    def test_multislot_commands_preflight_before_locks_or_destination_changes(self):
        commands = [['create', '--slot', '1', '--replace', '--seed', 'slot:2'],
                    ['stop', '--all'], ['destroy', '--all'], ['promote', '--slot', '1'],
                    ['promote', '--slot', '1', '--dry-run']]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve() / 'Library/Application Support/Checklist Test Instances'
            (base / 'slot-2/data').mkdir(parents=True)
            for live in self.overlaps(base, 2):
                for command in commands:
                    with self.subTest(live=live, command=command), ExitStack() as stack:
                        stack.enter_context(patch.object(harness, 'BASE', base))
                        stack.enter_context(patch.object(harness, 'LIVE', live))
                        stack.enter_context(patch.object(sys, 'argv', ['test_instances.py', *command]))
                        locks = stack.enter_context(patch.object(harness, 'locked'))
                        actions = [stack.enter_context(patch.object(harness, name))
                                   for name in ['create', 'stop', 'destroy', 'promote']]
                        with self.assertRaisesRegex(ValueError, 'effective live root'): harness.main()
                        locks.assert_not_called()
                        for action in actions: action.assert_not_called()
                        self.assertFalse((base / 'slot-1').exists())

    def test_component_siblings_remain_admitted(self):
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory).resolve() / 'Library/Application Support'
            base = support / 'Checklist Test Instances'
            for live in [support / 'Checklist', support / 'Checklist Test Instances2', base / 'slot-10/data']:
                with self.subTest(live=live), patch.object(harness, 'BASE', base), patch.object(harness, 'LIVE', live):
                    self.assertEqual(harness.checked(1), harness.paths(1))
                    with harness.locked(1): self.assertTrue((base / '.slot-1.lock').exists())
                    self.assertFalse((base / '.slot-1.lock').exists())

    def test_override_and_empty_default_match_service_semantics(self):
        self.assertEqual(harness.live_root({}), harness.DEFAULT_LIVE)
        self.assertEqual(harness.live_root({'CHECKLIST_DATA_ROOT': ''}), harness.DEFAULT_LIVE)
        self.assertEqual(harness.live_root({'CHECKLIST_DATA_ROOT': '/custom/live'}), Path('/custom/live'))
        self.assertEqual(harness.paths(1)['data'], harness.BASE / 'slot-1/data')

    def test_parent_aliases_match_store_bootstrap_but_final_entry_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();real = base / 'real';real.mkdir()
            alias = base / 'alias';alias.symlink_to(real)
            self.assertEqual(harness.live_root({'CHECKLIST_DATA_ROOT': str(alias / 'live')}), real / 'live')
            (real / 'live').symlink_to(base / 'another-store')
            self.assertEqual(harness.live_root({'CHECKLIST_DATA_ROOT': str(alias / 'live')}), real / 'live')

    def test_custom_live_root_controls_lookup_restriction_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            custom = Path(directory).resolve() / 'configured-live'
            snapshot = custom / 'backups/snapshot-fixture';snapshot.mkdir(parents=True)
            (snapshot / 'manifest.json').write_text('{}')
            with patch.object(harness, 'LIVE', custom):
                self.assertEqual(harness.latest_backup(), snapshot)
                self.assertTrue(harness.is_live_snapshot(snapshot, str(custom)))
                self.assertFalse(harness.is_live_snapshot(harness.DEFAULT_LIVE / 'backups/snapshot-old', str(harness.DEFAULT_LIVE)))
                self.assertFalse(harness.is_live_snapshot(snapshot, str(harness.DEFAULT_LIVE)))
                with self.assertRaisesRegex(ValueError, 'Only completed backups'): harness.snapshot_seed(custom / 'objects', Path('unused'))


class InstalledVerificationTests(unittest.TestCase):
    def status(self):
        return {'data': {'name': 'Checklist', 'version': '0.1.0', 'capabilities': ['durable_store']}}

    def test_zero_exit_recovery_unavailable_error_and_malformed_status_are_failures(self):
        target = Path('/synthetic/Checklist.app');paths = [str(target / 'Contents/MacOS/ChecklistApp')]
        for payload in [dict(self.status(), error={}), {'data': dict(self.status()['data'], state='recovery_required')},
                        {'data': dict(self.status()['data'], state='unavailable')}, {'data': {'error': 'failure'}}, {}, None]:
            with self.subTest(payload=payload):
                response = subprocess.CompletedProcess([], 0, stdout=json.dumps(payload))
                with self.assertRaises(ValueError): verify_install.verify(target, paths, lambda *a, **k: response)
        for response in [subprocess.CompletedProcess([], 0, stdout='not json'), subprocess.CompletedProcess([], 1, stdout=json.dumps(self.status()))]:
            with self.assertRaises(ValueError): verify_install.verify(target, paths, lambda *a, **k: response)

    def test_exact_installed_process_and_healthy_service_are_both_required(self):
        target = Path('/Applications/Checklist.app')
        with patch.object(verify_install.subprocess, 'run') as run:
            with self.assertRaises(ValueError): verify_install.verify(target, ['/test-slot/Checklist Test 1.app/Contents/MacOS/ChecklistApp'], run)
            run.assert_not_called()
        response = subprocess.CompletedProcess([], 0, stdout=json.dumps(self.status()))
        result = verify_install.verify(target, [str(target / 'Contents/MacOS/ChecklistApp')], lambda *a, **k: response)
        self.assertEqual(result['service_state'], 'healthy')

    def test_actual_installer_dispatch_preserves_previous_bundle_and_propagates_failure(self):
        # Execute only the actual read-only verification tail, never install/quiesce.
        script = (harness.REPO / 'script/build_and_run.sh').read_text()
        start = script.index('# Installed verification is mandatory')
        end = script.index('\nif [ "$HAD_PREVIOUS" = 1 ]; then echo "Previous bundle retained', start)
        block = script[start:end]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();binary = base / 'bin';binary.mkdir()
            stub = binary / 'python3'
            stub.write_text('#!' + sys.executable + '\n' + """import json,os,sys
with open(os.environ['VERIFY_TRACE'],'a') as trace: trace.write(json.dumps(sys.argv[1:])+'\\n')
raise SystemExit(int(os.environ['VERIFY_EXIT']))
""")
            stub.chmod(0o755);sleep = binary / 'sleep';sleep.write_text('#!/bin/sh\nexit 0\n');sleep.chmod(0o755)
            previous = base / 'previous.app';previous.mkdir();trace = base / 'trace.jsonl'
            for mode, code in [('--verify', 0), ('--install-stage', 0), ('--verify', 1), ('--install-stage', 1), ('--install', 1)]:
                trace.write_text('')
                environment = dict(os.environ, MODE=mode, ROOT_DIR=str(harness.REPO), DEST=str(base / 'installed.app'),
                                   HAD_PREVIOUS='1', PREVIOUS=str(previous), VERIFY_TRACE=str(trace), VERIFY_EXIT=str(code), PATH=str(binary) + os.pathsep + os.environ['PATH'])
                result = subprocess.run(['bash', '-c', 'set -euo pipefail\n' + block], env=environment, text=True, capture_output=True)
                self.assertTrue(previous.is_dir())
                calls = trace.read_text().splitlines()
                self.assertEqual(len(calls), 0 if mode == '--install' else 1)
                if mode != '--install' and code:
                    self.assertEqual(result.returncode, 1);self.assertIn(str(previous), result.stderr)
                    self.assertNotIn('Installed ' + str(base / 'installed.app'), result.stdout)
                else: self.assertEqual(result.returncode, 0, result.stderr)

    def test_verifier_invocation_failure_is_fatal_in_both_required_modes(self):
        script = (harness.REPO / 'script/build_and_run.sh').read_text()
        block = script[script.index('# Installed verification is mandatory'):]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve();previous = base / 'previous.app';previous.mkdir()
            for mode in ['--verify', '--install-stage']:
                with self.subTest(mode=mode):
                    environment = dict(os.environ, MODE=mode, ROOT_DIR=str(harness.REPO), DEST=str(base / 'installed.app'),
                                       HAD_PREVIOUS='1', PREVIOUS=str(previous))
                    code = 'set -euo pipefail\npython3() { return 70; }\nsleep() { :; }\n' + block
                    result = subprocess.run(['bash', '-c', code], env=environment, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(previous.is_dir());self.assertIn(str(previous), result.stderr)
                    self.assertNotIn('Installed ' + str(base / 'installed.app'), result.stdout)

    def test_promotion_never_reports_success_after_installed_verification_failure(self):
        selected = {'build_id': 'build', 'source_fingerprint': 'fingerprint', 'stage_path': '/synthetic/stage', 'seed': {'kind': 'empty'}}
        with tempfile.TemporaryDirectory() as directory, patch.object(harness, 'BASE', Path(directory).resolve()), \
             patch.object(harness, 'load', return_value=selected), patch.object(harness, 'bundle_check'), \
             patch.object(harness, 'promotion_gates', return_value={'selected_build_check': True, 'live_snapshot_check_same_build': True}), \
             patch.object(harness.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'stub installed verification')):
            output = io.StringIO()
            with redirect_stdout(output), self.assertRaises(subprocess.CalledProcessError):
                harness.promote(SimpleNamespace(dry_run=False), harness.checked(1))
            self.assertNotIn('Promoted build', output.getvalue())


if __name__ == '__main__':
    unittest.main()
