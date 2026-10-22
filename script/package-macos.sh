#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.2.0"
ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 2 ;; esac
STAGE="$ROOT_DIR/dist/release/ZSirCapture-$VERSION-macos-$ARCH"
if [[ -e "$STAGE" ]]; then echo "Package directory already exists: $STAGE" >&2; exit 1; fi
mkdir -p "$STAGE"
APP_BUNDLE="$STAGE/庄Sir采访录制助手.app" CONFIGURATION=release BUILD_ARCH="$ARCH" "$ROOT_DIR/script/build_and_run.sh" --build-only
cp "$ROOT_DIR/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT_DIR/docs/releases/$VERSION.md" "$STAGE/README.md"
codesign --verify --deep --strict "$STAGE/庄Sir采访录制助手.app"
plutil -lint "$STAGE/庄Sir采访录制助手.app/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$STAGE.zip"
shasum -a 256 "$STAGE.zip"
