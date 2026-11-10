#!/bin/bash
# Builds a distributable Trelune for macOS: universal app (Apple silicon + Intel) in a DMG.
#   VERSION=1.0.0 ./script/release.sh            -> dist/release/Trelune-1.0.0.dmg
# Signing:
#   - With a "Developer ID Application" certificate (or DEVELOPER_ID="Developer ID Application: …"), the app is
#     signed with the hardened runtime. If NOTARY_PROFILE names a `xcrun notarytool store-credentials` profile,
#     the DMG is notarized and stapled, so it opens on any Mac without warnings.
#   - Without it, the app is signed ad hoc; people open it once with right-click → Abrir (see README).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${RELEASE_BUNDLE_ID:-app.trelune.mac}"
OUT=dist/release
APP="$OUT/Trelune.app"
DMG="$OUT/Trelune-$VERSION.dmg"

rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "→ Compilando (arm64 + x86_64, release)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Trelune"
cp "$BIN" "$APP/Contents/MacOS/Trelune"
lipo -info "$APP/Contents/MacOS/Trelune"
cp Assets/TreluneMark.png "$APP/Contents/Resources/TreluneMark.png"

iconset="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Trelune</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>Trelune</string>
<key>CFBundleDisplayName</key><string>Trelune</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Trelune · open source</string>
</dict></plist>
PLIST

IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
  echo "→ Assinando com Developer ID"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "→ Sem Developer ID: assinatura ad hoc (o macOS pedirá confirmação na primeira abertura)"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "→ Gerando DMG"
staging="$(mktemp -d)"
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Trelune $VERSION" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "$IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "→ Notarizando"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Pronto: $DMG"
