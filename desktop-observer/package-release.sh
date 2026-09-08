#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
if (( $# > 1 )); then
    print -u2 -- "Usage: $0 [version matching Info.plist]"
    exit 1
fi
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")"
VERSION="${1:-$BUNDLE_VERSION}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 -- "The release version must have the form major.minor.patch."
    exit 1
fi
if [[ "$VERSION" != "$BUNDLE_VERSION" ]]; then
    print -u2 -- "Requested version $VERSION does not match Info.plist ($BUNDLE_VERSION)."
    exit 1
fi
APP_NAME="Zuno"
APP_DIR="$PROJECT_ROOT/dist/$APP_NAME.app"
RELEASE_DIR="$PROJECT_ROOT/release"
ZIP_NAME="$APP_NAME-$VERSION-macos-arm64.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
CHECKSUM_PATH="$ZIP_PATH.sha256"

mkdir -p "$RELEASE_DIR"
if [[ -e "$ZIP_PATH" || -e "$CHECKSUM_PATH" ]]; then
    print -u2 -- "Release $VERSION already exists; choose a new version instead of overwriting it."
    exit 1
fi
LOCK_DIR="$RELEASE_DIR/.package-$VERSION.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    print -u2 -- "A package operation for $VERSION is already in progress ($LOCK_DIR)."
    exit 1
fi
STAGING_DIR=""
cleanup() {
    if [[ -n "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
    rmdir "$LOCK_DIR"
}
trap cleanup EXIT
STAGING_DIR="$(mktemp -d "$RELEASE_DIR/.package-stage.XXXXXX")"

"$SCRIPT_DIR/build-app.sh" >/dev/null
PACKAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
if [[ "$PACKAGED_VERSION" != "$VERSION" ]]; then
    print -u2 -- "The built bundle version changed during packaging; no release was created."
    exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_DIR/$ZIP_NAME"
(
    cd "$STAGING_DIR"
    shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
    shasum -a 256 -c "$ZIP_NAME.sha256" >/dev/null
)
# Same-filesystem links publish each completed file without overwriting any
# existing destination, even if a second writer races the earlier check.
ln "$STAGING_DIR/$ZIP_NAME" "$ZIP_PATH"
ln "$STAGING_DIR/$ZIP_NAME.sha256" "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
