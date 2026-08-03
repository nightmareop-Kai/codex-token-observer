#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_ROOT/dist/Codex Token Observer.app"
CONTENTS="$APP_DIR/Contents"
cd "$SCRIPT_DIR"
swift build -c release
rm -rf -- "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/counter"
cp ".build/release/CodexTokenObserver" "$CONTENTS/MacOS/CodexTokenObserver"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
ditto "$PROJECT_ROOT/src" "$CONTENTS/Resources/counter/src"
mkdir -p "$CONTENTS/Resources/counter/data"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
