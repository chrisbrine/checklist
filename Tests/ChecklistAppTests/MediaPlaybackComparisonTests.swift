import XCTest
import AVFoundation
import CryptoKit
@testable import ChecklistApp
import ChecklistIPC
import ChecklistCore

/// CL-117: bounded audio/video comparison. Fakes and small synthetic media only.
@MainActor private final class FakeTake: MediaTakeControl {
    var plays = 0, pauses = 0
    func play() { plays += 1 }
    func pause() { pauses += 1 }
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
        playback.release("a"); XCTAssertNil(playback.playingKey); XCTAssertEqual(Set(playback.takes.keys), ["c"])
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
