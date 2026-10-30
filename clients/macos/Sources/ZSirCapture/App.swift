import AppKit
import SwiftUI
import RecordingCore
import AVFoundation

@MainActor
final class CaptureModel: ObservableObject {
    @Published var phase = "准备就绪"
    @Published var detail = ""
    @Published var busy = false
    @Published var requiresRestart = false
    @Published var canStop = false
    @Published var recordedSeconds: TimeInterval = 0
    var timecode: String {
        let seconds = Int(max(0, recordedSeconds))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    @Published var error: String?
    @Published var root: URL {
        didSet { UserDefaults.standard.set(root.path, forKey: "outputDirectory") }
    }
    @Published var lastTake: URL?
    let updates = Updates()
    let permissions: PermissionSetup
    @Published var mode: RecordingMode = .both {
        didSet {
            permissions.defaults.set(mode.rawValue, forKey: "recordingMode")
            if !busy { clearPreviews() }
        }
    }
    let cameraPreview = LivePreviewFeed()
    let desktopPreview = LivePreviewFeed()
    @Published var previewVisible = true
    @Published var idlePreviewLive = false
    @Published var idlePreviewError: String?
    @Published private(set) var idlePreviewCleaning = false
    @Published private(set) var previewWindowVisible = true
    @Published var settingsVisible = false
    @Published var selection = DeviceSelection() {
        didSet {
            let d = permissions.defaults
            d.set(selection.cameraID, forKey: "cameraID"); d.set(selection.microphoneID, forKey: "microphoneID")
            if oldValue.displayID != selection.displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(selection.displayID)?.takeRetainedValue() {
                d.set(CFUUIDCreateString(nil, uuid) as String, forKey: "displayUUID")
            }
        }
    }
    @Published var quality: RecordingQuality = .standard { didSet { permissions.defaults.set(quality.rawValue, forKey: "recordingQuality") } }
    @Published var profile: RecordingProfile = .balanced { didSet { permissions.defaults.set(profile.rawValue, forKey: "recordingProfile") } }
    @Published var systemAudio = RecordingCapabilities.systemAudio {
        didSet {
            if !RecordingCapabilities.systemAudio && systemAudio { systemAudio = false }
            permissions.defaults.set(systemAudio, forKey: "systemAudio")
        }
    }
    @Published var autoRecovery = false { didSet { permissions.defaults.set(autoRecovery, forKey: "autoRecovery") } }
    let settingsPreview = SettingsPreview()
    private var deviceObservers: [NSObjectProtocol] = []
    private var autoRecoveryAttempted = false
    @Published var cameras: [DeviceOption] = []
    @Published var microphones: [DeviceOption] = []
    @Published var displays: [DeviceOption] = []
    @Published var recoverable: [RecoveryCandidate] = []

    func refreshDevices() {
        guard !busy else { return }
        if selection.displayID == 0 {
            if let value = permissions.defaults.string(forKey: "displayUUID"), let uuid = CFUUIDCreateFromString(nil, value as CFString) {
                let id = CGDisplayGetDisplayIDFromUUID(uuid)
                selection.displayID = id == 0 ? UInt32.max : id
            } else { selection.displayID = CGMainDisplayID() }
        }
        cameras = captureDeviceOptions(.video)
        microphones = captureDeviceOptions(.audio)
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DeviceOption(id: id.stringValue, name: screen.localizedName)
        }
    }

    func scanRecovery() {
        guard !busy else { return }
        do { recoverable = try RecordingRecovery.scan(root: root) }
        catch { if FileManager.default.fileExists(atPath: root.path) { self.error = error.localizedDescription } }
    }

