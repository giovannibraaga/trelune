#!/bin/bash
# Builds dist/Trelune.app and opens it.
# Optional settings come from the environment or a local, git-ignored .env file:
#   BUNDLE_ID          bundle identifier (default app.trelune.mac). It also namespaces the Keychain
#                      items and the app preferences, so keep it stable once you connect accounts.
#   CODESIGN_IDENTITY  signing identity (default: first "Apple Development" certificate, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi
BUNDLE_ID="${BUNDLE_ID:-app.trelune.mac}"
APP=dist/Trelune.app

pkill -x Trelune || true
swift build
binary="$(swift build --show-bin-path)/Trelune"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/Trelune"
cp "$binary" "$APP/Contents/MacOS/Trelune"
cp Assets/TreluneMark.png "$APP/Contents/Resources/TreluneMark.png"
# App icon from Assets/AppIcon.png (regenerated only when the PNG changes).
icon_out="$APP/Contents/Resources/AppIcon.icns"
if [ -f Assets/AppIcon.png ] && [ Assets/AppIcon.png -nt "$icon_out" ]; then
  iconset="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icon_out"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Trelune</string><key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string><key>CFBundleName</key><string>Trelune</string><key>CFBundleDisplayName</key><string>Trelune</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
# Sign with a stable identity so Keychain "Always Allow" survives rebuilds.
# Ad-hoc signatures are identified by the binary hash, which changes every build.
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')}"
if [ -n "$identity" ]; then
  codesign --force --timestamp=none --sign "$identity" "$APP"
else
  echo "warning: no Apple Development certificate found; using ad-hoc signing (Keychain will ask again after each build)" >&2
  codesign --force --sign - "$APP"
fi
# Refresh LaunchServices so Finder and the Dock pick up icon changes.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
[ "${NO_OPEN:-}" = "1" ] || open -n "$APP"
