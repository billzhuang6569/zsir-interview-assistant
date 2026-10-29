import AppKit
import AVFoundation
import ScreenCaptureKit
import RecordingCore

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Lifecycle calls are serialized by CaptureModel; all active writer state stays on mediaQueue.
    // Device session work and media writes never run on the UI thread.
    private let sessionQueue = DispatchQueue(label: "zsir.session")
    private let mediaQueue = DispatchQueue(label: "zsir.media")
    private let captureQueue = DispatchQueue(label: "zsir.capture")
    private let admissionLock = NSLock()
    private var admissions: [(CMSampleBuffer, Bool, Bool)] = []
    private var drainScheduled = false
    private var admissionOverflow = false
    private var rejectedCameraVideo: UInt64 = 0
    private var rejectedDesktopVideo: UInt64 = 0
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var watchdog: DispatchSourceTimer?

    private func offer(_ sample: CMSampleBuffer, camera: Bool, video: Bool) {
        admissionLock.lock()
        let limit = video ? 3 : 64
        if admissions.filter({ $0.1 == camera && $0.2 == video }).count >= limit {
            admissionOverflow = true
            if video {
                if camera { rejectedCameraVideo += 1 } else { rejectedDesktopVideo += 1 }
            }
        } else { admissions.append((sample, camera, video)) }
        let schedule = !drainScheduled
        drainScheduled = true
        admissionLock.unlock()
        if schedule { mediaQueue.async { [weak self] in self?.drainAdmissions() } }
    }

    private func drainAdmissions() {
        admissionLock.lock()
        let batch = admissions
        let overflow = admissionOverflow
        let cameraRejected = rejectedCameraVideo
        let desktopRejected = rejectedDesktopVideo
        rejectedCameraVideo = 0
        rejectedDesktopVideo = 0
        admissions.removeAll(keepingCapacity: true)
        admissionOverflow = false
        drainScheduled = false
        heartbeat = ProcessInfo.processInfo.systemUptime
        admissionLock.unlock()
        camera?.noteIngressRejection(cameraRejected)
        desktop?.noteIngressRejection(desktopRejected)
        for (sample, isCamera, video) in batch {
            if previewOnly { if video { preview(sample, name: isCamera ? "camera" : "desktop") } }
            else if isCamera, accepting, let cameraClock {
                do { write(try MediaClock.hostSample(sample, from: cameraClock), to: camera, video: video) }
                catch { fail(error.localizedDescription) }
            } else if !isCamera { write(sample, to: desktop, video: video) }
        }
        if overflow { fail("采集队列超过容量，已停止并保留素材") }
    }

    private func startWatchdog() {
        admissionLock.lock()
        heartbeat = ProcessInfo.processInfo.systemUptime
        admissionLock.unlock()
        let watch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watch.schedule(deadline: .now() + 2, repeating: 2)
        watch.setEventHandler { [weak self] in
            guard let self else { return }
            self.admissionLock.lock()
            let stalled = ProcessInfo.processInfo.systemUptime - self.heartbeat > 8
            self.admissionLock.unlock()
            if stalled {
                watch.cancel()
                DispatchQueue.main.async { [weak self] in self?.onFailure?("媒体处理超过 8 秒无响应，正在保留素材供恢复") }
            }
        }
        watchdog = watch
        watch.resume()
    }
    private let session = AVCaptureSession()
    private var stream: SCStream?
    private var camera: MovieWriter?
    private var desktop: MovieWriter?
    private var accepting = false
    private var folder: URL?
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var startedUptime = ProcessInfo.processInfo.systemUptime
    private var captureError: String?
    private var devices: [String: Any] = [:]
    private var cameraClock: CMClock?
    private var endTime = CMTime.invalid
    private var takeEpoch = CMTime.invalid
    var onUpdate: ((String, Bool, TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPreview: ((String, CMSampleBuffer, Date) -> Void)?
    private var previewEnabled = true
    private var previewPending: Set<String> = []
    private var mode: RecordingMode = .both
    private var lease: TakeLease?
    private var activity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var selection = DeviceSelection()
    private var quality: RecordingQuality = .standard
    private var profile: RecordingProfile = .native
    private var previewOnly = false
    private var lastPreview: [String: TimeInterval] = [:]
    private var lastHealth: TimeInterval = 0
    private var systemAudio = true
    private var displaySize: CGSize?

    private func releaseResources() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        watchdog?.cancel()
        watchdog = nil
        lease = nil
    }

    deinit { releaseResources() }

    private func watchInterruptions() {
        for name in [Notification.Name("AVCaptureSessionRuntimeErrorNotification"), Notification.Name("AVCaptureSessionWasInterruptedNotification")] {
            let center = NotificationCenter.default
            let observer = center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.mediaQueue.async { [weak self] in self?.fail("摄像头或话筒采集被中断，正在保存已有素材") }
            }
            observers.append((center, observer))
        }
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.mediaQueue.async { [weak self] in self?.fail("系统即将睡眠，正在保存已有素材；唤醒后请检查素材") }
        }
        observers.append((center, observer))
    }
    private var activeWriters: [(String, MovieWriter)] {
        var result: [(String, MovieWriter)] = []
        if let camera { result.append(("camera", camera)) }
        if let desktop { result.append(("desktop", desktop)) }
        return result
    }

    func setPreviewEnabled(_ enabled: Bool) {
        mediaQueue.async { [self] in previewEnabled = enabled }
    }

    private func sessionWork(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try work(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func start(in root: URL, mode: RecordingMode, selection: DeviceSelection, quality: RecordingQuality = .standard, systemAudio: Bool = true, profile: RecordingProfile = .native) async throws -> URL {
        self.mode = mode
        self.selection = selection
        self.quality = quality
        self.profile = profile
        previewOnly = false
        lastPreview.removeAll()
        self.systemAudio = systemAudio && RecordingCapabilities.systemAudio
        let systemAudio = self.systemAudio
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (capacity.volumeAvailableCapacityForImportantUsage ?? 0) > 10_000_000_000 else {
            throw RecordingError("至少需要 10 GB 可用空间，请更换输出目录")
        }
        let take = try TakeFiles.create(in: root)
        folder = take
        lease = try TakeLease(folder: take)
        devices = ["system": ProcessInfo.processInfo.operatingSystemVersionString]
        captureError = nil
        try TakeFiles.writeReport(["state": "preparing", "mode": mode.rawValue], in: take)
        do {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在录制采访素材")
            watchInterruptions()
            if mode.includesCamera { try await prepareCamera() }
            let desktopBitRate = mode.includesDesktop ? try await prepareDesktop() : 0
            if mode.includesCamera { try await sessionWork { [self] in session.startRunning() } }
            if let stream { try await stream.startCapture() }
            try TakeFiles.writeReport(["state": "recording", "mode": mode.rawValue, "quality": quality.rawValue, "systemAudio": systemAudio,
                "startedAt": ISO8601DateFormatter().string(from: Date()), "devices": devices], in: take)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                mediaQueue.async { [self] in
                    let epoch = CMClockGetTime(CMClockGetHostTimeClock())
                    takeEpoch = epoch
                    if mode.includesCamera {
                        cameraClock = session.synchronizationClock
                        camera = MovieWriter(url: take.appendingPathComponent("camera.mp4"), epoch: epoch, videoBitRate: quality.cameraBitRate)
                    }
                    if mode.includesDesktop {
                        desktop = MovieWriter(url: take.appendingPathComponent("desktop.mp4"), epoch: epoch, videoBitRate: desktopBitRate, includesAudio: systemAudio)
                    }
                    accepting = true
                    startWatchdog()
                    startedAt = Date()
                    startedUptime = ProcessInfo.processInfo.systemUptime
                    let watch = DispatchSource.makeTimerSource(queue: mediaQueue)
                    watch.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
                    watch.setEventHandler { [weak self] in
                        guard let self, self.accepting else { return }
                        do {
                            let now = CMClockGetTime(CMClockGetHostTimeClock())
                            for (_, writer) in self.activeWriters { try writer.advance(to: now) }
                        } catch { self.fail(error.localizedDescription) }
                        let now = ProcessInfo.processInfo.systemUptime
                        self.admissionLock.lock()
                        self.heartbeat = now
                        self.admissionLock.unlock()
                        if now - self.lastHealth >= 1 { self.lastHealth = now; self.healthCheck() }
                    }
                    timer = watch
                    watch.resume()
                    continuation.resume()
                }
            }
        } catch {
            if let stream { try? await stream.stopCapture() }
            if mode.includesCamera { try? await sessionWork { [self] in session.stopRunning() } }
            try? TakeFiles.writeReport(["state": "start_failed", "mode": mode.rawValue, "error": error.localizedDescription], in: take)
            stream = nil
            releaseResources()
            throw error
        }
        return take
    }

    private func prepareCamera() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw RecordingError("未获得摄像头权限，请在系统设置中允许后重试")
        }
        if !previewOnly {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecordingError("未获得话筒权限，请在系统设置中允许后重试")
            }
        }
        guard let videoDevice = selection.cameraID.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: selection.cameraID) else {
            throw RecordingError("所选摄像头或话筒不可用，请刷新设备列表后重选")
        }
        let audioDevice = selection.microphoneID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: selection.microphoneID)
        guard previewOnly || audioDevice != nil else { throw RecordingError("所选话筒不可用") }
        devices["camera"] = videoDevice.localizedName
        devices["microphone"] = audioDevice?.localizedName ?? "none"
        try await sessionWork { [self] in
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                else { session.sessionPreset = .high }
                for device in (previewOnly ? [videoDevice] : [videoDevice] + [audioDevice].compactMap { $0 }) {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw RecordingError("设备不可用：\(device.localizedName)") }
                    session.addInput(input)
                }
                if videoDevice.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    try videoDevice.lockForConfiguration()
                    videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    videoDevice.unlockForConfiguration()
                }
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: captureQueue)
                let audio = AVCaptureAudioDataOutput()
                audio.setSampleBufferDelegate(self, queue: captureQueue)
                guard session.canAddOutput(video), previewOnly || session.canAddOutput(audio) else {
                    throw RecordingError("无法创建摄像头与话筒输出")
                }
                session.addOutput(video)
                if !previewOnly { session.addOutput(audio) }
        }
    }

    private func prepareDesktop() async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == (selection.displayID == 0 ? CGMainDisplayID() : selection.displayID) }) else {
            throw RecordingError("所选显示器已断开，请重新选择")
        }
        devices["displayID"] = display.displayID
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw RecordingError("无法排除本工具窗口，已取消录制") }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let size = try DisplayCaptureCompatibility.pixelSize(display: display, filter: filter)
        let dimensions = try profile.dimensions(width: Int(size.width), height: Int(size.height))
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        let desktopBitRate = try quality.desktopBitRate(width: configuration.width, height: configuration.height)
        displaySize = CGSize(width: CGDisplayPixelsWide(display.displayID), height: CGDisplayPixelsHigh(display.displayID))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: previewOnly ? 10 : 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 13, *) {
            configuration.capturesAudio = systemAudio
            configuration.excludesCurrentProcessAudio = false
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }
        let screenStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try screenStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if #available(macOS 13, *), systemAudio { try screenStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
        stream = screenStream
        return desktopBitRate
    }

    private func fail(_ message: String) {
        guard accepting else { return }
        accepting = false
        captureError = message
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    private func healthCheck() {
        guard accepting, let folder else { return }
        let writers = activeWriters
        if mode.includesDesktop, let id = devices["displayID"] as? UInt32, let size = displaySize,
           CGDisplayIsActive(id) == 0 || size != CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)) {
            fail("录制目标屏幕已断开或尺寸变化，正在保存已有素材"); return
        }
        do {
            for (_, writer) in writers { try writer.checkHealth() }

        } catch { fail(error.localizedDescription); return }
        let seconds = ProcessInfo.processInfo.systemUptime - startedUptime
        let ready = !writers.isEmpty && writers.allSatisfy { $0.1.videoSamples > 0 && (!$0.1.includesAudio || $0.1.audioSamples > 0) }
        let status = "正在写入本机 · 丢帧 \(writers.reduce(0) { $0 + $1.1.droppedVideo })"
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(status, ready, seconds) }
        if seconds > 12 && !ready {
            fail("12 秒内未收到所选机位的完整音视频；请检查设备权限和所选设备后重试")
            return
        }
        if let camera, seconds > 12 && seconds - camera.lastCapturedVideoSeconds > 8 {
            fail("摄像头超过 8 秒没有新画面，正在保留已有素材")
            return
        }
        if let camera, seconds > 12 && seconds - camera.lastAudioSeconds > 8 {
            fail("话筒超过 8 秒没有新数据，正在保留已有素材")
            return
        }
        do {
            guard let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
                throw RecordingError("无法检查剩余磁盘空间")
            }
            if free < 2_000_000_000 { fail("剩余空间不足 2 GB，已停止录制并保留素材") }
        } catch {
            fail("无法检查输出磁盘：\(error.localizedDescription)")
        }
    }

    private func write(_ sample: CMSampleBuffer, to writer: MovieWriter?, video: Bool) {
        guard accepting, let writer else { return }
        do {
            try writer.append(sample, isVideo: video)
            if video {
                preview(sample, name: writer === camera ? "camera" : "desktop")
            }
        }
        catch { fail(error.localizedDescription) }
    }

    private func preview(_ sample: CMSampleBuffer, name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard previewEnabled else { return }
        guard now - (lastPreview[name] ?? 0) >= 0.1, !previewPending.contains(name) else {
            (name == "camera" ? camera : desktop)?.notePreviewDrop()
            return
        }
        guard let displaySample = LivePreviewSample.make(from: sample) else { return }
        lastPreview[name] = now
        previewPending.insert(name)
        let capturedAt = Date()
        DispatchQueue.main.async { [self] in
            onPreview?(name, displaySample, capturedAt)
            mediaQueue.async { [self] in previewPending.remove(name) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        offer(sampleBuffer, camera: true, video: output is AVCaptureVideoDataOutput)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            offer(sampleBuffer, camera: false, video: true)
        } else if #available(macOS 13, *), type == .audio {
            offer(sampleBuffer, camera: false, video: false)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        mediaQueue.async { [weak self] in self?.fail("屏幕采集停止：\(error.localizedDescription)") }
    }

    func startPreview(mode: RecordingMode, selection: DeviceSelection) async throws {
        self.mode = mode
        self.selection = selection
        self.profile = .balanced
        self.systemAudio = false
        previewOnly = true
        previewEnabled = true
        lastPreview.removeAll()
        do {
            if mode.includesCamera { try await prepareCamera(); try await sessionWork { self.session.startRunning() } }
            if mode.includesDesktop { _ = try await prepareDesktop(); try await stream?.startCapture() }
        } catch {
            try? await stop()
            throw error
        }
    }

    func stop() async throws {
        if previewOnly {
            previewOnly = false
            previewEnabled = false
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if mode.includesCamera { try await sessionWork { self.session.stopRunning() } }
            return
        }
        defer { releaseResources() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mediaQueue.async { [self] in
                drainAdmissions()
                accepting = false
                let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), takeEpoch)
                endTime = CMTimeAdd(takeEpoch, CMTimeConvertScale(elapsed, timescale: 30, method: .roundTowardNegativeInfinity))
                timer?.cancel()
                timer = nil
                continuation.resume()
            }
        }
        var stopError: String?
        if let stream {
            do { try await stream.stopCapture() }
            catch { stopError = error.localizedDescription }
        }
        if mode.includesCamera { try await sessionWork { [self] in session.stopRunning() } }
        stream = nil
        let stopIssue = stopError
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mediaQueue.async { [self] in
                let writers = activeWriters
                guard let folder, !writers.isEmpty else {
                    continuation.resume(throwing: RecordingError("没有活动录制"))
                    return
                }
                let group = DispatchGroup()
                let issues = MediaIssues(queue: mediaQueue, values: [captureError, stopIssue].compactMap { $0 })
                for (name, writer) in writers {
                    if writer.videoSamples == 0 || (writer.includesAudio && writer.audioSamples == 0) {
                        issues.append("\(name) 未收到完整音视频")
                    }
                    group.enter()
                    writer.finish(at: endTime) { result in
                        self.mediaQueue.async {
                            if case .failure(let error) = result { issues.append("\(name)：\(error.localizedDescription)") }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: mediaQueue) { [self] in
                    let report: [String: Any] = [
                        "state": issues.values.isEmpty ? "finalized_unverified" : "needs_review",
                        "devices": devices, "mode": mode.rawValue, "errors": issues.values,
                        "profile": profile.rawValue, "quality": quality.rawValue, "qualityVersion": 1, "systemAudio": systemAudio,
                        "durationSeconds": Date().timeIntervalSince(startedAt),
                        "tracks": Dictionary(uniqueKeysWithValues: writers.map { ($0.0, self.metrics($0.1)) }),
                        "note": "封装完成不代表实机验收通过；需听检、检查首尾、Final Cut Pro 导入和长时同步。"
                    ]
                    do { try TakeFiles.writeReport(report, in: folder) }
                    catch { issues.append("检查报告保存失败：\(error.localizedDescription)") }
                    self.camera = nil
                    self.desktop = nil
                    if issues.values.isEmpty { continuation.resume() }
                    else { continuation.resume(throwing: RecordingError(issues.values.joined(separator: "\n"))) }
                }
            }
        }
    }

    private func metrics(_ writer: MovieWriter) -> [String: Any] {
        ["videoSamples": writer.videoSamples, "audioSamples": writer.audioSamples,
         "droppedVideo": writer.droppedVideo, "droppedAudio": writer.droppedAudio,
         "diagnostics": ["capturedFrames": writer.diagnostics.capturedFrames,
            "scheduledFrames": writer.diagnostics.scheduledFrames, "writtenFrames": writer.diagnostics.writtenFrames,
            "repeatedFrames": writer.diagnostics.repeatedFrames, "lateFrames": writer.diagnostics.lateFrames,
            "backpressureFrames": writer.diagnostics.backpressureFrames, "previewDroppedFrames": writer.diagnostics.previewDroppedFrames, "queueDepth": writer.diagnostics.queueDepth,
            "queueHighWaterMark": writer.diagnostics.queueHighWaterMark],
         "includesAudio": writer.includesAudio, "width": writer.width, "height": writer.height, "targetVideoBitRate": writer.videoBitRate,
         "firstVideoSeconds": writer.firstVideoSeconds ?? -1, "lastVideoSeconds": writer.lastVideoSeconds,
         "lastAudioSeconds": writer.lastAudioSeconds]
    }
}

/// Finalization aggregation belongs exclusively to mediaQueue, including finish callbacks.
private final class MediaIssues: @unchecked Sendable {
    private let queue: DispatchQueue
    private var storage: [String]
    init(queue: DispatchQueue, values: [String]) { self.queue = queue; storage = values }
    var values: [String] {
        dispatchPrecondition(condition: .onQueue(queue))
        return storage
    }
    func append(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        storage.append(message)
    }
}