    func recover(_ candidate: RecoveryCandidate) {
        guard !busy else { return }
        busy = true
        phase = "正在恢复素材…"
        detail = "生成新副本，保留原文件"
        Task {
            do {
                let result = try await RecordingRecovery.recover(candidate)
                lastTake = result.outputFolder
                phase = result.errors.isEmpty ? "恢复副本已生成" : "恢复未全部完成"
                detail = "请打开目录检查音画与可用时长"
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            } catch {
                phase = "恢复失败"
                detail = "原素材已保留，可稍后重试"
                self.error = error.localizedDescription
            }
            busy = false
            scanRecovery()
        }
    }
    var onResize: ((CGFloat) -> Void)?
    private var generation = 0
    private var engine: CaptureEngine?
    private var idleEngine: CaptureEngine?
    private var previewTransition: Task<Void, Never>?
    private var previewGeneration = 0
    private var lastIdlePreviewRequest: String?
    private var failedIdlePreviewConfiguration: String?
    private var idlePreviewStartForCheck: ((CaptureEngine, RecordingMode, DeviceSelection) async throws -> Void)?
    private var idlePreviewStopForCheck: ((CaptureEngine) async throws -> Void)?
    private var settingsPreviewTask: Task<Void, Never>?

    private var settingsStopTask: Task<Void, Never>?
    private var settingsStopGate: RecordingCompletion?

    @discardableResult
    func stopSettingsPreview(timeout: TimeInterval = 15) async -> Bool {
        let gate: RecordingCompletion
        if let existing = settingsStopGate { gate = existing }
        else {
            gate = RecordingCompletion()
            settingsStopGate = gate
            let pending = settingsPreviewTask
            settingsPreviewTask = nil
            pending?.cancel()
            settingsPreview.invalidate()
            let cleanup = Task {
                await pending?.value
                await self.settingsPreview.stop()
            }
            settingsStopTask = cleanup
            Task { [self] in
                await cleanup.value
                gate.complete(.success(()))
                if settingsStopGate === gate { settingsStopTask = nil; settingsStopGate = nil }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.complete(.failure(RecordingError("设置预览清理超过 15 秒；请退出并重新打开，暂不能开始新采集")))
            }
        }
        let result = await withCheckedContinuation { continuation in
            gate.observe { continuation.resume(returning: $0) }
        }
        if case .failure(let failure) = result {
            requiresRestart = true
            busy = true
            phase = "设备需要重启"
            detail = "设置预览未及时释放；可退出后重新打开"
            error = error ?? failure.localizedDescription
            return false
        }
        return true
    }

