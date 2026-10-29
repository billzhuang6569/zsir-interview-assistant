import AVFoundation

public struct RecordingError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// All calls belong to the capture engine's serial media queue.
public final class MovieWriter {
    private let url: URL
    private let epoch: CMTime
    public let videoBitRate: Int
    public let includesAudio: Bool
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var lastVideo: CMSampleBuffer?
    public private(set) var videoSamples = 0
    public private(set) var audioSamples = 0
    public private(set) var droppedVideo = 0
    public private(set) var droppedAudio = 0
    public private(set) var width: Int32 = 0
    public private(set) var height: Int32 = 0
    public private(set) var lastVideoSeconds: Double = 0
    public private(set) var lastAudioSeconds: Double = 0
    public private(set) var firstVideoSeconds: Double?
    public private(set) var lastCapturedVideoSeconds: Double = 0

    public init(url: URL, epoch: CMTime, videoBitRate: Int = 12_000_000, includesAudio: Bool = true) {
        precondition(videoBitRate > 0)
        self.videoBitRate = videoBitRate
        self.includesAudio = includesAudio
        self.url = url
        self.epoch = epoch
    }

    public private(set) var diagnostics = RecordingDiagnostics()
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var nextFrame: Int64?
    private var heldGeneration: UInt64 = 0
    private var writtenGeneration: UInt64?
    private var lastRejectedIndex: Int64?
    private var finishing = false
    private var finishGate: FinishGate?

    public func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        guard !finishing, CMSampleBufferDataIsReady(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric, CMTimeCompare(pts, epoch) >= 0 else { return }
        if isVideo {
            diagnostics.capturedFrames += 1
            lastCapturedVideoSeconds = CMTimeSubtract(pts, epoch).seconds
            guard pendingVideo.count < 3 else {
                diagnostics.backpressureFrames += 1
                throw RecordingError("视频输入队列已满；已停止以避免不连续帧时间轴")
            }
            pendingVideo.append(sample)
            pendingVideo.sort { CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), CMSampleBufferGetPresentationTimeStamp($1)) < 0 }
            diagnostics.queueDepth = pendingVideo.count
            diagnostics.queueHighWaterMark = max(diagnostics.queueHighWaterMark, pendingVideo.count)
            if nextFrame == nil {
                nextFrame = CMTimeConvertScale(CMTimeSubtract(pts, epoch), timescale: 30, method: .roundTowardPositiveInfinity).value
            }
        } else if writer == nil {
            guard pendingAudio.count < 64 else { droppedAudio += 1; throw RecordingError("音频启动缓冲已满") }
            pendingAudio.append(sample)
        } else {
            try encode(sample, isVideo: false)
        }
    }

    /// A maximum of three overdue ticks is drained. Any larger stall fails visibly,
    /// rather than producing a successful file with missing CFR timestamps.
    public func advance(to time: CMTime, exclusive: Bool = false) throws {
        guard var index = nextFrame else { return }
        let relative = CMTimeSubtract(time, epoch)
        let last = CMTimeConvertScale(relative, timescale: 30, method: .roundTowardNegativeInfinity).value
        let boundary = exclusive && CMTimeCompare(relative, CMTime(value: last, timescale: 30)) == 0 ? last - 1 : last
        guard boundary >= index else { return }
        guard boundary - index < 3 else {
            diagnostics.lateFrames += UInt64(boundary - index + 1)
            throw RecordingError("视频调度延迟超过 3 帧；已保留素材供恢复")
        }
        while index <= boundary {
            let tick = CMTimeAdd(epoch, CMTime(value: index, timescale: 30))
            while let first = pendingVideo.first, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(first), tick) <= 0 {
                lastVideo = pendingVideo.removeFirst()
                heldGeneration += 1
            }
            diagnostics.queueDepth = pendingVideo.count
            guard let held = lastVideo else { break }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: tick, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: held, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else {
                throw RecordingError("无法建立固定帧率时间戳")
            }
            if let video, !video.isReadyForMoreMediaData {
                if lastRejectedIndex != index {
                    diagnostics.backpressureFrames += 1
                    droppedVideo += 1
                    lastRejectedIndex = index
                }
                return // Retry this same frame index; the three-tick stall limit still applies.
            }
            diagnostics.scheduledFrames += 1
            if writtenGeneration == heldGeneration { diagnostics.repeatedFrames += 1 }
            try encode(copy, isVideo: true)
            diagnostics.writtenFrames += 1
            writtenGeneration = heldGeneration
            index += 1
            nextFrame = index
            let buffered = pendingAudio
            pendingAudio.removeAll()
            for sample in buffered { try encode(sample, isVideo: false) }
        }
    }

    private func encode(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        guard CMSampleBufferDataIsReady(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, CMTimeCompare(pts, epoch) >= 0 else { return }
        if writer == nil {
            // shortcut: pre-video audio is discarded; measure startup offsets before production use.
            guard isVideo, let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            width = dimensions.width
            height = dimensions.height
            let candidate = try AVAssetWriter(outputURL: url, fileType: .mp4)
            candidate.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            if #available(macOS 14, *), !RecordingCapabilities.macOS12Edition {
                candidate.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            } else {
                // macOS 13 cannot flush the first fragment separately; keep early recovery at the cost of more fragments.
                candidate.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(width), AVVideoHeightKey: Int(height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitRate,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ])
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            videoInput.expectsMediaDataInRealTime = true
            audioInput.expectsMediaDataInRealTime = true
            guard candidate.canAdd(videoInput), !includesAudio || candidate.canAdd(audioInput) else {
                throw RecordingError("无法建立 H.264 / AAC 编码管线")
            }
            candidate.add(videoInput)
            if includesAudio { candidate.add(audioInput) }
            guard candidate.startWriting() else {
                throw candidate.error ?? RecordingError("无法开始写入视频")
            }
            candidate.startSession(atSourceTime: .zero)
            writer = candidate
            video = videoInput
            audio = includesAudio ? audioInput : nil
        }
        guard let writer, writer.status == .writing else {
            throw writer?.error ?? RecordingError("编码器已停止写入")
        }
        guard let input = isVideo ? video : audio else { return }
        guard input.isReadyForMoreMediaData else {
            if isVideo { droppedVideo += 1 } else { droppedAudio += 1 }
            throw RecordingError("编码器背压导致媒体时间轴中断")
        }
        // Keep both files on the same relative timeline instead of exposing host uptime.
        let relative = try MediaClock.relativeSample(sample, to: epoch)
        guard input.append(relative) else {
            throw writer.error ?? RecordingError("媒体写入失败，已保留现有文件")
        }
        if isVideo {
            videoSamples += 1
            lastVideoSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
            if firstVideoSeconds == nil { firstVideoSeconds = lastVideoSeconds }
        } else {
            audioSamples += 1
            lastAudioSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
        }
    }

    public func noteIngressRejection(_ count: UInt64) {
        diagnostics.capturedFrames += count
        diagnostics.backpressureFrames += count
        droppedVideo += Int(count)
    }

    public func notePreviewDrop() { diagnostics.previewDroppedFrames += 1 }

    public func checkHealth() throws {
        if let writer, writer.status != .writing {
            throw writer.error ?? RecordingError("编码器已停止写入")
        }
    }

    public func finish(at end: CMTime? = nil, _ completion: @escaping (Result<Void, Error>) -> Void) {
        if let finishGate { finishGate.observe(completion); return }
        let gate = FinishGate()
        finishGate = gate
        gate.observe(completion)
        var finalError: Error?
        do { if let end { try advance(to: end, exclusive: true) } }
        catch { finalError = error }
        if let end, let nextFrame,
           CMTimeCompare(CMTime(value: nextFrame, timescale: 30), CMTimeSubtract(end, epoch)) < 0 {
            finalError = finalError ?? RecordingError("停止前的视频帧未能全部写入")
        }
        guard let writer else {
            gate.complete(.failure(RecordingError("没有收到视频帧")))
            return
        }
        guard writer.status == .writing else {
            gate.complete(.failure(writer.error ?? RecordingError("文件未处于写入状态")))
            return
        }
        finishing = true
        pendingVideo.removeAll()
        diagnostics.queueDepth = 0
        pendingAudio.removeAll()
        if let end { writer.endSession(atSourceTime: CMTimeSubtract(end, epoch)) }
        video?.markAsFinished()
        audio?.markAsFinished()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            gate.complete(.failure(RecordingError("封装超过 15 秒，原文件已保留供恢复")), before: {
                writer.cancelWriting()
            })
        }
        let timelineError = finalError
        writer.finishWriting {
            if writer.status == .completed {
                if let timelineError { gate.complete(.failure(timelineError)) }
                else { gate.complete(.success(())) }
            } else {
                gate.complete(.failure(writer.error ?? RecordingError("封装失败，原文件已保留")))
            }
        }
    }
}

