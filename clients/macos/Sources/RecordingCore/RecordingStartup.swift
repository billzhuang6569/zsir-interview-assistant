import AVFoundation

/// The coordinator owns this bounded barrier. No writer or Take clock starts
/// until every selected video source has supplied a usable frame.
public struct RecordingStartup {
    private let sources: Set<String>
    private var first: [String: CMSampleBuffer] = [:]
    private var latest: [String: CMSampleBuffer] = [:]
    private var latestArrival: [String: CMTime] = [:]
    private var audio: [String: [CMSampleBuffer]] = [:]
    private var sourceSummaries: [String: [[String: Any]]] = [:]
    public private(set) var audioBufferEvictions: [String: Int] = [:]
    public private(set) var videoFramesObserved: [String: Int] = [:]
    public init(sources: Set<String>) { precondition(!sources.isEmpty); self.sources = sources }
    public var latestVideo: [String: CMSampleBuffer] { latest }
    public var ready: Bool { sources.allSatisfy { first[$0] != nil } }

    public mutating func offer(_ sample: CMSampleBuffer, source: String, video: Bool) {
        guard sources.contains(source), CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else { return }
        if video {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { return }
            if first[source] == nil { first[source] = sample }
            latest[source] = sample
            latestArrival[source] = CMClockGetTime(CMClockGetHostTimeClock())
            videoFramesObserved[source, default: 0] += 1
            // Four early sources plus the selected prime: at most five frame
            // reads per source for this entire startup, never a per-frame logger.
            if sourceSummaries[source, default: []].count < 4 {
                sourceSummaries[source, default: []].append(Self.describe(sample, arrival: latestArrival[source]!))
            }
        } else {
            if audio[source, default: []].count == 64 {
                audio[source]?.removeFirst()
                audioBufferEvictions[source, default: 0] += 1
            }
            audio[source, default: []].append(sample)
        }
    }

    public struct Ready {
        public let epoch: CMTime
        public let video: [String: CMSampleBuffer]
        public let audio: [String: [CMSampleBuffer]]
        public let diagnostics: [String: Any]
    }

    public func activate() throws -> Ready {
        guard ready, let initial = latest.values.first else { throw RecordingError("所选源尚未全部收到首帧") }
        let epoch = latest.values.reduce(CMSampleBufferGetPresentationTimeStamp(initial)) {
            CMTimeMaximum($0, CMSampleBufferGetPresentationTimeStamp($1))
        }
        var primed: [String: CMSampleBuffer] = [:]
        var trimmed: [String: [CMSampleBuffer]] = [:]
        var excluded: [String: Int] = [:]
        var summaries = sourceSummaries
        var primeSummaries: [String: [String: Any]] = [:]
        for source in sources {
            // A delayed callback from another source must never make us fall
            // back to an arbitrarily old first image. All latest images are
            // eligible because the common epoch is their maximum timestamp.
            let selected = latest[source]!
            let sourcePTS = CMSampleBufferGetPresentationTimeStamp(selected).seconds
            primed[source] = try MediaClock.videoSample(selected, at: epoch)
            var prime: [String: Any]?
            for index in summaries[source, default: []].indices {
                let isSelected = summaries[source]![index]["sourcePTSSeconds"] as? Double == sourcePTS
                summaries[source]![index]["selectedAsPrime"] = isSelected
                if isSelected { prime = summaries[source]![index] }
            }
            if prime == nil { prime = Self.describe(selected, arrival: latestArrival[source]!) }
            prime?["selectedAsPrime"] = true
            prime?["writerPTSSeconds"] = 0
            prime?["primedHostPTSSeconds"] = epoch.seconds
            primeSummaries[source] = prime
            for sample in audio[source] ?? [] {
                if let sample = try MediaClock.audioSample(sample, atOrAfter: epoch) { trimmed[source, default: []].append(sample) }
                else { excluded[source, default: 0] += 1 }
            }
        }
        return Ready(epoch: epoch, video: primed, audio: trimmed, diagnostics: [
            "epochValue": epoch.value, "epochTimescale": epoch.timescale,
            "firstFrameOffsetsSeconds": first.mapValues { CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp($0), epoch).seconds },
            "videoFramesObserved": videoFramesObserved, "audioBufferEvictions": audioBufferEvictions,
            "audioPacketsBeforeEpoch": excluded,
            "sourceFrameSummaries": summaries, "primeFrameSummaries": primeSummaries,
            "summaryPolicy": "At most four initial source frames plus selected prime per source; sampled raw NV12 Y only, no image saved or frame filtered; extrema describe sampled pixels, not all pixels.",
            "note": "Startup-only buffers precede the common Take epoch; evictions are not recording audio drops."
        ])
    }
    private static func describe(_ sample: CMSampleBuffer, arrival: CMTime) -> [String: Any] {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var result: [String: Any] = ["sourcePTSSeconds": pts.seconds,
            "coordinatorArrivalHostSeconds": arrival.seconds, "sourceToCoordinatorSeconds": CMTimeSubtract(arrival, pts).seconds,
            "selectedAsPrime": false]
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return result }
        let format = CVPixelBufferGetPixelFormatType(pixel)
        result["pixelFormat"] = format
        result["width"] = CVPixelBufferGetWidth(pixel)
        result["height"] = CVPixelBufferGetHeight(pixel)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            result["lumaStatus"] = "not_Nv12"; return result
        }
        result["lumaRange"] = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "video_16_235" : "full_0_255"
        let began = ProcessInfo.processInfo.systemUptime
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
            result["lumaStatus"] = "read_lock_failed"; return result
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard CVPixelBufferIsPlanar(pixel), CVPixelBufferGetPlaneCount(pixel) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) else { return result }
        let width = CVPixelBufferGetWidthOfPlane(pixel, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixel, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        guard width > 0, height > 0 else { return result }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var minimum = 255, maximum = 0, total = 0, count = 0
        for y in 0..<min(36, height) {
            for x in 0..<min(64, width) {
                let value = Int(bytes[(y * height / min(36, height)) * stride + x * width / min(64, width)])
                minimum = min(minimum, value); maximum = max(maximum, value)
                total += value; count += 1
            }
        }
        result["sampledLumaMin"] = minimum; result["sampledLumaMax"] = maximum
        result["sampledLumaMean"] = count > 0 ? Double(total) / Double(count) : 0
        result["sampledLumaCount"] = count
        result["summaryReadSeconds"] = ProcessInfo.processInfo.systemUptime - began
        return result
    }

}
