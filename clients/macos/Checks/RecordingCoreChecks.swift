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

    func testEncoderPreparationBeforeEpoch() async throws {
        let root = try temporaryFolder()
        let initial = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 86, timescale: 1000))
        let formatSample = try videoSample(at: initial, width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let writer = MovieWriter(url: root.appendingPathComponent("prepared.mp4"), epoch: .invalid, videoBitRate: 4_000_000, includesAudio: false)
        try writer.prepareVideo(formatSample)
        expectEqual(writer.videoSamples, 0)
        // A deliberately slow preparation period must precede the chosen epoch,
        // rather than consume the recording deadline or produce dummy frames.
        try await Task.sleep(nanoseconds: 180_000_000)
        let epoch = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 86, timescale: 1000))
        let fresh = try MediaClock.videoSample(formatSample, at: epoch)
        try writer.begin(at: epoch)
        try writer.append(fresh, isVideo: true)
        try writer.advance(to: epoch)
        try writer.advance(to: CMClockGetTime(CMClockGetHostTimeClock()))
        expectEqual(writer.diagnostics.lateFrames, 0)
        let frames = writer.videoSamples
        expectGreater(frames, 1)
        expectEqual(writer.diagnostics.capturedFrames, 1)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTimeAdd(epoch, CMTime(value: Int64(frames), timescale: 30))) { c.resume(with: $0) }
        }
        let asset = AVURLAsset(url: root.appendingPathComponent("prepared.mp4"))
        let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); expect(reader.startReading())
        var decoded = 0
        while let sample = output.copyNextSampleBuffer() {
            expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(decoded), timescale: 30)), 0)
            decoded += 1
        }
        expectEqual(decoded, writer.videoSamples)
        expectEqual(reader.status, .completed)
        // Stopping after startWriting but before begin must not pass an invalid
        // endSession time or report a successful recording with no video.
        let aborted = MovieWriter(url: root.appendingPathComponent("aborted.mp4"), epoch: .invalid, includesAudio: false)
        try aborted.prepareVideo(formatSample)
        let closed = RecordingCompletion()
        aborted.whenClosed { closed.complete(.success(())) }
        await withCheckedContinuation { c in
            aborted.finish(at: CMClockGetTime(CMClockGetHostTimeClock())) { result in
                if case .success = result { fatalError("Unbegun prepared writer falsely succeeded") }
                c.resume()
            }
        }
        await withCheckedContinuation { c in closed.observe { _ in c.resume() } }
        print("PASS: cold setup + 180ms prepare before epoch; real 86ms source delay still within unchanged budget; \(decoded) zero-start frames decode; unbegun prepared writer closes as failure")
    }

    func testNonGridStopKeepsFinalFrame() async throws {
        let root = try temporaryFolder()
        let epoch = CMTime(value: 8275073364, timescale: 100000) // Real camera-clock scale from the failed Take.
        for (name, end, frames) in [("short", CMTime(value: 1010001, timescale: 1000000), 31),
                                     ("long", CMTime(value: 41710001, timescale: 1000000), 1252)] {
            let writer = MovieWriter(url: root.appendingPathComponent("\(name).mp4"), epoch: epoch, includesAudio: false)
            for frame in 0..<frames {
                let time = CMTimeAdd(epoch, CMTime(value: Int64(frame), timescale: 30))
                try writer.append(videoSample(at: time), isVideo: true)
                for retry in 0..<2000 {
                    try writer.advance(to: time)
                    if writer.videoSamples > frame { break }
                    if retry == 1999 { throw RecordingError("Synthetic writer remained backpressured") }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writer.finish(at: CMTimeAdd(epoch, end)) { c.resume(with: $0) }
            }
            let asset = AVURLAsset(url: root.appendingPathComponent("\(name).mp4"))
            let track = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); expect(reader.startReading())
            var decoded = 0
            while let sample = output.copyNextSampleBuffer() {
                expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(decoded), timescale: 30)), 0)
                decoded += 1
            }
            expectEqual(reader.status, .completed)
            expectEqual(decoded, frames)
            expectEqual(decoded, writer.videoSamples)
            expectEqual(CMTimeCompare(try await track.load(.timeRange).duration, CMTime(value: Int64(frames), timescale: 30)), 0)
            print("PASS stop \(name): requested \(end.seconds)s, encoded/decoded \(decoded), full end \(Double(frames) / 30)s")
        }
    }

    func measureColdEncoderStartupClock() async throws {
        let root = try temporaryFolder()
        let epoch = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: 5))
        let sample = try videoSample(at: epoch, width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let writer = MovieWriter(url: root.appendingPathComponent("cold.mp4"), epoch: epoch, videoBitRate: 4_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        try writer.append(sample, isVideo: true)
        try writer.advance(to: epoch)
        let firstVideo = ProcessInfo.processInfo.systemUptime - start
        try writer.append(audioSample(at: epoch), isVideo: false)
        let firstAudio = ProcessInfo.processInfo.systemUptime - start - firstVideo
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), epoch).seconds
        print("COLD START: firstVideo=\(firstVideo)s firstAudio=\(firstAudio)s hostMinusSourceEpoch=\(elapsed)s preparation=\(writer.encoderPreparationSeconds)s videoAppend=\(writer.firstVideoAppendSeconds)s audioAppend=\(writer.firstAudioAppendSeconds)s")
        do { try writer.advance(to: CMClockGetTime(CMClockGetHostTimeClock())); print("COLD START unexpectedly admitted wall clock") }
        catch { print("REPRODUCED: \(error.localizedDescription)") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTimeAdd(epoch, CMTime(value: 1, timescale: 30))) { c.resume(with: $0) }
        }
    }

    func testFinishDeadlinePreservesOpenOriginal() async throws {
        let root = try temporaryFolder()
        let take = try TakeFiles.create(in: root)
        let url = take.appendingPathComponent("desktop.mp4")
        let lease = try TakeLease(folder: take)
        defer { withExtendedLifetime(lease) {} }
        try TakeFiles.writeReport(["state": "needs_review"], in: take)
        let writer = MovieWriter(url: url, epoch: .zero, includesAudio: false)
        for frame in 0..<35 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            try writer.append(videoSample(at: time), isVideo: true)
            try writer.advance(to: time)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        let release = RecordingCompletion()
        let closed = RecordingCompletion()
        writer.whenClosed { closed.complete(.success(())) }
        await withCheckedContinuation { c in
            writer.finishWhenReleasedForCheck(at: CMTime(value: 35, timescale: 30), release: release, timeout: 0.05) { result in
                if case .success = result { fatalError("Held finalization falsely succeeded") }
                c.resume()
            }
        }
        expect(FileManager.default.fileExists(atPath: url.path))
        expect(!closed.isCompleted)
        expectEqual(try RecordingRecovery.scan(root: root).count, 0)
        expectGreater(try Data(contentsOf: url).count, 0)
        // A repeated finish must return the deadline failure without claiming
        // physical closure or restarting finalization.
        await withCheckedContinuation { c in
            writer.finish { result in
                if case .success = result { fatalError("Deadline failure changed into success") }
                c.resume()
            }
        }
        expect(!closed.isCompleted)
        release.complete(.success(()))
        await withCheckedContinuation { c in closed.observe { _ in c.resume() } }
        expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let video = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); expect(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        expectEqual(reader.status, .completed)
        expectEqual(count, 35)
    }

    func testDelayedCommonStartupEpoch() async throws {
        var dark = RecordingStartup(sources: ["camera"])
        let darkSource = try videoSample(at: .zero, width: 64, height: 36, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        for frame in 0..<8 {
            dark.offer(try MediaClock.videoSample(darkSource, at: CMTime(value: Int64(frame), timescale: 30)), source: "camera", video: true)
        }
        let described = try dark.activate()
        let summaries = described.diagnostics["sourceFrameSummaries"] as! [String: [[String: Any]]]
        let prime = (described.diagnostics["primeFrameSummaries"] as! [String: [String: Any]])["camera"]!
        expectEqual(summaries["camera"]!.count, 4)
        expectEqual(prime["sampledLumaMin"] as? Int, 80)
        expectEqual(prime["sampledLumaMax"] as? Int, 80)
        expectEqual(prime["sampledLumaMean"] as? Double, 80)
        expectEqual(prime["lumaRange"] as? String, "video_16_235")
        expectEqual(prime["sourcePTSSeconds"] as? Double, 7.0 / 30.0)
        expectEqual(prime["selectedAsPrime"] as? Bool, true)
        let root = try temporaryFolder()
        // Cross-source callback order differs from PTS order: desktop's older
        // first image arrives after the camera has already offered a newer one.
        var reordered = RecordingStartup(sources: ["camera", "desktop"])
        let oldCamera = try videoSample(at: CMTime(value: 2, timescale: 10))
        let newCamera = try videoSample(at: CMTime(value: 18, timescale: 10))
        reordered.offer(oldCamera, source: "camera", video: true)
        reordered.offer(newCamera, source: "camera", video: true)
        reordered.offer(try videoSample(at: CMTime(value: 17, timescale: 10)), source: "desktop", video: true)
        let reorderedReady = try reordered.activate()
        expectEqual(CMTimeCompare(reorderedReady.epoch, CMTime(value: 18, timescale: 10)), 0)
        let selected = try unwrap(CMSampleBufferGetImageBuffer(try unwrap(reorderedReady.video["camera"])))
        let newest = try unwrap(CMSampleBufferGetImageBuffer(newCamera))
        let oldest = try unwrap(CMSampleBufferGetImageBuffer(oldCamera))
        expectEqual(Unmanaged.passUnretained(selected).toOpaque(), Unmanaged.passUnretained(newest).toOpaque())
        expectNotEqual(Unmanaged.passUnretained(selected).toOpaque(), Unmanaged.passUnretained(oldest).toOpaque())
        var barrier = RecordingStartup(sources: ["camera", "desktop"])
        let cameraFirst = try videoSample(at: CMTime(value: 1002, timescale: 10))
        barrier.offer(cameraFirst, source: "camera", video: true)
        expect(!barrier.ready)
        do { _ = try barrier.activate(); fatalError("Barrier started without desktop") } catch {}
        for index in 0..<70 {
            barrier.offer(try audioSample(at: CMTime(value: Int64(100_000 + index * 10), timescale: 1000)), source: "camera", video: false)
        }
        expectEqual(barrier.audioBufferEvictions["camera"], 6)
        try await Task.sleep(nanoseconds: 50_000_000) // A real delayed second offer, without any writer yet.
        let recent = try videoSample(at: CMTime(value: 10169, timescale: 100))
        barrier.offer(recent, source: "camera", video: true)
        for source in ["camera", "desktop"] {
            barrier.offer(try audioSample(at: CMTime(value: 10169, timescale: 100), nonInterleaved: source == "desktop"), source: source, video: false)
        }
        barrier.offer(try videoSample(at: CMTime(value: 1017, timescale: 10)), source: "desktop", video: true)
        expect(barrier.ready)
        let ready = try barrier.activate()
        expectEqual(CMTimeCompare(ready.epoch, CMTime(value: 1017, timescale: 10)), 0)
        expect(CFEqual(CMSampleBufferGetImageBuffer(try unwrap(ready.video["camera"])), CMSampleBufferGetImageBuffer(recent)))
        var writers: [String: RecordingTrack] = [:]
        for source in ["camera", "desktop"] {
            let video = try unwrap(ready.video[source])
            expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(video), ready.epoch), 0)
            let audio = try unwrap(ready.audio[source]?.last)
            expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(audio), ready.epoch), 0)
            expectEqual(CMSampleBufferGetNumSamples(audio), 1120)
            let writer = RecordingTrack(url: root.appendingPathComponent("\(source).mp4"), epoch: ready.epoch)
            writers[source] = writer
            try writer.append(video, isVideo: true)
            try writer.advance(to: ready.epoch)
            try writer.append(audio, isVideo: false)
        }
        for frame in 1..<30 {
            let time = CMTimeAdd(ready.epoch, CMTime(value: Int64(frame), timescale: 30))
            for (source, writer) in writers {
                do {
                    try writer.advance(to: time) // Static source repeats are valid and share the same grid.
                    try writer.append(audioSample(at: time, nonInterleaved: source == "desktop"), isVideo: false)
                } catch { throw RecordingError("Startup fixture \(source) frame \(frame): \(error)") }
            }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        for (source, writer) in writers {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writer.finish(at: CMTimeAdd(ready.epoch, CMTime(value: 1, timescale: 1))) { result in
                    if case .failure(let error) = result { c.resume(throwing: RecordingError("Startup finish \(source): \(error)")) }
                    else { c.resume() }
                }
            }
            expectEqual(writer.videoSamples, 30)
            expectEqual(writer.firstVideoSeconds, 0)
            expectEqual(writer.diagnostics.repeatedFrames, 29)
            let asset = AVURLAsset(url: root.appendingPathComponent("\(source).mp4"))
            let video = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); expect(reader.startReading())
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                expectEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(count), timescale: 30)), 0)
                count += 1
            }
            expectEqual(count, 30); expectEqual(reader.status, .completed)
            let audio = try unwrap(try await asset.loadTracks(withMediaType: .audio).first)
            expectLess(abs(try await audio.load(.timeRange).start.seconds), 0.1)
        }
    }

    func testIndependentBoundedTracks() async throws {
        let root = try temporaryFolder()
        let blocked = RecordingTrack(url: root.appendingPathComponent("blocked.mp4"), epoch: .zero, includesAudio: false)
        let healthy = RecordingTrack(url: root.appendingPathComponent("healthy.mp4"), epoch: .zero, includesAudio: false)
        let release = DispatchSemaphore(value: 0)
        await blocked.blockOwnerForCheck(until: release)
        for frame in 0..<3 { try blocked.append(videoSample(at: CMTime(value: Int64(frame), timescale: 30)), isVideo: true) }
        do { try blocked.append(videoSample(at: CMTime(value: 3, timescale: 30)), isVideo: true); fatalError("Blocked track admitted a fourth video") }
        catch {}
        expectEqual(blocked.snapshot.ingressQueueDepth, 3)
        expectEqual(blocked.snapshot.ingressQueueHighWaterMark, 3)
        // The healthy owner must continue encoding while its sibling is blocked.
        for frame in 0..<30 {
            let time = CMTime(value: Int64(frame), timescale: 30)
            try healthy.append(videoSample(at: time), isVideo: true)
            try healthy.advance(to: time)
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        expectGreater(healthy.videoSamples, 25)
        expectEqual(blocked.videoSamples, 0)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            healthy.finish(at: CMTime(value: 1, timescale: 1)) { c.resume(with: $0) }
        }
        release.signal()
        await withCheckedContinuation { c in
            blocked.finish(at: CMTime(value: 1, timescale: 10)) { result in
                if case .success = result { fatalError("Saturated track falsely reported success") }
                blocked.whenClosed { c.resume() }
            }
        }
        expectEqual(blocked.diagnostics.backpressureFrames, 1)
        expectEqual(healthy.videoSamples, 30)
        let asset = AVURLAsset(url: root.appendingPathComponent("healthy.mp4"))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        expectEqual(tracks.count, 1)
        expectEqual(CMTimeCompare(try await tracks[0].load(.timeRange).duration, CMTime(value: 1, timescale: 1)), 0)
    }

    func testConcurrentCompletion() {
        let gate = RecordingCompletion()
        let lock = NSLock()
        var calls = 0
        for _ in 0..<20 {
            gate.observe { _ in lock.lock(); calls += 1; lock.unlock() }
        }
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index == 0 { gate.complete(.failure(RecordingError("deadline"))) }
            else { gate.complete(.success(())) }
        }
        expectEqual(calls, 20)
        gate.observe { _ in calls += 1 }
        expectEqual(calls, 21)
        expectEqual(gate.complete(.success(())), false)
    }

    func testBoundedCFRAdmissionAndFirstAvailability() async throws {
        let root = try temporaryFolder()
        let saturated = MovieWriter(url: root.appendingPathComponent("saturated.mp4"), epoch: .zero, includesAudio: false)
        for frame in 0..<3 { try saturated.append(videoSample(at: CMTime(value: Int64(frame), timescale: 30)), isVideo: true) }
        do {
            try saturated.append(videoSample(at: CMTime(value: 3, timescale: 30)), isVideo: true)
            fatalError("Queue accepted a fourth source sample")
        } catch {}
        expectEqual(saturated.diagnostics.queueHighWaterMark, 3)
        expectEqual(saturated.diagnostics.backpressureFrames, 1)
        do { try saturated.advance(to: CMTime(value: 4, timescale: 30)); fatalError("Overdue scheduler silently skipped ticks") } catch {}
        expectEqual(saturated.videoSamples, 0)
        expectEqual(saturated.diagnostics.lateFrames, 5)

        let writer = MovieWriter(url: root.appendingPathComponent("availability.mp4"), epoch: .zero, includesAudio: false)
        try writer.append(videoSample(at: CMTime(value: 1, timescale: 100)), isVideo: true)
        try writer.advance(to: .zero)
        expectEqual(writer.videoSamples, 0) // The future image cannot fill tick zero.
        try writer.advance(to: CMTime(value: 1, timescale: 30))
        expectEqual(writer.videoSamples, 1)
        expectEqual(writer.firstVideoSeconds, 1.0 / 30.0)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTime(value: 2, timescale: 30)) { c.resume(with: $0) }
        }
        // A repeated finish observes the same terminal result without touching AVAssetWriter.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writer.finish(at: CMTime(value: 99, timescale: 30)) { c.resume(with: $0) }
        }
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
                try writer.advance(to: CMTime(value: Int64(frame), timescale: 30))
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            for frame in 20..<30 {
                try writer.advance(to: CMTime(value: Int64(frame), timescale: 30))
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
            try writer.advance(to: time)
            do { try writer.append(audioSample(at: time), isVideo: false) }
            catch { throw RecordingError("Audio frame \(frame): \(error)") }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        for frame in 360..<420 {
            try writer.advance(to: CMTimeAdd(epoch, CMTime(value: Int64(frame), timescale: 30)))
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
        while let frame = output.copyNextSampleBuffer() {
            let actual = CMSampleBufferGetPresentationTimeStamp(frame)
            let expected = CMTime(value: Int64(count), timescale: 30)
            if CMTimeCompare(actual, expected) != 0 { print("CFR mismatch frame \(count): \(actual) expected \(expected)") }
            expectEqual(CMTimeCompare(actual, expected), 0)
            count += 1
        }
        expectEqual(reader.status, .completed)
        expectEqual(count, 420)
        expectEqual(count, writer.videoSamples)
        // AVAssetReader supplies invalid/zero durations for this fragmented MP4
        // on some macOS versions. Check the track duration and every PTS instead;
        // the external timeline checker also validates encoded packet durations.
        let timeRange = try await videos[0].load(.timeRange)
        expectEqual(CMTimeCompare(timeRange.duration, CMTime(value: 420, timescale: 30)), 0)
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
            try writer.advance(to: time)
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
                    try writer.advance(to: time)
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

            try writer.advance(to: time)
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

    private func videoSample(at time: CMTime, width: Int = 320, height: Int = 180, pixelFormat: OSType = kCVPixelFormatType_32BGRA) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        expectEqual(status, kCVReturnSuccess)
        let buffer = try unwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 80, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        } else { memset(CVPixelBufferGetBaseAddress(buffer), 80, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        expectEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        expectEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try unwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try unwrap(sample)
    }

    private func audioSample(at time: CMTime, nonInterleaved: Bool = false) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: nonInterleaved ? 2 : 4, mFramesPerPacket: 1, mBytesPerFrame: nonInterleaved ? 2 : 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
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
        if CommandLine.arguments.contains("--prepared-start-only") {
            try await checks.testEncoderPreparationBeforeEpoch()
            return
        }
        if CommandLine.arguments.contains("--stop-boundary-only") {
            try await checks.testNonGridStopKeepsFinalFrame()
            return
        }
        if CommandLine.arguments.contains("--cold-start-only") {
            try await checks.measureColdEncoderStartupClock()
            return
        }
        if CommandLine.arguments.contains("--finish-timeout-only") {
            try await checks.testFinishDeadlinePreservesOpenOriginal()
            print("PASS: finish deadline preserves open original; whenClosed waits for actual completion; late finish decodes all frames")
            return
        }
        if CommandLine.arguments.contains("--startup-only") {
            try await checks.testDelayedCommonStartupEpoch()
            print("PASS: delayed common epoch startup and PCM boundary trims")
            return
        }
        if CommandLine.arguments.contains("--cfr-only") {
            try await checks.testSyntheticVideoAndAudioProduceReadableMP4()
            return
        }
        try await checks.testEncoderPreparationBeforeEpoch()
        try await checks.testNonGridStopKeepsFinalFrame()
        try await checks.testFinishDeadlinePreservesOpenOriginal()
        print("PASS: finalization deadline preserves open original and cannot falsely close it")
        try await checks.testDelayedCommonStartupEpoch()
        print("PASS: delayed two-source barrier shares zero epoch; PCM boundary trims interleaved/non-interleaved; startup audio evictions are separate; both static CFR files decode from zero")
        try await checks.testIndependentBoundedTracks()
        print("PASS: blocked track has bounded ingress; sibling independently encodes 30 CFR frames; saturated track cannot report success")
        checks.testConcurrentCompletion()
        print("PASS: concurrent deadline/completion resolves once, including late observers")
        try await checks.testBoundedCFRAdmissionAndFirstAvailability()
        print("PASS: bounded source admission, late scheduler failure, first availability and repeated finish")
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