    static func checkSettingsPreviewDeadline() async throws {
        for pendingRefresh in [true, false] {
            let suite = "zsir.settings-deadline.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = CaptureModel(permissions: PermissionSetup(defaults: defaults))
            model.busy = true // Same preparation state as the Start button path.
            let camera = SettingsCamera()
            let release = DispatchSemaphore(value: 0)
            await camera.blockOwnerForCheck(until: release)
            model.settingsPreview.installCameraForCheck(camera)
            let pendingDone = RecordingCompletion()
            if pendingRefresh {
                model.settingsPreviewTask = Task { await camera.stop(); pendingDone.complete(.success(())) }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let stopped = await model.stopSettingsPreview(timeout: 0.05)
            precondition(!stopped && model.requiresRestart && model.busy && !model.canStop)
            precondition(ProcessInfo.processInfo.systemUptime - started < 1)
            precondition(model.settingsStopTask != nil)
            if pendingRefresh { precondition(!pendingDone.isCompleted) }
            model.start() // Restart-required state must never create another engine.
            precondition(model.engine == nil)
            release.signal()
            await model.settingsStopTask?.value
            if pendingRefresh { precondition(pendingDone.isCompleted) }
            precondition(model.requiresRestart) // Only an explicit restart clears this terminal state.
        }
        print("PASS: pending settings refresh and blocked camera stop have independent deadlines; cleanup stays alive; restart-required state blocks capture and permits explicit exit")
    }

    func refreshSettingsPreview() async {
        await updateIdlePreview(enabled: false).value
        await stopSettingsPreview()
        guard !Task.isCancelled, settingsVisible, previewWindowVisible, !busy, !requiresRestart else { return }
        let selection = selection
        let mode = mode
        let task = Task { await settingsPreview.refresh(selection: selection, mode: mode) }
        settingsPreviewTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    var idlePreviewID: String {
        "\(mode.rawValue)|\(selection.cameraID)|\(selection.microphoneID)|\(selection.displayID)|\(previewVisible)|\(previewWindowVisible)|\(settingsVisible)|\(permissions.visible)|\(permissions.requesting != nil)|\(busy)"
    }

    func setPreviewWindowVisible(_ visible: Bool) {
        previewWindowVisible = visible
        engine?.setPreviewEnabled(previewVisible && visible)
        if !visible { clearPreviews() }
        updateIdlePreview(enabled: visible)
    }

    private var idlePreviewConfiguration: String {
        let auth = CapturePermission.required(for: mode).map { "\($0.rawValue)=\(String(describing: permissions.statuses[$0]))" }.joined(separator: ",")
        return "\(mode.rawValue)|\(selection.cameraID)|\(selection.microphoneID)|\(selection.displayID)|\(auth)"
    }

    private func stopIdlePreview(_ preview: CaptureEngine) async -> Bool {
        idlePreviewCleaning = true
        defer { idlePreviewCleaning = false }
        do {
            if let stop = idlePreviewStopForCheck { try await stop(preview) }
            else { try await preview.stop() }
            return true
        } catch {
            // Real cleanup failure blocks every replacement session. Normal
            // preview errors must never borrow or restore the recording busy flag.
            requiresRestart = true
            busy = true
            idlePreviewError = error.localizedDescription
            if !canStop {
                phase = "设备需要重启"
                detail = "预览设备未及时释放，请退出并重新打开"
            }
            return false
        }
    }

    private func failIdlePreview(_ message: String, configuration: String, token: Int) {
        guard token == previewGeneration, configuration == idlePreviewConfiguration,
              !busy, !canStop else { return }
        failedIdlePreviewConfiguration = configuration
        idlePreviewError = message
        idlePreviewLive = false
        clearPreviews()
        phase = "预览不可用"
        detail = message
    }

    private func recoverIdlePreview(token: Int) {
        guard token == previewGeneration, !busy, !canStop,
              phase == "预览不可用" || phase == "预览需要检查" else { return }
        phase = "准备就绪"
        detail = ""
    }

    @discardableResult
    func updateIdlePreview(enabled: Bool) -> Task<Void, Never> {
        if !busy, permissions.requesting == nil { permissions.refresh(for: mode) }
        let configuration = idlePreviewConfiguration
        let request = "\(enabled)|\(idlePreviewID)|\(configuration)"
        if request == lastIdlePreviewRequest, let existing = previewTransition { return existing }
        lastIdlePreviewRequest = request
        previewGeneration += 1
        let token = previewGeneration
        let previous = previewTransition
        let selectedMode = mode
        let selectedDevices = selection
        idlePreviewLive = false
        // Claim the old session synchronously. Even a superseded stop request
        // must await its own cleanup before recording/settings may acquire devices;
        // it must never later look up and stop a newer session instead.
        let retiring = idleEngine
        idleEngine = nil
        retiring?.setPreviewEnabled(false)
        if !canStop { clearPreviews() }
        let transition = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let retiring { guard await self.stopIdlePreview(retiring) else { return } }
            guard token == self.previewGeneration, configuration == self.idlePreviewConfiguration,
                  enabled, self.previewVisible, self.previewWindowVisible,
                  !self.busy, !self.requiresRestart, !self.settingsVisible, !self.permissions.visible,
                  self.permissions.requesting == nil else { return }
            guard self.permissions.ready(for: self.mode), self.failedIdlePreviewConfiguration != configuration else { return }
            guard await self.stopSettingsPreview(), !self.requiresRestart else { return }
            guard token == self.previewGeneration, configuration == self.idlePreviewConfiguration else { return }
            self.idlePreviewError = nil
            let preview = CaptureEngine()
            self.idleEngine = preview
            preview.onPreview = { [weak self, weak preview] name, sample, capturedAt in
                guard let self, let preview, self.idleEngine === preview,
                      token == self.previewGeneration, self.previewVisible, !self.busy else { return }
                self.idlePreviewLive = true
                self.recoverIdlePreview(token: token)
                let feed = name == "camera" ? self.cameraPreview : self.desktopPreview
                feed.frame = (sample, capturedAt)
            }
            preview.onFailure = { [weak self, weak preview] message in
                guard let self, let preview, self.idleEngine === preview, token == self.previewGeneration else { return }
                self.failIdlePreview(message, configuration: configuration, token: token)
                self.updateIdlePreview(enabled: false)
            }
            do {
                if let start = self.idlePreviewStartForCheck { try await start(preview, selectedMode, selectedDevices) }
                else { try await preview.startPreview(mode: selectedMode, selection: selectedDevices) }
                if token != self.previewGeneration { preview.setPreviewEnabled(false) }
                else { self.recoverIdlePreview(token: token) }
            } catch {
                self.failIdlePreview(error.localizedDescription, configuration: configuration, token: token)
                _ = await self.stopIdlePreview(preview)
                if self.idleEngine === preview { self.idleEngine = nil }
            }
        }
        previewTransition = transition
        return transition
    }

    static func checkIdlePreviewFailureRecovery() async throws {
        let suite = "zsir.preview-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = PermissionSetup(defaults: defaults, readStatus: { _ in .allowed })
        let model = CaptureModel(permissions: setup)
        model.mode = .desktop
        model.selection.displayID = UInt32.max
        var starts = 0
        let clean = RecordingCompletion()
        model.idlePreviewStartForCheck = { _, _, selection in
            starts += 1
            if selection.displayID == UInt32.max { throw RecordingError("所选显示器已断开，请重新选择") }
        }
        model.idlePreviewStopForCheck = { _ in
            await withCheckedContinuation { c in clean.observe { _ in c.resume() } }
        }
        let first = model.updateIdlePreview(enabled: true)
        for _ in 0..<1000 { if model.idlePreviewCleaning { break }; await Task.yield() }
        precondition(model.idlePreviewCleaning && !model.busy && !model.requiresRestart)
        precondition(model.detail.contains("显示器已断开") && model.phase == "预览不可用")
        precondition(!model.canOpenSettings)
        model.start()
        precondition(model.engine == nil)
        for _ in 0..<20 { model.updateIdlePreview(enabled: true) }
        clean.complete(.success(()))
        await first.value
        precondition(starts == 1 && !model.busy && !model.idlePreviewCleaning)
        // SwiftUI's busy-key change and app-activation callbacks must not retry
        // the same failed display, even after its cleanup has completed.
        model.busy = true; model.canStop = true; model.phase = "正在录制"
        await model.updateIdlePreview(enabled: true).value
        precondition(model.busy && model.canStop && model.phase == "正在录制" && starts == 1)
        model.canStop = false; model.busy = false; model.phase = "预览不可用"
        await model.updateIdlePreview(enabled: true).value
        for _ in 0..<20 { await model.updateIdlePreview(enabled: true).value }
        precondition(starts == 1 && model.selection.displayID == UInt32.max)
        // Explicitly selecting another source is a retry and restores normal UI.
        model.selection.displayID = 42
        await model.updateIdlePreview(enabled: true).value
        precondition(starts == 2 && model.idlePreviewError == nil && model.phase == "准备就绪" && model.detail.isEmpty)
        await model.updateIdlePreview(enabled: false).value
        // A failed old startup, released after a new request/recording state,
        // must finish its cleanup without resetting the new busy/phase values.
        let releaseOld = RecordingCompletion()
        var oldStarted = false
        model.selection.displayID = 43
        model.idlePreviewStartForCheck = { _, _, _ in
            oldStarted = true
            await withCheckedContinuation { c in releaseOld.observe { _ in c.resume() } }
            throw RecordingError("过期预览失败")
        }
        let old = model.updateIdlePreview(enabled: true)
        for _ in 0..<1000 { if oldStarted { break }; await Task.yield() }
        precondition(oldStarted)
        model.busy = true; model.canStop = true; model.phase = "正在录制"; model.detail = "录制保护"
        let stop = model.updateIdlePreview(enabled: false)
        releaseOld.complete(.success(()))
        await old.value; await stop.value
        precondition(model.busy && model.canStop && model.phase == "正在录制" && model.detail == "录制保护")
        precondition(!model.requiresRestart && model.idlePreviewError == nil)
        model.busy = false; model.canStop = false; model.selection.displayID = 44
        model.idlePreviewStartForCheck = { _, _, _ in starts += 1 }
        await model.updateIdlePreview(enabled: true).value
        let retirement = RecordingCompletion()
        model.idlePreviewStopForCheck = { _ in
            await withCheckedContinuation { c in retirement.observe { _ in c.resume() } }
        }
        model.busy = true
        let recordingBarrier = model.updateIdlePreview(enabled: false)
        let redundantTask = model.updateIdlePreview(enabled: true) // .task responds to busy.
        let barrierDone = RecordingCompletion()
        Task { await recordingBarrier.value; barrierDone.complete(.success(())) }
        for _ in 0..<1000 { if model.idlePreviewCleaning { break }; await Task.yield() }
        precondition(model.idlePreviewCleaning && !barrierDone.isCompleted)
        retirement.complete(.success(()))
        await recordingBarrier.value; await redundantTask.value
        precondition(model.busy && model.idleEngine == nil)
        print("PASS: failed display stays latched across activation/busy changes; explicit reselection retries; cleanup blocks new capture/settings; stale failure cannot overwrite recording state")
    }

    private func clearPreviews() {
        cameraPreview.frame = nil
        desktopPreview.frame = nil
    }

    func togglePreview() {
        previewVisible.toggle()
        if previewVisible {
            failedIdlePreviewConfiguration = nil // Explicit user retry, not app activation.
            lastIdlePreviewRequest = nil
        }
        engine?.setPreviewEnabled(previewVisible && previewWindowVisible)
        if !previewVisible { clearPreviews() }
    }

    convenience init() { self.init(permissions: PermissionSetup()) }

    init(permissions: PermissionSetup) {
        self.permissions = permissions
        let defaults = permissions.defaults
        let existingSettings = ["recordingQuality", "recordingMode", "systemAudio", "autoRecovery", "cameraID", "microphoneID", "displayUUID", "outputDirectory", "permissionSetupStep", "permissionSetupCompleted"]
            .contains { defaults.object(forKey: $0) != nil }
        profile = RecordingProfile(rawValue: defaults.string(forKey: "recordingProfile") ?? "") ?? (existingSettings ? .native : .balanced)
        quality = RecordingQuality(rawValue: permissions.defaults.string(forKey: "recordingQuality") ?? "") ?? .standard
        systemAudio = RecordingCapabilities.systemAudio && (permissions.defaults.object(forKey: "systemAudio") as? Bool ?? true)
        autoRecovery = permissions.defaults.bool(forKey: "autoRecovery")
        selection = DeviceSelection(cameraID: permissions.defaults.string(forKey: "cameraID") ?? "", microphoneID: permissions.defaults.string(forKey: "microphoneID") ?? "")
        mode = RecordingMode(rawValue: permissions.defaults.string(forKey: "recordingMode") ?? "") ?? .both
        if let saved = permissions.defaults.string(forKey: "outputDirectory"), !saved.isEmpty {
            root = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            root = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZSir Recordings", isDirectory: true)
        }
        defaults.set(profile.rawValue, forKey: "recordingProfile")
    }

    func observeDevices() {
        guard deviceObservers.isEmpty else { return }
        for name in [NSApplication.didChangeScreenParametersNotification, NSNotification.Name.AVCaptureDeviceWasConnected, NSNotification.Name.AVCaptureDeviceWasDisconnected] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDevices() }
            })
        }
        refreshDevices()
    }

    func recoverAutomaticallyIfNeeded() {
        guard autoRecovery, !autoRecoveryAttempted, !busy else { return }
        autoRecoveryAttempted = true
        scanRecovery()
        let candidates = recoverable
        guard !candidates.isEmpty else { return }
        busy = true; phase = "正在恢复素材…"
        Task {
            for candidate in candidates {
                do {
                    let result = try await RecordingRecovery.recover(candidate)
                    lastTake = result.outputFolder
                    if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
                } catch { self.error = error.localizedDescription }
            }
            busy = false; phase = "恢复检查完成"; detail = "原素材保留，请检查恢复副本"; scanRecovery()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择素材目录"
        if panel.runModal() == .OK, let url = panel.url { root = url; scanRecovery() }
    }

    var canOpenSettings: Bool {
        !busy && !canStop && !requiresRestart && !idlePreviewCleaning && settingsStopTask == nil &&
            permissions.requesting == nil && !permissions.visible
    }

    func openSettings() {
        guard canOpenSettings else { return }
        refreshDevices()
        scanRecovery()
        settingsVisible = true
    }

    func start() {
        guard !busy, !requiresRestart, !idlePreviewCleaning, !settingsVisible, !permissions.visible, permissions.requesting == nil else { return }
        permissions.refresh(for: mode)
        guard permissions.ready(for: mode) else {
            permissions.present(for: mode, busy: busy)
            return
        }
        refreshDevices()
        if mode.includesDesktop && !displays.contains(where: { $0.id == String(selection.displayID) }) {
            error = "所选屏幕已断开，请在录制设置中重新选择"; return
        }
        if mode.includesCamera && ((!selection.cameraID.isEmpty && !cameras.contains(where: { $0.id == selection.cameraID })) || (!selection.microphoneID.isEmpty && !microphones.contains(where: { $0.id == selection.microphoneID }))) {
            error = "所选摄像头或麦克风已断开，请重新选择"; return
        }
        generation += 1
        let currentGeneration = generation
        clearPreviews()
        recordedSeconds = 0
        busy = true
        let idleStopped = updateIdlePreview(enabled: false)
        phase = "准备设备…"
        detail = "正在准备所选机位，请按提示授权"
        error = nil
        let recorder = CaptureEngine()
        engine = recorder
        recorder.setPreviewEnabled(previewVisible && previewWindowVisible)
        recorder.onPreview = { [weak self] name, sample, capturedAt in
            guard let self, self.generation == currentGeneration, self.canStop, self.previewVisible, self.previewWindowVisible else { return }
            let feed = name == "camera" ? self.cameraPreview : self.desktopPreview
            feed.frame = (sample, capturedAt)
        }
        recorder.onUpdate = { [weak self] status, ready, seconds in
            guard let self, self.generation == currentGeneration, self.canStop else { return }
            self.phase = ready ? "正在录制" : "等待录制数据…"
            self.detail = status
            self.recordedSeconds = seconds
        }
        recorder.onFailure = { [weak self] message in
            guard let self, self.generation == currentGeneration else { return }
            self.error = message
            self.stop()
        }
        Task {
            var attemptedStart = false
            do {
                await idleStopped.value
                guard !requiresRestart else { throw RecordingError("预览设备未能及时释放，请退出并重新打开") }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                guard await stopSettingsPreview(), !requiresRestart else {
                    throw RecordingError("设置预览未能及时释放，请退出并重新打开")
                }
                attemptedStart = true
                lastTake = try await recorder.start(in: root, mode: mode, selection: selection, quality: quality, systemAudio: systemAudio, profile: profile)
                canStop = true
                if self.error != nil { stop(); return }
                phase = "等待录制数据…"
                detail = mode.includesDesktop && systemAudio ? "请播放系统声音，确认声音已采集" : (mode.includesCamera ? "请对话筒讲话，确认声音已采集" : "桌面仅录画面，不含声音")
            } catch {
                phase = "未能开始"
                detail = "检查权限与设备后重试"
                self.error = error.localizedDescription
                if attemptedStart {
                    requiresRestart = true
                    detail = "启动失败；如设备仍在清理，请退出并重新打开"
                    await recorder.waitForCleanup()
                    requiresRestart = false
                }
                busy = requiresRestart
                engine = nil
            }
        }
    }

    func stop() {
        guard canStop, let recorder = engine else { return }
        canStop = false
        phase = "正在保存…"
        detail = "请勿退出或拔出磁盘"
        Task {
            do {
                try await recorder.stop()
                phase = self.error == nil ? "录制已保存" : "素材需要检查"
                detail = self.error == nil ? "已保存到本机 · 请检查音画后交付" : "录制曾发生异常，现有素材已保留"
            } catch {
                phase = "素材需要检查"
                detail = "已保留现有文件与检查报告"
                self.error = error.localizedDescription
                requiresRestart = true
                detail = "素材已保留；设备仍在清理时可退出，重开后恢复副本"
            }
            // The UI leaves “saving” at the deadline, while device ownership stays
            // busy until cleanup really finishes; never open a second capture session.
            await recorder.waitForCleanup()
            requiresRestart = false
            engine = nil
            busy = false
        }
    }

    func reveal() {
        do {
            if lastTake == nil { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            if !NSWorkspace.shared.open(lastTake ?? root) { error = "无法打开素材目录，请检查磁盘是否已连接。" }
        } catch { self.error = error.localizedDescription }
    }
}

/// Keep native focus/sheet support while enforcing the content-owned chrome
/// after AppKit recreates or re-enables titlebar controls during its lifecycle.
@MainActor
final class CaptureWindow: NSWindow {
    func hideNativeButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = standardWindowButton(kind) {
                if button.isEnabled { button.isEnabled = false }
                if !button.isHidden { button.isHidden = true }
            }
        }
    }
    override func update() { super.update(); hideNativeButtons() }
    override func becomeKey() { super.becomeKey(); hideNativeButtons() }
    override func becomeMain() { super.becomeMain(); hideNativeButtons() }
    override func endSheet(_ sheetWindow: NSWindow) {
        super.endSheet(sheetWindow)
        hideNativeButtons()
    }
    override func endSheet(_ sheetWindow: NSWindow, returnCode: NSApplication.ModalResponse) {
        super.endSheet(sheetWindow, returnCode: returnCode)
        hideNativeButtons()
    }
}

