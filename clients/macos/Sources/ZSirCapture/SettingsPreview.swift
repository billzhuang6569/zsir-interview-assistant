import AppKit
import AVFoundation
import ScreenCaptureKit
import RecordingCore

// This session has no writer and never creates a Take. All session work is serialized.
final class SettingsCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "zsir.settings.camera")
    private let session = AVCaptureSession()
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onLevel: ((Double) -> Void)?
    private var lastFrame = Date.distantPast
    private var lastLevel = Date.distantPast
    func start(_ selection: DeviceSelection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.stopRunning()
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    for input in session.inputs { session.removeInput(input) }
                    for output in session.outputs { session.removeOutput(output) }
                    session.sessionPreset = .medium
                    guard let camera = selection.cameraID.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: selection.cameraID),
                          let mic = selection.microphoneID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: selection.microphoneID) else { throw RecordingError("所选摄像头或麦克风已断开") }
                    for device in [camera, mic] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw RecordingError("设备无法用于预览") }
                        session.addInput(input)
                    }
                    let video = AVCaptureVideoDataOutput(); video.alwaysDiscardsLateVideoFrames = true
                    video.setSampleBufferDelegate(self, queue: queue)
                    let audio = AVCaptureAudioDataOutput(); audio.setSampleBufferDelegate(self, queue: queue)
                    guard session.canAddOutput(video), session.canAddOutput(audio) else { throw RecordingError("无法创建设置预览") }
                    session.addOutput(video); session.addOutput(audio)
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
        await withCheckedContinuation { c in queue.async { [self] in session.startRunning(); c.resume() } }
    }
    func blockOwnerForCheck(until signal: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(); signal.wait() }
        }
    }
    func stop() async {
        await withCheckedContinuation { c in queue.async { [self] in session.stopRunning(); c.resume() } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard Date().timeIntervalSince(lastFrame) >= 0.1, let frame = LivePreviewSample.make(from: sample) else { return }
            lastFrame = Date(); onFrame?(frame)
        } else {
            guard Date().timeIntervalSince(lastLevel) >= 0.1 else { return }
            lastLevel = Date()
            let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
            onLevel?(min(1, max(0, pow(10, Double(db) / 20))))
        }
    }
}

@MainActor
final class SettingsPreview: ObservableObject {
    let feed = LivePreviewFeed()
    @Published var level = 0.0
    @Published var cameraError: String?
    @Published var screenError: String?
    @Published var thumbnails: [UInt32: NSImage] = [:]
    @Published var sizes: [UInt32: CGSize] = [:]
    private var camera: SettingsCamera?
    private var generation = 0
    private var legacyPreview: Task<CGImage, Error>?
    func installCameraForCheck(_ device: SettingsCamera) { camera = device }
    func invalidate() {
        generation += 1
        feed.frame = nil; level = 0; thumbnails = [:]; sizes = [:]
    }
    func stop() async {
        invalidate()
        let old = camera; camera = nil
        let oldPreview = legacyPreview; legacyPreview = nil
        oldPreview?.cancel()
        feed.frame = nil; level = 0; thumbnails = [:]; sizes = [:]
        await old?.stop()
        _ = try? await oldPreview?.value
    }
    func refresh(selection: DeviceSelection, mode: RecordingMode) async {
        await stop()
        guard !Task.isCancelled else { return }
        let token = generation
        cameraError = nil; screenError = nil
        if mode.includesCamera && CapturePermission.status(.camera) == .allowed && CapturePermission.status(.microphone) == .allowed {
            let device = SettingsCamera(); camera = device
            device.onFrame = { [weak self] frame in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.feed.frame = (frame, Date())
            } }
            device.onLevel = { [weak self] value in Task { @MainActor in
                guard let self, self.generation == token else { return }; self.level = value
            } }
            do {
                try await device.start(selection)
                if generation != token || Task.isCancelled { await device.stop(); return }
            }
            catch { if generation == token { cameraError = error.localizedDescription }; await device.stop() }
        }
        guard generation == token, !Task.isCancelled, mode.includesDesktop, CapturePermission.status(.screen) == .allowed else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            for display in content.displays {
                guard generation == token, !Task.isCancelled else { return }
                let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                guard !own.isEmpty else { throw RecordingError("无法排除本工具窗口，已取消预览") }
                let size = try DisplayCaptureCompatibility.pixelSize(display: display, filter: filter)
                let config = SCStreamConfiguration()
                config.width = 360; config.height = max(2, Int(360 * size.height / max(1, size.width)))
                if #available(macOS 13, *) { config.capturesAudio = false }
                config.showsCursor = false
                let image: CGImage
                if #available(macOS 14, *), !RecordingCapabilities.macOS12Edition {
                    image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else {
                    let task = Task { try await LegacyScreenThumbnail().capture(filter: filter, configuration: config) }
                    legacyPreview = task
                    image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    if generation == token { legacyPreview = nil }
                }
                guard generation == token, !Task.isCancelled else { return }
                sizes[display.displayID] = size
                thumbnails[display.displayID] = NSImage(cgImage: image, size: .zero)
            }
        } catch { if generation == token { screenError = "屏幕预览不可用：\(error.localizedDescription)" } }
    }
}
