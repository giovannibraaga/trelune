#!/bin/bash
# Builds the styled installer DMG (Figma "57 · Instalação DMG · escuro") with dmgbuild,
# which writes the Finder layout directly (no Finder automation).
#   script/dmg/make-dmg.sh <path/to/Trelune.app> <output.dmg>
# dmgbuild comes from PyPI; it is installed once into .build/dmgbuild-venv when missing.
set -euo pipefail
APP="$1"; OUT="$2"
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || true)}"
if [ -z "$DMGBUILD" ]; then
  venv="$root/.build/dmgbuild-venv"
  [ -x "$venv/bin/dmgbuild" ] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q dmgbuild; }
  DMGBUILD="$venv/bin/dmgbuild"
fi
PYTHON="$(head -1 "$DMGBUILD" | sed 's/^#!//')"   # the interpreter that has dmgbuild's ds_store module
work="$(mktemp -d)"; mnt="$work/mnt"
trap 'hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
swift "$here/background.swift" "$work" >/dev/null
"$DMGBUILD" -s "$here/settings.py" -D app="$APP" -D background="$work/background.png" -D icon="$APP/Contents/Resources/AppIcon.icns" -D format=UDRW "Trelune" "$work/rw.dmg" >/dev/null
mkdir -p "$mnt"
hdiutil attach "$work/rw.dmg" -readwrite -nobrowse -noautoopen -mountpoint "$mnt" -quiet
"$PYTHON" "$here/dark-labels.py" "$mnt"
hdiutil detach "$mnt" -quiet
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null 2>&1
echo "DMG: $OUT"
