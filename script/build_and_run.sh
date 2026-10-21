#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---verify}"
case "$MODE" in run|--verify|--build-only) ;; *) echo "usage: $0 [run|--verify|--build-only]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ZSirCapture"
PACKAGE_DIR="$ROOT_DIR/clients/macos"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
CONFIGURATION="${CONFIGURATION:-debug}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in arm64|x86_64) ;; *) echo "Unsupported macOS architecture: $BUILD_ARCH" >&2; exit 2 ;; esac
TRIPLE="$BUILD_ARCH-apple-macosx14.0"
# Never kill a recorder: a rebuild must not interrupt an active Take.
if [[ "$APP_BUNDLE" == "$ROOT_DIR/dist/$APP_NAME.app" ]] && pgrep -x "$APP_NAME" >/dev/null; then
  echo "请先在应用内停止并保存，再按 ⌘Q 退出后重新构建。" >&2
  exit 1
fi
swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --triple "$TRIPLE"
BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" -c "$CONFIGURATION" --triple "$TRIPLE" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$PACKAGE_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ZSirCapture</string>
<key>CFBundleIdentifier</key><string>com.zsir.interview.capture.dev</string>
<key>CFBundleName</key><string>庄Sir采访录制助手</string>
<key>CFBundleDisplayName</key><string>庄Sir采访录制助手</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
<key>NSCameraUsageDescription</key><string>允许后，仅在你点击开始录制时采集摄像头画面，保存为本地采访素材。</string>
<key>NSMicrophoneUsageDescription</key><string>允许后，仅在你点击开始录制时采集话筒声音，录入本地摄像头素材。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_BUNDLE"
if [[ "$MODE" == "--build-only" ]]; then
  echo "Built: $APP_BUNDLE"
  exit 0
fi
/usr/bin/open -n "$APP_BUNDLE"
if [[ "$MODE" == "--verify" ]]; then
  sleep 2
  pgrep -x "$APP_NAME" >/dev/null
fi
