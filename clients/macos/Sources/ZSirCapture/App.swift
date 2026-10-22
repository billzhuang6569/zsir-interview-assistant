import AppKit
import SwiftUI
import RecordingCore
import AVFoundation

@MainActor
final class CaptureModel: ObservableObject {
    @Published var phase = "准备就绪"
    @Published var detail = ""
    @Published var busy = false
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

    private func clearPreviews() {
        cameraPreview.frame = nil
        desktopPreview.frame = nil
    }

    func togglePreview() {
        previewVisible.toggle()
        engine?.setPreviewEnabled(previewVisible)
    }

    convenience init() { self.init(permissions: PermissionSetup()) }

    init(permissions: PermissionSetup) {
        self.permissions = permissions
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
    }

    func observeDevices() {
        guard deviceObservers.isEmpty else { return }
        for name in [NSApplication.didChangeScreenParametersNotification, AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
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

    func start() {
        guard !busy, !settingsVisible, !permissions.visible, permissions.requesting == nil else { return }
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
        phase = "准备设备…"
        detail = "正在准备所选机位，请按提示授权"
        error = nil
        let recorder = CaptureEngine()
        engine = recorder
        recorder.setPreviewEnabled(previewVisible)
        recorder.onPreview = { [weak self] name, sample, capturedAt in
            guard let self, self.generation == currentGeneration, self.canStop, self.previewVisible else { return }
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
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                await settingsPreview.stop()
                lastTake = try await recorder.start(in: root, mode: mode, selection: selection, quality: quality, systemAudio: systemAudio)
                canStop = true
                if self.error != nil { stop(); return }
                phase = "等待录制数据…"
                detail = mode.includesDesktop && systemAudio ? "请播放系统声音，确认声音已采集" : (mode.includesCamera ? "请对话筒讲话，确认声音已采集" : "桌面仅录画面，不含声音")
            } catch {
                phase = "未能开始"
                detail = "检查权限与设备后重试"
                self.error = error.localizedDescription
                busy = false
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
            }
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
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 336, height: 300),
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
        let hosting = NSHostingView(rootView: CaptureView(model: model))
        if #available(macOS 13, *) { hosting.sizingOptions = [] }
        panel.contentView = hosting
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
            Task { @MainActor in
                guard let self, let window = self.window, !self.model.permissions.visible, !self.model.settingsVisible else { return }
                self.model.updates.promptIfNeeded(window: window)
            }
        }
        if CommandLine.arguments.contains("--show-settings") { model.settingsVisible = true }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        edgeController?.reveal(activate: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
