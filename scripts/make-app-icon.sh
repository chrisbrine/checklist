#!/usr/bin/env bash
# Produce native macOS icon representations by downsampling the retained artwork.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon/source.png"
python3 - "$SOURCE" <<'PY'
import subprocess,sys
from pathlib import Path
source=Path(sys.argv[1])
if not source.is_file():raise SystemExit('Retain Resources/AppIcon/source.png before generating the icon.')
properties=subprocess.check_output(['sips','-g','pixelWidth','-g','pixelHeight','-g','hasAlpha',str(source)],text=True)
values=dict(line.strip().split(': ',1) for line in properties.splitlines() if ': ' in line)
if values.get('pixelWidth')!=values.get('pixelHeight') or int(values.get('pixelWidth','0'))<1024:
    raise SystemExit('The source must be square and at least 1024 pixels; no representation may be upscaled.')
if values.get('hasAlpha')!='yes':raise SystemExit('The source must retain its transparent rounded corners.')
PY
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/checklist-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir "$ICONSET"
for logical_size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((logical_size * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/icon_${logical_size}x${logical_size}${suffix}.png" >/dev/null
  done
done
iconutil --convert icns --output "$ROOT_DIR/Resources/AppIcon.icns" "$ICONSET"
echo "Created Resources/AppIcon.icns from the retained source without upscaling."
