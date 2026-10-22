#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---verify}"
case "$MODE" in run|--verify|--build-only) ;; *) echo "usage: $0 [run|--verify|--build-only]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ZSirCapture"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
PACKAGE_DIR="$ROOT_DIR/clients/macos"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/dist/$APP_NAME.app}"
CONFIGURATION="${CONFIGURATION:-debug}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in arm64|x86_64) ;; *) echo "Unsupported macOS architecture: $BUILD_ARCH" >&2; exit 2 ;; esac
MACOS12_COMPAT="${MACOS12_COMPAT:-0}"
SWIFT_OPTIONS=(--package-path "$PACKAGE_DIR" -c "$CONFIGURATION")
case "$MACOS12_COMPAT" in
  0) MIN_MACOS=13.0 ;;
  1) MIN_MACOS=12.3; SWIFT_OPTIONS+=(-Xswiftc -DZSIR_MACOS12_COMPAT) ;;
  *) echo "MACOS12_COMPAT must be 0 or 1" >&2; exit 2 ;;
esac
TRIPLE="$BUILD_ARCH-apple-macosx$MIN_MACOS"
# SwiftPM otherwise replaces the triple deployment version with Package.swift's shared 12.3 floor.
SWIFT_OPTIONS+=(-Xswiftc -target -Xswiftc "$TRIPLE")
# Never kill a recorder: a rebuild must not interrupt an active Take.
if [[ "$APP_BUNDLE" == "$ROOT_DIR/dist/$APP_NAME.app" ]] && pgrep -x "$APP_NAME" >/dev/null; then
  echo "请先在应用内停止并保存，再按 ⌘Q 退出后重新构建。" >&2
  exit 1
fi
swift build "${SWIFT_OPTIONS[@]}" --triple "$TRIPLE"
BUILD_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --triple "$TRIPLE" --show-bin-path)"
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
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSCameraUseContinuityCameraDeviceType</key><true/>
<key>NSCameraUsageDescription</key><string>用于设置页预览和录制摄像头画面；只有开始录制后才保存本地采访素材。</string>
<key>NSMicrophoneUsageDescription</key><string>用于设置页麦克风电平检测和录制声音；只有开始录制后才保存本地采访素材。</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
if [[ "$MACOS12_COMPAT" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 12.3' "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.zsir.interview.capture.monterey' "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName 庄Sir采访录制助手（macOS12兼容版）' "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 庄Sir采访录制助手（macOS12兼容版）' "$APP_BUNDLE/Contents/Info.plist"
fi
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
