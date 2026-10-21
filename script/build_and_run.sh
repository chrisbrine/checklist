#!/usr/bin/env bash
# Build an immutable source capture, verify the stage, then replace only Checklist.
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$MODE" in run|--verify|--install|--install-stage|--stage|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--verify|--install|--install-stage|--stage|--debug|--logs|--telemetry]" >&2; exit 2;; esac
BUILD_ROOT="$ROOT_DIR/.local/build"
mkdir -p "$BUILD_ROOT"
if ! mkdir "$BUILD_ROOT/.build-lock" 2>/dev/null; then
  echo "Another Checklist build owns $BUILD_ROOT/.build-lock; reconcile it before retrying." >&2
  exit 1
fi
INCOMING=""
STAGE_ASSEMBLY=""
cleanup() {
  if [ -n "$STAGE_ASSEMBLY" ] && [ -d "$STAGE_ASSEMBLY" ]; then rm -rf "$STAGE_ASSEMBLY"; fi
  rmdir "$BUILD_ROOT/.build-lock" 2>/dev/null || true
  if [ -n "$INCOMING" ] && [ -d "$INCOMING" ]; then echo "A verified install stage remains for reconciliation: $INCOMING" >&2; fi
}
trap cleanup EXIT
CONFIGURATION="${CHECKLIST_BUILD_CONFIGURATION:-release}"
case "$CONFIGURATION" in debug|release) ;; *) echo "CHECKLIST_BUILD_CONFIGURATION must be debug or release." >&2; exit 2;; esac
if [ "${CHECKLIST_SIGN_IDENTITY+x}" = x ]; then
  SIGN_IDENTITY="${CHECKLIST_SIGN_IDENTITY:--}"
elif [ -f "$BUILD_ROOT/signing-identity" ]; then
  SIGN_IDENTITY="$(python3 - "$BUILD_ROOT/signing-identity" <<'PY'
import os,stat,sys
from pathlib import Path
path=Path(sys.argv[1]);metadata=path.lstat()
if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid!=os.getuid():raise SystemExit('Private signing selection must be an owned regular file.')
value=path.read_text().strip()
if not value or '\n' in value or '\r' in value:raise SystemExit('Private signing selection must contain one identity on one line.')
path.chmod(0o600)
print(value)
PY
)"
else
  SIGN_IDENTITY="-"
fi
export CHECKLIST_SIGN_IDENTITY="$SIGN_IDENTITY"
if [ "$MODE" = --install-stage ]; then
  if [ "$#" != 2 ]; then echo "usage: $0 --install-stage CAPTURE_DIR" >&2; exit 2; fi
  CAPTURE_DIR="$(python3 - "$ROOT_DIR/script" "$2" <<'PYVERIFY'
import sys
sys.path.insert(0,sys.argv[1])
from verify_stage import verify
print(verify(sys.argv[2])[0])
PYVERIFY
)"
  SOURCE="$CAPTURE_DIR/source"
  STAGE_FINAL="$CAPTURE_DIR/Checklist.app"
  STAGE="$STAGE_FINAL"
else
TOOLCHAIN_FILE="$(mktemp "$BUILD_ROOT/toolchain.XXXXXX")"
{ swift --version; xcrun --sdk macosx --show-sdk-version; uname -m; echo "$CONFIGURATION"; } > "$TOOLCHAIN_FILE"
python3 - "$TOOLCHAIN_FILE" <<'PY'
import hashlib,os,sys
from pathlib import Path
# The selection affects the fingerprint. A private certificate label never
# becomes a source default, console diagnostic or bundled manifest field.
identity=os.environ['CHECKLIST_SIGN_IDENTITY']
with Path(sys.argv[1]).open('a') as output:output.write('signing_identity_sha256='+hashlib.sha256(identity.encode()).hexdigest()+'\n')
PY
CAPTURE_INFO="$(python3 - "$ROOT_DIR" "$BUILD_ROOT" "$TOOLCHAIN_FILE" "$CONFIGURATION" <<'PY'
import datetime,hashlib,json,os,plistlib,shutil,stat,sys,tempfile
from pathlib import Path
root,build,toolchain_file=map(Path,sys.argv[1:4]);configuration=sys.argv[4]
inventory_path=root/'script'/'build_input_inventory.py'
if inventory_path.is_symlink() or not inventory_path.is_file():raise SystemExit('Build inventory helper must be a regular captured source input.')
inventory_source=inventory_path.read_bytes()
inventory_sha256=hashlib.sha256(inventory_source).hexdigest()
inventory_namespace={'__name__':'checklist_build_input_inventory','__file__':str(inventory_path)}
exec(compile(inventory_source,str(inventory_path),'exec'),inventory_namespace)
input_roots=inventory_namespace['INPUT_ROOTS'];inventory=inventory_namespace['inventory']
for required in ['Package.swift','Package.resolved','Sources','Resources/AppIcon.icns','Resources/org.checklist.service.plist','Resources/org.checklist.coordination.plist']:
 if not (root/required).exists(): raise SystemExit('Required pinned build input missing: '+required)
