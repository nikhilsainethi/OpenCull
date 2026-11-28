#!/bin/bash
# Read-only app ZIP/DMG/CLI validation. Never launches or installs software.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
EXPECTED_VERSION="${3:-${VERSION:-0.4.0}}"
ARCHIVE="${1:-$REPO/dist/OpenCull-${EXPECTED_VERSION}-macOS.zip}"
CLI="${2:-$REPO/dist/opencull-cli}"
DMG="${4:-$REPO/dist/OpenCull-${EXPECTED_VERSION}-macOS.dmg}"
if [[ ! -f "$ARCHIVE" || ! -f "$CLI" ]]; then
    echo "Missing release ZIP or CLI. Build first, or pass both paths." >&2
    exit 2
fi
if [[ -n "${4:-}" && ! -f "$DMG" ]]; then
    echo "Missing disk image: $DMG" >&2
    exit 2
fi
while IFS= read -r ENTRY; do
    case "$ENTRY" in
        /*|../*|*/../*|*/..|*\\*) echo "Unsafe archive member: $ENTRY" >&2; exit 1 ;;
    esac
    case "$ENTRY" in OpenCull.app|OpenCull.app/*) ;; *) echo "Unexpected archive member: $ENTRY" >&2; exit 1 ;; esac
done < <(unzip -Z1 "$ARCHIVE")
while IFS= read -r ENTRY; do
    case "$ENTRY" in l?????????*) echo "Symlinks are not expected in this release archive." >&2; exit 1 ;; esac
done < <(unzip -Z -l "$ARCHIVE")
unzip -tq "$ARCHIVE"
VERIFY_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/OpenCull-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_STAGE"' EXIT
ditto -x -k --norsrc --noextattr --noqtn "$ARCHIVE" "$VERIFY_STAGE"
APP="$VERIFY_STAGE/OpenCull.app"
BINARY="$APP/Contents/MacOS/OpenCull"
PLIST="$APP/Contents/Info.plist"
test -x "$BINARY"
plutil -lint "$PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "io.github.opencull.OpenCull"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = "14.0"
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSPhotoLibraryUsageDescription' "$PLIST")"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$CLI"
for ARCH in arm64 x86_64; do
    lipo "$BINARY" -verify_arch "$ARCH"
    lipo "$CLI" -verify_arch "$ARCH"
done
for EXECUTABLE in "$BINARY" "$CLI"; do
    MINIMUMS="$(xcrun vtool -show-build "$EXECUTABLE" | awk '$1 == "minos" {print $2}')"
    test -n "$MINIMUMS"
    while IFS= read -r MINIMUM; do
        case "$MINIMUM" in 14.0|14.0.*) ;; *) echo "Unexpected deployment target $MINIMUM in $EXECUTABLE" >&2; exit 1 ;; esac
    done <<< "$MINIMUMS"
done
echo "Verified OpenCull $EXPECTED_VERSION: fresh extraction, bundle metadata, strict signatures, arm64 + x86_64, macOS 14 deployment target."
if [[ -f "$DMG" ]]; then
    # Mount read-only without opening Finder; the image must hold the same app plus an Applications link.
    hdiutil verify -quiet "$DMG"
    MOUNT="$VERIFY_STAGE/dmg-mount"
    mkdir -p "$MOUNT"
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
    trap 'hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || hdiutil detach -quiet -force "$MOUNT" >/dev/null 2>&1 || true; rm -rf "$VERIFY_STAGE"' EXIT
    test -L "$MOUNT/Applications"
    test "$(readlink "$MOUNT/Applications")" = "/Applications"
    DMG_APP="$MOUNT/OpenCull.app"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DMG_APP/Contents/Info.plist")" = "$EXPECTED_VERSION"
    codesign --verify --deep --strict "$DMG_APP"
    for ARCH in arm64 x86_64; do lipo "$DMG_APP/Contents/MacOS/OpenCull" -verify_arch "$ARCH"; done
    cmp "$DMG_APP/Contents/MacOS/OpenCull" "$BINARY"
    hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT"
    trap 'rm -rf "$VERIFY_STAGE"' EXIT
    echo "Verified disk image: Applications link, same signed universal app as the ZIP."
    shasum -a 256 "$ARCHIVE" "$DMG" "$CLI"
else
    shasum -a 256 "$ARCHIVE" "$CLI"
fi
echo "Ad-hoc signing verified. Gatekeeper notarization and execution on other hardware are separate checks."