public enum TakeFiles {
    public static func create(in root: URL) throws -> URL {
        let take = root.appendingPathComponent("Take-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: take, withIntermediateDirectories: false)
        return take
    }

    public static func writeReport(_ report: [String: Any], in folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    }
}

public enum MediaClock {
    public static func hostSample(_ sample: CMSampleBuffer, from clock: CMClock) throws -> CMSampleBuffer {
        try mapSample(sample) { CMSyncConvertTime($0, from: clock, to: CMClockGetHostTimeClock()) }
    }

    public static func relativeSample(_ sample: CMSampleBuffer, to epoch: CMTime) throws -> CMSampleBuffer {
        try mapSample(sample) { CMTimeSubtract($0, epoch) }
    }

    private static func mapSample(_ sample: CMSampleBuffer, transform: (CMTime) -> CMTime) throws -> CMSampleBuffer {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr else {
            throw RecordingError("无法读取采集时间戳")
        }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else {
            throw RecordingError("无法读取采集时间轴")
        }
        for index in timings.indices {
            timings[index].presentationTimeStamp = transform(timings[index].presentationTimeStamp)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = transform(timings[index].decodeTimeStamp)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw RecordingError("无法统一采集时间轴") }
        return copy
    }
}

public enum RecordingMode: String, CaseIterable, Identifiable, Sendable {
    case camera, desktop, both
    public var id: String { rawValue }
    public var includesCamera: Bool { self != .desktop }
    public var includesDesktop: Bool { self != .camera }
    public var title: String {
        switch self { case .camera: return "摄像头"; case .desktop: return "桌面"; case .both: return "摄像头+桌面" }
    }
}

private final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolving = false
    private var result: Result<Void, Error>?
    private var callbacks: [(Result<Void, Error>) -> Void] = []

    func observe(_ callback: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            callback(result)
        } else {
            callbacks.append(callback)
            lock.unlock()
        }
    }

    /// Claim terminal ownership before touching the writer. A late timeout must
    /// never cancel a writer whose successful completion already won the race.
    func complete(_ value: Result<Void, Error>, before action: () -> Void = {}) {
        lock.lock()
        guard !resolving else { lock.unlock(); return }
        resolving = true
        lock.unlock()
        action()
        lock.lock()
        result = value
        let waiting = callbacks
        callbacks.removeAll()
        lock.unlock()
        for callback in waiting { callback(value) }
    }
}
