import AppKit
import AVFoundation
import RecordingCore

// Permission checks never create a capture session or a Take.
enum CapturePermission: String, CaseIterable, Identifiable {
    case camera, microphone, screen
    var id: String { rawValue }
    var title: String {
        switch self { case .camera: return "摄像头"; case .microphone: return "话筒"; case .screen: return RecordingCapabilities.systemAudio ? "屏幕与系统声音" : "屏幕录制" }
    }
    var purpose: String {
        switch self {
        case .camera: return "将你的人物画面保存为摄像头素材。"
        case .microphone: return "将你的声音录入摄像头素材。"
        case .screen: return RecordingCapabilities.systemAudio ? "保存所选显示器画面及电脑播放的声音。" : "仅保存所选显示器画面，不录系统播放声音。"
        }
    }
    var settingsPane: String {
        switch self { case .camera: return "Privacy_Camera"; case .microphone: return "Privacy_Microphone"; case .screen: return "Privacy_ScreenCapture" }
    }
    static func required(for mode: RecordingMode) -> [Self] {
        (mode.includesCamera ? [.camera, .microphone] : []) + (mode.includesDesktop ? [.screen] : [])
    }
    static func status(_ permission: Self) -> PermissionStatus {
        if permission == .screen { return CGPreflightScreenCaptureAccess() ? .allowed : .unconfirmed }
        return PermissionStatus(AVCaptureDevice.authorizationStatus(for: permission == .camera ? .video : .audio))
    }
    static func request(_ permission: Self) async {
        if permission == .screen { _ = CGRequestScreenCaptureAccess() }
        else { _ = await AVCaptureDevice.requestAccess(for: permission == .camera ? .video : .audio) }
    }
}

enum PermissionStatus: Equatable {
    case notDetermined, allowed, denied, restricted, unconfirmed
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .allowed
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unconfirmed
        }
    }
    var title: String {
        switch self {
        case .notDetermined: return "尚未设置"
        case .allowed: return "已允许"
        case .denied: return "未允许，请前往系统设置"
        case .restricted: return "系统限制，请联系设备管理员"
        case .unconfirmed: return "尚未确认授权"
        }
    }
}

@MainActor
final class PermissionSetup: ObservableObject {
    @Published var visible = false
    @Published var step: Int {
        didSet { defaults.set(step, forKey: "permissionSetupStep") }
    }
    @Published private(set) var statuses: [CapturePermission: PermissionStatus] = [:]
    @Published private(set) var requesting: CapturePermission?
    @Published var settingsError: String?
    let defaults: UserDefaults
    private let readStatus: (CapturePermission) -> PermissionStatus
    private let requestAccess: (CapturePermission) async -> Void

    init(defaults: UserDefaults = .standard,
         readStatus: @escaping (CapturePermission) -> PermissionStatus = CapturePermission.status,
         requestAccess: @escaping (CapturePermission) async -> Void = CapturePermission.request) {
        self.defaults = defaults
        self.readStatus = readStatus
        self.requestAccess = requestAccess
        step = min(2, max(0, defaults.integer(forKey: "permissionSetupStep")))
    }
    var completed: Bool { defaults.bool(forKey: "permissionSetupCompleted") }
    func ready(for mode: RecordingMode) -> Bool {
        CapturePermission.required(for: mode).allSatisfy { statuses[$0] == .allowed }
    }
    func refresh(for mode: RecordingMode) {
        statuses = Dictionary(uniqueKeysWithValues: CapturePermission.required(for: mode).map { ($0, readStatus($0)) })
        if step == 2 && !ready(for: mode) { step = 1 }
    }
    func present(for mode: RecordingMode, busy: Bool, firstLaunch: Bool = false) {
        guard !busy, requesting == nil, !firstLaunch || !completed else { return }
        refresh(for: mode)
        if !firstLaunch { step = 1 }
        visible = true
    }
    func finish(for mode: RecordingMode) {
        guard requesting == nil else { return }
        refresh(for: mode)
        guard ready(for: mode) else { return }
        defaults.set(true, forKey: "permissionSetupCompleted")
        step = 0
        visible = false
    }
    func request(_ permission: CapturePermission, for mode: RecordingMode) async {
        guard visible, requesting == nil, CapturePermission.required(for: mode).contains(permission) else { return }
        let status = readStatus(permission)
        guard status == .notDetermined || (permission == .screen && status == .unconfirmed) else {
            refresh(for: mode)
            return
        }
        requesting = permission
        await requestAccess(permission)
        requesting = nil
        refresh(for: mode)
    }
    func openSettings(for permission: CapturePermission) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsPane)")!
        settingsError = NSWorkspace.shared.open(url) ? nil : "未能打开系统设置，请按下方路径手动打开。"
        if permission == .screen && settingsError == nil { PermissionGuide.shared.show() }
    }
}
