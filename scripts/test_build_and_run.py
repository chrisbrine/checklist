"""Build-helper checks with disposable inputs and fake native tools; no installation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
import build_input_inventory
import build_support
import verify_stage


class StableSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.capture = self.root / 'capture'
        self.source = self.capture / 'source'
        (self.source / 'script').mkdir(parents=True)
        shutil.copyfile(ROOT / 'script/build_input_inventory.py', self.source / 'script/build_input_inventory.py')
        (self.source / 'Package.swift').write_text('// pinned manifest\n')
        (self.source / 'Sources').mkdir()
        (self.source / 'Sources/value.swift').write_text('let value = 1\n')
        self.manifest = {'inputs': build_input_inventory.inventory(self.source)}
        (self.capture / 'capture-manifest.json').write_text(json.dumps(self.manifest))
        self.lane = self.root / 'lane/source'

    def test_sync_preserves_unchanged_timestamps_and_removes_stale_inputs(self):
        build_support.sync_source(self.capture, self.lane)
        value = self.lane / 'Sources/value.swift'
        os.utime(value, ns=(1_000_000_000, 1_000_000_000))
        unchanged_ctime = value.stat().st_ctime_ns
        (self.lane / 'Sources/stale.swift').write_text('stale')
        (self.lane / 'Package@swift-6.4.swift').write_text('alternate manifest')
        build_support.sync_source(self.capture, self.lane)
        self.assertEqual(value.stat().st_mtime_ns, 1_000_000_000)
        self.assertEqual(value.stat().st_ctime_ns, unchanged_ctime)
        self.assertFalse((self.lane / 'Sources/stale.swift').exists())
        self.assertFalse((self.lane / 'Package@swift-6.4.swift').exists())
        build_support.verify_source(self.capture, self.lane)

    def test_modified_missing_extra_and_symlink_inputs_are_refused(self):
        for mutation in ['modified', 'missing', 'extra', 'symlink']:
            with self.subTest(mutation=mutation):
                build_support.sync_source(self.capture, self.lane)
                value = self.lane / 'Sources/value.swift'
                if mutation == 'modified': value.write_text('let value = 2\n')
                elif mutation == 'missing': value.unlink()
                elif mutation == 'extra': (self.lane / 'Package@swift-6.4.swift').write_text('alternate')
                else:
                    value.unlink();value.symlink_to(self.source / 'Sources/value.swift')
                with self.assertRaises(ValueError): build_support.verify_source(self.capture, self.lane)

    def test_product_cleanup_preserves_objects_and_rejects_outside_paths(self):
        scratch=self.root/'scratch';binary=scratch/'products';binary.mkdir(parents=True)
        (binary/'ChecklistApp').write_text('old app')
        bundle=binary/'Old.bundle';bundle.mkdir();(bundle/'resource').write_text('old')
        object_file=scratch/'compiled.o';object_file.write_text('reuse')
        build_support.clean_products(binary,scratch)
        self.assertFalse((binary/'ChecklistApp').exists());self.assertFalse(bundle.exists())
        self.assertEqual(object_file.read_text(),'reuse')
        with self.assertRaises(ValueError): build_support.clean_products(self.root,scratch)
        with self.assertRaises(ValueError): build_support.clean_products(scratch,scratch)

    def test_mutated_capture_and_helper_are_refused(self):
        (self.source / 'Sources/value.swift').write_text('changed capture')
        with self.assertRaises(ValueError): build_support.sync_source(self.capture, self.lane)
        shutil.copyfile(ROOT / 'script/build_input_inventory.py', self.source / 'script/build_input_inventory.py')
        (self.source / 'script/build_input_inventory.py').write_text('raise SystemExit("untrusted")')
        with self.assertRaises(ValueError): build_support.sync_source(self.capture, self.lane)


class BuildScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for folder in ['script', 'Sources', 'Resources', 'tools']:
            (self.root / folder).mkdir()
        for name in ['build_and_run.sh', 'build_input_inventory.py', 'build_support.py']:
            shutil.copyfile(ROOT / 'script' / name, self.root / 'script' / name)
        (self.root / 'script/build_and_run.sh').chmod(0o755)
        (self.root / 'Package.swift').write_text('// fixture\n')
        (self.root / 'Package.resolved').write_text('{}\n')
        (self.root / 'Sources/value.swift').write_text('let value = 1\n')
        (self.root / 'Resources/AppIcon.icns').write_bytes(b'icon-fixture')
        for name in ['org.checklist.service.plist', 'org.checklist.coordination.plist']:
            (self.root / 'Resources' / name).write_bytes(plistlib.dumps({'Label': name}))
        self.calls = self.root / 'calls.jsonl'
        tool = '''#!/usr/bin/env python3
import hashlib,json,os,pathlib,shutil,sys
name=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as out: out.write(json.dumps([name,*args])+'\\n')
if name=='swift':
 if args==['--version']: print('Swift fixture');sys.exit()
 source=pathlib.Path(args[args.index('--package-path')+1]);scratch=pathlib.Path(args[args.index('--scratch-path')+1]);bin=scratch/'bin'
 if '--show-bin-path' in args: print(bin);sys.exit()
 if os.environ.get('EDIT_CHECKOUT'):
  pathlib.Path(os.environ['EDIT_CHECKOUT']).write_text('#error("checkout edit must not compile")')
 bin.mkdir(parents=True,exist_ok=True)
 for product in ['ChecklistApp','ChecklistService','checklist']:
  if product==os.environ.get('OMIT_PRODUCT'):continue
  (bin/product).write_bytes((source/'Sources/value.swift').read_bytes())
 if os.environ.get('EDIT_LANE'): (source/'Sources/value.swift').write_text('modified lane')
elif name=='xcrun': print('fixture-sdk')
elif name=='codesign':
 if '-d' in args: print('TeamIdentifier=not set',file=sys.stderr)
elif name=='ditto': shutil.copytree(args[0],args[1],dirs_exist_ok=True)
elif name=='plutil': pass
'''
        for name in ['swift', 'xcrun', 'codesign', 'ditto', 'plutil']:
            path=self.root/'tools'/name;path.write_text(tool);path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root/'tools')+os.pathsep+os.environ['PATH'], CALLS=str(self.calls), CHECKLIST_SIGN_IDENTITY='-')

    def run_stage(self, **environment):
        return subprocess.run([str(self.root/'script/build_and_run.sh'), '--stage'], env=dict(self.env, **environment), capture_output=True, text=True)

    def capture(self):
        return next((self.root/'.local/build').glob('*/capture-manifest.json')).parent

    def test_one_three_product_build_one_bin_read_and_phase_receipt(self):
        result=self.run_stage();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        builds=[c for c in calls if c[:2]==['swift','build']]
        self.assertEqual(len(builds),2)
        compile=[c for c in builds if '--show-bin-path' not in c]
        self.assertEqual(len(compile),1)
        self.assertIn('ChecklistProducts',compile[0])
        self.assertNotIn('--disable-build-manifest-caching',compile[0])
        self.assertEqual(sum('--show-bin-path' in c for c in builds),1)
        receipt=json.loads((self.capture()/'build-verification.json').read_text())
        self.assertEqual(set(receipt['timing']['phases']),set(build_support.PHASES))
        self.assertIn('load_start',receipt['timing']);self.assertIn('load_end',receipt['timing'])
        for name,item in receipt['timing']['phases'].items():
            self.assertGreaterEqual(item['seconds'],0)
            self.assertEqual(item['status'],'skipped' if name=='install' else 'completed')
        self.assertTrue(receipt['captured_source_verified'])
        self.assertTrue(receipt['stable_source_verified'])
        self.assertEqual(set(receipt['binary_sha256']),{'ChecklistApp','ChecklistService','checklist'})

    def test_cached_stage_skips_compile_stage_and_sign(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        original_source=json.loads((self.capture()/'build-verification.json').read_text())['build_source']
        self.calls.write_text('')
        second=self.run_stage(BUILD_SOURCE='/ambient-value');self.assertEqual(second.returncode,0,second.stderr)
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertFalse(any(c[:2]==['swift','build'] for c in calls))
        receipt=json.loads((self.capture()/'build-verification.json').read_text())
        self.assertEqual(receipt['build_source'],original_source)
        self.assertTrue(receipt['stable_source_verified'])
        for phase in ['compile','stage','sign','install']:
            self.assertEqual(receipt['timing']['phases'][phase]['status'],'skipped')
        self.assertEqual(len((self.capture()/'build-timings.jsonl').read_text().splitlines()),2)

    def test_last_install_writer_copies_timing_without_installing(self):
        script=(ROOT/'script/build_and_run.sh').read_text()
        start=script.index('import json,sys',script.index('phase stop install'))
        block=script[start:script.index('\nPY',start)]
        build=self.root/'record';build.mkdir()
        dest=self.root/'installed-fixture.app';resources=dest/'Contents/Resources';resources.mkdir(parents=True)
        (resources/'build-info.json').write_text('{}')
        capture=self.root/'receipt';capture.mkdir()
        timing={'phases':{'install':{'seconds':2.0,'status':'completed'}},'load_start':'{ 1 2 3 }','load_end':'{ 3 2 1 }'}
        (capture/'build-verification.json').write_text(json.dumps({'timing':timing}))
        result=subprocess.run([sys.executable,'-c',block,str(build),str(dest),str(self.root/'previous'),'0',str(capture)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((build/'last-install.json').read_text())['timing'],timing)

    def test_checkout_edit_after_capture_does_not_enter_products(self):
        result=self.run_stage(EDIT_CHECKOUT=str(self.root/'Sources/value.swift'))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        capture=self.capture();receipt=json.loads((capture/'build-verification.json').read_text())
        self.assertTrue(receipt['checkout_changed_after_capture'])
        self.assertIn('Sources/value.swift',receipt['checkout_changed_paths'])
        self.assertEqual((capture/'Checklist.app/Contents/MacOS/ChecklistApp').read_text(),'let value = 1\n')

    def test_modified_lane_after_compile_refuses_to_publish_stage(self):
        result=self.run_stage(EDIT_LANE='1')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Stable build source differs',result.stderr)
        self.assertFalse((self.capture()/'Checklist.app').exists())
        self.assertFalse((self.capture()/'build-verification.json').exists())

    def test_stage_verifier_checks_recorded_binary_hashes(self):
        result=self.run_stage();self.assertEqual(result.returncode,0,result.stderr)
        with patch.object(verify_stage.subprocess,'run') as native, patch.object(verify_stage,'signing_teams'):
            verify_stage.verify(self.capture())
            native.reset_mock()
            (self.capture()/'Checklist.app/Contents/MacOS/checklist').write_text('changed')
            with self.assertRaisesRegex(ValueError,'Staged binaries differ'):
                verify_stage.verify(self.capture())
            native.assert_not_called()

    def test_cached_stage_rejects_changed_binary_before_rewriting_receipt(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        receipt=self.capture()/'build-verification.json';original_receipt=receipt.read_bytes()
        (self.capture()/'Checklist.app/Contents/MacOS/checklist').write_text('different binary')
        second=self.run_stage(BUILD_SOURCE='/ambient-value-must-not-prove-compilation');self.assertNotEqual(second.returncode,0)
        self.assertIn('Staged binaries differ',second.stderr)
        self.assertEqual(receipt.read_bytes(),original_receipt)

    def test_missing_product_cannot_use_old_scratch_executable(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        shutil.rmtree(self.capture()/'Checklist.app')
        second=self.run_stage(OMIT_PRODUCT='ChecklistService')
        self.assertNotEqual(second.returncode,0)
        self.assertFalse((self.capture()/'Checklist.app').exists())

    def test_held_build_lock_refuses_before_running_native_tools(self):
        lock=self.root/'.local/build/.build-lock';lock.mkdir(parents=True)
        result=self.run_stage()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Another Checklist build owns',result.stderr)
        self.assertTrue(lock.is_dir());self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()
