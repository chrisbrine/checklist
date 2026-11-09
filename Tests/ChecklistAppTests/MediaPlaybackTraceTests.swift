import XCTest
import AVFoundation
@testable import ChecklistApp

/// The diagnostic must distinguish its observation clock from the sample PTS,
/// and must not add a video output to normal playback.
@MainActor final class MediaPlaybackTraceTests: XCTestCase {
    func testTraceRequiresExplicitAbsoluteDirectoryAndArgumentWins() {
        XCTAssertNil(MediaPlaybackTrace.directory(arguments: ["Checklist"], environment: [:]))
        for path in ["", ".", "relative/path", "~/trace", "/"] {
            XCTAssertNil(MediaPlaybackTrace.directory(arguments: ["Checklist", "-ChecklistPlaybackTraceDirectory", path], environment: [:]))
        }
        XCTAssertNil(MediaPlaybackTrace.directory(arguments: ["Checklist", "-ChecklistPlaybackTraceDirectory"],
                                                  environment: ["CHECKLIST_PLAYBACK_TRACE_DIR": "/tmp/fallback"]))
        XCTAssertEqual(MediaPlaybackTrace.directory(arguments: ["Checklist", "-ChecklistPlaybackTraceDirectory", "/tmp/argument"],
                                                     environment: ["CHECKLIST_PLAYBACK_TRACE_DIR": "/tmp/environment"])?.path, "/tmp/argument")
        XCTAssertEqual(MediaPlaybackTrace.directory(arguments: [], environment: ["CHECKLIST_PLAYBACK_TRACE_DIR": "/tmp/environment"])?.path,
                       "/tmp/environment")
    }

    func testTraceMapsOutputPresentationTimeAcrossCyclesAndRejectsInvalidTimes() throws {
        let duration = 8.0 / 12
        for cycle in [0, 1, 449] {
            for frame in 0..<8 {
                let position = try XCTUnwrap(MediaPlaybackTrace.position(presentationSeconds: Double(cycle) * duration + Double(frame) / 12,
                                                                          sourceDuration: duration, frameRate: 12))
                XCTAssertEqual(position.cycle, cycle)
                XCTAssertEqual(position.estimatedFrame, frame)
                XCTAssertEqual(position.sourceSeconds, Double(frame) / 12, accuracy: 0.000001)
            }
        }
        XCTAssertEqual(MediaPlaybackTrace.position(presentationSeconds: 0, sourceDuration: duration, frameRate: nil)?.estimatedFrame, nil)
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertNil(MediaPlaybackTrace.position(presentationSeconds: invalid, sourceDuration: duration, frameRate: 12))
        }
        XCTAssertNil(MediaPlaybackTrace.position(presentationSeconds: 1, sourceDuration: 0, frameRate: 12))
    }

    func testTraceDrainsOrderedRecordsAndStopsAcceptingEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaTraceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let trace = try MediaPlaybackTrace(directory: directory, label: "synthetic:N", sourceDuration: 8.0 / 12,
                                          frameRate: 12, timelineDuration: 300, rate: 1)
        trace.event("rewind_begin", fields: ["generation": 1])
        trace.event("rewind_complete", fields: ["elapsed_ms": 45.25, "finished": true])
        trace.stop(); trace.stop()
        trace.event("must_not_be_recorded")
        let lines = try String(contentsOf: trace.fileURL, encoding: .utf8).split(separator: "\n")
        let rows = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["metadata", "rewind_begin", "rewind_complete"])
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
        XCTAssertEqual(rows.first?["label"] as? String, "synthetic:N")
        XCTAssertEqual(rows.first?["timeline_duration_seconds"] as? Double, 300)
        XCTAssertTrue((rows.first?["evidence"] as? String)?.contains("not AVPlayerLayer presentation") == true)
        XCTAssertFalse(trace.output.suppressesPlayerRendering)
        for row in rows {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(row["write_host_seconds"] as? Double), try XCTUnwrap(row["host_seconds"] as? Double))
        }
    }

    func testDisabledTraceAddsNoPlayerOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaTraceDisabledTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("eight.mp4")
        try await MediaPlaybackComparisonTests.writeMovie(url, width: 64, height: 48, frames: 8)
        let control = try await MediaNativeTakeControl(asset: AVURLAsset(url: url), loop: true, playbackRate: 1, traceDirectory: nil)
        defer { control.unload() }
        XCTAssertTrue(try XCTUnwrap(control.player.currentItem).outputs.isEmpty)
    }
}
