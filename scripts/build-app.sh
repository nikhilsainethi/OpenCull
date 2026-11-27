#!/bin/bash
# Builds dist/OpenCull.app (universal: Apple Silicon + Intel), the opencull-cli tool
# and a zip ready to attach to a GitHub release.
#
#   ./scripts/build-app.sh            # version 0.1.0
#   VERSION=0.2.0 ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product OpenCull
swift build -c release "${ARCHS[@]}" --product opencull-cli
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="dist/OpenCull.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OpenCull" "$APP/Contents/MacOS/OpenCull"
cp "$BIN/opencull-cli" dist/opencull-cli

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OpenCull</string>
    <key>CFBundleDisplayName</key><string>OpenCull</string>
    <key>CFBundleIdentifier</key><string>io.github.opencull.OpenCull</string>
    <key>CFBundleExecutable</key><string>OpenCull</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. For distribution without Gatekeeper warnings, sign with a
# Developer ID certificate and notarize instead (see README).
codesign --force --sign - "$APP"
codesign --force --sign - dist/opencull-cli

(cd dist && ditto -c -k --keepParent OpenCull.app "OpenCull-${VERSION}-macOS.zip")
echo "Built $APP and dist/OpenCull-${VERSION}-macOS.zip"
lipo -info "$APP/Contents/MacOS/OpenCull"
