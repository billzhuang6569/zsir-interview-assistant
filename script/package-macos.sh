#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
MACOS12_COMPAT="${MACOS12_COMPAT:-0}"
EDITION=macos
NAME="庄Sir采访录制助手"
if [[ "$MACOS12_COMPAT" == 1 ]]; then EDITION=macos12; NAME="庄Sir采访录制助手（macOS12兼容版）"; fi
ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 2 ;; esac
STAGE="$ROOT_DIR/dist/release/ZSirCapture-$VERSION-$EDITION-$ARCH"
if [[ -e "$STAGE" ]]; then echo "Package directory already exists: $STAGE" >&2; exit 1; fi
mkdir -p "$STAGE"
APP_BUNDLE="$STAGE/$NAME.app" MACOS12_COMPAT="$MACOS12_COMPAT" CONFIGURATION=release BUILD_ARCH="$ARCH" "$ROOT_DIR/script/build_and_run.sh" --build-only
cp "$ROOT_DIR/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT_DIR/docs/releases/$VERSION.md" "$STAGE/README.md"
codesign --verify --deep --strict "$STAGE/$NAME.app"
plutil -lint "$STAGE/$NAME.app/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$STAGE.zip"
shasum -a 256 "$STAGE.zip"
