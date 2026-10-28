"""Version arithmetic, release preflight and exact bundle/service identity; no live writes."""
import contextlib
import io
import json
import os
import shutil
import time
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
import version
import verify_install


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.allocator = self.root / 'shared-allocator'
        environment = patch.dict(os.environ, CHECKLIST_BUILD_ALLOCATOR_DIR=str(self.allocator))
        environment.start()
        self.addCleanup(environment.stop)

    def checkout(self, name, base='0.0.1'):
        root = self.root / name
        root.mkdir()
        (root / 'VERSION').write_text(base + '\n')
        build = root / '.local/build'
        build.mkdir(parents=True)
        return root, build

    def installed(self, number=121, value='0.0.1.1'):
        bundle = self.root / 'Installed.app'
        contents = bundle / 'Contents'
        contents.mkdir(parents=True, exist_ok=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(
            {'CFBundleVersion': str(number), 'ChecklistVersion': value}))
        return bundle

    def test_local_scopes_never_open_shared_or_legacy_history(self):
        root, build = self.checkout('local')
        (build / 'version-state.json').write_text('invalid legacy history')
        for scope in ['measurement', 'test', 'private-copy']:
            with self.subTest(scope=scope), patch.object(version, 'allocate', side_effect=AssertionError('shared allocation')):
                info = version.stage_version(root, build, scope)
                self.assertEqual(info, {'production_version': '0.0.1', 'version': '0.0.1.0',
                                       'build_number': 0, 'build_scope': scope, 'installable': False})
        self.assertFalse(self.allocator.exists())
        with self.assertRaisesRegex(ValueError, 'Unknown build scope'):
            version.stage_version(root, build, 'typo')
        self.assertFalse(self.allocator.exists())

    def test_local_stages_between_installations_do_not_advance_shared_history(self):
        root, build = self.checkout('scoped')
        installed = self.installed()
        first = version.stage_version(root, build, installed=installed)
        before = (self.allocator / 'version-state.json').read_bytes()
        for scope in ['measurement', 'test', 'private-copy']:
            version.stage_version(root, build, scope)
            self.assertEqual((self.allocator / 'version-state.json').read_bytes(), before)
        second = version.stage_version(root, build, installed=installed)
        self.assertTrue(first['installable']);self.assertEqual(first['build_scope'], 'install')
        self.assertEqual((first['version'], second['version']), ('0.0.1.2', '0.0.1.3'))
        self.assertEqual((first['build_number'], second['build_number']), (122, 123))

    def test_mixed_concurrent_scopes_do_not_share_reservations_or_block_local_stages(self):
        installed = self.installed();processes = []
        version.allocator_directory(self.allocator)
        with (self.allocator / 'allocator.lock').open('a+b') as lock:
            version.fcntl.flock(lock, version.fcntl.LOCK_EX)
            for scope in ['install', 'measurement', 'install', 'test', 'private-copy']:
                root, build = self.checkout('mixed-' + str(len(processes)))
                code = "import json,sys;sys.path.insert(0,sys.argv[1]);import version;print(json.dumps(version.stage_version(sys.argv[2],sys.argv[3],sys.argv[4],installed=sys.argv[5])))"
                process = subprocess.Popen([sys.executable, '-c', code, str(Path(version.__file__).parent),
                                            str(root), str(build), scope, str(installed)],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                processes.append((scope, process))
                def cleanup(process=process):
                    if process.poll() is None: process.kill()
                    process.communicate()
                self.addCleanup(cleanup)
            for scope, process in processes:
                if scope == 'install': continue
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(json.loads(stdout)['build_number'], 0)
            self.assertFalse((self.allocator / 'version-state.json').exists())
        results = []
        for scope, process in processes:
            if scope != 'install': continue
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr);results.append(json.loads(stdout))
        self.assertEqual({item['version'] for item in results}, {'0.0.1.2', '0.0.1.3'})
        self.assertEqual({item['build_number'] for item in results}, {122, 123})

    def test_initial_series_starts_at_one_above_historical_ordinal(self):
        self.assertEqual(version.next_version('0.0.1', 5, {'build_number': 118}),
                         {'production_version': '0.0.1', 'version': '0.0.1.1', 'build_number': 119})

    def test_series_reset_preserves_monotonic_ordinal(self):
        info = version.next_version('0.0.2', 120, {'build_number': 118, 'version': '0.0.1.1'})
        self.assertEqual(info['version'], '0.0.2.1');self.assertEqual(info['build_number'], 121)
        info = version.next_version('0.0.2', 121, {'build_number': 140, 'version': '0.0.2.3'}, info)
        self.assertEqual(info['version'], '0.0.2.4');self.assertEqual(info['build_number'], 141)

    def test_local_staged_version_dominates_older_installed_build(self):
        info = version.next_version('0.0.1', 122, {'build_number': 119, 'version': '0.0.1.1'}, {'build_number': 122, 'version': '0.0.1.4'})
        self.assertEqual(info['version'], '0.0.1.5');self.assertEqual(info['build_number'], 123)

    def test_installed_same_series_advances_its_fourth_component(self):
        info = version.next_version('0.0.1', 120, {'build_number': 119, 'version': '0.0.1.1'})
        self.assertEqual(info['version'], '0.0.1.2')
        self.assertEqual(info['build_number'], 121)

    def test_concurrent_reservations_from_separate_checkout_processes(self):
        installed = self.installed()
        processes = []
        # Hold the actual shared lock until both independent helpers are poised
        # to reserve. Each child imports its own checkout's byte-identical helper.
        version.allocator_directory(self.allocator)
        with (self.allocator / 'allocator.lock').open('a+b') as lock:
            version.fcntl.flock(lock, version.fcntl.LOCK_EX)
            for name in ['a', 'b']:
                root, build = self.checkout(name)
                shutil.copyfile(version.__file__, root / 'version.py')
                ready = root / 'ready'
                code = "import json,sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);import version;Path(sys.argv[4]).touch();print(json.dumps(version.allocate(sys.argv[1],sys.argv[2],sys.argv[3])))"
                process = subprocess.Popen([sys.executable, '-c', code, str(root), str(build), str(installed), str(ready)],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                processes.append(process)
                def cleanup(process=process):
                    if process.poll() is None: process.kill()
                    process.communicate()
                self.addCleanup(cleanup)
            deadline = time.monotonic() + 10
            while not all((self.root / name / 'ready').exists() for name in ['a', 'b']):
                self.assertLess(time.monotonic(), deadline, 'children did not reach reservation barrier')
                time.sleep(.01)
            self.assertTrue(all(process.poll() is None for process in processes))
        results = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            results.append(json.loads(stdout))
        self.assertEqual({value['version'] for value in results}, {'0.0.1.2', '0.0.1.3'})
        self.assertEqual({value['build_number'] for value in results}, {122, 123})

    def test_crashed_reservation_is_not_reused_by_another_checkout(self):
        root, build = self.checkout('crashed')
        installed = self.installed()
        code = """import os,sys
sys.path.insert(0,sys.argv[1])
import version
sync = version.sync_directory
def crash(path):
    sync(path)
    if (path / 'version-state.json').exists(): os._exit(73)
version.sync_directory = crash
version.allocate(sys.argv[2], sys.argv[3], sys.argv[4])
"""
        result = subprocess.run([sys.executable, '-c', code, str(Path(version.__file__).parent), str(root), str(build), str(installed)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        other, other_build = self.checkout('next')
        resumed = version.allocate(other, other_build, installed)
        self.assertEqual(resumed['version'], '0.0.1.3')
        self.assertEqual(resumed['build_number'], 123)

    def test_abandoned_reservation_and_series_history_survive_other_checkouts(self):
        first, first_build = self.checkout('abandoned')
        reserved = version.allocate(first, first_build, self.root / 'absent.app')
        second, second_build = self.checkout('new-series', '0.0.2')
        new = version.allocate(second, second_build, self.root / 'absent.app')
        third, third_build = self.checkout('old-series')
        resumed = version.allocate(third, third_build, self.root / 'absent.app')
        self.assertEqual([reserved['version'], new['version'], resumed['version']],
                         ['0.0.1.1', '0.0.2.1', '0.0.1.2'])
        self.assertEqual([reserved['build_number'], new['build_number'], resumed['build_number']], [1, 2, 3])

    def test_migration_takes_each_maximum_and_preserves_legacy_files(self):
        root, build = self.checkout('legacy')
        (build / 'version-state.json').write_text(json.dumps(
            {'production_version': '0.0.1', 'version': '0.0.1.9', 'build_number': 125}))
        (build / 'build-ordinal').write_text('130\n')
        before = {path.name: path.read_bytes() for path in build.iterdir()}
        first = version.allocate(root, build, self.installed())
        self.assertEqual((first['version'], first['build_number']), ('0.0.1.10', 131))
        self.assertEqual({path.name: path.read_bytes() for path in build.iterdir()}, before)
        other, other_build = self.checkout('higher-legacy')
        (other_build / 'version-state.json').write_text(json.dumps(
            {'production_version': '0.0.1', 'version': '0.0.1.15', 'build_number': 120}))
        second = version.allocate(other, other_build, self.installed())
        self.assertEqual((second['version'], second['build_number']), ('0.0.1.16', 132))
        third = version.allocate(root, build, self.installed())
        self.assertEqual((third['version'], third['build_number']), ('0.0.1.17', 133))

    def test_installed_version_and_ordinal_are_independent_lower_bounds(self):
        root, build = self.checkout('bounds')
        first = version.allocate(root, build, self.installed(150, '0.0.1.20'))
        self.assertEqual((first['version'], first['build_number']), ('0.0.1.21', 151))
        second = version.allocate(root, build, self.installed(200, '0.0.1.2'))
        self.assertEqual((second['version'], second['build_number']), ('0.0.1.22', 201))
        before = (self.allocator / 'version-state.json').read_bytes()
        with self.assertRaisesRegex(ValueError, 'below the installed'):
            version.allocate(root, build, self.installed(201, '0.0.2.1'))
        self.assertEqual((self.allocator / 'version-state.json').read_bytes(), before)

    def test_failed_atomic_replace_preserves_history_and_retry_works(self):
        root, build = self.checkout('replace')
        installed = self.installed()
        version.allocate(root, build, installed)
        state = self.allocator / 'version-state.json'
        before = state.read_bytes()
        with patch.object(Path, 'replace', side_effect=OSError('synthetic replace failure')):
            with self.assertRaisesRegex(OSError, 'synthetic replace failure'):
                version.allocate(root, build, installed)
        self.assertEqual(state.read_bytes(), before)
        self.assertEqual(sorted(path.name for path in self.allocator.iterdir()), ['allocator.lock', 'version-state.json'])
        self.assertEqual(version.allocate(root, build, installed)['build_number'], 123)

    def test_corrupt_shared_history_refuses_without_reset(self):
        root, build = self.checkout('corrupt')
        self.allocator.mkdir()
        state = self.allocator / 'version-state.json'
        for content in ['{', '{}', '{"schema_version":1,"build_number":5,"series":{"0.0.1":-1}}']:
            state.write_text(content)
            with self.assertRaises(ValueError): version.allocate(root, build, self.root / 'absent.app')
            self.assertEqual(state.read_text(), content)

    def test_invalid_inputs_and_exhaustion_refuse(self):
        for base in ['1.2', '0.01.1', '0.0.-1', '0.0.1.1', 'private']:
            with self.assertRaises(ValueError): version.next_version(base)
        for number in [-1, True, 'unknown', version.MAX_ORDINAL, version.MAX_ORDINAL + 1]:
            with self.assertRaises(ValueError): version.next_version('0.0.1', number)

    def test_allocator_reads_installed_plist_and_writes_only_shared_state(self):
        root, build = self.checkout('durable')
        installed = self.installed(117, '0.0.1.0')
        first = version.allocate(root, build, installed)
        second = version.allocate(root, build, installed)
        self.assertEqual(first['version'], '0.0.1.1')
        self.assertEqual(second['version'], '0.0.1.2')
        self.assertEqual(json.loads((self.allocator / 'version-state.json').read_text()),
                         {'schema_version': 1, 'build_number': 119, 'series': {'0.0.1': 2}})
        self.assertEqual(list(build.iterdir()), [])
        self.assertEqual((root / 'VERSION').read_text(), '0.0.1\n')

    def test_explicit_temporary_allocator_overrides_environment(self):
        root, build = self.checkout('parameter')
        explicit = self.root / 'other-allocator'
        info = version.allocate(root, build, self.root / 'absent.app', allocator=explicit)
        self.assertEqual(info['version'], '0.0.1.1')
        self.assertTrue((explicit / 'version-state.json').is_file())
        self.assertFalse(self.allocator.exists())

    def test_historical_installed_ordinal_does_not_seed_series(self):
        root, build = self.checkout('historical')
        bundle = self.root / 'Historical.app'
        contents = bundle / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '118'}))
        info = version.allocate(root, build, bundle)
        self.assertEqual((info['version'], info['build_number']), ('0.0.1.1', 119))

    def test_open_count_pages_and_counts_all_unfinished_categories(self):
        pages = [{'state':'registered','projects':[{'id':'project'}]},
                 {'tasks':[{'status_category':v} for v in ['done','canceled','queued','active','review']], 'has_more': True, 'next_cursor':'opaque'},
                 {'tasks':[{'status_category':v} for v in ['blocked','parked']], 'has_more': False}]
        with patch.object(version,'call',side_effect=pages) as call:
            self.assertEqual(version.open_ticket_count('/synthetic', '/synthetic/cli'),5)
            self.assertEqual(call.call_args.args[2]['cursor'],'opaque')

    def test_release_dry_run_bumps_patch_and_leaves_files_and_refs_untouched(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            def git(*args): return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
            git('init','-b','main');git('config','user.name','Synthetic Test');git('config','user.email','synthetic@example.invalid')
            (root/'VERSION').write_text('0.0.1\n');git('add','VERSION');git('commit','-m','Synthetic baseline')
            head=git('rev-parse','HEAD');output=io.StringIO()
            with contextlib.redirect_stdout(output): self.assertEqual(version.release(root,0,dry_run=True),'0.0.2')
            self.assertIn('Open tickets: 0',output.getvalue());self.assertIn('tag v0.0.2',output.getvalue())
            self.assertEqual(git('rev-parse','HEAD'),head);self.assertEqual(git('tag'),'')
            self.assertEqual((root/'VERSION').read_text(),'0.0.1\n');self.assertEqual(git('status','--porcelain'),'')
            with self.assertRaisesRegex(ValueError,'zero open'): version.release(root,1,dry_run=True)
            (root/'dirty').write_text('synthetic')
            with self.assertRaisesRegex(ValueError,'clean checkout'): version.release(root,0,dry_run=True)


    def test_release_command_dry_run_reads_queue_and_leaves_repository_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)/'repo';root.mkdir()
            def git(*args): return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()
            git('init','-b','main');git('config','user.name','Synthetic Test');git('config','user.email','synthetic@example.invalid')
            (root/'VERSION').write_text('0.0.1\n');git('add','VERSION');git('commit','-m','Synthetic baseline')
            head=git('rev-parse','HEAD')
            cli=Path(folder)/'synthetic-cli'
            cli.write_text('#!/usr/bin/env python3\nimport json,sys\nmethod=sys.argv[2]\nprint(json.dumps({"data": {"state":"registered","projects":[{"id":"synthetic"}]} if method == "project_resolve" else {"tasks":[{"status_category":"done"},{"status_category":"canceled"}],"has_more":False}}))\n')
            cli.chmod(0o755)
            result=subprocess.run([sys.executable,str(Path(version.__file__)), '--root',str(root),'--release','--dry-run','--cli',str(cli)],capture_output=True,text=True,check=True)
            self.assertIn('Open tickets: 0',result.stdout);self.assertIn('tag v0.0.2',result.stdout)
            self.assertEqual(git('rev-parse','HEAD'),head);self.assertEqual(git('tag'),'')
            self.assertEqual(git('status','--porcelain'),'');self.assertEqual((root/'VERSION').read_text(),'0.0.1\n')


class BundleVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.bundle=self.root/'Checklist.app'
        (self.bundle/'Contents/Resources').mkdir(parents=True)
        (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({}))
        self.manifest={'version':'0.0.1.1','production_version':'0.0.1','build_number':118,'build_id':'0123456789abcdef','source_fingerprint':'0123456789abcdef'*4,'source_root':'/synthetic','configuration':'debug','toolchain':'synthetic','captured_at':'synthetic','signing_identity_sha256':'synthetic','signing_profile':'ad-hoc'}
        (self.root/'capture-manifest.json').write_text(json.dumps(self.manifest))
        version.stamp(self.root,self.bundle)

    def test_stamp_and_verify_keep_apple_fields_and_full_identity_consistent(self):
        info=version.verify_bundle(self.bundle)
        self.assertEqual(info['version'],'0.0.1.1')
        plist=plistlib.loads((self.bundle/'Contents/Info.plist').read_bytes())
        self.assertEqual(plist['CFBundleVersion'],'118');self.assertEqual(plist['CFBundleShortVersionString'],'0.0.1')
        for key in ['ChecklistVersion','ChecklistBuildID','CFBundleVersion','CFBundleShortVersionString']:
            changed=dict(plist);changed[key]='wrong'
            (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(changed))
            with self.assertRaises(ValueError): version.verify_bundle(self.bundle)
        (self.bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
        changed=dict(self.manifest,version='0.0.1.2')
        (self.bundle/'Contents/Resources/source-manifest.json').write_text(json.dumps(changed))
        with self.assertRaises(ValueError): version.verify_bundle(self.bundle)

    def test_local_bundle_scope_is_stamped_verified_and_refused_before_native_calls(self):
        for scope in ['measurement', 'test', 'private-copy']:
            with self.subTest(scope=scope):
                manifest = dict(self.manifest, version='0.0.1.0', build_number=0, build_scope=scope, installable=False)
                (self.root / 'capture-manifest.json').write_text(json.dumps(manifest))
                version.stamp(self.root, self.bundle)
                info = version.verify_bundle(self.bundle)
                self.assertEqual(info['build_scope'], scope);self.assertIs(info['installable'], False)
                with patch.object(verify_install, 'executable_paths') as paths, patch.object(verify_install.subprocess, 'run') as native:
                    with self.assertRaisesRegex(ValueError, 'not installable'):
                        verify_install.verify(self.bundle)
                    paths.assert_not_called();native.assert_not_called()
                # A changed mark cannot relabel a local bundle for installation.
                info['build_scope'] = 'install';info['installable'] = True
                (self.bundle / 'Contents/Resources/build-info.json').write_text(json.dumps(info))
                with self.assertRaisesRegex(ValueError, 'scope differs'):
                    version.verify_bundle(self.bundle)

    def test_installed_check_rejects_stale_service_version_id_or_ordinal(self):
        paths=[str(self.bundle/'Contents/MacOS/ChecklistApp')]
        body=dict(self.manifest,name='Checklist',capabilities=['durable_store'])
        for key in ['version','build_id','build_number']:
            changed=dict(body);changed[key]='stale'
            runner=lambda *a,**k: subprocess.CompletedProcess([],0,json.dumps({'data':changed}))
            with self.assertRaisesRegex(ValueError,'Running service differs'): verify_install.verify(self.bundle,paths,runner)
        runner=lambda *a,**k: subprocess.CompletedProcess([],0,json.dumps({'data':body}))
        self.assertEqual(verify_install.verify(self.bundle,paths,runner)['service_state'],'healthy')


if __name__ == '__main__': unittest.main()
