import AppKit
import AVFoundation
import ScreenCaptureKit
import RecordingCore

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // CaptureModel serializes lifecycle calls; mediaQueue coordinates bounded per-track writer owners.
    // Device session work and media writes never run on the UI thread.
    private let sessionQueue = DispatchQueue(label: "zsir.session")
    private let mediaQueue = DispatchQueue(label: "zsir.media")
    private let captureQueue = DispatchQueue(label: "zsir.capture")
    private let admissionLock = NSLock()
    private var admissions: [(CMSampleBuffer, Bool, Bool)] = []
    private var drainScheduled = false
    private var admissionOpen = true
    private let stopGate = RecordingCompletion()
    private let cleanupGate = RecordingCompletion()
    private let previewStartupSettled = RecordingCompletion()
    private let recordingDevicesSettled = RecordingCompletion()
    private var recordingDevicesRequested = false
    private var previewStartupRequested = false
    private var stopRequested = false
    private var requestedEnd: CMTime?
    private var admissionOverflow = false
    private var rejectedCameraVideo: UInt64 = 0
    private var rejectedDesktopVideo: UInt64 = 0
    private var heartbeat = ProcessInfo.processInfo.systemUptime
    private var watchdog: DispatchSourceTimer?

    private func offer(_ sample: CMSampleBuffer, camera: Bool, video: Bool) {
        admissionLock.lock()
        guard admissionOpen else { admissionLock.unlock(); return }
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
            if previewOnly { if video { preview(sample, name: isCamera ? "camera" : "desktop") }; continue }
            do {
                let normalized: CMSampleBuffer
                if isCamera {
                    guard let cameraClock else { continue }
                    normalized = try MediaClock.hostSample(sample, from: cameraClock)
                } else { normalized = sample }
                if startup != nil {
                    startup?.offer(normalized, source: isCamera ? "camera" : "desktop", video: video)
                    if startup?.ready == true, !encoderPreparationInProgress { try prepareStartupEncoders() }
                } else { write(normalized, to: isCamera ? camera : desktop, video: video) }
            } catch {
                if !firstFrames.isCompleted {
                    startup = nil
                    firstFrames.complete(.failure(error))
                }
                fail(error.localizedDescription)
            }
        }
        if overflow { fail("采集队列超过容量，已停止并保留素材") }
    }

    private func startWatchdog() {
        admissionLock.lock()
        heartbeat = ProcessInfo.processInfo.systemUptime
        admissionLock.unlock()
        let tracks = activeWriters.map(\.1)
        let watch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watch.schedule(deadline: .now() + 2, repeating: 2)
        watch.setEventHandler { [weak self] in
            guard let self else { return }
            self.admissionLock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let stalled = now - self.heartbeat > 8 || tracks.contains { now - $0.snapshot.ownerProgressUptime > 8 }
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
    private var camera: RecordingTrack?
    private var desktop: RecordingTrack?
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
    private var startup: RecordingStartup?
    private let firstFrames = RecordingCompletion()
    private var startupBitRate = 0
    private var encoderPreparationInProgress = false
    private var startupDiagnostics: [String: Any] = [:]
    var onUpdate: ((String, Bool, TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPreview: ((String, CMSampleBuffer, Date) -> Void)?
    private var previewEnabled = true
    private var previewToken: UInt64 = 0
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
    private var activeWriters: [(String, RecordingTrack)] {
        var result: [(String, RecordingTrack)] = []
        if let camera { result.append(("camera", camera)) }
        if let desktop { result.append(("desktop", desktop)) }
        return result
    }

    func setPreviewEnabled(_ enabled: Bool) {
        admissionLock.lock()
        previewEnabled = enabled
        previewToken &+= 1
        admissionLock.unlock()
    }

    private func sessionWork(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try work(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func markRecordingDeviceStartup() {
        admissionLock.lock(); recordingDevicesRequested = true; admissionLock.unlock()
    }

    private func needsRecordingDeviceBarrier() -> Bool {
        admissionLock.lock(); defer { admissionLock.unlock() }
        return recordingDevicesRequested
    }

    func start(in root: URL, mode: RecordingMode, selection: DeviceSelection, quality: RecordingQuality = .standard, systemAudio: Bool = true, profile: RecordingProfile = .native) async throws -> URL {
        markRecordingDeviceStartup()
        let gate = RecordingResult<URL>()
        Task { [self] in
            do {
                let take = try await startResources(in: root, mode: mode, selection: selection, quality: quality, systemAudio: systemAudio, profile: profile)
                if !gate.complete(.success(take)) { try? await stop() }
            } catch {
                recordingDevicesSettled.complete(.success(()))
                completeFailedStartCleanup()
                gate.complete(.failure(error))
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            let error = RecordingError("启动超过 15 秒；未收到所有选中源首帧，正在释放设备")
            if gate.complete(.failure(error)) {
                self.mediaQueue.async { self.firstFrames.complete(.failure(error)); self.startup = nil }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            gate.observe { continuation.resume(with: $0) }
        }
    }

    private func completeFailedStartCleanup() {
        admissionLock.lock(); let stopping = stopRequested; admissionLock.unlock()
        if !stopping { cleanupGate.complete(.success(())) }
    }

    private func startResources(in root: URL, mode: RecordingMode, selection: DeviceSelection, quality: RecordingQuality, systemAudio: Bool, profile: RecordingProfile) async throws -> URL {
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
            guard recordingAdmissionOpen() else { throw RecordingError("录制设备准备已取消") }
            await withCheckedContinuation { continuation in
                mediaQueue.async { [self] in
                    startupBitRate = desktopBitRate
                    startup = RecordingStartup(sources: Set([mode.includesCamera ? "camera" : nil, mode.includesDesktop ? "desktop" : nil].compactMap { $0 }))
                    continuation.resume()
                }
            }
            if mode.includesCamera {
                try await sessionWork { [self] in session.startRunning() }
                await withCheckedContinuation { continuation in
                    mediaQueue.async { [self] in cameraClock = session.synchronizationClock; continuation.resume() }
                }
            }
            guard recordingAdmissionOpen() else { throw RecordingError("录制设备启动已取消") }
            if let stream { try await stream.startCapture() }
            recordingDevicesSettled.complete(.success(()))
            try await withCheckedThrowingContinuation { continuation in
                firstFrames.observe { continuation.resume(with: $0) }
            }
            try TakeFiles.writeReport(["state": "recording", "mode": mode.rawValue, "quality": quality.rawValue, "systemAudio": systemAudio,
                "startedAt": ISO8601DateFormatter().string(from: Date()), "devices": devices,
                "startup": startupDiagnostics], in: take)
        } catch {
            // No code after this point can open another device. Resolve this
            // narrower barrier before a catch path awaits stop, avoiding a cycle.
            recordingDevicesSettled.complete(.success(()))
            if !activeWriters.isEmpty {
                try? await stop()
                throw error
            }
            if let stream { try? await stream.stopCapture() }
            if mode.includesCamera { try? await sessionWork { [self] in session.stopRunning() } }
            try? TakeFiles.writeReport(["state": "start_failed", "mode": mode.rawValue, "error": error.localizedDescription], in: take)
            stream = nil
            releaseResources()
            throw error
        }
        return take
    }

    private func recordingAdmissionOpen() -> Bool {
        admissionLock.lock(); defer { admissionLock.unlock() }
        return admissionOpen && !stopRequested
    }

    private func prepareStartupEncoders() throws {
        guard recordingAdmissionOpen() else { throw RecordingError("录制启动已取消") }
        guard let startup, let folder else { throw RecordingError("没有待准备的录制会话") }
        encoderPreparationInProgress = true
        if mode.includesCamera, camera == nil {
            camera = RecordingTrack(url: folder.appendingPathComponent("camera.mp4"), epoch: .invalid, videoBitRate: quality.cameraBitRate)
        }
        if mode.includesDesktop, desktop == nil {
            desktop = RecordingTrack(url: folder.appendingPathComponent("desktop.mp4"), epoch: .invalid, videoBitRate: startupBitRate, includesAudio: systemAudio)
        }
        let group = DispatchGroup()
        for (source, writer) in activeWriters {
            guard let sample = startup.latestVideo[source] else { throw RecordingError("所选源尚未提供视频格式") }
            group.enter()
            writer.prepareVideo(sample) { [self] result in
                mediaQueue.async {
                    if case .failure(let error) = result { self.fail(error.localizedDescription) }
                    group.leave()
                }
            }
        }
        group.notify(queue: mediaQueue) { [self] in
            guard self.startup != nil, recordingAdmissionOpen() else { return }
            do { try activateStartup() }
            catch { self.startup = nil; firstFrames.complete(.failure(error)) }
        }
    }

    private func activateStartup() throws {
        guard recordingAdmissionOpen() else { throw RecordingError("录制启动已取消") }
        guard let startup else { throw RecordingError("没有待启动的录制会话") }
        let ready = try startup.activate()
        let epoch = ready.epoch
        takeEpoch = epoch
        startupDiagnostics = ready.diagnostics
        startupDiagnostics["sourceEpochToAdmissionSeconds"] = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), epoch).seconds
        self.startup = nil
        startupDiagnostics["encoderPreparationBeforeEpoch"] = true
        for (source, writer) in activeWriters {
            guard let first = ready.video[source] else { throw RecordingError("所选源缺少首帧") }
            writer.begin(at: epoch, firstVideo: first, audio: ready.audio[source] ?? [])
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
                self.admissionLock.lock()
                let boundary = self.requestedEnd
                self.admissionLock.unlock()
                for (_, writer) in self.activeWriters { try writer.advance(to: boundary ?? now, exclusive: boundary != nil) }
            } catch { self.fail(error.localizedDescription) }
            let now = ProcessInfo.processInfo.systemUptime
            self.admissionLock.lock()
            self.heartbeat = now
            self.admissionLock.unlock()
            if now - self.lastHealth >= 1 { self.lastHealth = now; self.healthCheck() }
        }
        timer = watch
        watch.resume()
        firstFrames.complete(.success(()))
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
                let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
                devices["cameraFormat"] = ["width": Int(dimensions.width), "height": Int(dimensions.height),
                    "minimumFrameSeconds": videoDevice.activeVideoMinFrameDuration.seconds,
                    "maximumFrameSeconds": videoDevice.activeVideoMaxFrameDuration.seconds]
                let video = AVCaptureVideoDataOutput()
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
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
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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
        if startup != nil {
            startup = nil
            firstFrames.complete(.failure(RecordingError(message)))
            return
        }
        if previewOnly {
            setPreviewEnabled(false)
            admissionLock.lock(); admissionOpen = false; admissionLock.unlock()
            captureError = message
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
            return
        }
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
        if seconds > 12, let stalledAudio = writers.first(where: { $0.1.includesAudio && seconds - $0.1.lastAudioSeconds > 8 }) {
            fail("\(stalledAudio.0) 音频超过 8 秒没有新数据，正在保留已有素材")
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

    private func write(_ sample: CMSampleBuffer, to writer: RecordingTrack?, video: Bool) {
        guard accepting, let writer else { return }
        admissionLock.lock()
        let boundary = requestedEnd
        admissionLock.unlock()
        if let boundary, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), boundary) >= 0 { return }
        do {
            let admitted: CMSampleBuffer
            if video { admitted = sample }
            else {
                guard let cropped = try MediaClock.audioSample(sample, atOrAfter: takeEpoch) else { return }
                admitted = cropped
            }
            try writer.append(admitted, isVideo: video)
            if video {
                preview(sample, name: writer === camera ? "camera" : "desktop")
            }
        }
        catch { fail(error.localizedDescription) }
    }

    private func preview(_ sample: CMSampleBuffer, name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        admissionLock.lock()
        let enabled = previewEnabled
        let token = previewToken
        admissionLock.unlock()
        guard enabled else { return }
        guard now - (lastPreview[name] ?? 0) >= 0.1, !previewPending.contains(name) else {
            (name == "camera" ? camera : desktop)?.notePreviewDrop()
            return
        }
        guard let displaySample = LivePreviewSample.make(from: sample) else { return }
        lastPreview[name] = now
        previewPending.insert(name)
        let capturedAt = Date()
        DispatchQueue.main.async { [self] in
            admissionLock.lock()
            let valid = previewEnabled && previewToken == token && admissionOpen
            admissionLock.unlock()
            if valid { onPreview?(name, displaySample, capturedAt) }
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

    private func markPreviewStartup() {
        admissionLock.lock(); previewStartupRequested = true; admissionLock.unlock()
    }

    private func needsPreviewStartupBarrier() -> Bool {
        admissionLock.lock(); defer { admissionLock.unlock() }
        return previewStartupRequested
    }

    func startPreview(mode: RecordingMode, selection: DeviceSelection) async throws {
        try await startPreviewBounded { [self] in
            try await startPreviewResources(mode: mode, selection: selection)
        }
    }

    private func startPreviewBounded(timeout: TimeInterval = 15, operation: @escaping () async throws -> Void) async throws {
        markPreviewStartup()
        let gate = RecordingCompletion()
        Task { [self] in
            do {
                try await operation()
                previewStartupSettled.complete(.success(()))
                if !gate.complete(.success(())) { try? await stop() }
            } catch {
                previewStartupSettled.complete(.success(()))
                gate.complete(.failure(error))
                try? await stop()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            gate.complete(.failure(RecordingError("预览启动超过 15 秒；正在清理设备，可退出并重新打开")))
        }
        try await withCheckedThrowingContinuation { continuation in
            gate.observe { continuation.resume(with: $0) }
        }
    }

    private func startPreviewResources(mode: RecordingMode, selection: DeviceSelection) async throws {
        self.mode = mode
        self.selection = selection
        self.profile = .balanced
        self.systemAudio = false
        previewOnly = true
        previewEnabled = true
        lastPreview.removeAll()
        watchInterruptions()
        if mode.includesCamera { try await prepareCamera(); try await sessionWork { self.session.startRunning() } }
        if mode.includesDesktop { _ = try await prepareDesktop(); try await stream?.startCapture() }
    }

    private func requestStop() -> Bool {
        admissionLock.lock()
        let first = !stopRequested
        stopRequested = true
        if first { requestedEnd = CMClockGetTime(CMClockGetHostTimeClock()) }
        admissionOpen = false
        admissionLock.unlock()
        return first
    }

    func waitForCleanup() async {
        await withCheckedContinuation { continuation in
            cleanupGate.observe { _ in continuation.resume() }
        }
    }

    func stop() async throws {
        if requestStop() {
            let boundary = requestedEnd ?? CMClockGetTime(CMClockGetHostTimeClock())
            let take = folder
            // An unstructured cleanup task may outlive the deadline. It retains this
            // engine and its Take lease until writers really stop, preventing recovery
            // from racing an encoder that is still touching the original files.
            Task { [self] in
                do { try await stopResources(at: boundary); cleanupGate.complete(.success(())); stopGate.complete(.success(())) }
                catch { cleanupGate.complete(.failure(error)); stopGate.complete(.failure(error)) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [self] in
                let error = RecordingError("停止超过 15 秒，素材需要检查；后台仍在清理设备，请勿开始新录制，必要时退出后恢复副本")
                if stopGate.complete(.failure(error)), let take {
                    // A separate atomic marker cannot overwrite the eventual detailed report.
                    let marker: [String: Any] = ["state": "needs_review", "error": error.localizedDescription,
                        "recovery": "Wait for device cleanup or quit the app before recovering a copy."]
                    if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]) {
                        try? data.write(to: take.appendingPathComponent("stop-timeout.json"), options: .atomic)
                    }
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            stopGate.observe { continuation.resume(with: $0) }
        }
    }

    private func stopResources(at boundary: CMTime) async throws {
        if needsRecordingDeviceBarrier() {
            await withCheckedContinuation { continuation in
                recordingDevicesSettled.observe { _ in continuation.resume() }
            }
        }
        // A late startup must settle before cleanup so it cannot reopen a device
        // after stop has already completed. The public stop deadline stays independent.
        if needsPreviewStartupBarrier() {
            await withCheckedContinuation { continuation in
                previewStartupSettled.observe { _ in continuation.resume() }
            }
        }
        if previewOnly {
            previewOnly = false
            previewEnabled = false
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if mode.includesCamera { try await sessionWork { self.session.stopRunning() } }
            releaseResources()
            return
        }
        defer { releaseResources() }
        // Stop capture independently of a potentially blocked media writer.
        let sourceStop = Task { [self] () -> String? in
            var issue: String?
            if let stream {
                do { try await stream.stopCapture() }
                catch { issue = error.localizedDescription }
            }
            if mode.includesCamera {
                do { try await sessionWork { [self] in session.stopRunning() } }
                catch { issue = issue ?? error.localizedDescription }
            }
            return issue
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            mediaQueue.async { [self] in
                // Invalidate preparation before draining/finishing so a late
                // encoder-ready callback cannot begin media or restart timers.
                startup = nil
                firstFrames.complete(.failure(RecordingError("录制启动已取消")))
                drainAdmissions()
                accepting = false
                // All tracks receive the same raw stop. MovieWriter rounds the
                // relative end once, directly to the rational 30fps grid.
                endTime = boundary
                timer?.cancel()
                timer = nil
                continuation.resume()
            }
        }
        let stopIssue = await sourceStop.value
        stream = nil
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
                    group.enter()
                    writer.finish(at: endTime) { result in
                        writer.whenClosed {
                            self.mediaQueue.async {
                                if writer.videoSamples == 0 || (writer.includesAudio && writer.audioSamples == 0) {
                                    issues.append("\(name) 未收到完整音视频")
                                }
                                if case .failure(let error) = result { issues.append("\(name)：\(error.localizedDescription)") }
                                group.leave()
                            }
                        }
                    }
                }
                group.notify(queue: mediaQueue) { [self] in
                    if let timeout = stopGate.failureDescription { issues.append(timeout) }
                    let report: [String: Any] = [
                        "state": issues.values.isEmpty ? "finalized_unverified" : "needs_review",
                        "devices": devices, "mode": mode.rawValue, "errors": issues.values, "startup": startupDiagnostics,
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

    static func checkPreparationStopRaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func engineWithTake() throws -> CaptureEngine {
            let engine = CaptureEngine()
            engine.mode = .desktop; engine.systemAudio = false
            let take = try TakeFiles.create(in: root)
            engine.folder = take; engine.lease = try TakeLease(folder: take)
            try TakeFiles.writeReport(["state": "preparing"], in: take)
            try Data([0]).write(to: take.appendingPathComponent("camera.mp4"))
            return engine
        }
        // A delayed regular-device startup must settle before stop can release
        // its lease, even while no stream or writer has been published yet.
        let devices = try engineWithTake()
        devices.markRecordingDeviceStartup()
        Task { try? await devices.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!devices.cleanupGate.isCompleted)
        let activeTakes = try RecordingRecovery.scan(root: root)
        precondition(activeTakes.isEmpty)
        devices.recordingDevicesSettled.complete(.success(()))
        await devices.waitForCleanup()
        precondition(devices.cleanupGate.isCompleted)
        // Block the real per-track owner before prepare. A late preparation
        // completion must not reactivate the canceled coordinator or its timer.
        let preparing = try engineWithTake()
        let worker = RecordingTrack(url: preparing.folder!.appendingPathComponent("desktop.mp4"), epoch: .invalid, includesAudio: false)
        preparing.desktop = worker
        let release = DispatchSemaphore(value: 0)
        await worker.blockOwnerForCheck(until: release)
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        preparing.startup = RecordingStartup(sources: ["desktop"])
        preparing.startup?.offer(sample!, source: "desktop", video: true)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            preparing.mediaQueue.async {
                do { try preparing.prepareStartupEncoders(); c.resume() }
                catch { c.resume(throwing: error) }
            }
        }
        Task { try? await preparing.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!preparing.cleanupGate.isCompleted)
        precondition(preparing.firstFrames.failureDescription != nil)
        release.signal()
        await preparing.waitForCleanup()
        await withCheckedContinuation { c in
            preparing.mediaQueue.async {
                precondition(preparing.startup == nil && !preparing.accepting && preparing.timer == nil)
                c.resume()
            }
        }
        precondition(worker.videoSamples == 0)
        print("PASS: stop retains lease during late regular-device startup; canceled encoder preparation cannot begin, restart timers or publish startup success")
    }

    static func checkBoundedPreviewStartup() async throws {
        let engine = CaptureEngine()
        engine.mode = .desktop
        engine.previewOnly = true
        let release = RecordingCompletion()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await engine.startPreviewBounded(timeout: 0.1) {
                await withCheckedContinuation { continuation in
                    release.observe { _ in continuation.resume() }
                }
            }
            throw RecordingError("blocked preview startup incorrectly succeeded")
        } catch {
            precondition(ProcessInfo.processInfo.systemUptime - started < 1)
        }
        // Stop must not falsely finish while a startup can still open devices.
        let stopped = RecordingCompletion()
        Task { try? await engine.stop(); stopped.complete(.success(())) }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(!stopped.isCompleted)
        release.complete(.success(()))
        await engine.waitForCleanup()
        print("PASS: preview startup deadline returns independently; cleanup waits for late startup and then closes once")
    }

    /// Device-free fault injection: block the real media owner, exercise concurrent
    /// stop requests, and verify the lease remains held until cleanup resumes.
    static func checkBoundedStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CaptureEngine()
        engine.mode = .desktop
        let take = try TakeFiles.create(in: root)
        engine.folder = take
        engine.lease = try TakeLease(folder: take)
        try TakeFiles.writeReport(["state": "recording"], in: take)
        try Data([0]).write(to: take.appendingPathComponent("desktop.mp4"))
        let blocked = DispatchSemaphore(value: 0)
        await withCheckedContinuation { continuation in
            engine.mediaQueue.async { continuation.resume(); blocked.wait() }
        }
        let start = ProcessInfo.processInfo.systemUptime
        async let first: Void = engine.stop()
        async let second: Void = engine.stop()
        do { _ = try await (first, second); throw RecordingError("blocked stop incorrectly succeeded") }
        catch {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            precondition(elapsed >= 14 && elapsed < 18)
            let active = try RecordingRecovery.scan(root: root)
            precondition(active.isEmpty)
        }
        // The timeout observer resumes before its best-effort disk marker; wait
        // for that independent write without holding the media owner.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: take.appendingPathComponent("stop-timeout.json").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: take.appendingPathComponent("stop-timeout.json").path))
        blocked.signal()
        await engine.waitForCleanup()
        // Even a late completed report must not hide deadline failure evidence.
        try TakeFiles.writeReport(["state": "finalized_unverified"], in: take)
        let candidates = try RecordingRecovery.scan(root: root)
        precondition(candidates.count == 1)
        print("PASS: blocked media owner exits saving in 15s; concurrent stop is idempotent; active lease excludes recovery; timeout marker survives late completion")
    }

    private func metrics(_ writer: RecordingTrack) -> [String: Any] {
        ["videoSamples": writer.videoSamples, "audioSamples": writer.audioSamples,
         "droppedVideo": writer.droppedVideo, "droppedAudio": writer.droppedAudio,
         "diagnostics": ["capturedFrames": writer.diagnostics.capturedFrames,
            "scheduledFrames": writer.diagnostics.scheduledFrames, "writtenFrames": writer.diagnostics.writtenFrames,
            "repeatedFrames": writer.diagnostics.repeatedFrames, "lateFrames": writer.diagnostics.lateFrames,
            "backpressureFrames": writer.diagnostics.backpressureFrames, "previewDroppedFrames": writer.diagnostics.previewDroppedFrames, "queueDepth": writer.diagnostics.queueDepth,
            "queueHighWaterMark": writer.diagnostics.queueHighWaterMark],
         "ingressQueueDepth": writer.snapshot.ingressQueueDepth,
         "ingressQueueHighWaterMark": writer.snapshot.ingressQueueHighWaterMark,
         "encoderPreparationSeconds": writer.snapshot.encoderPreparationSeconds,
         "firstVideoAppendSeconds": writer.snapshot.firstVideoAppendSeconds,
         "firstAudioAppendSeconds": writer.snapshot.firstAudioAppendSeconds,
         "encoderPolicy": writer.encoderPolicy, "includesAudio": writer.includesAudio, "width": writer.width, "height": writer.height, "targetVideoBitRate": writer.videoBitRate,
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
