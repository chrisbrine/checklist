import XCTest
import protocol Combine.Publisher
import CryptoKit
import ChecklistCore
@testable import ChecklistApp

final class PreviewCancellationTests: XCTestCase {
    private func fixture(bytes: Int, name: String = UUID().uuidString + ".mp4") throws -> (URL, Record) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPreviewCancellation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(name), data = Data(repeating: 7, count: bytes)
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, Record(values: ["id": name, "name": name, "project_id": "p", "task_id": "t", "mode": "managed", "availability": "available",
                                    "size": bytes, "sha256": sha, "author": "synthetic-uploader", "origin": "worker", "target_manifest_id": "exact-target", "review_attempt_id": "exact-review"]))
    }

    func testCopyProgressCancellationDiscardsThePartialCopy() throws {
        let (url, source) = try fixture(bytes: 16 * 1024 * 1024)
        let progress = Progress(totalUnitCount: Int64(source.integer("size")))
        let observation = progress.observe(\.completedUnitCount, options: [.new]) { value, _ in
            if value.completedUnitCount > 0 { value.cancel() }
        }
        defer { observation.invalidate() }
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: url.path, source: source, progress: progress)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(progress.completedUnitCount, 0)
        XCTAssertLessThan(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(progress.totalUnitCount, Int64(source.integer("size")))
        let temporary = FileManager.default.temporaryDirectory
        let roots = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ChecklistPreview-") }
        XCTAssertFalse(roots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(source.string("name")).path) })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(), source.string("sha256"))
    }

    @MainActor func testExplicitCancellationDuringCopyReleasesHoldAndKeepsNextPreview() async throws {
        let (url, source) = try fixture(bytes: 1024 * 1024)
        let (nextURL, nextSource) = try fixture(bytes: 20, name: "next.md")
        var calls: [String] = [], released: [String] = []
        let store = makeStore(root: url.deletingLastPathComponent()) { method, params in
            calls.append(method)
            if method == "attachment_read_release" { released.append(params["read_hold_id"] as? String ?? ""); return [:] }
            XCTAssertEqual(method, "attachment_read")
            let next = params["attachment_id"] as? String == nextSource.id
            var reply = next ? nextSource.values : source.values
            reply["url"] = next ? nextURL.path : url.path
            reply["read_hold_id"] = next ? "next-hold" : "active-hold"
            return reply
        }
        let resumeCopy = DispatchSemaphore(value: 0)
        let loader = FilePreviewLoader(didCopyChunkForTesting: { count in
            // Keep the first write partial until the throttled main-queue observer
            // cancels, regardless of filesystem speed or scheduler load.
            if count == 256 * 1024 {
                XCTAssertEqual(resumeCopy.wait(timeout: .now() + 10), .success, "Progress observer must cancel the paused copy")
            }
        })
        var observedPartial: Int64 = 0
        let observation = loader.$copiedBytes.sink { count in
            if observedPartial == 0, loader.copying, count > 0, count < loader.totalBytes {
                observedPartial = count
                loader.cancelPreparation()
                resumeCopy.signal()
            }
        }
        defer { observation.cancel() }
        await loader.load(source, store: store)
        XCTAssertEqual(observedPartial, 256 * 1024, "Cancellation must be issued while the first chunk is paused")
        XCTAssertTrue(loader.canceled); XCTAssertFalse(loader.loading); XCTAssertFalse(loader.copying)
        XCTAssertNil(loader.file); XCTAssertTrue(loader.problem.isEmpty)
        XCTAssertGreaterThan(loader.copiedBytes, 0); XCTAssertLessThan(loader.copiedBytes, loader.totalBytes)
        XCTAssertTrue(loader.cancellationSummary.contains("\(loader.copiedBytes) of \(loader.totalBytes)"))
        XCTAssertEqual(released, ["active-hold"])
        print("ACTIVE COPY CANCELED: \(loader.copiedBytes) / \(loader.totalBytes) bytes; hold released")
        await loader.load(nextSource, store: store)
        XCTAssertFalse(loader.canceled); XCTAssertFalse(loader.loading)
        let file = try XCTUnwrap(loader.file)
        XCTAssertEqual(file.source.id, nextSource.id)
        XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: nextURL))
        XCTAssertEqual(file.source.string("author"), nextSource.string("author"))
        XCTAssertEqual(file.source.string("target_manifest_id"), nextSource.string("target_manifest_id"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(loader.file?.source.id, nextSource.id, "Late progress/results cannot replace the next preview")
        XCTAssertEqual(calls, ["attachment_read", "attachment_read_release", "attachment_read", "attachment_read_release"])
        XCTAssertEqual(released, ["active-hold", "next-hold"])
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(), source.string("sha256"))
        loader.cancel()
    }

    @MainActor func testClosingDuringAuthorizationStillReleasesTheReturnedHold() async throws {
        let (url, source) = try fixture(bytes: 20)
        var pending: CheckedContinuation<[String: Any], Error>?, calls: [String] = []
        let store = makeStore(root: url.deletingLastPathComponent()) { method, params in
            calls.append(method)
            if method == "attachment_read" { return try await withCheckedThrowingContinuation { pending = $0 } }
            XCTAssertEqual(method, "attachment_read_release")
            XCTAssertEqual(params["read_hold_id"] as? String, "late-hold")
            return [:]
        }
        let loader = FilePreviewLoader()
        let load = Task { @MainActor in await loader.load(source, store: store) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        load.cancel()
        var reply = source.values; reply["url"] = url.path; reply["read_hold_id"] = "late-hold"
        continuation.resume(returning: reply)
        await load.value
        XCTAssertNil(loader.file); XCTAssertFalse(loader.loading)
        XCTAssertEqual(loader.copiedBytes, 0)
        XCTAssertEqual(calls, ["attachment_read", "attachment_read_release"])
    }

    @MainActor private func makeStore(root: URL, transport: @escaping (String, [String: Any]) async throws -> [String: Any]) -> ChecklistStore {
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: root.appendingPathComponent("drafts")),
                                   preferences: isolatedDefaults("PreviewCancellation").preferences, restorePendingCommand: false,
                                   desktopAlerts: DesktopAlertCoordinator(sink: CancellationNoAlerts()), requestTransport: transport)
        store.connected = true
        return store
    }
}

@MainActor private final class CancellationNoAlerts: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { XCTFail("Unexpected notification") }
    func remove(_ identifiers: [String]) { }
}