@MainActor
private final class CaptureHostingView: NSHostingView<CaptureView> {
    override func layout() {
        super.layout()
        (window as? CaptureWindow)?.hideNativeButtons()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CaptureModel()
    var window: NSWindow?
    var edgeController: RecordingEdgeController?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出庄Sir采访录制助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        let panel = CaptureWindow(contentRect: NSRect(x: 0, y: 0, width: 336, height: 300),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = RecordingCapabilities.applicationName
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = CaptureHostingView(rootView: CaptureView(model: model))
        if #available(macOS 13, *) { hosting.sizingOptions = [] }
        panel.contentView = hosting
        panel.hideNativeButtons()
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 16))
        }
        panel.makeKeyAndOrderFront(nil)
        window = panel
        model.onResize = { [weak panel] contentHeight in
            guard let panel else { return }
            var frame = panel.frame
            let height = ceil(contentHeight)
            guard abs(frame.height - height) > 0.5 else { return }
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
        edgeController = RecordingEdgeController(model: model, window: panel)
        model.observeDevices()
        model.recoverAutomaticallyIfNeeded()
        model.updates.busy = { [weak model] in model?.busy != false }
        model.updates.start()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window, !self.model.permissions.visible, !self.model.settingsVisible else { return }
                self.model.updates.promptIfNeeded(window: window)
            }
        }
        if CommandLine.arguments.contains("--show-settings") { model.openSettings() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        edgeController?.reveal(activate: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.requiresRestart {
            let alert = NSAlert()
            alert.messageText = "退出并保留待检查素材？"
            alert.informativeText = "设备或编码器未及时结束。退出会中断残余清理；重新打开后可恢复已落盘片段的副本。原素材保留。"
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "继续等待")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        if model.busy {
            let alert = NSAlert()
            alert.messageText = model.canStop ? "请先停止录制并等待保存完成" : "正在处理素材，请等待完成后退出"
            alert.informativeText = "保存完成后可以通过 ⌘Q 退出。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main
enum CaptureApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--check-preview-recovery") {
            Task { do { try await CaptureModel.checkIdlePreviewFailureRecovery(); exit(0) } catch { print("FAIL preview recovery: \(error)"); exit(1) } }
            app.run(); return
        }
        if CommandLine.arguments.contains("--check-lifecycle") {
            Task { do { try await CaptureEngine.checkPreparationStopRaces(); try await CaptureModel.checkSettingsPreviewDeadline(); try await CaptureEngine.checkBoundedPreviewStartup(); try await CaptureEngine.checkBoundedStop(); exit(0) } catch { print("FAIL lifecycle: \(error)"); exit(1) } }
            app.run(); return
        }
        if CommandLine.arguments.contains("--check-updates") {
            Task { do { try await UpdateChecks.run(); exit(0) } catch { print("FAIL updates: \(error)"); exit(1) } }
            app.run(); return
        }
        if CommandLine.arguments.contains("--check-recording-ui") { RecordingPresentationChecks.run(); return }
        if CommandLine.arguments.contains("--check-permissions") {
            Task { await PermissionSetupChecks.run(); exit(0) }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
