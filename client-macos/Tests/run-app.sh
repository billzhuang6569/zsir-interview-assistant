#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export HTTPS_PROXY=http://127.0.0.1:7897
build="${ZSIR_BUILD_DIR:-.build}"
swift build -c release --scratch-path "$build" --disable-sandbox
xcrun swiftc -module-cache-path "$build/ModuleCache" -parse-as-library -Onone \
    App/RecorderBridge.swift App/Preview.swift App/AppModel.swift \
    Recorder/Options.swift Recorder/StdinControl.swift Tests/AppTests.swift -o "$build/app-selfcheck"
"$build/app-selfcheck"
