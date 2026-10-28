import XCTest
@testable import ChecklistApp
import ChecklistCore

/// CL-119: list projection and playback-list budgets at 300, 1,000 and 1,200 items.
/// Synthetic rows and fake takes only; native rendering at both viewports is the installed check.
@MainActor private final class ScaleTake: MediaTakeControl {
    var plays = 0, pauses = 0
    func play() { plays += 1 }
    func pause() { pauses += 1 }
}

@MainActor final class MediaWorkflowScaleTests: XCTestCase {
    private func rows(_ count: Int) -> [Record] {
        (0..<count).map { index in
            Record(values: ["id": String(format: "item-%04d", index), "title": "Item \(index)", "disposition": "pending",
                "group_path": [["field_id": "character", "value": index < count / 2 ? "hero" : "villain", "item_count": count / 2],
                               ["field_id": "animation_label", "value": "walk", "item_count": count / 2]]])
        }
    }

    func testListProjectionAndPlaybackWalkStayWithinBudgetsAt300And1000AndAbove() {
        for count in [300, 1000, 1200] {
            let input = rows(count), start = Date()
            let flat = MediaFlatRow.project(input), projectSeconds = Date().timeIntervalSince(start)
            XCTAssertEqual(flat.count, count + 4)
            XCTAssertEqual(Set(flat.map(\.id)).count, flat.count)
            XCTAssertEqual(flat.compactMap { $0.item?.id }, input.map(\.id))
            // Playback list: each item's take passes through the coordinator in list order.
            let playback = MediaPlaybackCoordinator(), walk = Date()
            var maxTakes = 0, maxBytes = 0, controls: [ScaleTake] = []
            for row in input {
                let key = row.id, control = ScaleTake()
                XCTAssertTrue(playback.beginPreparation(key)); XCTAssertFalse(playback.beginPreparation("other"))
                playback.endPreparation(key)
                playback.admit(MediaPreparedTake(key: key, label: key, kind: "video", ids: ["reference_id": key], control: control,
                    measurement: .init(copyMilliseconds: 1, probeMilliseconds: 1, bytes: 400 * 1024 * 1024,
                        facts: .init(durationSeconds: 1, width: 16, height: 16, frames: 10, hasVideo: true, hasAudio: false))))
                playback.play(key); controls.append(control)
                XCTAssertEqual(playback.playingKey, key)
                maxTakes = max(maxTakes, playback.takes.count); maxBytes = max(maxBytes, playback.cachedBytes)
            }
            XCTAssertLessThanOrEqual(maxTakes, MediaPlaybackBudget.preparedTakes)
            XCTAssertLessThanOrEqual(maxBytes, MediaPlaybackBudget.cacheBytes)
            XCTAssertEqual(controls.map(\.plays).reduce(0, +), count)
            XCTAssertTrue(controls.dropLast().allSatisfy { $0.pauses >= 1 })
            playback.releaseAll(); XCTAssertTrue(playback.takes.isEmpty); XCTAssertNil(playback.playingKey)
            print("CL119_APP_SCALE items=\(count) flat_rows=\(flat.count) project_s=\(projectSeconds) playback_walk_s=\(Date().timeIntervalSince(walk)) max_takes=\(maxTakes) max_cached_bytes=\(maxBytes)")
        }
    }
}
