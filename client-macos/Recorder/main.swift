import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

// Authorization callbacks can remain pending while nobody is at the Mac.
final class PermissionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ allowed: Bool) { lock.lock(); value = allowed; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

func permissions(_ tracks: Set<String>) async -> [String] {
    var errors: [String] = []
    if tracks.contains("screen"), !CGPreflightScreenCaptureAccess() {
        // Request on a worker: the system prompt must not stall JSON output forever.
        DispatchQueue.global().async { _ = CGRequestScreenCaptureAccess() }
        errors.append("PERMISSION_SCREEN: 请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中授权当前终端/recorder，然后重试")
    }
    if tracks.contains("cam") {
        for (type, code) in [(AVMediaType.video, "PERMISSION_CAMERA"), (.audio, "PERMISSION_MIC")] {
            let status = AVCaptureDevice.authorizationStatus(for: type)
            if status == .authorized { continue }
            if status == .notDetermined {
                let result = PermissionResult()
                AVCaptureDevice.requestAccess(for: type) { result.set($0) }
                let deadline = Date().addingTimeInterval(5)
                while result.get() == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                if result.get() == true { continue }
            }
            errors.append("\(code): 权限未授予；请在系统设置 → 隐私与安全性中允许当前终端/recorder 访问\(type == .video ? "摄像头" : "麦克风")，然后重试")
        }
    }
    return errors
}

func main() async -> Int32 {
    var preflight = false
    var engine: CaptureEngine?
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    do {
        var options = try Options(Array(CommandLine.arguments.dropFirst()))
        preflight = options.command == "preflight"
        if options.command == "devices" {
            var ids = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { throw RecorderError("DEVICE_DISPLAY: 无法枚举显示器") }
            emit(["cameras": captureDevices(.video).map { ["id": $0.uniqueID, "name": $0.localizedName] },
                  "mics": captureDevices(.audio).map { ["id": $0.uniqueID, "name": $0.localizedName] },
                  "displays": ids.prefix(Int(count)).map { id -> [String: Any] in
                      let mode = CGDisplayCopyDisplayMode(id)
                      return ["id": String(id), "name": "Display \(id)", "width": mode?.pixelWidth ?? CGDisplayPixelsWide(id), "height": mode?.pixelHeight ?? CGDisplayPixelsHigh(id)]
                  }])
            return 0
        }
        let errors = await permissions(options.tracks)
        if !errors.isEmpty { throw RecorderError(errors.joined(separator: "\n")) }
        if preflight {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zsir-preflight-\(UUID().uuidString)")
            temporary = dir; options.out = dir; options.duration = 3
        }
        guard let directory = options.out else { throw RecorderError("ARGUMENT: 缺少输出目录") }
        let capture = CaptureEngine(options: options, directory: directory)
        engine = capture
        try await capture.configure()
        try await capture.run(report: !preflight)
        if preflight {
            var errors: [String] = []
            if capture.writers["cam"]?.audioSamples == 0 { errors.append("NO_MIC_AUDIO: 未收到话筒音频样本") }
            if capture.writers["screen"]?.audioSamples == 0 { errors.append("NO_SYSTEM_AUDIO: 未收到系统音频样本；请播放声音后重试") }
            emit(["cam": capture.writers["cam"]?.info(elapsed: 3) ?? ["ok": false],
                  "screen": capture.writers["screen"]?.info(elapsed: 3) ?? ["ok": false],
                  "systemAudio": ["ok": (capture.writers["screen"]?.audioSamples ?? 0) > 0],
                  "encoder": "VideoToolbox H.264 (hardware required)", "diskFreeBytes": diskFree(directory), "errors": errors])
            return errors.isEmpty ? 0 : 1
        }
        return 0
    } catch {
        let errors = String(describing: error).components(separatedBy: "\n")
        if preflight {
            emit(["cam": engine?.writers["cam"]?.info(elapsed: 3) ?? ["ok": false],
                  "screen": engine?.writers["screen"]?.info(elapsed: 3) ?? ["ok": false],
                  "systemAudio": ["ok": false], "encoder": "unverified",
                  "diskFreeBytes": diskFree(FileManager.default.temporaryDirectory), "errors": errors])
        } else { emit(["errors": errors]) }
        return 1
    }
}
Task { exit(await main()) }
dispatchMain()
