#!/bin/bash
set -euo pipefail

# ÆtherCodex — release DMG builder.
# Builds a release binary, wraps it into AetherCodex.app via bundle_app.sh,
# and stages a Finder-friendly .dmg (app + Applications symlink).
#
# Usage: ./make_dmg.sh [version]

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo '0.1.0')}"
ARCH="$(uname -m)"
BUILD_DIR=".build/${ARCH}-apple-macosx/release"
APP_DIR="AetherCodex.app"
DMG_NAME="AetherCodex-${VERSION}-${ARCH}.dmg"
STAGING="dmg-staging"
VOLNAME="AetherCodex"

echo "🔮 Conjuring ${DMG_NAME} (v${VERSION}, ${ARCH})…"

echo "   ⚙️  Building release (swift build -c release)…"
swift build -c release

echo "   🧪 Bundling ${APP_DIR} from release…"
./bundle_app.sh "$BUILD_DIR"

echo "   📦 Staging DMG contents…"
rm -rf "$STAGING" "$DMG_NAME"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "   💿 Creating compressed DMG (hdiutil)…"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"

echo "   🧹 Cleaning staging…"
rm -rf "$STAGING"

echo "✅ Done: ${DMG_NAME}"
ls -lh "$DMG_NAME"
