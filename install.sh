#!/bin/bash
# Installs or updates Trelune from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/giovannibraaga/trelune/main/install.sh | bash
# Downloads the DMG, checks its SHA-256, copies Trelune.app to /Applications (or ~/Applications when
# /Applications is not writable) and opens it. Files fetched with curl are not quarantined, so the
# first-launch warning of browser downloads does not appear.
set -euo pipefail

REPO="${TRELUNE_REPO:-giovannibraaga/trelune}"
BASE="https://github.com/$REPO/releases/latest/download"
[ "$(uname -s)" = "Darwin" ] || { echo "O Trelune é um app para macOS." >&2; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || { echo "O Trelune precisa do macOS 14 ou posterior (este Mac tem $(sw_vers -productVersion))." >&2; exit 1; }

work="$(mktemp -d)"; mountpoint="$work/mount"
cleanup() { hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

echo "→ Baixando o Trelune…"
curl -fL --progress-bar "$BASE/Trelune.dmg" -o "$work/Trelune.dmg"
curl -fsSL "$BASE/Trelune.dmg.sha256" -o "$work/Trelune.dmg.sha256"
echo "→ Conferindo o checksum…"
(cd "$work" && shasum -a 256 -c Trelune.dmg.sha256 >/dev/null) || { echo "O checksum não confere. Tente de novo." >&2; exit 1; }

mkdir -p "$mountpoint"
hdiutil attach "$work/Trelune.dmg" -nobrowse -readonly -mountpoint "$mountpoint" -quiet

target="${TRELUNE_INSTALL_DIR:-/Applications}"
[ -w "$target" ] || { target="$HOME/Applications"; mkdir -p "$target"; }
if [ "${TRELUNE_NO_OPEN:-}" != "1" ] && pgrep -x Trelune >/dev/null; then echo "→ Fechando o Trelune aberto…"; osascript -e 'quit app "Trelune"' >/dev/null 2>&1 || true; sleep 2; fi
echo "→ Instalando em $target…"
rm -rf "$target/Trelune.app"
ditto "$mountpoint/Trelune.app" "$target/Trelune.app"
xattr -dr com.apple.quarantine "$target/Trelune.app" 2>/dev/null || true

version="$(defaults read "$target/Trelune.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
echo "✓ Trelune ${version} instalado em $target/Trelune.app"
[ "${TRELUNE_NO_OPEN:-}" = "1" ] || open "$target/Trelune.app"
