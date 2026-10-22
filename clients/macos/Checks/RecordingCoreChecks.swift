import AVFoundation
import RecordingCore
import Darwin

final class RecordingCoreChecks {
    var folders: [URL] = []
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        folders.append(url)
        return url
    }

    func testQualityAndSilentRecovery() async throws {
        expectEqual(try RecordingQuality.standard.desktopBitRate(width: 1920, height: 1080), 12_000_000)
        expectEqual(try RecordingQuality.high.desktopBitRate(width: 3840, height: 2160), 72_000_000)
        expectEqual(try RecordingQuality.compact.desktopBitRate(width: 720, height: 1280), 6_000_000)
        expectEqual(try RecordingQuality.standard.desktopBitRate(width: 3841, height: 2161), 48_000_000)
        do { _ = try RecordingQuality.high.desktopBitRate(width: 0, height: 1080); fatalError("invalid size accepted") } catch {}
        for quality in RecordingQuality.allCases {
            let root = try temporaryFolder()
            let take = try TakeFiles.create(in: root)
            let url = take.appendingPathComponent("desktop.mp4")
            try TakeFiles.writeReport(["state": "needs_review", "systemAudio": false], in: take)
            let writer = MovieWriter(url: url, epoch: .zero, videoBitRate: quality.cameraBitRate, includesAudio: false)
            for frame in 0..<20 {
                try writer.append(videoSample(at: CMTime(value: Int64(frame), timescale: 30)), isVideo: true)
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in writer.finish(at: CMTime(seconds: 1, preferredTimescale: 600)) { c.resume(with: $0) } }
            let asset = AVURLAsset(url: url)
            expectEqual(try await asset.loadTracks(withMediaType: .audio).count, 0)
            try await RecordingRecovery.validate(url, requiresAudio: false)
            let original = try Data(contentsOf: url)
            let candidate = try unwrap(RecordingRecovery.scan(root: root).first)
            let result = try await RecordingRecovery.recover(candidate)
            expect(result.errors.isEmpty); expectEqual(result.files.count, 1)
            expectEqual(try Data(contentsOf: url), original)
        }
    }

    func testTakeDirectoriesNeverOverwriteExistingMedia() throws {
        let root = try temporaryFolder()
        let first = try TakeFiles.create(in: root)
        let media = first.appendingPathComponent("camera.mp4")
        try Data("keep".utf8).write(to: media)
        let second = try TakeFiles.create(in: root)
        expectNotEqual(first, second)
        try TakeFiles.writeReport(["state": "preparing"], in: first)
        try TakeFiles.writeReport(["state": "needs_review"], in: first)
        expectEqual(try String(contentsOf: media), "keep")
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: first.appendingPathComponent("report.json"))) as? [String: String]
        expectEqual(report?["state"], "needs_review")
    }

    func testNoSamplesCannotReportSuccessfulSave() async throws {
        let root = try temporaryFolder()
        let writer = MovieWriter(url: root.appendingPathComponent("empty.mp4"), epoch: .zero)
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        }
        if case .success = result { fatalError("Empty capture must not succeed") }
    }

    func testSyntheticVideoAndAudioProduceReadableMP4() async throws {
        let root = try temporaryFolder()
        let url = root.appendingPathComponent("synthetic.mp4")
        let epoch = CMTime(seconds: 100, preferredTimescale: 48_000)
        let writer = MovieWriter(url: url, epoch: epoch, videoBitRate: 8_000_000)
        let early = try videoSample(at: CMTime(seconds: 99, preferredTimescale: 30))
        try writer.append(early, isVideo: true)
        expectEqual(writer.videoSamples, 0)
        for frame in 0..<360 {
            let time = CMTimeAdd(epoch, CMTime(value: Int64(frame), timescale: 30))
            let video = try videoSample(at: time)
            let retimed = try MediaClock.hostSample(video, from: CMClockGetHostTimeClock())
            expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(retimed), time), 0)
            do { try writer.append(retimed, isVideo: true) }
            catch { throw RecordingError("Video frame \(frame): \(error)") }
            do { try writer.append(audioSample(at: time), isVideo: false) }
            catch { throw RecordingError("Audio frame \(frame): \(error)") }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        print("Synthetic samples written: video=\(writer.videoSamples), audio=\(writer.audioSamples)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTimeAdd(epoch, CMTime(seconds: 14, preferredTimescale: 600))) { continuation.resume(with: $0) }
        }
        expectGreater(writer.videoSamples, 300)
        expectGreater(writer.audioSamples, 300)
        print("Writer finalized")
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        expectEqual(videos.count, 1)
        expectEqual(audios.count, 1)
        let duration = try await asset.load(.duration)
        print("Encoded duration: \(duration.seconds)")
        expectGreater(duration.seconds, 13.9)
        expectLess(duration.seconds, 14.2)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        expect(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        expectEqual(reader.status, .completed)
        // The end marker at exactly endSession is trimmed; the preceding frame holds to that time.
        expectEqual(count, writer.videoSamples - 1)
        let audioReader = try AVAssetReader(asset: asset)
        let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        audioReader.add(audioOutput)
        expect(audioReader.startReading())
        var audioFrames = 0
        while let sample = audioOutput.copyNextSampleBuffer() { audioFrames += CMSampleBufferGetNumSamples(sample) }
        expectEqual(audioReader.status, .completed)
        expectGreater(audioFrames, 500_000)
    }

    func testDesktop4KPreservesPixels() async throws {
        let root = try temporaryFolder()
        let url = root.appendingPathComponent("desktop-4k.mp4")
        let writer = MovieWriter(url: url, epoch: .zero, videoBitRate: 48_000_000)
        for frame in 0..<30 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            try writer.append(videoSample(at: time, width: 3840, height: 2160), isVideo: true)
            try writer.append(audioSample(at: time), isVideo: false)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTime(seconds: 1, preferredTimescale: 600)) { continuation.resume(with: $0) }
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try unwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        expectEqual(size, CGSize(width: 3840, height: 2160))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        expect(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let pixel = try unwrap(CMSampleBufferGetImageBuffer(sample))
            expectEqual(CVPixelBufferGetWidth(pixel), 3840)
            expectEqual(CVPixelBufferGetHeight(pixel), 2160)
            count += 1
        }
        expectEqual(reader.status, .completed)
        expectGreater(count, 20)
    }

    func testSelectedTracksOnlyCreateSelectedFiles() async throws {
        let root = try temporaryFolder()
        for (mode, expected) in [(RecordingMode.camera, ["camera.mp4"]), (.desktop, ["desktop.mp4"]), (.both, ["camera.mp4", "desktop.mp4"])] {
            let folder = try TakeFiles.create(in: root)
            var writers: [MovieWriter] = []
            if mode.includesCamera { writers.append(MovieWriter(url: folder.appendingPathComponent("camera.mp4"), epoch: .zero, videoBitRate: 8_000_000)) }
            if mode.includesDesktop { writers.append(MovieWriter(url: folder.appendingPathComponent("desktop.mp4"), epoch: .zero)) }
            for frame in 0..<15 {
                let time = CMTime(value: Int64(frame), timescale: 30)
                for writer in writers {
                    try writer.append(videoSample(at: time), isVideo: true)
                    try writer.append(audioSample(at: time), isVideo: false)
                }
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            for writer in writers {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    writer.finish(at: CMTime(seconds: 0.5, preferredTimescale: 600)) { continuation.resume(with: $0) }
                }
            }
            expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), Set(expected))
            for name in expected {
                let asset = AVURLAsset(url: folder.appendingPathComponent(name))
                expectEqual(try await asset.loadTracks(withMediaType: .video).count, 1)
                expectEqual(try await asset.loadTracks(withMediaType: .audio).count, 1)
            }
        }
    }

    func testLivePreviewDoesNotChangeRecordingSamples() throws {
        for frame in 0..<60 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            let source = try videoSample(at: time)
            let preview = try unwrap(LivePreviewSample.make(from: source))
            expect(source !== preview)
            expect(CMSampleBufferGetImageBuffer(source) === CMSampleBufferGetImageBuffer(preview))
            expectEqual(CMSampleBufferGetPresentationTimeStamp(preview), time)
            let previewAttachments = CMSampleBufferGetSampleAttachmentsArray(preview, createIfNecessary: false) as? [[String: Any]]
            expectEqual(previewAttachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
            let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: false) as? [[String: Any]]
            expect(sourceAttachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] == nil)
        }
        expect(LivePreviewSample.make(from: try audioSample(at: .zero)) == nil)
    }

    func crashFixture(folder: URL) async throws {
        let lease = try TakeLease(folder: folder)
        defer { withExtendedLifetime(lease) {} }
        try TakeFiles.writeReport(["state": "recording"], in: folder)
        let writer = MovieWriter(url: folder.appendingPathComponent("desktop.mp4"), epoch: .zero)
        for frame in 0..<1800 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            if frame == 0 { try writer.append(videoSample(at: time), isVideo: true) }
            else { try writer.holdLastFrame(at: time) }
            try writer.append(audioSample(at: time), isVideo: false)
            if frame == 750 { try Data().write(to: folder.appendingPathComponent("ready")) }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
    }

    func testKilledProcessRecoveryPreservesOriginal() async throws {
        let root = try temporaryFolder()
        let folder = try TakeFiles.create(in: root)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--crash-fixture", folder.path]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        var ready = false
        for _ in 0..<450 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) { ready = true; break }
            if !child.isRunning { throw RecordingError("Synthetic child exited early") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { throw RecordingError("Synthetic crash fixture timed out") }
        expectEqual(try RecordingRecovery.scan(root: root).count, 0)
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let source = folder.appendingPathComponent("desktop.mp4")
        let original = try Data(contentsOf: source)
        let candidates = try RecordingRecovery.scan(root: root)
        expectEqual(candidates.count, 1)
        let result = try await RecordingRecovery.recover(candidates[0])
        guard result.errors.isEmpty else { throw RecordingError(result.errors.joined(separator: "; ")) }
        expectEqual(result.files.count, 1)
        expectEqual(try Data(contentsOf: source), original)
        let duration = try await AVURLAsset(url: result.files[0]).load(.duration).seconds
        expectGreater(duration, 1)
        expectLess(duration, 26)
        expectEqual(try RecordingRecovery.scan(root: root).count, 0)
        print("Recovered static desktop after SIGKILL: \(duration)s; original \(original.count) bytes unchanged")

        let invalid = try TakeFiles.create(in: root)
        try TakeFiles.writeReport(["state": "recording"], in: invalid)
        let broken = invalid.appendingPathComponent("camera.mp4")
        try Data("incomplete".utf8).write(to: broken)
        let failed = try await RecordingRecovery.recover(try unwrap(RecordingRecovery.scan(root: root).first))
        expect(failed.files.isEmpty && !failed.errors.isEmpty)
        expectEqual(try String(contentsOf: broken), "incomplete")
        try FileManager.default.createSymbolicLink(at: invalid.appendingPathComponent("desktop.mp4"), withDestinationURL: source)
        expectEqual(try RecordingRecovery.scan(root: root).first?.files.count, 1)
    }

    private func videoSample(at time: CMTime, width: Int = 320, height: Int = 180) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        expectEqual(status, kCVReturnSuccess)
        let buffer = try unwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        expectEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        expectEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try unwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try unwrap(sample)
    }

    private func audioSample(at time: CMTime) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        expectEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        expectEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 6400, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: 6400, flags: 0, blockBufferOut: &block), noErr)
        let data = try unwrap(block)
        expectEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: 6400), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        expectEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try unwrap(format), sampleCount: 1600, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try unwrap(sample)
    }
}

