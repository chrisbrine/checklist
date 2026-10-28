"""Build-helper checks with disposable inputs and fake native tools; no installation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
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
        for name in ['build_and_run.sh', 'build_input_inventory.py', 'build_support.py', 'version.py', 'verify_stage.py']:
            shutil.copyfile(ROOT / 'script' / name, self.root / 'script' / name)
        (self.root / 'script/build_and_run.sh').chmod(0o755)
        (self.root / 'VERSION').write_text('0.0.1\n')
        (self.root / 'Package.swift').write_text('// fixture\n')
        (self.root / 'Package.resolved').write_text('{}\n')
        (self.root / 'Sources/value.swift').write_text('let value = 1\n')
        (self.root / 'Resources/AppIcon.icns').write_bytes(b'icon-fixture')
        for name in ['org.checklist.service.plist', 'org.checklist.coordination.plist']:
            (self.root / 'Resources' / name).write_bytes(plistlib.dumps({'Label': name}))
        self.calls = self.root / 'calls.jsonl'
        tool = '''#!/usr/bin/env python3
import hashlib,json,os,pathlib,shutil,sys,time
name=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as out: out.write(json.dumps([name,*args])+'\\n')
if name=='swift':
 if args==['--version']: print('Swift fixture');sys.exit()
 source=pathlib.Path(args[args.index('--package-path')+1]);scratch=pathlib.Path(args[args.index('--scratch-path')+1]);bin=scratch/'bin'
 if args[0]=='package':
  if scratch.exists(): shutil.rmtree(scratch)
  sys.exit()
 if '--show-bin-path' in args: print(bin);sys.exit()
 if os.environ.get('PAUSE_READY'):
  pathlib.Path(os.environ['PAUSE_READY']).touch()
  deadline=time.monotonic()+20
  while not pathlib.Path(os.environ['PAUSE_RELEASE']).exists():
   if time.monotonic()>deadline: raise SystemExit('Timed out waiting for test release')
   time.sleep(.02)
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
elif name=='mv':
 if os.environ.get('FAIL_STAGE_PUBLISH') and '/stage-' in args[0] and args[0].endswith('/Checklist.app'):sys.exit(74)
 os.execv('/bin/mv',['/bin/mv',*args])
elif name=='rm':
 failure=os.environ.get('FAIL_CLEANUP')
 if failure=='stage' and any('/stage-' in a for a in args):sys.exit(73)
 if failure=='files' and any('/timing.' in a or '/build-verification.' in a for a in args):sys.exit(73)
 os.execv('/bin/rm',['/bin/rm',*args])
elif name=='plutil': pass
'''
        for name in ['swift', 'xcrun', 'codesign', 'ditto', 'plutil', 'mv', 'rm']:
            path=self.root/'tools'/name;path.write_text(tool);path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root/'tools')+os.pathsep+os.environ['PATH'], CALLS=str(self.calls), CHECKLIST_SIGN_IDENTITY='-', CHECKLIST_BUILD_ALLOCATOR_DIR=str(self.root/'allocator'))

    def run_stage(self, mode='--stage', **environment):
        return subprocess.run([str(self.root/'script/build_and_run.sh'), mode], env=dict(self.env, **environment), capture_output=True, text=True)

    def capture(self):
        return next((self.root/'.local/build').glob('*/capture-manifest.json')).parent

    def test_scope_switch_separates_captures_reuses_compilation_lane_and_reserves_only_install(self):
        captures = {}
        for scope in ['measurement', 'install', 'test', 'private-copy', 'measurement', 'install']:
            result = self.run_stage(CHECKLIST_BUILD_SCOPE=scope)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            capture = Path(next(line[7:] for line in result.stdout.splitlines() if line.startswith('Staged '))).parent
            manifest = json.loads((capture / 'capture-manifest.json').read_text())
            info = json.loads((capture / 'Checklist.app/Contents/Resources/build-info.json').read_text())
            self.assertEqual(manifest['build_scope'], scope);self.assertEqual(info['build_scope'], scope)
            self.assertIs(info['installable'], scope == 'install')
            if scope == 'measurement' and not captures: self.assertFalse((self.root / 'allocator').exists())
            if scope != 'install':
                self.assertEqual((info['version'], info['build_number']), ('0.0.1.0', 0))
            if scope in captures: self.assertEqual(capture, captures[scope])
            captures[scope] = capture
        self.assertEqual(len(set(captures.values())), 4)
        install = json.loads((captures['install'] / 'capture-manifest.json').read_text())
        state = json.loads((self.root / 'allocator/version-state.json').read_text())
        self.assertEqual(state['build_number'], install['build_number'])
        self.assertEqual(state['series']['0.0.1'], int(install['version'].rsplit('.', 1)[1]))
        self.assertEqual(len(list((self.root / '.local/build').glob('swiftpm-*'))), 1)
        with patch.object(verify_stage.subprocess, 'run'), patch.object(verify_stage, 'signing_teams'):
            verify_stage.verify(captures['measurement'])  # usable by disposable test slots
            verify_stage.verify(captures['install'], for_install=True)
        for scope in ['measurement', 'test', 'private-copy']:
            result = subprocess.run([str(self.root / 'script/build_and_run.sh'), '--install-stage', str(captures[scope])],
                                    env=self.env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not installable', result.stderr)

    def test_invalid_scope_and_local_install_mode_refuse_before_build_or_allocation(self):
        for mode, scope in [('--stage', 'typo'), ('--verify', 'measurement'), ('--install', 'test')]:
            result = self.run_stage(mode=mode, CHECKLIST_BUILD_SCOPE=scope)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.calls.exists());self.assertFalse((self.root / 'allocator').exists())

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

    def test_release_flags_are_captured_and_passed_to_both_build_calls(self):
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.capture() / 'capture-manifest.json').read_text())
        flags = ['-Xswiftc', '-no-whole-module-optimization', '-Xswiftc', '-incremental', '-Xswiftc', '-enable-batch-mode']
        self.assertEqual(manifest['configuration'], 'release')
        self.assertEqual(manifest['swift_flags'], flags)
        self.assertIn('swift_flag=-no-whole-module-optimization\n', manifest['toolchain'])
        self.assertIn('swift_flag=-incremental\n', manifest['toolchain'])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        for call in [c for c in calls if c[:2] == ['swift', 'build']]:
            start = call.index('-Xswiftc')
            self.assertEqual(call[start:start + len(flags)], flags)
            self.assertNotIn('-Onone', call)
            self.assertEqual(call[call.index('--build-system') + 1], 'native')

    def test_debug_keeps_its_compiler_defaults(self):
        result = self.run_stage(CHECKLIST_BUILD_CONFIGURATION='debug')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.capture() / 'capture-manifest.json').read_text())
        self.assertEqual(manifest['configuration'], 'debug')
        self.assertEqual(manifest['swift_flags'], [])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        for call in [c for c in calls if c[:2] == ['swift', 'build']]:
            self.assertNotIn('-Xswiftc', call)

    def test_changed_compilation_flags_select_a_new_capture_lane_and_scratch(self):
        first = self.run_stage()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.capture()
        first_manifest = json.loads((before / 'capture-manifest.json').read_text())
        first_receipt = json.loads((before / 'build-verification.json').read_text())
        script = self.root / 'script/build_and_run.sh'
        script.write_text(script.read_text().replace('-Xswiftc -enable-batch-mode)', '-Xswiftc -enable-batch-mode -Xswiftc -Osize)'))
        second = self.run_stage()
        self.assertEqual(second.returncode, 0, second.stderr)
        latest = next(p.parent for p in (self.root / '.local/build').glob('*/capture-manifest.json') if p.parent != before)
        manifest = json.loads((latest / 'capture-manifest.json').read_text())
        receipt = json.loads((latest / 'build-verification.json').read_text())
        self.assertNotEqual(first_manifest['source_fingerprint'], manifest['source_fingerprint'])
        self.assertNotEqual(first_manifest['toolchain'], manifest['toolchain'])
        self.assertEqual(manifest['swift_flags'][-2:], ['-Xswiftc', '-Osize'])
        self.assertNotEqual(first_receipt['build_source'], receipt['build_source'])
        self.assertEqual(len(list((self.root / '.local/build').glob('swiftpm-*'))), 2)

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
        captured=(capture/'source/Sources/value.swift').read_bytes()
        self.assertNotEqual((self.root/'Sources/value.swift').read_bytes(),captured)
        for product,sha256 in receipt['binary_sha256'].items():
            binary=capture/'Checklist.app/Contents/MacOS'/product
            self.assertEqual(binary.read_bytes(),captured)
            self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(),sha256)

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

    def test_rebuild_stage_reuses_lane_and_scratch_across_captures(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        capture=self.capture();before=json.loads((capture/'build-verification.json').read_text())
        lane=Path(before['build_source']);unchanged=lane/'Resources/AppIcon.icns'
        mtime=unchanged.stat().st_mtime_ns
        scratch=next((self.root/'.local/build').glob('swiftpm-*'))
        marker=scratch/'compiled.o';marker.write_text('retained object')
        (self.root/'Sources/value.swift').write_text('let value = 2\n')
        second=self.run_stage();self.assertEqual(second.returncode,0,second.stderr)
        captures=list((self.root/'.local/build').glob('*/capture-manifest.json'))
        self.assertEqual(len(captures),2)
        latest=next(p.parent for p in captures if p.parent!=capture)
        after=json.loads((latest/'build-verification.json').read_text())
        self.assertEqual(before['build_source'],after['build_source'])
        self.assertEqual(unchanged.stat().st_mtime_ns,mtime)
        self.assertEqual(marker.read_text(),'retained object')
        rebuilt=self.run_stage(mode='--rebuild-stage');self.assertEqual(rebuilt.returncode,0,rebuilt.stderr)
        receipt=json.loads((latest/'build-verification.json').read_text())
        self.assertEqual(receipt['timing']['phases']['compile']['status'],'completed')
        self.assertFalse((latest/'Checklist.app/Checklist.app').exists())
        self.assertEqual(marker.read_text(),'retained object')
        failed=self.run_stage(mode='--rebuild-stage',OMIT_PRODUCT='ChecklistService')
        self.assertNotEqual(failed.returncode,0)
        self.assertEqual((latest/'Checklist.app/Contents/MacOS/ChecklistService').read_text(),'let value = 2\n')
        self.assertEqual(json.loads((latest/'build-verification.json').read_text()),receipt)

    def test_failed_rebuild_publication_restores_prior_stage_and_receipt(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        capture=self.capture();receipt=capture/'build-verification.json'
        original=receipt.read_bytes()
        failed=self.run_stage(mode='--rebuild-stage',FAIL_STAGE_PUBLISH='1')
        self.assertNotEqual(failed.returncode,0)
        self.assertEqual(receipt.read_bytes(),original)
        for product in ['ChecklistApp','ChecklistService','checklist']:
            self.assertEqual((capture/'Checklist.app/Contents/MacOS'/product).read_text(),'let value = 1\n')
        self.assertEqual(list(capture.glob('build-verification.*.json')),[])
        self.assertFalse((self.root/'.local/build/.build-lock').exists())

    @unittest.skipUnless(Path('/usr/bin/ditto').exists(), 'requires native macOS ditto')
    def test_nested_resources_repeat_stage_without_changing_immutable_capture(self):
        # Keep the real copy/removal tools: permission propagation caused the defect.
        (self.root / 'tools/ditto').unlink()
        (self.root / 'tools/rm').unlink()
        for resource in ['skills', 'plugins', 'templates']:
            nested = self.root / resource / 'example/nested'
            nested.mkdir(parents=True)
            (nested / 'SKILL.md').write_text('nested resource\n')
        first = self.run_stage()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        capture = self.capture()
        source = capture / 'source'
        snapshot = {str(p.relative_to(source)): (stat.S_IMODE(p.stat().st_mode),
                    p.read_bytes() if p.is_file() else None) for p in [source, *source.rglob('*')]}
        self.assertTrue(all(mode & 0o222 == 0 for mode, _ in snapshot.values()))
        # Also qualify replacement of stages generated by the old read-only recipe.
        for p in (capture / 'Checklist.app/Contents/Resources').rglob('*'):
            p.chmod(stat.S_IMODE(p.stat().st_mode) & ~0o222)
        for mode in ['--rebuild-stage', '--clean-stage']:
            result = self.run_stage(mode=mode)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.root / '.local/build/.build-lock').exists())
            self.assertEqual(list(capture.glob('stage-*')), [])
            self.assertEqual(snapshot, {str(p.relative_to(source)): (stat.S_IMODE(p.stat().st_mode),
                p.read_bytes() if p.is_file() else None) for p in [source, *source.rglob('*')]})
            for resource in ['skills', 'plugins', 'templates']:
                copied = capture / 'Checklist.app/Contents/Resources' / resource
                self.assertTrue(all(p.stat().st_mode & stat.S_IWUSR for p in [copied, *copied.rglob('*')]))
                self.assertEqual((copied / 'example/nested/SKILL.md').read_text(), 'nested resource\n')
        # A generated stage can be removed with native rm without pre-chmod.
        removed = subprocess.run(['/bin/rm', '-rf', str(capture / 'Checklist.app')], capture_output=True, text=True)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse((capture / 'Checklist.app').exists())

    def test_failed_stage_cleanup_still_removes_receipt_timing_and_lock(self):
        first = self.run_stage()
        self.assertEqual(first.returncode, 0, first.stderr)
        result = self.run_stage(mode='--rebuild-stage', FAIL_STAGE_PUBLISH='1', FAIL_CLEANUP='stage')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cleanup failed for generated stage:', result.stderr)
        self.assertFalse((self.root / '.local/build/.build-lock').exists())
        self.assertEqual(list(self.capture().glob('build-verification.*.json')), [])
        self.assertEqual(list((self.root / '.local/build').glob('timing.*')), [])
        self.assertEqual(len(list(self.capture().glob('stage-*'))), 1)
        # A later invocation is not blocked by the reported leftover output.
        retried = self.run_stage()
        self.assertEqual(retried.returncode, 0, retried.stderr)

    def test_temporary_file_cleanup_failure_is_reported_and_releases_lock(self):
        result = self.run_stage(FAIL_CLEANUP='files')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cleanup failed for timing file:', result.stderr)
        self.assertFalse((self.root / '.local/build/.build-lock').exists())
        self.assertTrue((self.capture() / 'Checklist.app').exists())
        self.assertEqual(len(list((self.root / '.local/build').glob('timing.*'))), 1)

    def test_catchable_signals_exit_and_release_lock(self):
        for sig in [signal.SIGHUP, signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signal=sig):
                fixture = BuildScriptTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
                # Keep Bash's builtin read blocked until the signal exits it. Releasing
                # a foreground compiler first races Bash's deferred SIGINT handling.
                process, _ = fixture.start_paused(signal_wait=True)
                process.send_signal(sig)
                stdout, stderr = process.communicate(timeout=30)
                self.assertEqual(process.returncode, 128 + sig, stdout + stderr)
                self.assertFalse((fixture.root / '.local/build/.build-lock').exists())
                self.assertEqual(list(fixture.capture().glob('stage-*')), [])

    def test_clean_stage_is_explicit_and_cleans_only_selected_scratch(self):
        first=self.run_stage();self.assertEqual(first.returncode,0,first.stderr)
        scratch=next((self.root/'.local/build').glob('swiftpm-*'))
        marker=scratch/'compiled.o';marker.write_text('old object')
        result=self.run_stage(mode='--clean-stage');self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(marker.exists())
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        clean=[c for c in calls if c[:2]==['swift','package']]
        self.assertEqual(len(clean),1);self.assertEqual(clean[0][-1],'clean')
        self.assertEqual(clean[0][clean[0].index('--build-system') + 1], 'native')
        self.assertEqual(clean[0][clean[0].index('--scratch-path')+1],str(scratch))
        self.assertTrue((self.capture()/'source/Sources/value.swift').is_file())

    def start_paused(self, signal_wait=False):
        ready=self.root/'ready';release=self.root/'release'
        environment = (dict(self.env, CHECKLIST_TEST_BUILD_SIGNAL_READY=str(ready)) if signal_wait
                       else dict(self.env, PAUSE_READY=str(ready), PAUSE_RELEASE=str(release)))
        process=subprocess.Popen([str(self.root/'script/build_and_run.sh'),'--stage'],
            env=environment, stdin=subprocess.PIPE if signal_wait else None,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        def finish():
            release.touch()
            if process.poll() is None:
                process.communicate(input='\n' if signal_wait else None, timeout=30)
        self.addCleanup(finish)
        deadline=time.monotonic()+20
        while not ready.exists():
            if process.poll() is not None or time.monotonic()>deadline:
                self.fail('First build did not reach the compile barrier: '+str(process.poll()))
            time.sleep(.02)
        return process,release

    def test_concurrent_same_checkout_refuses_without_touching_running_lane(self):
        first,release=self.start_paused()
        calls=self.calls.read_bytes()
        lane=next((self.root/'.local/build').glob('lane-*/source'))
        captured=(lane/'Sources/value.swift').read_bytes()
        second=self.run_stage()
        self.assertNotEqual(second.returncode,0)
        self.assertIn('Another Checklist build owns',second.stderr)
        self.assertEqual(self.calls.read_bytes(),calls)
        self.assertEqual((lane/'Sources/value.swift').read_bytes(),captured)
        release.touch();stdout,stderr=first.communicate(timeout=30)
        self.assertEqual(first.returncode,0,stdout+stderr)
        self.assertFalse((self.root/'.local/build/.build-lock').exists())

    def test_concurrent_checkouts_keep_separate_lanes_and_outputs(self):
        other=BuildScriptTests();other.setUp();self.addCleanup(other.doCleanups)
        (other.root/'Sources/value.swift').write_text('let value = 99\n')
        other.env['CHECKLIST_BUILD_ALLOCATOR_DIR'] = self.env['CHECKLIST_BUILD_ALLOCATOR_DIR']
        first,release=self.start_paused()
        second,other_release=other.start_paused()
        release.touch();other_release.touch()
        for process in [first,second]:
            stdout,stderr=process.communicate(timeout=30)
            self.assertEqual(process.returncode,0,stdout+stderr)
        lanes=[];identities=[]
        for fixture,value in [(self,'let value = 1\n'),(other,'let value = 99\n')]:
            capture=fixture.capture();receipt=json.loads((capture/'build-verification.json').read_text())
            lanes.append(receipt['build_source'])
            identities.append(json.loads((capture/'capture-manifest.json').read_text()))
            for product in receipt['binary_sha256']:
                self.assertEqual((capture/'Checklist.app/Contents/MacOS'/product).read_text(),value)
        self.assertNotEqual(lanes[0],lanes[1])
        for key in ['version', 'build_number', 'build_id']:
            self.assertNotEqual(identities[0][key], identities[1][key], key)

    def test_concurrent_install_and_local_stages_only_reserve_the_install_version(self):
        fixtures = [self]
        for scope in ['measurement', 'test', 'private-copy']:
            fixture = BuildScriptTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
            fixture.env.update(CHECKLIST_BUILD_SCOPE=scope,
                               CHECKLIST_BUILD_ALLOCATOR_DIR=self.env['CHECKLIST_BUILD_ALLOCATOR_DIR'])
            fixtures.append(fixture)
        paused = [fixture.start_paused() for fixture in fixtures]
        installed = json.loads((self.capture() / 'capture-manifest.json').read_text())
        state = self.root / 'allocator/version-state.json';reserved = state.read_bytes()
        for _, release in paused: release.touch()
        for process, _ in paused:
            stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        for fixture in fixtures[1:]:
            info = json.loads((fixture.capture() / 'Checklist.app/Contents/Resources/build-info.json').read_text())
            self.assertFalse(info['installable']);self.assertEqual(info['build_number'], 0)
        self.assertEqual(state.read_bytes(), reserved)
        self.assertEqual(json.loads(reserved)['build_number'], installed['build_number'])
        self.assertEqual(json.loads(reserved)['series']['0.0.1'], int(installed['version'].rsplit('.', 1)[1]))

    def test_held_build_lock_refuses_before_running_native_tools(self):
        lock=self.root/'.local/build/.build-lock';lock.mkdir(parents=True)
        result=self.run_stage()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Another Checklist build owns',result.stderr)
        self.assertTrue(lock.is_dir());self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main()
