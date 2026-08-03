#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
VERSION="${1:-0.1.0}"
APP_NAME="Codex Token Observer"
APP_DIR="$PROJECT_ROOT/dist/$APP_NAME.app"
RELEASE_DIR="$PROJECT_ROOT/release"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-macos-arm64.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

"$SCRIPT_DIR/build-app.sh" >/dev/null
mkdir -p "$RELEASE_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
