import XCTest
import AVFoundation
import CryptoKit
@testable import ChecklistApp
import ChecklistIPC
import ChecklistCore

/// CL-117: bounded audio/video comparison. Fakes and small synthetic media only.
@MainActor private final class FakeTake: MediaTakeControl {
    var plays = 0, pauses = 0, unloads = 0
    func play() { plays += 1 }
    func pause() { pauses += 1 }
    func unload() { unloads += 1; pause() }
}
@MainActor private final class Released { var ids: [String] = [] }

@MainActor final class MediaPlaybackComparisonTests: XCTestCase {
    private func take(_ key: String, bytes: Int = 1024, control: FakeTake = FakeTake()) -> MediaPreparedTake {
        MediaPreparedTake(key: key, label: key, kind: "video", ids: ["reference_id": key], control: control,
            measurement: .init(copyMilliseconds: 1, probeMilliseconds: 1, bytes: bytes,
                facts: .init(durationSeconds: 1, width: 16, height: 16, frames: 10, hasVideo: true, hasAudio: false)))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaPlaybackTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCoordinatorKeepsTwoTakesOnePreparationAndOnePlayingTake() {
        let playback = MediaPlaybackCoordinator(), a = FakeTake(), b = FakeTake(), c = FakeTake()
        XCTAssertTrue(playback.beginPreparation("a")); XCTAssertFalse(playback.beginPreparation("b"))
        playback.endPreparation("a"); XCTAssertTrue(playback.beginPreparation("b")); playback.endPreparation("b"); XCTAssertNil(playback.preparing)
        playback.admit(take("a", control: a)); playback.admit(take("b", control: b))
        playback.play("a"); XCTAssertEqual(playback.playingKey, "a"); XCTAssertEqual(a.plays, 1)
        playback.play("b"); XCTAssertEqual(playback.playingKey, "b"); XCTAssertEqual(b.plays, 1); XCTAssertGreaterThanOrEqual(a.pauses, 1)
        // Native inline controls start a take directly: every other take still pauses.
        let before = b.pauses; playback.didStart("a"); XCTAssertEqual(playback.playingKey, "a"); XCTAssertEqual(b.pauses, before + 1)
        // A third take evicts the oldest non-playing take; never more than two loaded.
        playback.admit(take("c", control: c)); XCTAssertEqual(Set(playback.takes.keys), ["a", "c"]); XCTAssertEqual(playback.playingKey, "a")
        playback.release("a"); XCTAssertNil(playback.playingKey); XCTAssertEqual(Set(playback.takes.keys), ["c"]); XCTAssertEqual(a.unloads, 1)
        // Cache budget: loaded takes stay within 1 GiB together.
        playback.admit(take("d", bytes: 600 * 1024 * 1024)); playback.admit(take("e", bytes: 600 * 1024 * 1024))
        XCTAssertEqual(Set(playback.takes.keys), ["e"]); XCTAssertLessThanOrEqual(playback.cachedBytes, MediaPlaybackBudget.cacheBytes)
        playback.admit(take("example:x")); playback.releaseAll(prefix: "example:"); XCTAssertNil(playback.takes["example:x"])
        playback.play("e"); playback.releaseAll(); XCTAssertTrue(playback.takes.isEmpty); XCTAssertNil(playback.playingKey)
    }

    func testVerifiedCopyAlwaysReleasesItsExactLease() async throws {
        let bytes = Data("synthetic take bytes".utf8), url = try directory().appendingPathComponent("take.bin")
        try bytes.write(to: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), released = Released()
        func lease(_ id: String, size: Int? = nil) -> MediaTakeLoader.Lease {
            .init(id: id, path: url.path, size: size ?? bytes.count, name: "take.bin", attachmentID: "attachment-1")
        }
        let (file, _) = try await MediaTakeLoader.verifiedCopy(expectedSHA256: digest, lease: { lease("lease-1") }, release: { released.ids.append($0) })
        XCTAssertEqual(try Data(contentsOf: file.url), bytes); XCTAssertNotEqual(file.url, url); XCTAssertEqual(released.ids, ["lease-1"])
        do { _ = try await MediaTakeLoader.verifiedCopy(expectedSHA256: String(repeating: "0", count: 64), lease: { lease("lease-2") }, release: { released.ids.append($0) }); XCTFail("hash mismatch") } catch {}
        XCTAssertEqual(released.ids.last, "lease-2")
        do { _ = try await MediaTakeLoader.verifiedCopy(expectedSHA256: digest, lease: { lease("lease-3", size: MediaPlaybackBudget.originalBytes + 1) }, release: { released.ids.append($0) }); XCTFail("size") } catch {}
        XCTAssertEqual(released.ids.last, "lease-3")
        // Cancelled while the lease is granted (view disappeared): the lease is still released.
        let task = Task { @MainActor in
            try await MediaTakeLoader.verifiedCopy(expectedSHA256: digest, lease: { withUnsafeCurrentTask { $0?.cancel() }; return lease("lease-4") }, release: { released.ids.append($0) })
        }
        do { _ = try await task.value; XCTFail("cancelled") } catch {}
        XCTAssertEqual(released.ids, ["lease-1", "lease-2", "lease-3", "lease-4"])
    }

    func testPlaybackLeaseRequestsAreExactForCurrentItemAndExample() {
        let original = Record(values: ["reference_id": "ref-1"])
        let current = MediaReviewModel.playbackLeaseRequest(roundID: "round", selectedID: "item", targetID: "target", original: original, example: nil)
        XCTAssertEqual(current.0, "media_original_read")
        XCTAssertEqual(NSDictionary(dictionary: current.1), NSDictionary(dictionary: ["round_id": "round", "item_id": "item", "target_id": "target", "reference_id": "ref-1", "representation": "lease", "seconds": 60]))
        let example = MediaReviewModel.playbackLeaseRequest(roundID: "round", selectedID: "item", targetID: "target", original: original,
            example: Record(values: ["target_id": "accepted-target", "decision_id": "decision"]))
        XCTAssertEqual(example.0, "media_example_read_lease")
        XCTAssertEqual(NSDictionary(dictionary: example.1), NSDictionary(dictionary: ["round_id": "round", "target_id": "accepted-target", "decision_id": "decision", "reference_id": "ref-1", "seconds": 60]))
    }

    func testSyntheticWrittenMovieIsSelfContainedAndProbeMeasuresIt() async throws {
        let url = try directory().appendingPathComponent("synthetic.mp4")
        try await Self.writeMovie(url, width: 64, height: 48, frames: 12)
        let inspected = try XCTUnwrap(MediaIntakeMovie.inspect(try Data(contentsOf: url)))
        XCTAssertTrue(inspected.hasVideo); XCTAssertFalse(inspected.hasAudio)
        let (_, measured, probeMilliseconds) = try await MediaTakeLoader.probe(url: url, kind: "video")
        XCTAssertEqual(measured.width, 64); XCTAssertEqual(measured.height, 48); XCTAssertTrue(measured.hasVideo)
        XCTAssertGreaterThan(measured.frames, 0); XCTAssertLessThanOrEqual(measured.frames, 13)
        XCTAssertLessThan(probeMilliseconds, Int(MediaPlaybackBudget.probeSeconds * 1000))
        XCTAssertNil(MediaPlaybackBudget.refusal(measured, kind: "video"))
        // One second over the video duration bound is refused.
        var long = measured; long.durationSeconds = MediaPlaybackBudget.videoSeconds + 1
        XCTAssertNotNil(MediaPlaybackBudget.refusal(long, kind: "video"))
    }

    func testDeclaredFrameRateUsesMeasuredSourceRateAndRefusesUnverifiableSpeed() throws {
        XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate: 24, declaredFrameRate: 12).rate, 0.5)
        XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate: 12, declaredFrameRate: 12).rate, 1)
        XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate: 12, declaredFrameRate: 24).rate, 2)
        XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate: nil, declaredFrameRate: nil).rate, 1)
        for invalid in [Double.nan, .infinity, 0, 241] {
            XCTAssertThrowsError(try MediaPlaybackTiming(nominalFrameRate: 12, declaredFrameRate: invalid))
        }
        for unknown in [nil, 0, Double.nan, .infinity] as [Double?] {
            XCTAssertThrowsError(try MediaPlaybackTiming(nominalFrameRate: unknown, declaredFrameRate: 12))
        }
        XCTAssertThrowsError(try MediaPlaybackTiming(nominalFrameRate: 1, declaredFrameRate: 12))
        XCTAssertEqual(MediaPlaybackLabels.playback(loop: true, frameRate: 12), "Loops at 12 fps")
        XCTAssertEqual(MediaPlaybackLabels.playback(loop: false, frameRate: nil), "Plays once at source speed")
    }

    func testEightFrameVideoLoopsAtTwelveFPSAndPauseRetainsQueueUntilUnload() async throws {
        let url = try directory().appendingPathComponent("eight-frames.mp4")
        try await Self.writeMovie(url, width: 64, height: 48, frames: 8)
        let (asset, _, _) = try await MediaTakeLoader.probe(url: url, kind: "video")
        let timing = try await MediaTakeLoader.timing(asset: asset, frameRate: 12)
        XCTAssertEqual(try XCTUnwrap(timing.nominalFrameRate), 12, accuracy: 0.01)
        let control = MediaNativeTakeControl(asset: asset, loop: true, playbackRate: timing.rate)
        defer { control.unload() }
        let looper = try XCTUnwrap(control.looper)
        XCTAssertGreaterThanOrEqual(looper.loopingPlayerItems.count, 2)
        control.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while looper.loopCount < 2, looper.status != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(looper.status, .failed, String(describing: looper.error))
        XCTAssertGreaterThanOrEqual(looper.loopCount, 2, "Generated 8-frame/12-fps take must advance through native queue replicas.")
        XCTAssertNotNil(control.player.currentItem)
        XCTAssertEqual(control.player.rate, 1, accuracy: 0.001)
        control.pause()
        XCTAssertEqual(control.player.rate, 0)
        XCTAssertTrue(control.looper === looper)
        XCTAssertFalse(control.player.items().isEmpty)
        control.unload()
        XCTAssertNil(control.looper); XCTAssertTrue(control.player.items().isEmpty)
        XCTAssertEqual(looper.status, .cancelled)
        control.play(); XCTAssertEqual(control.player.rate, 0)
    }

    func testLoopingTakeCyclesEightFrameDurationsAtTheDeclaredRate() async throws {
        // CL-335: R52C's ffmpeg take reported nominal 10.67 fps but 1/12 s frames; it must play at 1x.
        let reordered = MediaPlaybackTiming.sourceFrameRate(nominal: 32.0 / 3, minimumFrameDuration: 1.0 / 12)
        XCTAssertEqual(try XCTUnwrap(reordered), 12, accuracy: 0.0001)
        XCTAssertEqual(try MediaPlaybackTiming(nominalFrameRate: reordered, declaredFrameRate: 12).rate, 1, accuracy: 0.0001)
        XCTAssertEqual(MediaPlaybackTiming.sourceFrameRate(nominal: 24, minimumFrameDuration: .nan), 24)
        XCTAssertNil(MediaPlaybackTiming.sourceFrameRate(nominal: nil, minimumFrameDuration: nil))
        let url = try directory().appendingPathComponent("cadence-take.mp4")
        try await Self.writeMovie(url, width: 64, height: 48, frames: 8)
        let (asset, _, _) = try await MediaTakeLoader.probe(url: url, kind: "video")
        let timing = try await MediaTakeLoader.timing(asset: asset, frameRate: 12)
        let control = MediaNativeTakeControl(asset: asset, loop: true, playbackRate: timing.rate)
        defer { control.unload() }
        let looper = try XCTUnwrap(control.looper)
        control.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while looper.loopCount < 2 || (control.player.currentItem?.timebase).map(CMTimebaseGetRate) ?? 0 == 0,
              looper.status != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(looper.loopCount, 2, String(describing: looper.error))
        // Read the item's own clock, not wall time: each loop is eight 1/12 s frames of
        // source time, and that clock advances at exactly 1x, so one loop lasts 0.667 s.
        let item = try XCTUnwrap(control.player.currentItem)
        let clockRate = CMTimebaseGetRate(try XCTUnwrap(item.timebase))
        XCTAssertEqual(item.duration.seconds, 8.0 / 12, accuracy: 0.002)
        XCTAssertEqual(clockRate, 1, accuracy: 0.0001)
        XCTAssertEqual(item.duration.seconds / clockRate, 8.0 / 12, accuracy: 0.002)
    }

    func testNativeControlPlayKeepsDeclaredSpeedAndNonloopingTakeHasNoLooper() async throws {
        let url = try directory().appendingPathComponent("slower-take.mp4")
        try await Self.writeMovie(url, width: 64, height: 48, frames: 8)
        let (asset, _, _) = try await MediaTakeLoader.probe(url: url, kind: "video")
        let timing = try await MediaTakeLoader.timing(asset: asset, frameRate: 6)
        let control = MediaNativeTakeControl(asset: asset, loop: false, playbackRate: timing.rate)
        defer { control.unload() }
        XCTAssertNil(control.looper)
        XCTAssertEqual(control.player.defaultRate, 0.5)
        // Same entry point as AVKit's native Play, after the owner pauses.
        control.player.play()
        XCTAssertEqual(control.player.rate, 0.5)
        control.pause(); XCTAssertEqual(control.player.rate, 0)
        control.player.rate = 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while abs(control.player.rate - 0.5) > 0.001, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(control.player.rate, 0.5)
        control.pause()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(control.player.rate, 0, "A queued rate observation must never undo Pause.")
    }

    func testNonloopingTakeRetainsCompletedItemAndReplaysWithoutUndoingPauseOrUnload() async throws {
        let url = try directory().appendingPathComponent("replay-take.mp4")
        try await Self.writeMovie(url, width: 64, height: 48, frames: 8)
        let (asset, _, _) = try await MediaTakeLoader.probe(url: url, kind: "video")
        let control = MediaNativeTakeControl(asset: asset, loop: false, playbackRate: 1)
        defer { control.unload() }
        let item = try XCTUnwrap(control.player.currentItem)
        XCTAssertEqual(control.player.actionAtItemEnd, .pause)
        let ended=expectation(description:"Native single take completed")
        let token=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:item,queue:.main) {_ in ended.fulfill()}
        defer {NotificationCenter.default.removeObserver(token)}
        control.play()
        await fulfillment(of:[ended],timeout:8)
        let rewindDeadline=ContinuousClock.now.advanced(by:.seconds(3))
        while item.currentTime().seconds >= item.duration.seconds - 0.001,ContinuousClock.now < rewindDeadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertTrue(control.player.currentItem === item)
        XCTAssertEqual(control.player.rate,0)
        XCTAssertLessThan(item.currentTime().seconds,item.duration.seconds - 0.001)
        // A naturally completed take is ready for AVKit's native Play again.
        control.player.play()
        let replayDeadline=ContinuousClock.now.advanced(by:.seconds(3))
        while (item.currentTime().seconds < 0.02 || control.player.rate == 0),ContinuousClock.now < replayDeadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertGreaterThan(control.player.rate,0)
        XCTAssertGreaterThan(item.currentTime().seconds,0)
        control.pause()
        await control.player.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero)
        control.play(); control.pause()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(control.player.rate, 0, "Pause fences an in-flight rewind completion.")
        await control.player.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero)
        control.play(); control.player.pause()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(control.player.rate, 0, "Native AVKit Pause must not be undone by a rewind completion.")
        // The app's explicit Play also rewinds an end position without reload.
        await control.player.seek(to:item.duration,toleranceBefore:.zero,toleranceAfter:.zero)
        control.play()
        let customReplayDeadline=ContinuousClock.now.advanced(by:.seconds(3))
        while (item.currentTime().seconds < 0.02 || item.currentTime().seconds >= item.duration.seconds - 0.001 || control.player.rate == 0),ContinuousClock.now < customReplayDeadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertLessThan(item.currentTime().seconds,item.duration.seconds - 0.001)
        XCTAssertGreaterThan(control.player.rate,0)
        control.pause()
        await control.player.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero)
        control.play(); control.unload()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(control.player.rate, 0); XCTAssertNil(control.player.currentItem)
    }

    static func writeMovie(_ url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }
}
