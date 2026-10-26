import XCTest
import ChecklistIPC
@testable import ChecklistApp

final class DraftFileStorageTests: XCTestCase {
    private final class MemoryFiles: DraftFileStorage {
        var values: [URL: Data] = [:]
        var failWrite = false
        func exists(_ url: URL) throws -> Bool { values[url] != nil || values.keys.contains { $0.deletingLastPathComponent().path == url.path } }
        func read(_ url: URL) throws -> Data { try XCTUnwrap(values[url]) }
        func contents(of directory: URL) throws -> [URL] { values.keys.filter { $0.deletingLastPathComponent().path == directory.path } }
        func replace(_ bytes: Data, at target: URL, directory: URL) throws {
            if failWrite { throw CocoaError(.fileWriteNoPermission) }
            values[target] = bytes
        }
    }
    func testJournalRoundTripsThroughExplicitStorage() throws {
        let files = MemoryFiles()
        let journal = LocalDraftJournal(directory: URL(fileURLWithPath: "/synthetic/drafts"), files: files)
        try journal.save("Unsent owner text", kind: "note", key: "ticket")
        XCTAssertTrue(journal.contains(kind: "note", key: "ticket"))
        XCTAssertEqual(try journal.load(String.self, kind: "note"), ["ticket": "Unsent owner text"])
        try journal.checkSaved("Unsent owner text", kind: "note", key: "ticket")
        XCTAssertEqual(files.values.count, 1)
    }
    func testFailedReplacementDoesNotReportSavedOrReplayAnything() throws {
        let files = MemoryFiles()
        let journal = LocalDraftJournal(directory: URL(fileURLWithPath: "/synthetic/drafts"), files: files)
        try journal.save("Original", kind: "note", key: "ticket")
        files.failWrite = true
        XCTAssertThrowsError(try journal.save("Changed", kind: "note", key: "ticket"))
        XCTAssertEqual(try journal.load(String.self, kind: "note"), ["ticket": "Original"])
        XCTAssertThrowsError(try journal.checkSaved("Changed", kind: "note", key: "ticket"))
    }
    func testUnsupportedStorageFailsExplicitly() throws {
        let journal = LocalDraftJournal(directory: URL(fileURLWithPath: "/synthetic/drafts"), files: UnavailableDraftFileStorage())
        XCTAssertThrowsError(try journal.save("Unsent", kind: "note", key: "ticket")) { error in
            XCTAssertEqual((error as? ChecklistError)?.code, "PLATFORM_CAPABILITY_UNAVAILABLE")
            XCTAssertEqual((error as? ChecklistError)?.details["capability"] as? String, "owner_draft_storage")
        }
        XCTAssertThrowsError(try journal.load(String.self, kind: "note"))
    }
}
