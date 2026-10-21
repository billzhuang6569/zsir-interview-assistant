import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreImage

final class Preview: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate {
    @Published var cameraImage: NSImage?
    @Published var screenImage: NSImage?
    @Published var level = -120.0
    @Published var error = ""
    private var session: AVCaptureSession?
    private var stream: SCStream?
    private var change: Task<Void, Never>?
    private var generation = 0
    private let context = CIContext()
    private var lastCamera = Date.distantPast
    private var lastScreen = Date.distantPast

    // Serialize device changes and teardown, including changes during SCStream startup.
    @discardableResult
    func update(enabled: Bool, camera: String = "", mic: String = "", display: String = "") -> Task<Void, Never> {
        generation += 1
        let token = generation
        let previous = change
        let task = Task { @MainActor in
            await previous?.value
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if let session {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { session.stopRunning(); continuation.resume() }
                }
            }
            session = nil; level = -120
            guard token == generation else { return }
            error = ""
            guard enabled else { return }
            cameraImage = nil; screenImage = nil
            do {
                let session = AVCaptureSession()
                session.sessionPreset = .medium
                self.session = session
                for (id, type) in [(camera, AVMediaType.video), (mic, .audio)] {
                    guard AVCaptureDevice.authorizationStatus(for: type) == .authorized,
                          let device = id.isEmpty ? AVCaptureDevice.default(for: type) : AVCaptureDevice(uniqueID: id) else { continue }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw previewError("设备正在被其他软件使用，请关闭其摄像头后重试。") }
                    session.addInput(input)
                }
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: .main)
                let audio = AVCaptureAudioDataOutput()
                audio.setSampleBufferDelegate(self, queue: .main)
                for output in [video as AVCaptureOutput, audio] where session.canAddOutput(output) { session.addOutput(output) }
                if !session.inputs.isEmpty {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().async { session.startRunning(); continuation.resume() }
                    }
                }
                if CGPreflightScreenCaptureAccess() {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let target = content.displays.first(where: { String($0.displayID) == display }) ?? (display.isEmpty ? content.displays.first : nil) else { throw previewError("请选择可用显示器。") }
                    let filter = SCContentFilter(display: target, excludingApplications: content.applications.filter { $0.processID == getpid() }, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = 480; config.height = max(2, 480 * target.height / max(1, target.width))
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
                    config.capturesAudio = false; config.queueDepth = 3
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    self.stream = stream
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                    try await stream.startCapture()
                }
            } catch { self.error = "预览不可用：\(error.localizedDescription)" }
        }
        change = task
        return task
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput { level = Double(connection.audioChannels.first?.averagePowerLevel ?? -120); return }
        guard Date().timeIntervalSince(lastCamera) >= 0.2 else { return }
        lastCamera = Date(); cameraImage = image(sampleBuffer)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Date().timeIntervalSince(lastScreen) >= 0.2 else { return }
        lastScreen = Date(); screenImage = image(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.error = "屏幕预览已停止，请重新选择显示器。" }
    }
    private func image(_ sample: CMSampleBuffer) -> NSImage? {
        guard let buffer = sample.imageBuffer else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
    private func previewError(_ message: String) -> Error { NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
