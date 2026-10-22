import AVFoundation
import Darwin

/// Advisory lock releases automatically on process death; recovery never touches an active Take.
public final class TakeLease {
    private let descriptor: Int32
    public init(folder: URL) throws {
        let path = folder.appendingPathComponent(".recording.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RecordingError("无法锁定素材目录") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RecordingError("这条素材仍在录制或恢复中")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct RecoveryCandidate: Identifiable, Sendable {
    public var id: String { folder.path }
    public let folder: URL
    public let files: [URL]
}

public struct RecoveryResult: Sendable {
    public let outputFolder: URL
    public let files: [URL]
    public let errors: [String]
}

public enum RecordingRecovery {
    private static func isRegular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    public static func scan(root: URL) throws -> [RecoveryCandidate] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return folders.compactMap { folder in
            guard folder.lastPathComponent.hasPrefix("Take-"),
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let reportURL = folder.appendingPathComponent("report.json")
            guard isRegular(reportURL),
                  let data = try? Data(contentsOf: reportURL),
                  let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  report["state"] as? String != "finalized_unverified",
                  report["recoveryState"] as? String != "recovered" else { return nil }
            let files = ["camera.mp4", "desktop.mp4"].map { folder.appendingPathComponent($0) }.filter(isRegular)
            guard !files.isEmpty, let lease = try? TakeLease(folder: folder) else { return nil }
            return withExtendedLifetime(lease) { RecoveryCandidate(folder: folder, files: files) }
        }.sorted { $0.folder.lastPathComponent < $1.folder.lastPathComponent }
    }

    public static func recover(_ candidate: RecoveryCandidate) async throws -> RecoveryResult {
        let values = try candidate.folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw RecordingError("素材目录不可用") }
        let lease = try TakeLease(folder: candidate.folder)
        defer { withExtendedLifetime(lease) {} }
        let output = candidate.folder.appendingPathComponent("Recovered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sourceReport = (try? JSONSerialization.jsonObject(with: Data(contentsOf: candidate.folder.appendingPathComponent("report.json")))) as? [String: Any]
        var recovered: [URL] = []
        var errors: [String] = []
        for input in candidate.files {
            guard ["camera.mp4", "desktop.mp4"].contains(input.lastPathComponent),
                  input.deletingLastPathComponent().standardizedFileURL == candidate.folder.standardizedFileURL,
                  isRegular(input) else { throw RecordingError("恢复输入不是有效的本地素材") }
            do {
                let bytes = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let free = try output.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard free > Int64(bytes) + 512_000_000 else { throw RecordingError("恢复副本空间不足，原素材已保留") }
                let asset = AVURLAsset(url: input)
                guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw RecordingError("尚无可读取的视频片段")
                }
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw RecordingError("不能重封装此素材")
                }
                let partial = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-partial.mp4")
                export.outputURL = partial
                export.outputFileType = .mp4
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    export.exportAsynchronously { continuation.resume() }
                }
                guard export.status == .completed else {
                    throw export.error ?? RecordingError("恢复封装失败，原素材已保留")
                }
                try await validate(partial, requiresAudio: !(input.lastPathComponent == "desktop.mp4" && sourceReport?["systemAudio"] as? Bool == false))
                let result = output.appendingPathComponent(input.lastPathComponent)
                try FileManager.default.moveItem(at: partial, to: result)
                recovered.append(result)
            } catch { errors.append("\(input.lastPathComponent)：\(error.localizedDescription)") }
        }
        let report: [String: Any] = ["state": errors.isEmpty ? "recovered" : "partial_or_failed",
            "files": recovered.map { $0.lastPathComponent }, "errors": errors,
            "validation": "video/audio tracks, positive duration, first/last video frame decode; original files preserved"]
        try TakeFiles.writeReport(report, in: output)
        if errors.isEmpty && !recovered.isEmpty {
            let reportURL = candidate.folder.appendingPathComponent("report.json")
            var original = (try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL))) as? [String: Any] ?? [:]
            original["recoveryState"] = "recovered"
            original["recoveryFolder"] = output.lastPathComponent
            try TakeFiles.writeReport(original, in: candidate.folder)
        }
        return RecoveryResult(outputFolder: output, files: recovered, errors: errors)
    }

    public static func validate(_ url: URL, requiresAudio: Bool = true) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.seconds.isFinite, duration.seconds > 0,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
              (!requiresAudio || !audioTracks.isEmpty) else {
            throw RecordingError("恢复副本缺少有效音视频，原文件仍保留")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 180)
        for time in [CMTime.zero, CMTime(seconds: max(0, duration.seconds - 0.1), preferredTimescale: 600)] {
            if #available(macOS 13, *), !RecordingCapabilities.macOS12Edition {
                _ = try await generator.image(at: time)
            } else {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                        if result == .succeeded, image != nil { c.resume() }
                        else { c.resume(throwing: error ?? RecordingError("无法解码恢复副本，原文件仍保留")) }
                    }
                }
            }
        }
    }
}
