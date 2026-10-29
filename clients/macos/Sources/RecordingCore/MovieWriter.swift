import AVFoundation
import VideoToolbox

public struct RecordingError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Media methods belong to one track's serial owner queue; completion gates are thread safe.
public final class MovieWriter {
    private let url: URL
    private var epoch: CMTime
    public let videoBitRate: Int
    public let includesAudio: Bool
    public let encoderPolicy = "hardware-required; no software fallback"
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
    public private(set) var encoderPreparationSeconds: Double = 0
    public private(set) var firstVideoAppendSeconds: Double = 0
    public private(set) var firstAudioAppendSeconds: Double = 0

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
    private var finishGate: RecordingCompletion?
    private let cleanupGate = RecordingCompletion()

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
        try advance(relative: CMTimeSubtract(time, epoch), exclusive: exclusive)
    }

    private func advance(relative: CMTime, exclusive: Bool) throws {
        guard var index = nextFrame else { return }
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
            try encode(copy, isVideo: true, frameIndex: index)
            diagnostics.writtenFrames += 1
            writtenGeneration = heldGeneration
            index += 1
            nextFrame = index
            let buffered = pendingAudio
            pendingAudio.removeAll()
            for sample in buffered { try encode(sample, isVideo: false) }
        }
    }

    /// Allocate/configure the real encoder before committing a Take epoch.
    /// No dummy or startup image is appended to the final media file.
    public func prepareVideo(_ sample: CMSampleBuffer) throws {
        guard writer == nil else { return }
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw RecordingError("视频格式尚不可用") }
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
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ],
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
        videoInput.mediaTimeScale = 30
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
        encoderPreparationSeconds = ProcessInfo.processInfo.systemUptime - preparationStarted
    }

    public func begin(at epoch: CMTime) throws {
        guard epoch.isNumeric, videoSamples == 0, audioSamples == 0,
              nextFrame == nil, pendingVideo.isEmpty, pendingAudio.isEmpty, !finishing else {
            throw RecordingError("录制时钟只能在首个样本之前确定")
        }
        self.epoch = epoch
    }

    private func encode(_ sample: CMSampleBuffer, isVideo: Bool, frameIndex: Int64? = nil) throws {
        guard CMSampleBufferDataIsReady(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, CMTimeCompare(pts, epoch) >= 0 else { return }
        if writer == nil {
            guard isVideo else { return }
            try prepareVideo(sample)
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
        let relative: CMSampleBuffer
        if let frameIndex {
            // Do not subtract host uptime from an absolute tick: CMTime's finite
            // host timescale can round that addition and corrupt the rational grid.
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: frameIndex, timescale: 30), decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr, let retimed else {
                throw RecordingError("无法建立相对固定帧率时间戳")
            }
            relative = retimed
        } else { relative = try MediaClock.relativeSample(sample, to: epoch) }
        let appendStarted = ProcessInfo.processInfo.systemUptime
        guard input.append(relative) else {
            throw writer.error ?? RecordingError("媒体写入失败，已保留现有文件")
        }
        let appendSeconds = ProcessInfo.processInfo.systemUptime - appendStarted
        if isVideo {
            if videoSamples == 0 { firstVideoAppendSeconds = appendSeconds }
            videoSamples += 1
            lastVideoSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
            if firstVideoSeconds == nil { firstVideoSeconds = lastVideoSeconds }
        } else {
            if audioSamples == 0 { firstAudioAppendSeconds = appendSeconds }
            audioSamples += 1
            lastAudioSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
        }
    }

    public func noteIngressRejection(_ count: UInt64) {
        diagnostics.capturedFrames += count
        diagnostics.backpressureFrames += count
        droppedVideo += Int(count)
    }

    public func noteAudioIngressRejection(_ count: UInt64) { droppedAudio += Int(count) }

    public func notePreviewDrop() { diagnostics.previewDroppedFrames += 1 }

    public func checkHealth() throws {
        if let writer, writer.status != .writing {
            throw writer.error ?? RecordingError("编码器已停止写入")
        }
    }

    public func whenClosed(_ completion: @escaping () -> Void) {
        cleanupGate.observe { _ in completion() }
    }

    public func finish(at end: CMTime? = nil, _ completion: @escaping (Result<Void, Error>) -> Void) {
        finish(at: end, timeout: 15, beginFinalization: { writer, finished in
            writer.finishWriting(completionHandler: finished)
        }, completion)
    }

    /// Device-free fault injection: keep the real AVAssetWriter in .writing
    /// across the deadline, then allow it to finish without canceling its file.
    public func finishWhenReleasedForCheck(at end: CMTime, release: RecordingCompletion,
        timeout: TimeInterval, _ completion: @escaping (Result<Void, Error>) -> Void) {
        finish(at: end, timeout: timeout, beginFinalization: { writer, finished in
            release.observe { _ in writer.finishWriting(completionHandler: finished) }
        }, completion)
    }

    private func finish(at end: CMTime?, timeout: TimeInterval,
        beginFinalization: (AVAssetWriter, @escaping () -> Void) -> Void,
        _ completion: @escaping (Result<Void, Error>) -> Void) {
        if let finishGate { finishGate.observe(completion); return }
        let gate = RecordingCompletion()
        finishGate = gate
        gate.observe(completion)
        var finalError: Error? = epoch.isNumeric ? nil : RecordingError("编码器准备在录制开始前已停止")
        // Round the common stop up to a complete frame boundary. Using an
        // arbitrary host timestamp here can turn the final accepted frame into
        // a zero-duration/discard sample when the MP4 track timescale is 30.
        var relativeEnd: CMTime? = end.flatMap {
            guard epoch.isNumeric else { return nil }
            return CMTimeConvertScale(CMTimeSubtract($0, epoch), timescale: 30, method: .roundTowardPositiveInfinity)
        }
        if let nextFrame, let boundary = relativeEnd {
            relativeEnd = CMTimeMaximum(boundary, CMTime(value: nextFrame, timescale: 30))
        }
        do { if let boundary = relativeEnd { try advance(relative: boundary, exclusive: true) } }
        catch { finalError = error }
        if let boundary = relativeEnd, let nextFrame,
           CMTimeCompare(CMTime(value: nextFrame, timescale: 30), boundary) < 0 {
            finalError = finalError ?? RecordingError("停止前的视频帧未能全部写入")
        }
        guard let writer else {
            cleanupGate.complete(.success(()))
            gate.complete(.failure(RecordingError("没有收到视频帧")))
            return
        }
        guard writer.status == .writing else {
            cleanupGate.complete(.success(()))
            gate.complete(.failure(writer.error ?? RecordingError("文件未处于写入状态")))
            return
        }
        finishing = true
        pendingVideo.removeAll()
        diagnostics.queueDepth = 0
        pendingAudio.removeAll()
        if let boundary = relativeEnd { writer.endSession(atSourceTime: boundary) }
        video?.markAsFinished()
        audio?.markAsFinished()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            // AVAssetWriter.cancelWriting deletes its output. A deadline only
            // reports failure; the writer, close gate and Take lease remain alive
            // until real finalization returns or the user explicitly exits.
            gate.complete(.failure(RecordingError("封装超过 15 秒，原文件已保留供恢复")))
        }
        let timelineError = finalError
        beginFinalization(writer) { [self] in
            cleanupGate.complete(.success(()))
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

    public static func videoSample(_ sample: CMSampleBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else {
            throw RecordingError("无法保持首帧到共同录制起点")
        }
        return copy
    }

    /// Trim only the leading PCM boundary, including non-interleaved SCK audio.
    /// This copies at most one boundary packet per source, never video pixels.
    public static func audioSample(_ sample: CMSampleBuffer, atOrAfter epoch: CMTime) throws -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if CMTimeCompare(pts, epoch) >= 0 { return sample }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mSampleRate > 0, asbd.pointee.mSampleRate <= Double(Int32.max) else {
            throw RecordingError("无法裁剪共同起点前的 PCM 音频")
        }
        let rate = Int32(asbd.pointee.mSampleRate.rounded())
        let skip = CMTimeConvertScale(CMTimeSubtract(epoch, pts), timescale: rate, method: .roundTowardPositiveInfinity).value
        let count = CMSampleBufferGetNumSamples(sample)
        guard skip < count else { return nil }
        let remaining = count - Int(skip)
        guard skip >= 0, skip <= Int32.max, remaining <= Int32.max,
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(remaining)) else {
            throw RecordingError("音频起点裁剪尺寸无效")
        }
        pcm.frameLength = AVAudioFrameCount(remaining)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(skip), frameCount: Int32(remaining), into: pcm.mutableAudioBufferList) == noErr else {
            throw RecordingError("无法读取起点音频样本")
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTimeAdd(pts, CMTime(value: skip, timescale: rate)), decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: remaining,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &output) == noErr, let output,
              CMSampleBufferSetDataBufferFromAudioBufferList(output, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
              CMSampleBufferSetDataReady(output) == noErr else {
            throw RecordingError("无法建立裁剪后的音频包")
        }
        return output
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

/// Thread-safe one-shot completion shared by bounded stop and writer finalization.
public typealias RecordingCompletion = RecordingResult<Void>

public final class RecordingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var callbacks: [(Result<Value, Error>) -> Void] = []
    public init() {}
    public var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }; return result != nil
    }
    public var failureDescription: String? {
        lock.lock(); defer { lock.unlock() }
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }
    public func observe(_ callback: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        if let result { lock.unlock(); callback(result) }
        else { callbacks.append(callback); lock.unlock() }
    }
    @discardableResult
    public func complete(_ value: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let waiting = callbacks
        callbacks.removeAll()
        lock.unlock()
        for callback in waiting { callback(value) }
        return true
    }
}
