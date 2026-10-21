#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build="${ZSIR_BUILD_DIR:-/tmp/zsir-mac-selfcheck-build}"
HTTPS_PROXY=http://127.0.0.1:7897 swift build -c release --scratch-path "$build" --disable-sandbox
bin=$(HTTPS_PROXY=http://127.0.0.1:7897 swift build -c release --scratch-path "$build" --show-bin-path --disable-sandbox)
xcrun swiftc -module-cache-path "$build/ModuleCache" -parse-as-library -Onone -I "$bin/Modules" \
    Recorder/Options.swift Recorder/TrackWriter.swift Recorder/CaptureEngine.swift \
    Tests/RecorderTests.swift "$bin/Shared.build/Version.swift.o" -o "$build/selfcheck"
"$build/selfcheck" "$@"