before=inventory(root)
inventory_entry=next((entry for entry in before if entry['path']=='script/build_input_inventory.py'),None)
if not inventory_entry or inventory_entry['sha256']!=inventory_sha256:raise SystemExit('Build inventory helper changed while bootstrapping; capture again before building.')
toolchain=toolchain_file.read_text(); toolchain_file.unlink()
canonical=json.dumps({'inputs':before,'toolchain':toolchain,'configuration':configuration},sort_keys=True,separators=(',',':')).encode()
fingerprint=hashlib.sha256(canonical).hexdigest(); destination=build/fingerprint
if not destination.exists():
 temporary=Path(tempfile.mkdtemp(prefix='capture-',dir=build));source=temporary/'source';source.mkdir()
 try:
  for entry in before:
   p=source/entry['path'];p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/entry['path'],p);p.chmod(0o755 if entry['executable'] else 0o644)
  if inventory(source)!=before or inventory(root)!=before: raise RuntimeError('Build inputs changed while capturing. Capture again; the installed app is untouched.')
  ordinal_path=build/'build-ordinal'
  prior=int(ordinal_path.read_text().strip()) if ordinal_path.exists() else 0
  if prior<0 or prior>=2147483647:raise RuntimeError('Build ordinal is outside its supported integer range; preserve and reconcile it before retrying.')
  installed=Path('/Applications/Checklist.app/Contents/Info.plist')
  if installed.exists():
   version=str(plistlib.loads(installed.read_bytes()).get('CFBundleVersion','0'))
   if version.isdecimal():prior=max(prior,int(version))
  number=prior+1
  if number>2147483647:raise RuntimeError('Build ordinal exhausted; preserve installation history before changing the version policy.')
  ordinal_temporary=build/('build-ordinal.'+str(os.getpid()));ordinal_temporary.write_text(str(number)+'\n');ordinal_temporary.replace(ordinal_path)
  identity=os.environ['CHECKLIST_SIGN_IDENTITY']
  manifest={'schema_version':1,'source_fingerprint':fingerprint,'build_id':fingerprint[:16],'build_number':number,'source_root':str(root),'configuration':configuration,'toolchain':toolchain,'signing_profile':'ad-hoc' if identity=='-' else 'certificate','signing_identity_sha256':hashlib.sha256(identity.encode()).hexdigest(),'input_roots':input_roots,'inputs':before,'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
  (temporary/'capture-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  for p in sorted(source.rglob('*'),reverse=True): p.chmod(0o555 if p.is_dir() or bool(p.stat().st_mode&stat.S_IXUSR) else 0o444)
  source.chmod(0o555);temporary.rename(destination)
 except BaseException:
  for p in temporary.rglob('*'):
   if p.is_dir():p.chmod(0o755)
  shutil.rmtree(temporary,ignore_errors=True);raise
else:
 manifest=json.loads((destination/'capture-manifest.json').read_text())
 if manifest['inputs']!=before or manifest['source_fingerprint']!=fingerprint or inventory(destination/'source')!=before: raise SystemExit('Existing source capture failed verification; preserve it and reconcile before retrying.')
print(str(destination)+'\n'+hashlib.sha256(toolchain.encode()).hexdigest()[:20])
PY
)"
CAPTURE_DIR="$(printf '%s\n' "$CAPTURE_INFO" | sed -n '1p')"
TOOLCHAIN_ID="$(printf '%s\n' "$CAPTURE_INFO" | sed -n '2p')"
SOURCE="$CAPTURE_DIR/source"
SCRATCH="$BUILD_ROOT/swiftpm-$TOOLCHAIN_ID"
STAGE_FINAL="$CAPTURE_DIR/Checklist.app"
STAGE="$STAGE_FINAL"
if [ ! -d "$STAGE_FINAL" ]; then
  # A failed copy/build/sign never publishes a directory reusable as a full stage.
  STAGE_ASSEMBLY="$(mktemp -d "$CAPTURE_DIR/stage-XXXXXX")"
  STAGE="$STAGE_ASSEMBLY/Checklist.app"
  for product in ChecklistApp ChecklistService checklist; do
    swift build --package-path "$SOURCE" --scratch-path "$SCRATCH" --configuration "$CONFIGURATION" --disable-build-manifest-caching --force-resolved-versions --product "$product"
  done
  BIN_DIR="$(swift build --package-path "$SOURCE" --scratch-path "$SCRATCH" --configuration "$CONFIGURATION" --disable-build-manifest-caching --show-bin-path)"
  mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
  for executable in ChecklistApp ChecklistService checklist; do
    cp "$BIN_DIR/$executable" "$STAGE/Contents/MacOS/$executable"
    chmod +x "$STAGE/Contents/MacOS/$executable"
  done
  for bundle in "$BIN_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then ditto "$bundle" "$STAGE/Contents/Resources/$(basename "$bundle")"; fi
  done
  cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ChecklistApp</string>
<key>CFBundleIdentifier</key><string>org.checklist.app</string>
<key>CFBundleName</key><string>Checklist</string>
<key>CFBundleDisplayName</key><string>Checklist</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Checklist development build</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Quick capture file</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>None</string>
<key>LSItemContentTypes</key><array><string>public.item</string></array>
</dict></array>
</dict></plist>
PLIST
  python3 - "$CAPTURE_DIR" "$STAGE" <<'PY'
import datetime,json,plistlib,sys
from pathlib import Path
capture,stage=map(Path,sys.argv[1:]);manifest=json.loads((capture/'capture-manifest.json').read_text())
info={key:manifest[key] for key in ['build_id','build_number','source_fingerprint','source_root','configuration','toolchain','captured_at','signing_identity_sha256']}
info.update(built_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),profile='local-development',signing=manifest['signing_profile'],source_capture=str(capture/'source'))
(stage/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(plistlib.loads((stage/'Contents/Info.plist').read_bytes()),CFBundleVersion=str(manifest['build_number']))))
(stage/'Contents/Resources/build-info.json').write_text(json.dumps(info,indent=2)+'\n')
(stage/'Contents/Resources/source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
  for resource in skills plugins templates; do
    if [ -d "$SOURCE/$resource" ]; then ditto "$SOURCE/$resource" "$STAGE/Contents/Resources/$resource"; fi
  done
  cp "$SOURCE/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
  mkdir -p "$STAGE/Contents/Library/LaunchAgents"
  for agent_plist in org.checklist.service.plist org.checklist.coordination.plist; do
    cp "$SOURCE/Resources/$agent_plist" "$STAGE/Contents/Library/LaunchAgents/$agent_plist"
    chmod 644 "$STAGE/Contents/Library/LaunchAgents/$agent_plist"
    plutil -lint "$STAGE/Contents/Library/LaunchAgents/$agent_plist"
  done
  for executable in ChecklistService checklist; do codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier "org.checklist.$executable" "$STAGE/Contents/MacOS/$executable"; done
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier org.checklist.app "$STAGE"
fi
fi
codesign --verify --deep --strict "$STAGE"
python3 - "$STAGE" "$CAPTURE_DIR" <<'PY'
import hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
stage,capture=map(Path,sys.argv[1:]);manifest=json.loads((capture/'capture-manifest.json').read_text())
if plistlib.loads((stage/'Contents/Info.plist').read_bytes()).get('CFBundleIconFile')!='AppIcon':raise SystemExit('The application icon is not declared; the installed bundle is untouched.')
icon=stage/'Contents/Resources/AppIcon.icns'
expected_icon=next(entry['sha256'] for entry in manifest['inputs'] if entry['path']=='Resources/AppIcon.icns')
if not icon.is_file() or hashlib.sha256(icon.read_bytes()).hexdigest()!=expected_icon:raise SystemExit('The application icon differs from the captured asset; the installed bundle is untouched.')
teams=[]
for path in [stage,stage/'Contents/MacOS/ChecklistService',stage/'Contents/MacOS/checklist']:
 result=subprocess.run(['codesign','-d','--verbose=4',str(path)],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
 match=re.search(r'^TeamIdentifier=(.+)$',result.stderr,re.MULTILINE)
 teams.append(match.group(1) if match else None)
if len(set(teams))!=1:raise SystemExit('App and bundled helper signing teams differ; the installed bundle is untouched.')
if manifest['signing_profile']!='ad-hoc' and teams[0] in [None,'not set']:raise SystemExit('Selected certificate produced no signing team; the installed bundle is untouched.')
print('Verified one signing team across the app and both helpers ('+manifest['signing_profile']+').')
PY
# The captured tree is the build authority. The writer barrier ended after
# capture, so later checkout edits are provenance, not a reason to reject it.
python3 - "$CAPTURE_DIR" "$ROOT_DIR" <<'PY'
import datetime,hashlib,json,stat,sys
from pathlib import Path
capture,root=map(Path,sys.argv[1:]);manifest=json.loads((capture/'capture-manifest.json').read_text())
inventory_path=capture/'source'/'script'/'build_input_inventory.py'
inventory_entry=next((entry for entry in manifest['inputs'] if entry['path']=='script/build_input_inventory.py'),None)
if not inventory_entry or inventory_path.is_symlink() or not inventory_path.is_file():raise SystemExit('Captured inventory helper changed; the installed app is untouched.')
inventory_source=inventory_path.read_bytes()
if hashlib.sha256(inventory_source).hexdigest()!=inventory_entry['sha256']:raise SystemExit('Captured inventory helper changed; the installed app is untouched.')
inventory_namespace={'__name__':'checklist_build_input_inventory','__file__':str(inventory_path)}
exec(compile(inventory_source,str(inventory_path),'exec'),inventory_namespace)
inventory=inventory_namespace['inventory']
if inventory(capture/'source')!=manifest['inputs']:raise SystemExit('Immutable source capture changed during build; the installed app is untouched.')
receipt={'schema_version':1,'build_id':manifest['build_id'],'source_fingerprint':manifest['source_fingerprint'],'captured_source_verified':True,'verified_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
try:
 current=inventory(root);receipt['checkout_changed_after_capture']=current!=manifest['inputs']
 receipt['checkout_inventory_sha256']=hashlib.sha256(json.dumps(current,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 before={x['path']:x for x in manifest['inputs']};after={x['path']:x for x in current}
 changed=sorted(p for p in set(before)|set(after) if before.get(p)!=after.get(p))
 receipt['checkout_changed_paths']=changed[:100];receipt['checkout_changed_path_count']=len(changed)
except (OSError,RuntimeError) as error:
 receipt.update(checkout_changed_after_capture=True,checkout_comparison_error=str(error))
(capture/'build-verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Verified immutable source capture '+manifest['build_id'])
if receipt['checkout_changed_after_capture']:print('Checkout advanced after capture. This bundle contains the verified captured source, not the latest checkout.')
PY
if [ -n "$STAGE_ASSEMBLY" ]; then
  mv "$STAGE" "$STAGE_FINAL"
  rmdir "$STAGE_ASSEMBLY"
  STAGE_ASSEMBLY=""
  STAGE="$STAGE_FINAL"
fi
if [ "$MODE" = --stage ]; then echo "Staged $STAGE"; exit 0; fi
DEST="/Applications/Checklist.app"
INSTALL_STARTED="$(date +%s)"
INSTALL_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INCOMING="/Applications/.Checklist-incoming-$INSTALL_ID.app"
PREVIOUS="/Applications/.Checklist-previous-$INSTALL_ID.app"
if [ -e "$INCOMING" ] || [ -e "$PREVIOUS" ]; then echo "Install paths already exist; reconcile them before retrying." >&2; exit 1; fi
if [ -e "$DEST" ]; then
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$IDENTIFIER" != org.checklist.app ]; then echo "Refusing to replace an unrelated application at $DEST." >&2; exit 1; fi
fi
ditto "$STAGE" "$INCOMING"
codesign --verify --deep --strict "$INCOMING"
# Quiesce only this UI and the process holding this installation's service lock.
# Data remains in Application Support. This does not claim or create a database backup.
python3 - "$ROOT_DIR" "$DEST" <<'PY'
import ctypes,os,signal,subprocess,sys,time
from pathlib import Path
root,dest=map(Path,sys.argv[1:]);targets=[]
test_root=Path.home()/'Library/Application Support/Checklist Test Instances'
libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
def actual_path(pid):
 buffer=ctypes.create_string_buffer(4096)
 return os.fsdecode(buffer.value) if libproc.proc_pidpath(pid,buffer,len(buffer))>0 else ''
def test_process(path):return path.startswith(str(test_root)+os.sep)
for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
 parts=line.strip().split(None,1)
 if len(parts)!=2:continue
 pid=int(parts[0]);path=actual_path(pid)
 if test_process(path):continue
 if path==str(dest/'Contents/MacOS/ChecklistApp') or (path.startswith(str(root)+os.sep) and path.endswith('/ChecklistApp')):targets.append(pid)
data=Path(os.environ.get('CHECKLIST_DATA_ROOT',str(Path.home()/'Library/Application Support/Checklist')))
lock=data/'service.lock'
if lock.exists():
 result=subprocess.run(['lsof','-t',str(lock)],text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 for pid_text in result.stdout.split():
  pid=int(pid_text);path=actual_path(pid)
  if not test_process(path) and path.endswith('/ChecklistService'):targets.append(pid)
for pid in set(targets):
 try:os.kill(pid,signal.SIGTERM)
 except ProcessLookupError:pass
for pid in set(targets):
 deadline=time.monotonic()+5
 while time.monotonic()<deadline:
  try:os.kill(pid,0)
  except ProcessLookupError:break
  time.sleep(.05)
 else:raise SystemExit('Checklist process did not stop within five seconds; installed bundle preserved. PID '+str(pid))
PY
HAD_PREVIOUS=0
if [ -e "$DEST" ]; then mv "$DEST" "$PREVIOUS"; HAD_PREVIOUS=1; fi
if ! mv "$INCOMING" "$DEST"; then
  if [ "$HAD_PREVIOUS" = 1 ] && [ ! -e "$DEST" ]; then mv "$PREVIOUS" "$DEST"; fi
  echo "Install failed; previous bundle restored where possible. Data was retained." >&2
  exit 1
fi
INCOMING=""
if ! codesign --verify --deep --strict "$DEST"; then
  mv "$DEST" "/Applications/.Checklist-rejected-$INSTALL_ID.app"
  if [ "$HAD_PREVIOUS" = 1 ]; then mv "$PREVIOUS" "$DEST"; fi
  echo "Installed signature failed; previous bundle restored. Data was retained." >&2
  exit 1
fi
python3 - "$BUILD_ROOT" "$DEST" "$PREVIOUS" "$HAD_PREVIOUS" "$CAPTURE_DIR" <<'PY'
import json,sys
from pathlib import Path
build,dest,previous=map(Path,sys.argv[1:4]);record={'installed':str(dest),'previous_bundle':str(previous) if sys.argv[4]=='1' else None,'build':json.loads((dest/'Contents/Resources/build-info.json').read_text()),'database_backup_created_by_script':False}
record['verification']=json.loads((Path(sys.argv[5])/'build-verification.json').read_text())
(build/'last-install.json').write_text(json.dumps(record,indent=2)+'\n')
PY
case "$MODE" in
  --debug) lldb -- "$DEST/Contents/MacOS/ChecklistApp" ;;
  --logs|--telemetry) open -n "$DEST"; /usr/bin/log stream --info --style compact --predicate 'process == "ChecklistApp" OR process == "ChecklistService"' ;;
  *) open -n "$DEST" ;;
esac
# Installed verification is mandatory for both verified installation routes.
case "$MODE" in
  --verify|--install-stage)
  sleep 2
  if ! python3 "$ROOT_DIR/script/verify_install.py" "$DEST" --install-started "$INSTALL_STARTED"; then
    echo "Installed verification failed." >&2
    if ! python3 "$ROOT_DIR/script/verify_install.py" --failure-guidance --install-started "$INSTALL_STARTED" >&2; then
      echo "The installed bundle and the store were kept. Check checklist service status and the service log. If the first start upgraded the store, a rollback is a restore of its protected pre-upgrade generation, not the previous bundle." >&2
    fi
    if [ "$HAD_PREVIOUS" = 1 ]; then
      echo "Previous bundle kept at $PREVIOUS; it does not restore the store." >&2
    fi
    exit 1
  fi
  ;;
esac
echo "Installed $DEST"
if [ "$HAD_PREVIOUS" = 1 ]; then echo "Previous bundle retained at $PREVIOUS; it does not restore the store."; fi
