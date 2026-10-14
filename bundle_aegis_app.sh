#!/bin/bash
set -e

# Assemble AetherAegis.app — the privilege-holding shield. Signs with the stable
# self-signed identity from `make_aegis_cert.sh` when present, so TCC grants
# survive rebuilds; falls back to ad-hoc otherwise (with a warning).
ARCH=$(uname -m)
if [ -d ".build/${ARCH}-apple-macosx/debug" ]; then
    DEFAULT_DIR=".build/${ARCH}-apple-macosx/debug"
elif [ -d ".build/debug" ]; then
    DEFAULT_DIR=".build/debug"
else
    DEFAULT_DIR=".build/${ARCH}-apple-macosx/release"
fi
BUILD_DIR="${1:-$DEFAULT_DIR}"
BINARY="$BUILD_DIR/AetherAegis"
APP_DIR="AetherAegis.app"
ICON_PNG="appicon.png"

echo "🛡 Conjuring AetherAegis.app (from $BUILD_DIR)..."

[ -f "$BINARY" ] || { echo "   ✗ $BINARY not found — run: swift build --product AetherAegis"; exit 1; }

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/AetherAegis"
chmod +x "$APP_DIR/Contents/MacOS/AetherAegis"

# Icon (reuses the app icon; the shield will gain its own glyph later).
if [ -f "$ICON_PNG" ]; then
    ICONSET="AetherAegis.iconset"
    rm -rf "$ICONSET"; mkdir "$ICONSET"
    sips -z 16 16   "$ICON_PNG" --out "$ICONSET/icon_16x16.png"       >/dev/null 2>&1
    sips -z 32 32   "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null 2>&1
    sips -z 32 32   "$ICON_PNG" --out "$ICONSET/icon_32x32.png"       >/dev/null 2>&1
    sips -z 64 64   "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null 2>&1
    sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png"     >/dev/null 2>&1
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null 2>&1
    sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png"     >/dev/null 2>&1
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null 2>&1
    sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png"     >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AetherAegis.icns"
    rm -rf "$ICONSET"
    echo "   🎨 Icon generated."
fi

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AetherAegis</string>
    <key>CFBundleIdentifier</key>
    <string>com.aethercodex.aegis</string>
    <key>CFBundleName</key>
    <string>AetherAegis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AetherAegis.icns</string>
    <!-- Screen Recording & Accessibility need usage strings to avoid a hard
         termination the first time the TCC prompt would appear. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>The Ægis reflects the light of the screen so the oracle may behold your work.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>The Ægis speaks to other applications on the oracle's behalf.</string>
</dict>
</plist>
PLIST

# Sign with the stable identity when available, else ad-hoc.
IDENTITY="AetherAegis Identity"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign -s "$IDENTITY" -f --deep "$APP_DIR" 2>/dev/null \
        && echo "   📜 Signed with stable identity ($IDENTITY)." \
        || { echo "   ⚠️  Stable sign failed; ad-hoc fallback."; codesign -s - -f --deep "$APP_DIR"; }
else
    echo "   ⚠️  No stable identity — run ./make_aegis_cert.sh once, else TCC re-prompts on rebuild."
    codesign -s - -f --deep "$APP_DIR" 2>/dev/null || echo "   ⚠️  Signing failed."
fi

echo "✅ AetherAegis.app ready."
echo "   Install it to a stable location so the grants anchor:"
echo "       cp -R AetherAegis.app /Applications/"
echo "   Then open it once and grant the lights."
