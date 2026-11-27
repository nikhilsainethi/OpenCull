#!/bin/bash
# Build and verify outside synced Documents directories. Preserve prior outputs.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
RELEASE_VERSION="${VERSION:-0.2.0}"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must have three numeric components (for example 0.2.0)." >&2
    exit 2
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt 15 ]]; then
    echo "OpenCull requires the macOS 15+ SDK from Xcode 16 or newer." >&2
    exit 2
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/OpenCull-release.XXXXXX")"
INCOMING=""
cleanup() {
    rm -rf "$STAGE"
    if [[ -n "$INCOMING" && -d "$INCOMING" ]]; then rm -rf "$INCOMING"; fi
}
trap cleanup EXIT
ARTIFACTS="$STAGE/artifacts"
APP="$ARTIFACTS/OpenCull.app"
CLI="$ARTIFACTS/opencull-cli"
ZIP="$ARTIFACTS/OpenCull-${RELEASE_VERSION}-macOS.zip"
ARCHS=(--arch arm64 --arch x86_64)
swift build --package-path "$REPO" --scratch-path "$STAGE/build" -c release "${ARCHS[@]}" --product OpenCull
swift build --package-path "$REPO" --scratch-path "$STAGE/build" -c release "${ARCHS[@]}" --product opencull-cli
BIN="$(swift build --package-path "$REPO" --scratch-path "$STAGE/build" -c release "${ARCHS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$BIN/OpenCull" "$APP/Contents/MacOS/OpenCull"
cp -X "$BIN/opencull-cli" "$CLI"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>OpenCull</string>
    <key>CFBundleDisplayName</key><string>OpenCull</string>
    <key>CFBundleIdentifier</key><string>io.github.opencull.OpenCull</string>
    <key>CFBundleExecutable</key><string>OpenCull</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${RELEASE_VERSION}</string>
    <key>CFBundleVersion</key><string>${RELEASE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSPhotoLibraryUsageDescription</key><string>Choose photographs to copy into a local OpenCull album. Only selected items are imported; your Photos library is not changed.</string>
</dict></plist>
PLIST
# Sign clean temporary artifacts. No account, Developer ID or network needed.
xattr -cr "$ARTIFACTS"
codesign --force --sign - "$APP"
codesign --force --sign - "$CLI"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$CLI"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"
"$REPO/scripts/verify-release.sh" "$ZIP" "$CLI" "$RELEASE_VERSION" | tee "$ARTIFACTS/release-verification.txt"
DIST="$REPO/dist"
mkdir -p "$DIST"
INCOMING="$(mktemp -d "$DIST/.incoming.XXXXXX")"
ditto --norsrc --noextattr --noqtn "$APP" "$INCOMING/OpenCull.app"
cp -X "$CLI" "$INCOMING/opencull-cli"
cp -X "$ZIP" "$INCOMING/$(basename "$ZIP")"
cp -X "$ARTIFACTS/release-verification.txt" "$INCOMING/release-verification.txt"
BACKUP=""
for NAME in OpenCull.app opencull-cli "$(basename "$ZIP")" release-verification.txt; do
    if [[ -e "$DIST/$NAME" || -L "$DIST/$NAME" ]]; then
        if [[ -z "$BACKUP" ]]; then
            mkdir -p "$DIST/.previous"
            BACKUP="$(mktemp -d "$DIST/.previous/build-${RELEASE_VERSION}.XXXXXX")"
        fi
        mv "$DIST/$NAME" "$BACKUP/$NAME"
    fi
    mv "$INCOMING/$NAME" "$DIST/$NAME"
done
rmdir "$INCOMING"
INCOMING=""
cmp "$ZIP" "$DIST/$(basename "$ZIP")"
echo "Built and verified OpenCull $RELEASE_VERSION:"
echo "  $DIST/OpenCull.app"
echo "  $DIST/$(basename "$ZIP")"
echo "  $DIST/opencull-cli"
if [[ -n "$BACKUP" ]]; then echo "Previous generated outputs preserved at $BACKUP"; fi
