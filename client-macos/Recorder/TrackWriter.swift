import AVFoundation
import VideoToolbox

// All sample handling and writer state are confined to CaptureEngine.queue.
final class TrackWriter {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let url: URL
    let width: Int
    let height: Int
    let fps: Int
    var frames = 0
    var audioSamples = 0
    var dropped = 0
    var firstPTS: Double?
    var levelDb = -120.0
    var lastVideo: CMSampleBuffer?
    var lastPTS = -Double.infinity
    var epoch: CMTime?

    init(url: URL, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.url = url; self.width = width; self.height = height; self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256000
        ])
        for input in [video, audio] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError("ENCODER: 无法添加 \(input.mediaType.rawValue) 编码输入（检查硬件编码器与系统媒体服务权限）") }
            writer.add(input)
        }
    }
    func start(_ time: CMTime) throws {
        guard writer.startWriting() else { throw writer.error ?? RecorderError("ENCODER: 启动失败") }
        writer.startSession(atSourceTime: time)
        epoch = time
    }
    func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        guard let epoch, sample.presentationTimeStamp >= epoch else { return }
        let input = isVideo ? video : audio
        if writer.status == .failed { throw writer.error ?? RecorderError("WRITE: 写入失败") }
        guard input.isReadyForMoreMediaData else { dropped += 1; return }
        guard input.append(sample) else { throw writer.error ?? RecorderError("WRITE: append 失败") }
        if isVideo {
            frames += 1
            firstPTS = firstPTS ?? sample.presentationTimeStamp.seconds
            lastPTS = sample.presentationTimeStamp.seconds
            lastVideo = sample
        } else {
            audioSamples += sample.numSamples
            levelDb = audioLevel(sample)
        }
    }
    func prepareFinish(at end: CMTime) throws {
        guard epoch != nil, writer.status == .writing else { return }
        // Static desktops may stop producing frames; extend their final image to the stop time.
        let tail = end - CMTime(value: 1, timescale: Int32(fps))
        if let lastVideo, tail.seconds > lastPTS, video.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)), presentationTimeStamp: tail, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideo, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
            guard status == noErr, let copy, video.append(copy) else { throw writer.error ?? RecorderError("WRITE: 尾帧失败") }
        }
        writer.endSession(atSourceTime: end)
        video.markAsFinished(); audio.markAsFinished()
    }
    var bytes: Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }
    func info(elapsed: Double) -> [String: Any] {
        ["ok": frames > 0 && writer.status != .failed, "width": width, "height": height,
         "fps": Double(frames) / max(elapsed, 0.001), "targetFPS": fps, "bytes": bytes,
         "levelDb": levelDb, "audioSamples": audioSamples, "droppedSamples": dropped,
         "firstPTS": firstPTS as Any? ?? NSNull(),
         "firstFrameOffsetMs": firstPTS.map { ($0 - (epoch?.seconds ?? 0)) * 1000 } as Any? ?? NSNull()]
    }
}

func audioLevel(_ sample: CMSampleBuffer) -> Double {
    guard let format = sample.formatDescription,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM else { return -120 }
    var required = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &required, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: max(required, MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: required, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return -120 }
    var peak = 0.0
    for buffer in UnsafeMutableAudioBufferListPointer(list) {
        guard let data = buffer.mData else { continue }
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            for value in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4) { peak = max(peak, Double(abs(value))) }
        } else if asbd.mBitsPerChannel == 16 {
            for value in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(buffer.mDataByteSize) / 2) { peak = max(peak, abs(Double(value)) / 32768) }
        }
    }
    return peak.isFinite ? max(-120, 20 * log10(max(peak, 0.000001))) : -120
}
