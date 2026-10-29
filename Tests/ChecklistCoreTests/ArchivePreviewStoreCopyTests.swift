import ChecklistTestSupport
import XCTest
import GRDB
@testable import ChecklistCore

/// Opt-in only: the path must name an owned qualification copy, never the installed store.
final class ArchivePreviewStoreCopyTests: XCTestCase {
    func testCL24PreviewOnOwnedStoreCopy() throws {
        try QualificationSuite.requireEnabled()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CHECKLIST_CL150_STORE_COPY"] else { throw XCTSkip("Set CHECKLIST_CL150_STORE_COPY to an owned store copy.") }
        let root = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        let caches = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:false).resolvingSymlinksInPath()
        guard root.path.hasPrefix(caches.appendingPathComponent("ChecklistQualification").path + "/") else { throw CoreError("QUALIFICATION_COPY_REQUIRED", "Use an owned copy under ChecklistQualification.") }
        let router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer { try? router.closeStore() }
        let owner = Caller(role:"owner",installation:"cl150-store-copy",projectIDs:[])
        let params: JSON = ["project_id":"00000000-0000-0000-0000-000000000001","task_id":"00000000-0000-0000-0000-000000000002"]
        // Time the actual command, including read-to-writer retry when a preview is first stored.
        var times: [Double] = [], previews: [String] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try router.handle(method:"attachment_cleanup_preview",params:params,caller:owner)
            times.append(ProcessInfo.processInfo.systemUptime - start)
            previews.append(try jsonString(try XCTUnwrap(result["data"] as? JSON)))
        }
        XCTAssertTrue(previews.allSatisfy { $0 == previews[0] }, "Full preview must remain identical across observations")
        if let expected = env["CHECKLIST_CL150_EXPECTED_PREVIEW"] { XCTAssertEqual(previews[0],try String(contentsOfFile:expected,encoding:.utf8)) }
        if let output = env["CHECKLIST_CL150_WRITE_PREVIEW"] { try previews[0].write(toFile:output,atomically:true,encoding:.utf8) }
        print("CL-150 owned copy preview seconds=\(times) median=\(times.sorted()[2]); stored absolute paths differ from the live store")
        if env["CHECKLIST_CL150_REQUIRE_FAST"] == "1" { XCTAssertLessThan(times.sorted()[2],0.5) }
        // Separate profiling of the retained reference path; not included in command samples.
        try router.dbQueue.read { db in
            let task = try router.scoped(db,params["task_id"] as! String,params["project_id"] as! String,type:"task")
            let attachments = try router.scopedTaskRows(db,type:"attachment",task:task)
            let relevantStart = ProcessInfo.processInfo.systemUptime
            let relevant = try router.archiveCleanupRelevantReferenceRows(db,attachments:attachments)
            let start = ProcessInfo.processInfo.systemUptime
            print("CL-150 profile relevant rows=\(relevant.count) observation=\(start-relevantStart)s")
            let graph = try router.archiveCleanupReferenceRows(db)
            let decoded = ProcessInfo.processInfo.systemUptime
            let fullIndex = try ArchiveCleanupReferenceIndex(graph)
            print("CL-150 profile rows=\(graph.count) decode=\(decoded-start)s index=\(ProcessInfo.processInfo.systemUptime-decoded)s")
            let relevantIndex = try ArchiveCleanupReferenceIndex(relevant)
            for a in attachments where !bool(a,"unlinked") {
                XCTAssertEqual(try router.completeArchiveCleanupHolds(db,attachment:a,task:task,considerArchiving:true,currentIndex:fullIndex),
                               try router.completeArchiveCleanupHolds(db,attachment:a,task:task,considerArchiving:true,currentIndex:relevantIndex),
                               a["id"] as? String ?? "attachment")
            }
        }
    }
}
