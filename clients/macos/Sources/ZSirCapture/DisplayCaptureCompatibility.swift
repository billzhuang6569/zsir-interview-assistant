import AppKit
import ScreenCaptureKit
import CoreImage
import RecordingCore

/// Keep the thumbnail estimate and encoder on the same pixel dimensions.
enum DisplayCaptureCompatibility {
    static func pixelSize(display: SCDisplay, filter: SCContentFilter) throws -> CGSize {
        if #available(macOS 14, *), !RecordingCapabilities.macOS12Edition {
            return try evenSize(CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                                      height: filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        }
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else {
            throw RecordingError("无法读取所选显示器的像素尺寸，请刷新设备")
        }
        return try legacyPixelSize(modePixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
                                   bounds: CGDisplayBounds(display.displayID).size)
    }

    static func legacyPixelSize(modePixels: CGSize, bounds: CGSize) throws -> CGSize {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw RecordingError("所选显示器已断开或尺寸无效")
        }
        // Display modes can retain native orientation while display bounds are rotated.
        let rotated = (bounds.width > bounds.height) != (modePixels.width > modePixels.height)
        return try evenSize(rotated ? CGSize(width: modePixels.height, height: modePixels.width) : modePixels)
    }

    static func evenSize(_ size: CGSize) throws -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 2, size.height >= 2, size.width <= 32768, size.height <= 32768 else {
            throw RecordingError("显示器像素尺寸无效")
        }
        return CGSize(width: Int(size.width.rounded()) / 2 * 2, height: Int(size.height.rounded()) / 2 * 2)
    }
}

/// One screen frame only: no microphone, writer, Take, or on-disk image.
@MainActor
final class LegacyScreenThumbnail: NSObject, SCStreamOutput, SCStreamDelegate {
    private var result: Result<CGImage, Error>?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var timeout: Task<Void, Never>?
    private var started = false
    private let context = CIContext()

    func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try Task.checkCancellation()
        if #available(macOS 13, *) { configuration.capturesAudio = false }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        let start = Task {
            do { try await stream.startCapture(); started = true }
            catch { resolve(.failure(error)) }
        }
        let outcome: Result<CGImage, Error>
        do { outcome = .success(try await waitForImage()) }
        catch { outcome = .failure(error) }
        // Even cancellation during start must wait for start before stopping its stream.
        await start.value
        do { if started { try await stream.stopCapture() } }
        catch {
            try? stream.removeStreamOutput(self, type: .screen)
            throw error
        }
        try stream.removeStreamOutput(self, type: .screen)
        try Task.checkCancellation()
        return try outcome.get()
    }

    func waitForImage(timeoutNanoseconds: UInt64 = 3_000_000_000) async throws -> CGImage {
        try await withTaskCancellationHandler {
            if Task.isCancelled { resolve(.failure(CancellationError())) }
            return try await withCheckedThrowingContinuation { c in
                if let result { c.resume(with: result); return }
                precondition(continuation == nil)
                continuation = c
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    self?.resolve(.failure(RecordingError("屏幕缩略图获取超时，请重试")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.failure(CancellationError())) }
        }
    }

    func resolve(_ value: Result<CGImage, Error>) {
        guard result == nil else { return }
        result = value
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: value)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        Task { @MainActor in
            guard self.result == nil else { return }
            let input = CIImage(cvPixelBuffer: pixel)
            guard let image = self.context.createCGImage(input, from: input.extent) else {
                self.resolve(.failure(RecordingError("无法生成屏幕缩略图"))); return
            }
            self.resolve(.success(image))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.resolve(.failure(error)) }
    }
}
