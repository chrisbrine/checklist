import XCTest
import CryptoKit
import CoreServices
import PDFKit
import CoreGraphics
import ChecklistCore
@testable import ChecklistApp

final class FilePreviewNativeTests: XCTestCase {
    @MainActor func testPDFWorkerTransfersAReadableDocumentToItsMainActorOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("one-page.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(bounds)
        context.endPDFPage()
        context.closePDF()
        let owner = await NativePDFDocument.load(url: url)
        MainActor.preconditionIsolated()
        let document = try XCTUnwrap(owner.document)
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertFalse(document.isLocked)
        XCTAssertEqual(document.documentURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNotNil(document.page(at: 0))
    }

    @MainActor func testPDFWorkerRejectsMissingAndUnreadableFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.pdf")
        try Data("This is not a PDF".utf8).write(to: corrupt)
        for url in [root.appendingPathComponent("missing.pdf"), corrupt] {
            let owner = await NativePDFDocument.load(url: url)
            MainActor.preconditionIsolated()
            XCTAssertNil(owner.document, url.lastPathComponent)
        }
    }

    func fixture(_ data: Data = Data("# Sample\n".utf8)) throws -> (URL, Record) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.md"); try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, Record(values: ["id": "attachment", "project_id": "project", "task_id": "ticket", "target_manifest_id": "round-two", "name": "sample.md", "sha256": digest, "size": data.count, "origin": "agent", "author": "source-author", "availability": "available", "mode": "managed"]))
    }
    func testVerifiedReadCopiesAndNeverChangesOriginal() throws {
        let (url, record) = try fixture()
        let file = try AuthorizedPreviewFile.copy(path: url.path, source: record)
        XCTAssertNotEqual(file.url, url); XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: url))
        XCTAssertEqual(file.sha256, record.string("sha256"))
        let copy = try file.externalWorkingCopy(baseDirectory: url.deletingLastPathComponent())
        try Data("edited".utf8).write(to: copy)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Sample\n")
        let provenance = try JSONSerialization.jsonObject(with: Data(contentsOf: copy.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".checklist-source.json"))) as! [String: Any]
        XCTAssertEqual(provenance["attachment_id"] as? String, "attachment")
        XCTAssertEqual(provenance["source_author"] as? String, "source-author")
        XCTAssertEqual(provenance["target_manifest_id"] as? String, "round-two")
    }
    func testMissingSymlinkHashChangesAndCancellationRefusePreview() throws {
        let (url, record) = try fixture()
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: url.path + "missing", source: record))
        let link = url.deletingLastPathComponent().appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: link.path, source: record))
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: url.path, source: record, isCanceled: { true }))
        try Data("# Changed".utf8).write(to: url)
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: url.path, source: record))
    }
    func testCancellationDuringLargeCopyDoesNotProduceAUsableFile() throws {
        let (url, record) = try fixture(Data(repeating: 7, count: 16 * 1024 * 1024))
        var checks = 0
        XCTAssertThrowsError(try AuthorizedPreviewFile.copy(path: url.path, source: record, isCanceled: { checks += 1; return checks > 3 }))
        XCTAssertEqual(try Data(contentsOf: url).count, 16 * 1024 * 1024)
    }
    @MainActor func testOSAssociationDiscoveryReturnsOnlyExistingUniqueApplications() throws {
        let (url, _) = try fixture()
        let apps = NativeOpenApplications.discover(url)
        XCTAssertEqual(Set(apps.map(\.id)).count, apps.count)
        XCTAssertTrue(apps.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertLessThanOrEqual(apps.filter(\.isDefault).count, 1)
        // Empty is an honest valid result on a host with no registered handler.
    }
    func testNativeOpenCancellationKeepsErrorDomainsDistinct() {
        XCTAssertTrue(Canceled.isUserCancellation(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertTrue(Canceled.isUserCancellation(NSError(domain: NSOSStatusErrorDomain, code: Int(userCanceledErr))))
        XCTAssertFalse(Canceled.isUserCancellation(NSError(domain: "SyntheticOtherDomain", code: NSUserCancelledError)))
    }
    @MainActor func testMarkdownResourceNamesWithCanonicalAliasesStayAmbiguous() {
        let source = Record(values: ["id": "document", "project_id": "p", "task_id": "t"])
        let files = [
            Record(values: ["id": "first", "project_id": "p", "task_id": "t", "name": "é.png"]),
            Record(values: ["id": "second", "project_id": "p", "task_id": "t", "name": "e\u{301}.png"]),
            Record(values: ["id": "front", "project_id": "p", "task_id": "t", "name": "front.png"]),
            Record(values: ["id": "foreign", "project_id": "other", "task_id": "t", "name": "front.png"])
        ]
        let view = RenderedMarkdownPreview(document: .parse("![Front](front.png)"), resources: files, source: source)
        XCTAssertEqual(view.resourceMap, ["front.png": "front"])
        guard case .unavailable = MarkdownResource.resolve("é.png", image: true, attachments: view.resourceMap) else { return XCTFail("Aliases must not silently route to another original") }
    }
    @MainActor func testLoaderRequiresTheExactServiceIdentityAndReleasesItsHoldOnRefusal() async throws {
        let (url, record) = try fixture()
        let preferences = isolatedDefaults("FilePreview").preferences
        var calls: [String] = []
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: url.deletingLastPathComponent().appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: FilePreviewNoAlertSink()), requestTransport: { method, _ in
            calls.append(method)
            var reply = record.values; reply["url"] = url.path; reply["read_hold_id"] = "synthetic-hold"
            reply["task_id"] = "other-ticket"
            return method == "attachment_read" ? reply : [:]
        })
        store.connected = true
        let loader = FilePreviewLoader(); await loader.load(record, store: store)
        XCTAssertNil(loader.file); XCTAssertFalse(loader.loading); XCTAssertFalse(loader.problem.isEmpty)
        XCTAssertEqual(calls, ["attachment_read", "attachment_read_release"])
        XCTAssertFalse(calls.contains("human_request_answer")); XCTAssertFalse(calls.contains("review_record"))
    }
    @MainActor func testLoaderRequiresManagedHoldButReferencesUseTheirExistingAuthorization() async throws {
        let (url, record) = try fixture()
        let preferences = isolatedDefaults("FilePreview").preferences
        var initialReply = record.values; initialReply["url"] = url.path
        let reply = FixtureState(initialReply)
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: url.deletingLastPathComponent().appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: FilePreviewNoAlertSink()), requestTransport: { _, _ in reply.value })
        store.connected = true
        let loader = FilePreviewLoader(); await loader.load(record, store: store)
        XCTAssertNil(loader.file, "Managed originals require the service reader hold")
        reply.value["mode"] = "external_reference"
        let reference = Record(values: reply.value)
        await loader.load(reference, store: store)
        let copy = try XCTUnwrap(loader.file?.url)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: url))
        loader.cancel(); XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
    @MainActor func testLoaderReadAndReleaseErrorsSettleWithoutLosingVerifiedCopy() async throws {
        let (url, record) = try fixture()
        let preferences = isolatedDefaults("FilePreview").preferences
        let failRead = FixtureState(true)
        let store = ChecklistStore(draftJournal: LocalDraftJournal(directory: url.deletingLastPathComponent().appendingPathComponent("drafts")), preferences: preferences, restorePendingCommand: false, desktopAlerts: DesktopAlertCoordinator(sink: FilePreviewNoAlertSink()), requestTransport: { method, _ in
            if failRead.value || method == "attachment_read_release" { throw FilePreviewFailure("Synthetic peer did not reply before its read deadline.") }
            var reply = record.values; reply["url"] = url.path; reply["read_hold_id"] = "synthetic-hold"
            return reply
        })
        store.connected = true
        let loader = FilePreviewLoader()
        await loader.load(record, store: store)
        XCTAssertFalse(loader.loading); XCTAssertNil(loader.file)
        XCTAssertTrue(loader.problem.contains("Synthetic peer"))
        failRead.value = false
        await loader.load(record, store: store)
        XCTAssertFalse(loader.loading)
        XCTAssertNotNil(loader.file, "An unconfirmed release must not discard verified preview bytes")
        XCTAssertTrue(loader.problem.contains("reader hold"))
        XCTAssertTrue(loader.problem.contains("expire automatically"))
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: XCTUnwrap(loader.file).url))
    }
}

@MainActor private final class FilePreviewNoAlertSink: DesktopAlertSink {
    func authorization() async -> DesktopAlertAuthorization { .denied }
    func requestAuthorizationFromOwnerAction() async throws -> Bool { false }
    func send(_ alert: DesktopAlert) async throws { throw FilePreviewFailure("Unexpected synthetic notification") }
    func remove(_ identifiers: [String]) { }
}
