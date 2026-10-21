import Foundation
import AVFoundation
import VideoToolbox

@main
struct RecorderTests {
    static func main() async {
      do {
        let tests = RecorderTests()
        try tests.testArgumentsAndPresets()
        try await tests.testRefusesExistingRecording()
        print("PASS: arguments, presets, existing-output protection")
        fflush(stdout)
        if CommandLine.arguments.contains("--logic-only") { return }
        var probe: VTCompressionSession?
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 320, height: 240, codecType: kCMVideoCodecType_H264, encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &probe)
        print("VT hardware probe OSStatus=\(result)")
        if let probe { VTCompressionSessionInvalidate(probe) }
        fflush(stdout)
        try await tests.testFragmentedWriter()
        print("PASS: hardware H.264 + AAC, MP4 fragments, duration")
      } catch {
        print("FAIL: \(error)"); exit(1)
      }
    }
    func testArgumentsAndPresets() throws {
        let screen = try Options(["capture", "--out", "/tmp/example", "--tracks", "screen", "--quality", "saver", "--duration", "0.5"])
        checkEqual(screen.tracks, ["screen"])
        checkEqual(screen.screenFPS, 15)
        checkEqual(screen.bitrate("cam"), 6_000_000)
        let recommended = try Options(["preflight", "--json"])
        checkEqual(recommended.cameraWidth, 1920)
        checkEqual(recommended.screenWidth, 2560)
        checkEqual(recommended.bitrate("screen"), 10_000_000)
        for args in [["capture"], ["capture", "--out", "/tmp/a", "--duration", "nan"], ["capture", "--out", "/tmp/a", "--duration", "-1"], ["capture", "--out", "/tmp/a", "--tracks", "screen,"], ["devices", "--camera", "x"], ["preflight", "--quality", "high"], ["capture", "--out", "/tmp/a", "--quality", "x"]] {
            do { _ = try Options(args); fatalError("accepted invalid arguments: \(args)") } catch {}
        }
    }

    func testRefusesExistingRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cam.mp4")
        try Data("keep".utf8).write(to: file)
        let options = try Options(["capture", "--out", directory.path, "--tracks", "screen"])
        do { try await CaptureEngine(options: options, directory: directory).configure(); fatalError("must refuse") }
        catch { assert(String(describing: error).contains("OUTPUT_EXISTS")) }
        checkEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    // Exercises the real hardware encoder and MP4 muxer without TCC or capture devices.
    func testFragmentedWriter() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZSIR_TEST_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("zsir-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try TrackWriter(url: directory.appendingPathComponent("synthetic.mp4"), width: 320, height: 240, fps: 30, bitrate: 500_000)
        let epoch = CMTime(seconds: 100, preferredTimescale: 48000)
        try writer.start(epoch)
        var pixel: CVPixelBuffer?
        checkEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = pixel!
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var videoFormat: CMVideoFormatDescription?
        checkEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &videoFormat), noErr)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var audioFormat: CMAudioFormatDescription?
        checkEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat), noErr)
        let longRun = ProcessInfo.processInfo.environment["ZSIR_TEST_LONG"] != nil
        print("SYNTHETIC_OUTPUT=\(writer.url.path)")
        fflush(stdout)
        for frame in 0..<(longRun ? 1800 : 180) {
            let pts = epoch + CMTime(value: Int64(frame), timescale: 30)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var video: CMSampleBuffer?
            checkEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: videoFormat!, sampleTiming: &timing, sampleBufferOut: &video), noErr)
            try writer.append(video!, isVideo: true)
            var block: CMBlockBuffer?
            checkEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 6400, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 6400, flags: 0, blockBufferOut: &block), noErr)
            checkEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 6400), noErr)
            var audio: CMSampleBuffer?
            var audioTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var sampleSize = 4
            checkEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &audioTiming, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &audio), noErr)
            try writer.append(audio!, isVideo: false)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        try writer.prepareFinish(at: epoch + CMTime(seconds: longRun ? 60 : 6, preferredTimescale: 48000))
        await writer.writer.finishWriting()
        checkEqual(writer.writer.status, .completed, "\(String(describing: writer.writer.error))")
        assert(writer.frames > 170)
        checkEqual(writer.levelDb, -120)
        let data = try Data(contentsOf: writer.url)
        assert(data.range(of: Data("moof".utf8)) != nil, "must contain movie fragments")
        let asset = AVURLAsset(url: writer.url)
        let tracks = try await asset.load(.tracks)
        checkEqual(tracks.count, 2)
        let duration = try await asset.load(.duration)
        assert(abs(duration.seconds - (longRun ? 60 : 6)) < 0.1)
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") { precondition(lhs == rhs, "\(lhs) != \(rhs) \(message)") }
