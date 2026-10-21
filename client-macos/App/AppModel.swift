import AppKit
import AVFoundation

struct Device: Identifiable {
    let id: String
    let name: String
}

final class AppModel: ObservableObject {
    let defaults: UserDefaults
    let recorder: URL
    let preview = Preview()
    @Published var camera: String { didSet { changed("camera", camera) } }
    @Published var mic: String { didSet { changed("mic", mic) } }
    @Published var display: String { didSet { changed("display", display) } }
    @Published var output: String { didSet { changed("output", output) } }
    @Published var quality: String { didSet { changed("quality", quality) } }
    @Published var scope: String { didSet { changed("scope", scope) } }
    @Published var cameras: [Device] = []
    @Published var mics: [Device] = []
    @Published var displays: [Device] = []
    @Published var phase = "ready"
    @Published var countdown = 3
    @Published var elapsed = 0.0
    @Published var tracks: [String: [String: Any]] = [:]
    @Published var levels: [String: Double] = [:]
    @Published var disk: Int64 = 0
    @Published var message = ""
    @Published var warning = ""
    @Published var saved: URL?
    @Published var permissions: [Bool] = [false, false, false]
    @Published var step = 1
    @Published var checking = false
    @Published var preflight: [String: Any]?
    @Published var outputWritable: Bool?
    @Published var checkErrors: [String] = []
    @Published var setupVisible = false
    @Published var settings = false
    var capture: RecorderBridge?
    private var query: RecorderBridge?
    private var check: RecorderBridge?
    private var timer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var sessionURL: URL?
    private var recoveryPID: Int32?
    var presentSetup: (() -> Void)?
    var presentFloat: (() -> Void)?
    var finishSetup: (() -> Void)?