func expect(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Check failed", file: file, line: line)
}
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected \(lhs) == \(rhs)", file: file, line: line)
}
func expectNotEqual<T: Equatable>(_ lhs: T, _ rhs: T) { precondition(lhs != rhs) }
func expectGreater<T: Comparable>(_ lhs: T, _ rhs: T) { precondition(lhs > rhs) }
func expectLess<T: Comparable>(_ lhs: T, _ rhs: T) { precondition(lhs < rhs) }
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw RecordingError("Missing synthetic test value") }
    return value
}
@main struct RunChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        let checks = RecordingCoreChecks()
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash-fixture" {
            try await checks.crashFixture(folder: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        defer { for folder in checks.folders { try? FileManager.default.removeItem(at: folder) } }
        try await checks.testQualityAndSilentRecovery()
        print("PASS: quality rates, invalid sizes, three silent MP4 files and recovery preserve originals")
        try await checks.testKilledProcessRecoveryPreservesOriginal()
        print("PASS: active Take lock, SIGKILL recovery, original preservation, invalid input and symlink exclusion")
        try checks.testLivePreviewDoesNotChangeRecordingSamples()
        print("PASS: 60 live preview samples share pixels, display immediately, preserve recording metadata, and reject audio")
        try checks.testTakeDirectoriesNeverOverwriteExistingMedia()
        print("PASS: unique folders and atomic reports preserve media")
        try await checks.testNoSamplesCannotReportSuccessfulSave()
        print("PASS: empty capture cannot report success")
        try await checks.testSelectedTracksOnlyCreateSelectedFiles()
        print("PASS: camera-only, desktop-only and dual synthetic outputs")
        try await checks.testDesktop4KPreservesPixels()
        print("PASS: 4K desktop H.264/AAC encoding and full-resolution decode")
        try await checks.testSyntheticVideoAndAudioProduceReadableMP4()
        print("PASS: 12-second H.264/AAC fragmented MP4, clock mapping, tracks, duration and full video decode")
    }
}
