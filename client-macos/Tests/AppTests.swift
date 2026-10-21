import Foundation
import AppKit

@main
struct AppTests {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--control-child") {
            let control = StdinControl(grace: 0.3) { exit(0) }
            control.start()
            for _ in 0..<100 { emit(["alive": true]); try await Task.sleep(nanoseconds: 20_000_000) }
            withExtendedLifetime(control) {}
            exit(7)
        }
        var parser = JSONLines()
        let partial = try parser.append(Data("{\"t\":".utf8)); assert(partial.isEmpty)
        let values = try parser.append(Data("1}\n{\"errors\":[\"错误\"]}\n".utf8))
        assert(values.count == 2 && values[1]["errors"] as? [String] == ["错误"])
        do { _ = try parser.append(Data("[]\n".utf8)); fatalError("invalid JSON object accepted") } catch {}
        let opts = try Options(["capture", "--out", "/tmp/test", "--stdin-control"])
        assert(opts.stdinControl)
        for args in [["preflight", "--stdin-control"], ["capture", "--out", "/tmp/a", "--stdin-control", "--stdin-control"]] {
            do { _ = try Options(args); fatalError("invalid flag accepted") } catch {}
        }
        print("PASS: chunked JSON lines, UTF-8, invalid records, stdin flag validation")

        // Real subprocess: broken stdout must survive, partial stop must wait for newline.
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--control-child"]; process.standardInput = input; process.standardOutput = output
        try process.run(); input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
        _ = output.fileHandleForReading.availableData
        output.fileHandleForReading.closeFile()
        try input.fileHandleForWriting.write(contentsOf: Data("nonsense\nsto".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        assert(process.isRunning, "broken stdout or partial stop killed recorder")
        try input.fileHandleForWriting.write(contentsOf: Data("p\n".utf8))
        process.waitUntilExit(); assert(process.terminationStatus == 0)
        input.fileHandleForWriting.closeFile()

        let orphan = Process(); let orphanInput = Pipe()
        orphan.executableURL = process.executableURL; orphan.arguments = ["--control-child"]
        orphan.standardInput = orphanInput; orphan.standardOutput = FileHandle.nullDevice
        try orphan.run(); orphanInput.fileHandleForReading.closeFile()
        orphanInput.fileHandleForWriting.closeFile()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(orphan.isRunning, "EOF stopped immediately")
        orphan.waitUntilExit(); assert(orphan.terminationStatus == 0)
        print("PASS: real subprocess stdin stop, ignored unknown line, broken stdout survival, EOF grace/final callback")

        let bridge = RecorderBridge()
        var received = false
        var finished: Int32?
        try bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"t\":1,\"tracks\":{}}\\n'; read line; test \"$line\" = stop"], logURL: nil,
                         event: { _ in received = true }, completion: { code, _ in finished = code })
        for _ in 0..<100 { if received { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(received); try bridge.stop()
        for _ in 0..<100 { if finished != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(finished == 0)
        let crashing = RecorderBridge(); var crash: Int32?
        try crashing.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 9"], logURL: nil, event: { _ in }, completion: { code, _ in crash = code })
        for _ in 0..<100 { if crash != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(crash == 9)
        print("PASS: RecorderBridge JSON delivery, stdin stop, completion order, nonzero watchdog status")

        let suite = "zsir-selfcheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.output = directory.path; model.camera = "camera-id"; model.scope = "screen"
        assert(AppModel(defaults: defaults).camera == "camera-id")
        try model.checkOutput()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path); assert(files.isEmpty)
        model.phase = "starting"; model.receive(["t": 1.0, "tracks": ["screen": ["ok": true]], "levels": ["screen": -20.0]])
        assert(model.phase == "recording" && model.elapsed == 1)
        model.phase = "stopping"; model.receive(["t": 2.0]); assert(model.phase == "stopping")
        model.completed(9, nil); assert(model.phase == "error" && model.message.contains("RECORDER_CRASHED") && model.capture == nil)
        model.completed(0, nil); assert(model.phase == "ready")
        defaults.set(directory.path, forKey: "activeSession")
        try Data("{\"state\":\"finished\"}".utf8).write(to: directory.appendingPathComponent("session.json"))
        model.recover(); assert(model.saved?.path == directory.path && model.phase == "ready")
        defaults.set(directory.path, forKey: "activeSession")
        try Data("{\"state\":\"recording\"}".utf8).write(to: directory.appendingPathComponent("session.json"))
        model.recover(); assert(model.phase == "error")
        defaults.set(true, forKey: "onboarded")
        model.permissions = [true, true, true]; model.phase = "ready"
        model.start(); assert(model.phase == "countdown" && model.countdown == 3)
        model.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        assert(model.phase == "ready" && model.capture == nil)
        print("PASS: persistence, output write probe, recording/stopping/error transitions, recovery, countdown cancellation")
        let fixture = directory.appendingPathComponent("fake-recorder")
        let script = """
        #!/bin/sh
        case "$1" in
          devices) printf '{"cameras":[{"id":"cam","name":"Camera"}],"mics":[{"id":"mic","name":"Mic"}],"displays":[{"id":"1","name":"Display"}]}\\n' ;;
          preflight) printf '{"cam":{"ok":true},"screen":{"ok":true},"systemAudio":{"ok":true},"encoder":"test","diskFreeBytes":99999999999,"errors":[]}\\n' ;;
          capture)
            shift
            while [ "$#" -gt 0 ]; do
              if [ "$1" = --out ]; then shift; out="$1"; fi
              shift
            done
            printf '{"state":"recording"}' > "$out/session.json"
            printf '{"t":1,"tracks":{"screen":{"ok":true}},"levels":{"screen":-20}}\\n'
            read line
            test "$line" = stop || exit 8
            printf '{"state":"finished"}' > "$out/session.json"
            ;;
        esac
        """
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let live = AppModel(defaults: defaults, recorder: fixture)
        live.loadDevices()
        for _ in 0..<100 { if !live.displays.isEmpty { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(live.displays.count == 1)
        live.runPreflight()
        for _ in 0..<100 { if !live.checking { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(live.preflightOK)
        live.permissions = [true, true, true]
        let started = Date()
        live.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(live.capture == nil && live.phase == "countdown")
        for _ in 0..<200 { if live.phase == "recording" { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(live.phase == "recording" && Date().timeIntervalSince(started) >= 3)
        assert(defaults.string(forKey: "activeSession") != nil && defaults.integer(forKey: "activePID") > 0)
        live.phase = "stopping"; try live.capture?.stop()
        for _ in 0..<100 { if live.phase != "stopping" { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        assert(live.phase == "ready" && live.saved != nil && defaults.string(forKey: "activeSession") == nil)
        print("PASS: AppModel devices/preflight, full 3-second countdown, capture JSON, stdin stop/finalize, saved directory (fixture subprocess)")

    }
}
