import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

/// Opt-in, in-process qualification. Caller supplies a fresh owned copy, never the reference/live store.
final class GroupKeyStoreCopyTests: XCTestCase {
    func testInspectCompleteOwnedStoreInventory() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_GROUP_KEY_INVENTORY_COPY"] else {throw XCTSkip("Requires an explicitly selected already re-rooted owned clone.")}
        let root = try OwnedStoreBackupQualification.ownedRoot(path),result = try OwnedStoreBackupQualification.diagnoseInventory(root)
        let output = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-inventory.json")
        try OwnedStoreBackupQualification.encoded(result).write(to:output)
        print("OWNED_STORE_INVENTORY " + output.path)
        XCTAssertTrue((result["missing_required_files"] as! [[String:Any]]).isEmpty,"Exact missing paths are in the inventory receipt; no file was removed.")
        XCTAssertTrue((result["size_or_kind_mismatches"] as! [[String:Any]]).isEmpty,"Exact mismatches are in the inventory receipt; no file was changed.")
    }
    func testBackupAfterBackfillOnCompleteOwnedStoreCopy() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CHECKLIST_GROUP_KEY_FULL_STORE_COPY"] else {throw XCTSkip("Requires an explicitly cloned complete owned store.")}
        guard let prefix = environment["CHECKLIST_GROUP_KEY_SOURCE_ROOT"] else {throw CoreError("QUALIFICATION_REFUSED","Set the explicit original root prefix for the owned copy.")}
        let result = try OwnedStoreBackupQualification.run(root:OwnedStoreBackupQualification.ownedRoot(path),sourceRoot:prefix,label:"IMPL",requireKeys:true)
        XCTAssertEqual(result["backup_verified"] as? Bool,true,"Backup failure is recorded in the clone's -result.json; do not repair unrelated storage code when BASE has the same failure.")
    }

    func testStartupBackfillOnOwnedStoreCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["CHECKLIST_GROUP_KEY_STORE_COPY"] else {throw XCTSkip("Requires an owned disposable store copy.")}
        let root = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        let allowed = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == allowed,root.lastPathComponent.hasPrefix("group-key-qualification-") else {throw CoreError("QUALIFICATION_COPY_REQUIRED","Use an explicitly copied group-key-qualification-* folder beside this checkout.")}
        var config = Configuration();config.readonly = true;config.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        func observation() throws -> (groups:[JSON],tickets:String) {
            let q = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:config);defer {try? q.close()}
            return try q.read { db in
                let rows = try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type IN ('group','task') ORDER BY id")
                var groups:[JSON] = [],tickets:[JSON] = []
                for row in rows {let e = try GRDBRecordEnvelopeAdapter.decode(row);if e.type == "group" {groups.append(e.object)} else {tickets.append(["id":e.id,"key":e.object["key"] ?? NSNull()])}}
                XCTAssertEqual(try String.fetchOne(db,sql:"PRAGMA integrity_check"),"ok")
                return (groups,try jsonString(tickets))
            }
        }
        let before = try observation(),start = ProcessInfo.processInfo.systemUptime
        var router:CommandRouter? = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let after = try observation();XCTAssertEqual(before.tickets,after.tickets)
        var result:JSON = ["startup_succeeded":true,"startup_seconds":seconds,"ticket_keys_and_count_unchanged":before.tickets == after.tickets,"ticket_count":(try JSONSerialization.jsonObject(with:Data(before.tickets.utf8)) as! [JSON]).count,"schema_user_version":2]
        for kind in ["triage","epic"] {
            let old = before.groups.filter {$0["kind"] as? String == kind},groups = after.groups.filter {$0["kind"] as? String == kind}.sorted {intSuffix($0["key"] as? String ?? "") < intSuffix($1["key"] as? String ?? "")}
            XCTAssertTrue(groups.allSatisfy {!($0["key"] as? String ?? "").isEmpty})
            result[kind] = ["count":groups.count,"backfilled":old.filter {($0["key"] as? String ?? "").isEmpty}.count,"first_key":groups.first?["key"] ?? NSNull(),"last_key":groups.last?["key"] ?? NSNull()]
        }
        try router!.closeStore();router = nil
        router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        let second = try observation();XCTAssertEqual(try jsonString(after.groups),try jsonString(second.groups));XCTAssertEqual(after.tickets,second.tickets)
        result["second_start_group_records_unchanged"] = true
        result["group_records_sha256"] = ChecklistCore.hash(Data(try jsonString(after.groups).utf8))
        // The supplied copy may omit retained captures/absolute managed authorities.
        // Do not fabricate them or read the installed store to repair qualification.
        do {
            let backup = try router!.handle(method:"backup_create",params:["command_id":uuid(),"path":root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-backup").path],caller:Caller(role:"owner",installation:"group-key-qualification",projectIDs:[]))
            result["backup_after_backfill"] = backup
        } catch { result["backup_after_backfill_error"] = String(describing:error) }
        try router!.closeStore();router = nil
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:allowed.appendingPathComponent("group-key-qualification.json"))
        print("GROUP_KEY_QUALIFICATION " + (try jsonString(result)))
    }
}
private func intSuffix(_ key:String) -> Int {Int(key.split(separator:"-").last?.dropFirst() ?? "") ?? 0}
