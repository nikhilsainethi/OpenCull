#!/bin/bash
# Read-only app ZIP/CLI validation. Never launches or installs software.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
EXPECTED_VERSION="${3:-${VERSION:-0.3.0}}"
ARCHIVE="${1:-$REPO/dist/OpenCull-${EXPECTED_VERSION}-macOS.zip}"
CLI="${2:-$REPO/dist/opencull-cli}"
if [[ ! -f "$ARCHIVE" || ! -f "$CLI" ]]; then
    echo "Missing release ZIP or CLI. Build first, or pass both paths." >&2
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
shasum -a 256 "$ARCHIVE" "$CLI"
echo "Ad-hoc signing verified. Gatekeeper notarization and execution on other hardware are separate checks."
