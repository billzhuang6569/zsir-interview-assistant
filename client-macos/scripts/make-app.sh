#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export HTTPS_PROXY=http://127.0.0.1:7897
build="${ZSIR_BUILD_DIR:-.build}"
swift build -c release --scratch-path "$build" --disable-sandbox
bin=$(swift build -c release --scratch-path "$build" --show-bin-path --disable-sandbox)
app="${1:-$PWD/.build/庄Sir线上采访助手.app}"
mkdir -p "$app/Contents/MacOS"
cp "$bin/App" "$app/Contents/MacOS/App"
cp "$bin/recorder" "$app/Contents/MacOS/recorder"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>work.zsir.interview</string>
<key>CFBundleName</key><string>庄Sir线上采访助手</string>
<key>CFBundleDisplayName</key><string>庄Sir线上采访助手</string>
<key>CFBundleExecutable</key><string>App</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>14</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>用于您主动打开的设备预览、自检和采访摄像头录制。</string>
<key>NSMicrophoneUsageDescription</key><string>用于您主动打开的音量预览、自检和采访话筒录制。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"
printf 'APP_BUNDLE=%s\n' "$app"
