import AVFoundation

/// One bounded ingress and one serial writer owner per selected output. The
/// capture/coordinator queue never waits for encoder readiness or disk writes.
public final class RecordingTrack: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let writer: MovieWriter
    private var samples = BoundedRecordingQueue<(CMSampleBuffer, Bool)>(capacity: 67)
    private var videoDepth = 0
    private var audioDepth = 0
    private var ingressHighWater = 0
    private var rejectedVideo: UInt64 = 0
    private var rejectedAudio: UInt64 = 0
    private var previewDrops: UInt64 = 0
    private var drainScheduled = false
    private var advanceScheduled = false
    private var requestedAdvance: (CMTime, Bool)?
    private var end: CMTime?
    private var closed = false
    private var state = Snapshot()

    public struct Snapshot {
        public var videoSamples = 0
        public var audioSamples = 0
        public var droppedVideo = 0
        public var droppedAudio = 0
        public var width: Int32 = 0
        public var height: Int32 = 0
        public var firstVideoSeconds: Double?
        public var lastVideoSeconds: Double = 0
        public var lastAudioSeconds: Double = 0
        public var lastCapturedVideoSeconds: Double = 0
        public var diagnostics = RecordingDiagnostics()
        public var error: String?
        public var ingressQueueDepth = 0
        public var ingressQueueHighWaterMark = 0
        public var encoderPreparationSeconds: Double = 0
        public var firstVideoAppendSeconds: Double = 0
        public var firstAudioAppendSeconds: Double = 0
        public var ownerProgressUptime = ProcessInfo.processInfo.systemUptime
    }

    public let includesAudio: Bool
    public let videoBitRate: Int
    public let encoderPolicy: String

    public init(url: URL, epoch: CMTime, videoBitRate: Int = 12_000_000, includesAudio: Bool = true) {
        writer = MovieWriter(url: url, epoch: epoch, videoBitRate: videoBitRate, includesAudio: includesAudio)
        queue = DispatchQueue(label: "zsir.writer.\(url.lastPathComponent)")
        self.includesAudio = includesAudio
        self.videoBitRate = videoBitRate
        encoderPolicy = writer.encoderPolicy
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        var copy = state
        copy.ingressQueueDepth = samples.count
        copy.ingressQueueHighWaterMark = ingressHighWater
        return copy
    }
    public var videoSamples: Int { snapshot.videoSamples }
    public var audioSamples: Int { snapshot.audioSamples }
    public var droppedVideo: Int { snapshot.droppedVideo }
    public var droppedAudio: Int { snapshot.droppedAudio }
    public var width: Int32 { snapshot.width }
    public var height: Int32 { snapshot.height }
    public var firstVideoSeconds: Double? { snapshot.firstVideoSeconds }
    public var lastVideoSeconds: Double { snapshot.lastVideoSeconds }
    public var lastAudioSeconds: Double { snapshot.lastAudioSeconds }
    public var lastCapturedVideoSeconds: Double { snapshot.lastCapturedVideoSeconds }
    public var diagnostics: RecordingDiagnostics { snapshot.diagnostics }

    public func prepareVideo(_ sample: CMSampleBuffer, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            lock.lock(); let stopped = closed; lock.unlock()
            guard !stopped else { completion(.failure(RecordingError("编码器准备已取消"))); return }
            perform { try writer.prepareVideo(sample) }
            if let error = snapshot.error { completion(.failure(RecordingError(error))) }
            else { completion(.success(())) }
        }
    }

    public func begin(at epoch: CMTime, firstVideo: CMSampleBuffer, audio: [CMSampleBuffer]) {
        queue.async { [self] in
            lock.lock(); let stopped = closed; lock.unlock()
            guard !stopped else { return }
            perform {
                try writer.begin(at: epoch)
                try writer.append(firstVideo, isVideo: true)
                try writer.advance(to: epoch)
                for sample in audio { try writer.append(sample, isVideo: false) }
            }
        }
    }

    public func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if let error = state.error { lock.unlock(); throw RecordingError(error) }
        if (isVideo ? videoDepth >= 3 : audioDepth >= 64) {
            if isVideo { rejectedVideo += 1 } else { rejectedAudio += 1 }
            state.error = "分路媒体输入队列已满；已停止并保留素材"
            let schedule = !drainScheduled
            drainScheduled = true
            lock.unlock()
            if schedule { queue.async { [self] in drain() } }
            throw RecordingError("分路媒体输入队列已满；已停止并保留素材")
        }
        _ = samples.enqueue((sample, isVideo))
        if isVideo { videoDepth += 1 } else { audioDepth += 1 }
        ingressHighWater = max(ingressHighWater, samples.count)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    public func noteIngressRejection(_ count: UInt64) {
        lock.lock(); rejectedVideo += count; lock.unlock()
    }
    public func notePreviewDrop() {
        lock.lock(); previewDrops += 1; lock.unlock()
    }

    /// Coalesce scheduler wakeups, including while this writer is blocked. A
    /// delayed owner sees the newest deadline and applies MovieWriter's CFR budget.
    public func advance(to time: CMTime, exclusive: Bool = false) throws {
        lock.lock()
        if let error = state.error { lock.unlock(); throw RecordingError(error) }
        guard !closed else { lock.unlock(); return }
        requestedAdvance = (time, exclusive)
        let schedule = !advanceScheduled
        advanceScheduled = true
        lock.unlock()
        if schedule {
            queue.async { [self] in
                lock.lock()
                let target = requestedAdvance
                let boundary = end
                requestedAdvance = nil
                advanceScheduled = false
                lock.unlock()
                if let target {
                    perform {
                        if let boundary, CMTimeCompare(target.0, boundary) >= 0 { try writer.advance(to: boundary, exclusive: true) }
                        else { try writer.advance(to: target.0, exclusive: target.1) }
                    }
                }
            }
        }
    }

    public func checkHealth() throws {
        if let error = snapshot.error { throw RecordingError(error) }
    }

    private func drain() {
        lock.lock()
        var batch: [(CMSampleBuffer, Bool)] = []
        while let sample = samples.dequeue() { batch.append(sample) }
        videoDepth = 0; audioDepth = 0
        let rejected = rejectedVideo; rejectedVideo = 0
        let audioRejected = rejectedAudio; rejectedAudio = 0
        let drops = previewDrops; previewDrops = 0
        drainScheduled = false
        let boundary = end
        lock.unlock()
        writer.noteIngressRejection(rejected)
        writer.noteAudioIngressRejection(audioRejected)
        for _ in 0..<drops { writer.notePreviewDrop() }
        perform {
            for (sample, video) in batch {
                if let boundary, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), boundary) >= 0 { continue }
                try writer.append(sample, isVideo: video)
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); try writer.checkHealth() }
        catch {
            let native = error as NSError
            lock.lock(); state.error = state.error ?? "\(error.localizedDescription) (\(native.domain):\(native.code))"; lock.unlock()
        }
        publish()
    }

    private func publish() {
        lock.lock()
        state.videoSamples = writer.videoSamples; state.audioSamples = writer.audioSamples
        state.droppedVideo = writer.droppedVideo; state.droppedAudio = writer.droppedAudio
        state.width = writer.width; state.height = writer.height
        state.firstVideoSeconds = writer.firstVideoSeconds
        state.lastVideoSeconds = writer.lastVideoSeconds; state.lastAudioSeconds = writer.lastAudioSeconds
        state.lastCapturedVideoSeconds = writer.lastCapturedVideoSeconds
        state.diagnostics = writer.diagnostics
        state.encoderPreparationSeconds = writer.encoderPreparationSeconds
        state.firstVideoAppendSeconds = writer.firstVideoAppendSeconds
        state.firstAudioAppendSeconds = writer.firstAudioAppendSeconds
        state.ownerProgressUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    public func finish(at boundary: CMTime? = nil, _ completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); closed = true; end = boundary; lock.unlock()
        queue.async { [self] in
            drain()
            writer.finish(at: boundary) { [self] result in
                queue.async {
                    self.publish()
                    if let error = self.snapshot.error { completion(.failure(RecordingError(error))) }
                    else { completion(result) }
                }
            }
        }
    }
    public func whenClosed(_ completion: @escaping () -> Void) { writer.whenClosed(completion) }

    /// Device-free fault injection used by the synthetic checks.
    public func blockOwnerForCheck(until signal: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(); signal.wait() }
        }
    }
}
