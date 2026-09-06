#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_ROOT/dist/Codex Token Observer.app"
SOURCE_DIR="$PROJECT_ROOT/src"
cd "$SCRIPT_DIR"
BUILD_OPTIONS=(-c release --arch arm64 -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=/codex-token-observer")
swift build "${BUILD_OPTIONS[@]}"
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/CodexTokenObserver"
if [[ "$(lipo -archs "$EXECUTABLE")" != "arm64" ]]; then
    print -u2 -- "Expected an arm64 executable; refusing to package another architecture."
    exit 1
fi

# Stage a clean bundle so obsolete resources from an earlier build cannot leak
# into a public download, and a failed build leaves the existing app untouched.
mkdir -p "$PROJECT_ROOT/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_ROOT/dist/.observer-build.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Codex Token Observer.app"
CONTENTS="$STAGED_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/counter"
cp -X "$EXECUTABLE" "$CONTENTS/MacOS/CodexTokenObserver"
# Swift's prefix map does not rewrite the linker's OSO debug-map entries, which
# can retain absolute object-file paths. Remove debug symbols before signing.
strip -S "$CONTENTS/MacOS/CodexTokenObserver"
cp -X "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp -X "$PROJECT_ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"
cp -X "$PROJECT_ROOT/PRIVACY.md" "$CONTENTS/Resources/PRIVACY.md"

# The counter is a pure-Python package. Deliberately copy only source files, not
# __pycache__, .pyc files, logs, local databases, credentials, or other siblings.
SOURCE_FILES=("$SOURCE_DIR"/codex_token_counter/**/*.py(N))
if (( ${#SOURCE_FILES[@]} == 0 )); then
    print -u2 -- "No counter Python sources found."
    exit 1
fi
for SOURCE_FILE in "${SOURCE_FILES[@]}"; do
    RELATIVE_PATH="${SOURCE_FILE#$SOURCE_DIR/}"
    DESTINATION="$CONTENTS/Resources/counter/src/$RELATIVE_PATH"
    mkdir -p "${DESTINATION:h}"
    cp -X "$SOURCE_FILE" "$DESTINATION"
done
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
rm -rf -- "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
echo "$APP_DIR"
