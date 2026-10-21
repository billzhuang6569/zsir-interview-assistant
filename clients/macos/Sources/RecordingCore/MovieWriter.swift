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

    public init(url: URL, epoch: CMTime, videoBitRate: Int = 12_000_000) {
        precondition(videoBitRate > 0)
        self.videoBitRate = videoBitRate
        self.url = url
        self.epoch = epoch
    }

    public func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
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
            candidate.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
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
            guard candidate.canAdd(videoInput), candidate.canAdd(audioInput) else {
                throw RecordingError("无法建立 H.264 / AAC 编码管线")
            }
            candidate.add(videoInput)
            candidate.add(audioInput)
            guard candidate.startWriting() else {
                throw candidate.error ?? RecordingError("无法开始写入视频")
            }
            candidate.startSession(atSourceTime: .zero)
            writer = candidate
            video = videoInput
            audio = audioInput
        }
        guard let writer, writer.status == .writing else {
            throw writer?.error ?? RecordingError("编码器已停止写入")
        }
        guard let input = isVideo ? video : audio else { return }
        guard input.isReadyForMoreMediaData else {
            if isVideo { droppedVideo += 1 } else { droppedAudio += 1 }
            return
        }
        // Keep both files on the same relative timeline instead of exposing host uptime.
        let relative = try MediaClock.relativeSample(sample, to: epoch)
        guard input.append(relative) else {
            throw writer.error ?? RecordingError("媒体写入失败，已保留现有文件")
        }
        if isVideo {
            lastVideo = sample
            videoSamples += 1
            lastVideoSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
            if firstVideoSeconds == nil { firstVideoSeconds = lastVideoSeconds }
        } else {
            audioSamples += 1
            lastAudioSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
        }
    }

    public func checkHealth() throws {
        if let writer, writer.status != .writing {
            throw writer.error ?? RecordingError("编码器已停止写入")
        }
    }

    public func holdLastFrame(at time: CMTime) throws {
        guard let lastVideo, CMTimeSubtract(time, CMSampleBufferGetPresentationTimeStamp(lastVideo)).seconds >= 1 else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideo,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw RecordingError("静态桌面帧延续失败") }
        try append(copy, isVideo: true)
    }

    public func finish(at end: CMTime? = nil, _ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let writer else {
            completion(.failure(RecordingError("没有收到视频帧")))
            return
        }
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? RecordingError("文件未处于写入状态")))
            return
        }
        // ScreenCaptureKit emits no new complete frames for an unchanged desktop.
        if let end, let lastVideo, CMTimeCompare(end, CMSampleBufferGetPresentationTimeStamp(lastVideo)) > 0 {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: end, decodeTimeStamp: .invalid)
            var tail: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideo,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &tail)
            if status == noErr, let tail {
                do { try append(tail, isVideo: true) }
                catch { completion(.failure(error)); return }
            }
        }
        if let end { writer.endSession(atSourceTime: CMTimeSubtract(end, epoch)) }
        video?.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(writer.error ?? RecordingError("封装失败，原文件已保留")))
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
        switch self { case .camera: return "摄像头"; case .desktop: return "桌面"; case .both: return "双路" }
    }
}
