#!/bin/zsh
# Builds the release binary (Universal: arm64 + x86_64) and wraps it in build/C64.app.
# Signs with the "Developer ID Application" identity (hardened runtime) when it is in the
# keychain, otherwise ad-hoc (anyone building from source).
#   ./scripts/make-app.sh             # build + sign
#   ./scripts/make-app.sh --release   # also notarize, staple and zip to build/C64.app.zip
# Overrides: SIGN_ID=..., NOTARY_PROFILE=... (default "App Store Connect Profile").
# Version: VERSION=0.2.0 BUILD=2 ./scripts/make-app.sh --release   (then tag the release v0.2.0).
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/C64Emu"
APP=build/C64.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/C64"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>C64</string>
    <key>CFBundleDisplayName</key><string>C64</string>
    <key>CFBundleIdentifier</key><string>com.c64emu.C64</string>
    <key>CFBundleExecutable</key><string>C64</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Commodore 64 Media</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>prg</string><string>p00</string><string>d64</string><string>d71</string>
                <string>d81</string><string>g64</string><string>t64</string><string>tap</string>
                <string>crt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
# The updater compares this with release tags (vX.Y.Z), so it must match the tag's X.Y.Z.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  SIGN_ID="-"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (signed: $SIGN_ID)"

if [ "$1" = "--release" ]; then
  [ "$SIGN_ID" != "-" ] || { echo "--release needs a Developer ID Application identity" >&2; exit 1; }
  ZIP=build/C64.app.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-App Store Connect Profile}" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl -a -vv -t exec "$APP"
  echo "Notarized and stapled: $ZIP"
fi
