#!/bin/bash
set -e

# Auto-detect architecture and use debug by default
ARCH=$(uname -m)
if [ -d ".build/${ARCH}-apple-macosx/debug" ]; then
    DEFAULT_DIR=".build/${ARCH}-apple-macosx/debug"
elif [ -d ".build/debug" ]; then
    DEFAULT_DIR=".build/debug"
else
    DEFAULT_DIR=".build/${ARCH}-apple-macosx/release"
fi
BUILD_DIR="${1:-$DEFAULT_DIR}"
BINARY="$BUILD_DIR/AetherCodex"
RESOURCE_BUNDLE="$BUILD_DIR/AetherCodex_AetherCodex.bundle"
APP_DIR="AetherCodex.app"
ICON_PNG="appicon.png"

echo "🔮 Conjuring AetherCodex.app (from $BUILD_DIR)..."

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/AetherCodex"
chmod +x "$APP_DIR/Contents/MacOS/AetherCodex"

# Generate .icns from appicon.png
if [ -f "$ICON_PNG" ]; then
    ICONSET="AetherCodex.iconset"
    rm -rf "$ICONSET"
    mkdir "$ICONSET"
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
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AetherCodex.icns"
    rm -rf "$ICONSET"
    echo "   🎨 App icon generated."
else
    echo "   ⚠️  No appicon.png found — skipping icon."
fi

# Copy the SwiftPM resource bundle — Bundle.module requires it
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
    # Also copy to app root — SPM's resource_bundle_accessor looks at Bundle.main.bundleURL
    # (the .app directory itself), not resourceURL. This prevents Bundle.module fatalError.
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/"
    # Create subdirectories for resource loaders that expect a directory structure
    # (SPM flattens resource bundles, so ThemeLoader can't find a "Themes/" dir inside)
    mkdir -p "$APP_DIR/Contents/Resources/Themes"
    mkdir -p "$APP_DIR/Contents/Resources/Syntax/queries"
    cp "$RESOURCE_BUNDLE"/*.scm "$APP_DIR/Contents/Resources/Syntax/queries/" 2>/dev/null || true
    # Syntax .yml files (heuristic, languages, tree-sitter-*) go to Syntax/
    # Theme .yml files go to Themes/ — they have 'kind:' field; others will be rejected by ThemeLoader
    cp "$RESOURCE_BUNDLE"/*.yml "$APP_DIR/Contents/Resources/Themes/" 2>/dev/null || true
    cp "$RESOURCE_BUNDLE"/heuristic.yml "$APP_DIR/Contents/Resources/Syntax/" 2>/dev/null || true
    cp "$RESOURCE_BUNDLE"/languages.yml "$APP_DIR/Contents/Resources/Syntax/" 2>/dev/null || true
    cp "$RESOURCE_BUNDLE"/tree-sitter-*.yml "$APP_DIR/Contents/Resources/Syntax/" 2>/dev/null || true
    echo "   📦 Resource bundle copied (Resources + root + subdirs)."
else
    echo "   ⚠️  Resource bundle not found at $RESOURCE_BUNDLE"
fi

# Copy Pythia web chamber (Æther oracle UI)
PYTHIA_DIR="Pythia"
if [ -d "$PYTHIA_DIR" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/Pythia"
    cp -R "$PYTHIA_DIR/." "$APP_DIR/Contents/Resources/Pythia/"
    echo "   🐍 Pythia chamber copied."
else
    echo "   ⚠️  Pythia directory not found"
fi

# Copy the full Ruby intelligence core (1:1 mirror of the plugin brain)
RUBY_DIR="Ruby"
if [ -d "$RUBY_DIR" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/Ruby"
    cp -R "$RUBY_DIR/." "$APP_DIR/Contents/Resources/Ruby/"
    # Never ship any vendored bundle inside the tree (copied separately below)
    rm -rf "$APP_DIR/Contents/Resources/Ruby/.vendor_bundle"
    echo "   💎 Ruby intelligence core copied (full brain)."
else
    echo "   ⚠️  Ruby directory not found"
fi

# Copy Ruby Gems vendor bundle if it exists
VENDOR_BUNDLE="$RUBY_DIR/.vendor_bundle"
if [ -d "$VENDOR_BUNDLE" ]; then
    cp -R "$VENDOR_BUNDLE" "$APP_DIR/Contents/Resources/Ruby/"
    echo "   💎 Ruby gems bundled."
fi

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AetherCodex</string>
    <key>CFBundleIdentifier</key>
    <string>com.aethercodex.editor</string>
    <key>CFBundleName</key>
    <string>AetherCodex</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AetherCodex.icns</string>
</dict>
</plist>
PLIST

# Ad-hoc code sign (required for Apple Silicon / Rosetta)
codesign -s - -f --deep "$APP_DIR" 2>/dev/null && echo "   📜 Ad-hoc signed." || echo "   ⚠️  Signing failed."

echo "✅ AetherCodex.app ready."
echo "   Run:  open AetherCodex.app"
echo "   Or:   ./AetherCodex.app/Contents/MacOS/AetherCodex"