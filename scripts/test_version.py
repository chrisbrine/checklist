"""Version arithmetic, release preflight and exact bundle/service identity; no live writes."""
import contextlib
import io
import json
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

    def test_interrupted_allocation_skips_reserved_version_and_ordinal(self):
        for initial in [None, {'production_version': '0.0.1', 'version': '0.0.1.3', 'build_number': 120}]:
            with self.subTest(initial=initial), tempfile.TemporaryDirectory() as folder:
                root = Path(folder); (root/'VERSION').write_text('0.0.1\n')
                build = root/'build'; build.mkdir()
                (build/'build-ordinal').write_text('120\n' if initial else '118\n')
                if initial: (build/'version-state.json').write_text(json.dumps(initial))
                replace = Path.replace
                def interrupted(path, target):
                    if target.name == 'build-ordinal': raise OSError('synthetic interruption')
                    return replace(path, target)
                with patch.object(Path, 'replace', interrupted):
                    with self.assertRaisesRegex(OSError, 'synthetic interruption'):
                        version.allocate(root, build, root/'absent.app')
                reserved = json.loads((build/'version-state.json').read_text())
                resumed = version.allocate(root, build, root/'absent.app')
                self.assertEqual(resumed['build_number'], reserved['build_number'] + 1)
                self.assertEqual(int(resumed['version'].rsplit('.', 1)[1]), int(reserved['version'].rsplit('.', 1)[1]) + 1)

    def test_invalid_inputs_and_exhaustion_refuse(self):
        for base in ['1.2', '0.01.1', '0.0.-1', '0.0.1.1', 'private']:
            with self.assertRaises(ValueError): version.next_version(base)
        for number in [-1, True, 'unknown', version.MAX_ORDINAL, version.MAX_ORDINAL + 1]:
            with self.assertRaises(ValueError): version.next_version('0.0.1', number)

    def test_allocator_reads_installed_plist_and_writes_durable_local_state(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);(root/'VERSION').write_text('0.0.1\n')
            build=root/'build';build.mkdir()
            installed=root/'Installed.app';contents=installed/'Contents';contents.mkdir(parents=True)
            (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '117'}))
            first=version.allocate(root, build, installed);second=version.allocate(root, build, installed)
            self.assertEqual(first['version'],'0.0.1.1');self.assertEqual(second['version'],'0.0.1.2')
            self.assertEqual((build/'build-ordinal').read_text(),'119\n')
            self.assertEqual(json.loads((build/'version-state.json').read_text()),second)
            self.assertEqual((root/'VERSION').read_text(),'0.0.1\n')

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