    init(defaults: UserDefaults = .standard, recorder: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/recorder")) {
        self.defaults = defaults; self.recorder = recorder
        camera = defaults.string(forKey: "camera") ?? ""
        mic = defaults.string(forKey: "mic") ?? ""
        display = defaults.string(forKey: "display") ?? ""
        output = defaults.string(forKey: "output") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/庄Sir采访").path
        quality = defaults.string(forKey: "quality") ?? "recommended"
        scope = defaults.string(forKey: "scope") ?? "cam,screen"
    }
    var busy: Bool { phase == "countdown" || phase == "starting" || phase == "recording" || phase == "stopping" || phase == "recovering" }
    var preflightOK: Bool { preflight != nil && checkErrors.isEmpty && !checking }
    var title: String {
        switch phase {
        case "countdown": return "即将开始录制"
        case "starting": return "正在启动录制"
        case "recording": return "录制中"
        case "stopping": return "正在保存文件"
        case "recovering": return "后台录制收尾中"
        case "error": return "录制出错"
        default: return warning.isEmpty ? "就绪 · 本地使用" : "⚠ 请检查"
        }
    }
    func changed(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
        preflight = nil; checkErrors = []; outputWritable = nil
        if setupVisible && (step == 3 || settings) && ["camera", "mic", "display"].contains(key) { updatePreview() }
    }
    func activate() {
        refresh()
        recover()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        loadDevices()
    }
    func refresh() {
        permissions = [AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                       AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, CGPreflightScreenCaptureAccess()]
        var path = URL(fileURLWithPath: output)
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" { path.deleteLastPathComponent() }
        disk = (try? FileManager.default.attributesOfFileSystem(forPath: path.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        warning = disk < 10_000_000_000 ? "磁盘剩余不足 10 GB" : ""
        if phase == "recovering" { pollRecovery() }
    }
    func requestPermission(_ index: Int) {
        if index == 2 { _ = CGRequestScreenCaptureAccess(); refresh() }
        else { AVCaptureDevice.requestAccess(for: index == 0 ? .video : .audio) { _ in DispatchQueue.main.async { self.refresh() } } }
    }
    func openPermission(_ index: Int) {
        let pane = ["Camera", "Microphone", "ScreenCapture"][index]
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }
    var deviceArguments: [String] {
        [("--camera", camera), ("--mic", mic), ("--display", display)].flatMap { $0.1.isEmpty ? [] : [$0.0, $0.1] }
    }
    func loadDevices() {
        guard query == nil else { return }
        let bridge = RecorderBridge(); query = bridge
        do {
            try bridge.start(executable: recorder, arguments: ["devices", "--json"], logURL: nil, event: { [weak self] value in
                guard let self else { return }
                func devices(_ key: String) -> [Device] { (value[key] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }; return Device(id: id, name: name)
                } }
                cameras = devices("cameras"); mics = devices("mics"); displays = devices("displays")
                if camera.isEmpty {
                    let external = cameras.first { AVCaptureDevice(uniqueID: $0.id)?.deviceType != .builtInWideAngleCamera }
                    camera = external?.id ?? cameras.first?.id ?? ""
                }
                if mic.isEmpty { mic = mics.first?.id ?? "" }
                if display.isEmpty, displays.count == 1 { display = displays[0].id }
            }, completion: { [weak self] code, error in
                self?.query = nil
                if code != 0 || error != nil { self?.message = "无法读取设备，请关闭并重新打开应用。" }
            })
        } catch { query = nil; message = error.localizedDescription }
    }
    func updatePreview() { preview.update(enabled: setupVisible && (settings || step == 3) && !busy && !checking, camera: camera, mic: mic, display: display) }
    func go(_ step: Int) { self.step = step; updatePreview(); if step == 3 { loadDevices() }; if step == 4 { runPreflight() } }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: output)
        if panel.runModal() == .OK, let url = panel.url { output = url.path; refresh() }
    }
    func checkOutput() throws {
        outputWritable = false
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".write-check-\(UUID().uuidString)")
        try Data("write check".utf8).write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
        refresh()
        if disk < 2_000_000_000 { throw NSError(domain: "Disk", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁盘空间不足 2 GB，请更换输出目录。"] ) }
        outputWritable = true
    }
    func runPreflight() {
        guard !checking && !busy else { return }
        checking = true; preflight = nil; checkErrors = []
        Task { @MainActor in
            await preview.update(enabled: false).value
            do {
                try checkOutput()
                let bridge = RecorderBridge(); check = bridge
                try bridge.start(executable: recorder, arguments: ["preflight", "--json"] + deviceArguments, logURL: nil, event: { [weak self] value in
                    self?.preflight = value; self?.checkErrors = value["errors"] as? [String] ?? []
                }, completion: { [weak self] code, error in
                    guard let self else { return }
                    checking = false; check = nil
                    if let error { checkErrors.append(error) }
                    if code != 0 && checkErrors.isEmpty { checkErrors.append("自检未完成，请重新自检。") }
                    if preflight == nil && checkErrors.isEmpty { checkErrors.append("自检未返回结果，请重试。") }
                })
            } catch { checking = false; check = nil; checkErrors = [error.localizedDescription] }
        }
    }
    func start() {
        guard !busy && !checking else { return }
        guard defaults.bool(forKey: "onboarded") else { settings = false; presentSetup?(); return }
        saved = nil; message = ""; tracks = [:]; levels = [:]; elapsed = 0
        if (scope.contains("cam") && (!permissions[0] || !permissions[1])) || (scope.contains("screen") && !permissions[2]) {
            phase = "error"; message = "请打开设置，允许所选录制范围需要的系统权限。"; return
        }
        if scope.contains("screen") && displays.count > 1 && display.isEmpty { phase = "error"; message = "请在设置里选择要录制的显示器。"; return }
        finishSetup?()
        phase = "countdown"; countdown = 3; presentFloat?()
        countdownTask = Task { @MainActor in
            await preview.update(enabled: false).value
            do {
                for number in stride(from: 3, through: 1, by: -1) {
                    countdown = number
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try checkOutput()
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
                let directory = URL(fileURLWithPath: output).appendingPathComponent(formatter.string(from: Date()))
                // Exclusive mkdir: never reuse a recording directory, even within the same second.
                guard mkdir(directory.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                sessionURL = directory
                defaults.set(directory.path, forKey: "activeSession")
                defaults.synchronize()
                phase = "starting"
                let bridge = RecorderBridge(); capture = bridge
                try bridge.start(executable: recorder, arguments: ["capture", "--stdin-control", "--out", directory.path, "--tracks", scope, "--quality", quality] + deviceArguments,
                    logURL: directory.appendingPathComponent("log.txt"), event: { [weak self] value in self?.receive(value) },
                    completion: { [weak self] code, error in self?.completed(code, error) })
                defaults.set(bridge.pid, forKey: "activePID"); defaults.synchronize()
            } catch is CancellationError { phase = "ready" }
            catch { capture = nil; phase = "error"; message = "无法开始录制：\(error.localizedDescription)"; clearActive() }
        }
    }
    func receive(_ value: [String: Any]) {
        if let errors = value["errors"] as? [String] { message = errors.map(Self.advice).joined(separator: "\n") }
        if let t = value["t"] as? Double {
            elapsed = t; tracks = value["tracks"] as? [String: [String: Any]] ?? [:]; levels = value["levels"] as? [String: Double] ?? [:]
            if phase == "starting" { phase = "recording" }
        }
    }
    func stop() {
        if phase == "countdown" { countdownTask?.cancel(); return }
        guard phase == "recording" || phase == "starting" else { return }
        let alert = NSAlert(); alert.messageText = "停止本次录制？"; alert.informativeText = "两路文件会保存在您的电脑上，请等待保存完成。"
        alert.addButton(withTitle: "停止并保存"); alert.addButton(withTitle: "继续录制")
        guard alert.runModal() == .alertFirstButtonReturn, capture != nil else { return }
        do { try capture?.stop(); phase = "stopping" }
        catch { message = "停止指令未送达，请等待录制器状态更新。" }
    }
    func completed(_ code: Int32, _ error: String?) {
        capture = nil
        if code != 0 || error != nil {
            phase = "error"; message = "RECORDER_CRASHED · \(message.isEmpty ? "录制意外停止，请检查输出文件后重新自检。" : message)"
        } else {
            phase = "ready"; saved = sessionURL; message = "已保存到 \(sessionURL?.path ?? output)"
        }
        clearActive()
    }
    private func clearActive() { defaults.removeObject(forKey: "activePID"); defaults.removeObject(forKey: "activeSession"); defaults.synchronize() }
    func recover() {
        guard let path = defaults.string(forKey: "activeSession") else { return }
        sessionURL = URL(fileURLWithPath: path)
        recoveryPID = Int32(defaults.integer(forKey: "activePID"))
        phase = "recovering"; message = "检测到上次应用退出。录制器会在断开后 60 秒自动保存，请稍候。"
        pollRecovery()
    }
    private func pollRecovery() {
        guard let sessionURL else { return }
        let state = (try? Data(contentsOf: sessionURL.appendingPathComponent("session.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let state { receive(state) }
        if state?["state"] as? String == "finished" { phase = "ready"; saved = sessionURL; message = "上次录制已保存到 \(sessionURL.path)"; clearActive(); return }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let alive = recoveryPID.map { $0 > 0 && proc_pidpath($0, &path, UInt32(path.count)) > 0 && URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath() == recorder.resolvingSymlinksInPath() } ?? false
        if !alive {
            phase = "error"; message = "上次录制未正常结束，请打开输出目录检查文件后重新自检。"; saved = sessionURL; clearActive()
        }
    }
    func openSaved() { NSWorkspace.shared.open(saved ?? sessionURL ?? URL(fileURLWithPath: output)) }
    static func advice(_ error: String) -> String {
        if error.contains("PERMISSION") { return "请在系统设置 → 隐私与安全性中允许摄像头、麦克风和屏幕录制，再重新自检。" }
        if error.contains("CAMERA") || error.contains("TIMEOUT") { return "摄像头未就绪，请关闭会议软件的摄像头或改选设备，再重试。" }
        if error.contains("MIC") { return "话筒未收到声音，请检查连接、取消静音并重新选择话筒。" }
        if error.contains("SYSTEM_AUDIO") { return "请在电脑上播放声音，然后重新自检系统声。" }
        if error.contains("ENCODER") { return "硬件编码器不可用，请关闭其他录屏软件后重试。" }
        if error.contains("DISK") { return "磁盘空间不足，请更换输出目录后重试。" }
        return error
    }
}
