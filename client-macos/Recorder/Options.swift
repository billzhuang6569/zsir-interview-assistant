import Foundation

struct RecorderError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Options {
    var command: String
    var out: URL?
    var tracks: Set<String> = ["cam", "screen"]
    var camera: String?
    var mic: String?
    var display: String?
    var duration: Double?
    var quality = "recommended"

    init(_ args: [String]) throws {
        guard let command = args.first, ["devices", "preflight", "capture"].contains(command) else {
            throw RecorderError("USAGE: recorder devices --json | preflight --json [--camera id] [--mic id] [--display id] | capture --out dir [--tracks cam,screen] [--duration seconds] [--quality saver|recommended|high]")
        }
        self.command = command
        var i = 1
        var seen = Set<String>()
        while i < args.count {
            let key = args[i]
            guard seen.insert(key).inserted else { throw RecorderError("ARGUMENT: 重复参数 \(key)") }
            if key == "--json", command != "capture" { i += 1; continue }
            let allowed = command == "devices" ? [] : command == "preflight" ? ["--camera", "--mic", "--display"] : ["--camera", "--mic", "--display", "--out", "--tracks", "--duration", "--quality"]
            guard allowed.contains(key), i + 1 < args.count else { throw RecorderError("ARGUMENT: 未知参数或缺少值 \(key)") }
            let value = args[i + 1]
            switch key {
            case "--out": out = URL(fileURLWithPath: value, isDirectory: true)
            case "--camera": camera = value
            case "--mic": mic = value
            case "--display": display = value
            case "--tracks":
                let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, parts.allSatisfy({ ["cam", "screen"].contains($0) }), Set(parts).count == parts.count else { throw RecorderError("ARGUMENT: tracks 必须为 cam、screen 或 cam,screen") }
                tracks = Set(parts)
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { throw RecorderError("ARGUMENT: duration 必须为正有限秒数") }
                duration = seconds
            case "--quality":
                guard ["saver", "recommended", "high"].contains(value) else { throw RecorderError("ARGUMENT: 无效 quality") }
                quality = value
            default: break
            }
            i += 2
        }
        if command == "capture", out == nil { throw RecorderError("ARGUMENT: capture 需要 --out") }
    }
    var cameraWidth: Int { quality == "high" ? 3840 : 1920 }
    var screenWidth: Int { quality == "high" ? Int.max : quality == "saver" ? 1920 : 2560 }
    var screenFPS: Int { quality == "saver" ? 15 : 30 }
    func bitrate(_ track: String) -> Int {
        quality == "high" ? (track == "cam" ? 20_000_000 : 16_000_000) : quality == "saver" ? (track == "cam" ? 6_000_000 : 5_000_000) : 10_000_000
    }
}

func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
func emit(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    } catch { FileHandle.standardError.write(Data("JSON: \(error)\n".utf8)) }
}
