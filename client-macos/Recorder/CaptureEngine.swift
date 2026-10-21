import AppKit
import AVFoundation
import ScreenCaptureKit
import Shared
import IOKit.pwr_mgt

final class CaptureEngine: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "zsir.capture")
    let session = AVCaptureSession()
    var stream: SCStream?
    var writers: [String: TrackWriter] = [:]
    var devices: [String: String] = [:]
    var excludedPIDs: [pid_t] = []
    var ready = Set<String>()
    var failure: String?
    var epoch: CMTime?
    var end: CMTime?
    var stopping = false
    var stopRequested = false
    var signals: [DispatchSourceSignal] = []
    var assertion: IOPMAssertionID = 0
    var startedAt = ""
    let options: Options
    let directory: URL

    init(options: Options, directory: URL) {
        self.options = options; self.directory = directory
    }
    func installSignals() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.stopRequested = true }
            source.resume(); signals.append(source)
        }
    }
    func configure() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never overwrite any part of a previous recording, even for an unselected track.
        for name in ["cam.mp4", "screen.mp4", "session.json"] where fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw RecorderError("OUTPUT_EXISTS: \(name) 已存在，请使用新的输出目录")
        }
        if options.tracks.contains("cam") { try configureCamera() }
        if options.tracks.contains("screen") { try await configureScreen() }
        try writeSession(state: "starting", elapsed: 0)
    }
    func configureCamera() throws {
        let cameras = captureDevices(.video)
        let microphones = captureDevices(.audio)
        guard let camera = options.camera.flatMap({ id in cameras.first { $0.uniqueID == id } }) ?? (options.camera == nil ? AVCaptureDevice.default(for: .video) : nil) else { throw RecorderError("DEVICE_CAMERA: 找不到摄像头") }
        guard let mic = options.mic.flatMap({ id in microphones.first { $0.uniqueID == id } }) ?? (options.mic == nil ? AVCaptureDevice.default(for: .audio) : nil) else { throw RecorderError("DEVICE_MIC: 找不到话筒") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for device in [camera, mic] {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RecorderError("DEVICE: 无法使用 \(device.localizedName)") }
            session.addInput(input)
        }
        let formats = camera.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width <= options.cameraWidth && size.height <= (options.quality == "high" ? 2160 : 1080) && $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let format = formats.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }) else { throw RecorderError("DEVICE_CAMERA: 没有支持 30fps 的合适格式") }
        try camera.lockForConfiguration()
        camera.activeFormat = format
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        camera.unlockForConfiguration()
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        video.setSampleBufferDelegate(self, queue: queue)
        let audio = AVCaptureAudioDataOutput()
        audio.setSampleBufferDelegate(self, queue: queue)
        for output in [video as AVCaptureOutput, audio] {
            guard session.canAddOutput(output) else { throw RecorderError("DEVICE: 无法添加捕获输出") }
            session.addOutput(output)
        }
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        writers["cam"] = try TrackWriter(url: directory.appendingPathComponent("cam.mp4"), width: Int(size.width), height: Int(size.height), fps: 30, bitrate: options.bitrate("cam"))
        devices["camera"] = camera.localizedName; devices["mic"] = mic.localizedName
    }
    func configureScreen() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = options.display.flatMap({ id in content.displays.first { String($0.displayID) == id } }) ?? (options.display == nil ? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first : nil) else { throw RecorderError("DEVICE_DISPLAY: 找不到显示器") }
        var ancestors = Set<pid_t>([getpid()])
        var pid = getppid()
        while pid > 1, ancestors.insert(pid).inserted {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            pid = pid_t(info.pbi_ppid)
        }
        let excluded = content.applications.filter { ancestors.contains($0.processID) }
        excludedPIDs = excluded.map(\.processID)
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = SCStreamConfiguration()
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else { throw RecorderError("DEVICE_DISPLAY: 显示器模式不可用") }
        let nativeWidth = mode.pixelWidth
        let nativeHeight = mode.pixelHeight
        let width = min(nativeWidth, options.screenWidth)
        config.width = max(2, width / 2 * 2)
        config.height = max(2, Int(Double(nativeHeight) * Double(config.width) / Double(nativeWidth)) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(options.screenFPS))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2; config.showsCursor = true
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        writers["screen"] = try TrackWriter(url: directory.appendingPathComponent("screen.mp4"), width: config.width, height: config.height, fps: options.screenFPS, bitrate: options.bitrate("screen"))
        devices["display"] = "Display \(display.displayID)"
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { failure = "CLOCK: 摄像头时钟不可用"; return }
        let original = sampleBuffer.presentationTimeStamp
        let host = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock())
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else { failure = "CLOCK: 无法读取时间戳"; return }
        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + (host - original)
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + (host - original) }
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy) == noErr, let copy else { failure = "CLOCK: 无法转换时间戳"; return }
        receive(copy, track: "cam", video: output is AVCaptureVideoDataOutput)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        }
        receive(sampleBuffer, track: "screen", video: type == .screen)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.failure = "SCREEN: \(error.localizedDescription)" } }
    func receive(_ sample: CMSampleBuffer, track: String, video: Bool) {
        guard sample.isValid, CMSampleBufferDataIsReady(sample), !stopping else { return }
        if video { ready.insert(track) }
        guard epoch != nil else { return }
        if let end, sample.presentationTimeStamp >= end { return }
        do { try writers[track]?.append(sample, isVideo: video) } catch { failure = String(describing: error) }
    }
    func run(report: Bool) async throws {
        installSignals()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "庄Sir录制" as CFString, &assertion)
        defer { if assertion != 0 { IOPMAssertionRelease(assertion) }; signals.forEach { $0.cancel() } }
        var runError: Error?
        do {
            if options.tracks.contains("cam") { await withCheckedContinuation { continuation in queue.async { self.session.startRunning(); continuation.resume() } } }
            if let stream { try await stream.startCapture() }
            let deadline = Date().addingTimeInterval(10)
            while queue.sync(execute: { ready != options.tracks && failure == nil && !stopRequested }), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try queue.sync {
                if let failure { throw RecorderError(failure) }
                if stopRequested { return }
                guard ready == options.tracks else { throw RecorderError("CAPTURE_TIMEOUT: 10 秒内未收到所有视频轨道，检查权限和设备占用") }
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                epoch = time
                if let duration = options.duration { end = time + CMTime(seconds: duration, preferredTimescale: 1_000_000_000) }
                startedAt = ISO8601DateFormatter().string(from: Date())
                for writer in writers.values { try writer.start(time) }
                try writeSession(state: "recording", elapsed: 0)
            }
            var nextReport = 1.0
            while let epoch = queue.sync(execute: { self.epoch }) {
                let elapsed = (CMClockGetTime(CMClockGetHostTimeClock()) - epoch).seconds
                if queue.sync(execute: { stopRequested || failure != nil }) || elapsed >= (options.duration ?? .infinity) { break }
                if elapsed >= nextReport {
                    try queue.sync {
                        if report { emit(status(elapsed: elapsed)) }
                        try writeSession(state: "recording", elapsed: elapsed)
                        if diskFree(directory) < 2_000_000_000 { failure = "DISK_CRITICAL: 剩余空间低于 2 GB，安全停止" }
                    }
                    nextReport += 1
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch { runError = error }
        let stop = queue.sync { () -> CMTime in
            stopping = true
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            return end.map { CMTimeMinimum(now, $0) } ?? now
        }
        if let stream { do { try await stream.stopCapture() } catch { if runError == nil { runError = error } } }
        if session.isRunning { await withCheckedContinuation { continuation in queue.async { self.session.stopRunning(); continuation.resume() } } }
        for writer in writers.values {
            do {
                try queue.sync { try writer.prepareFinish(at: stop) }
                if writer.writer.status == .writing { await writer.writer.finishWriting() }
                if writer.writer.status == .failed { throw writer.writer.error ?? RecorderError("WRITE: finalize 失败") }
            } catch { if runError == nil { runError = error } }
        }
        try queue.sync {
            if let failure, runError == nil { runError = RecorderError(failure) }
            if epoch != nil, writers.values.contains(where: { $0.frames == 0 }), runError == nil { runError = RecorderError("NO_VIDEO: 录制未收到视频") }
            let elapsed = epoch.map { (stop - $0).seconds } ?? 0
            try writeSession(state: runError == nil ? "finished" : "failed", elapsed: elapsed, error: runError.map(String.init(describing:)))
        }
        if let runError { throw runError }
    }
    func status(elapsed: Double) -> [String: Any] {
        ["t": elapsed, "tracks": writers.mapValues { $0.info(elapsed: elapsed) }, "levels": writers.mapValues { $0.levelDb }]
    }
    func writeSession(state: String, elapsed: Double, error: String? = nil) throws {
        var data = status(elapsed: elapsed)
        data["version"] = appVersion; data["state"] = state; data["startedAt"] = startedAt
        data["clock"] = "CMClock.hostTimeClock"; data["hostTimeT0"] = epoch?.seconds ?? 0
        data["devices"] = devices; data["excludedApplicationPIDs"] = excludedPIDs
        data["quality"] = options.quality; data["encoder"] = "VideoToolbox H.264 (hardware required)"
        data["error"] = error
        try jsonData(data).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}

func diskFree(_ directory: URL) -> Int64 {
    (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
}

func captureDevices(_ type: AVMediaType) -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) {
        types = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
    } else {
        types = type == .video ? [.builtInWideAngleCamera, .externalUnknown] : [.builtInMicrophone, .externalUnknown]
    }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: type, position: .unspecified).devices
}
