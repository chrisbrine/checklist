import Foundation
import GRDB
import CryptoKit
import Darwin
@testable import ChecklistCore

/// Test-only owned-copy preparation. No installed-root default and no connection-file access.
/// Also compiled unchanged against the BASE module for the paired control.
enum OwnedStoreBackupQualification {
    typealias Object = [String:Any]

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CoreError("QUALIFICATION_REFUSED",message) }
    }
    static func ownedRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath()
        let parent = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().deletingLastPathComponent()
        try require(root.deletingLastPathComponent() == parent && root.lastPathComponent.hasPrefix("group-key-qualification-full-"),"Use a fresh group-key-qualification-full-* clone beside IMPL.")
        return root
    }
    static func configuration(readonly: Bool = false) -> Configuration {
        var value = Configuration();value.readonly = readonly
        value.prepareDatabase {try SchemaMigrations.installStorageCollation($0)}
        return value
    }
    static func sha(_ data: Data) -> String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    static func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes])
    }

    /// Only whole JSON string prefixes at a path boundary change. Preserve every
    /// suffix and every byte outside that prefix; never reserialize a record.
    /// Current service JSON has canonical unescaped path prefixes. Refuse a
    /// different encoding rather than silently normalize unrelated bytes.
    static func replacingRoot(_ raw: Data, from: String, to: String) throws -> (Data,Int) {
        let bytes = Array(raw),old = Array(try encoded(from).dropLast()),new = Array(try encoded(to).dropLast())
        var result = Data(),index = 0,changes = 0
        while index < bytes.count {
            guard bytes[index] == 34 else {result.append(bytes[index]);index += 1;continue}
            let start = index;index += 1
            while index < bytes.count {
                if bytes[index] == 92 {index += 2;continue}
                if bytes[index] == 34 {break}
                index += 1
            }
            try require(index < bytes.count,"Unterminated record JSON string.")
            index += 1
            let token = Data(bytes[start..<index])
            guard let string = try JSONSerialization.jsonObject(with:token,options:.fragmentsAllowed) as? String else {throw CoreError("QUALIFICATION_REFUSED","Invalid record JSON string.")}
            if string == from || string.hasPrefix(from + "/") {
                try require(token.starts(with:old),"A selected path prefix is not encoded canonically; no record was normalized.")
                result.append(contentsOf:new);result.append(token.dropFirst(old.count));changes += 1
            } else {result.append(token)}
        }
        return (result,changes)
    }
    private static let witnessColumns = """
        rowid,type,CAST(data AS BLOB) AS raw,
        CAST(rowid AS TEXT)||'|'||typeof(id)||':'||hex(CAST(id AS BLOB))||'|'||
        typeof(project_id)||':'||hex(CAST(project_id AS BLOB))||'|'||
        typeof(type)||':'||hex(CAST(type AS BLOB))||'|'||
        typeof(revision)||':'||hex(CAST(revision AS BLOB))||'|'||typeof(data) AS header
        """
    private static func otherCells(_ db: Database) throws -> String {
        var digest = SHA256()
        for table in ["metadata","commands","events","cursors","sqlite_sequence"] {
            let columns = try Row.fetchAll(db,sql:"PRAGMA table_info(" + table + ")").map {$0["name"] as String}
            let selections = ["CAST(rowid AS TEXT)"] + columns.flatMap {["typeof(\"" + $0 + "\")","hex(CAST(\"" + $0 + "\" AS BLOB))"]}
            let cursor = try Row.fetchCursor(db,sql:"SELECT " + selections.joined(separator:",") + " FROM " + table + " ORDER BY rowid")
            digest.update(data:Data(table.utf8))
            while let row = try cursor.next() {for i in 0..<row.count {let bytes = Data((row[i] as String).utf8);var n = UInt64(bytes.count).bigEndian;withUnsafeBytes(of:&n) {digest.update(data:Data($0))};digest.update(data:bytes)}}
        }
        return digest.finalize().map {String(format:"%02x",$0)}.joined()
    }
    static func reroot(_ root: URL, sourceRoot: String) throws -> Object {
        try require(sourceRoot.hasPrefix("/") && !sourceRoot.hasSuffix("/") && sourceRoot != root.path,"Select the explicit original root prefix.")
        let queue = try DatabaseQueue(path:StorageBootstrap.writableURI(root.appendingPathComponent("checklist.sqlite")),configuration:configuration())
        defer {try? queue.close()}
        return try queue.write { db in
            _ = try SchemaMigrations.inspect(db)
            let original = try Row.fetchAll(db,sql:"SELECT " + witnessColumns + " FROM records ORDER BY rowid")
            let beforeOther = try otherCells(db)
            var byType:[String:Int] = [:],prefixes = 0
            for row in original {
                let raw:Data = row["raw"],id:Int64 = row["rowid"],type:String = row["type"]
                let (next,count) = try replacingRoot(raw,from:sourceRoot,to:root.path)
                if count > 0 {
                    try require(try replacingRoot(next,from:root.path,to:sourceRoot).0 == raw,"Prefix reversal changed other record bytes.")
                    try db.execute(sql:"UPDATE records SET data=CAST(? AS TEXT) WHERE rowid=?",arguments:[next,id])
                    byType[type,default:0] += 1;prefixes += count
                }
            }
            let after = try Row.fetchAll(db,sql:"SELECT " + witnessColumns + " FROM records ORDER BY rowid")
            try require(original.count == after.count,"Re-root changed the record count.")
            var beforeDigest = SHA256(),revertedDigest = SHA256()
            for (before,after) in zip(original,after) {
                let a:String = before["header"],b:String = after["header"],raw:Data = before["raw"],next:Data = after["raw"]
                try require(a.utf8.elementsEqual(b.utf8),"Re-root changed a record header or rowid.")
                let reverted = try replacingRoot(next,from:root.path,to:sourceRoot).0
                try require(reverted == raw,"A committed record has a non-prefix difference.")
                for bytes in [Data(a.utf8),raw] {var n = UInt64(bytes.count).bigEndian;withUnsafeBytes(of:&n) {beforeDigest.update(data:Data($0))};beforeDigest.update(data:bytes)}
                for bytes in [Data(b.utf8),reverted] {var n = UInt64(bytes.count).bigEndian;withUnsafeBytes(of:&n) {revertedDigest.update(data:Data($0))};revertedDigest.update(data:bytes)}
            }
            let afterOther = try otherCells(db)
            try require(beforeOther == afterOther,"Re-root changed non-record SQL cells.")
            let beforeSHA = beforeDigest.finalize().map {String(format:"%02x",$0)}.joined(),revertedSHA = revertedDigest.finalize().map {String(format:"%02x",$0)}.joined()
            return ["record_count":original.count,"changed_records_by_type":byType,"changed_records":byType.values.reduce(0,+),"changed_prefixes":prefixes,"all_record_headers_and_reversed_data_byte_identical":true,"original_record_cells_sha256":beforeSHA,"reverted_record_cells_sha256":revertedSHA,"non_record_cells_unchanged":true,"non_record_cells_sha256":beforeOther,"source_prefix":sourceRoot,"clone_prefix":root.path,"scope":"SQL cell bytes; SQLite page/WAL layout is not asserted byte-identical"]
        }
    }
    static func observation(_ root: URL) throws -> (groups:[Object],tickets:Data) {
        let queue = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration(readonly:true));defer {try? queue.close()}
        return try queue.read { db in
            let rows = try Row.fetchAll(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type IN ('group','task') ORDER BY id")
            var groups:[Object] = [],tickets:[Object] = []
            for row in rows {let envelope = try GRDBRecordEnvelopeAdapter.decode(row);if envelope.type == "group" {groups.append(envelope.object)} else {tickets.append(["id":envelope.id,"key":envelope.object["key"] ?? NSNull()])}}
            try require(try String.fetchOne(db,sql:"PRAGMA integrity_check") == "ok","Integrity check failed.")
            return (groups,try encoded(tickets))
        }
    }
    static func run(root: URL, sourceRoot: String, label: String, requireKeys: Bool) throws -> Object {
        var result:Object = ["label":label,"root":root.path,"reroot":try reroot(root,sourceRoot:sourceRoot)]
        let output = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-result.json")
        func save() throws {try encoded(result).write(to:output,options:.atomic)}
        try save()
        let before = try observation(root),start = ProcessInfo.processInfo.systemUptime
        var router:CommandRouter? = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        defer {try? router?.closeStore()}
        result["startup_seconds"] = ProcessInfo.processInfo.systemUptime - start;result["startup_succeeded"] = true
        let after = try observation(root)
        try require(before.tickets == after.tickets,"Startup changed ticket keys/count.")
        result["ticket_count"] = (try JSONSerialization.jsonObject(with:after.tickets) as! [Object]).count
        result["ticket_keys_and_count_unchanged"] = true
        for kind in ["triage","epic"] {
            let groups = after.groups.filter {$0["kind"] as? String == kind},prior = before.groups.filter {$0["kind"] as? String == kind}
            if requireKeys {try require(groups.allSatisfy {!($0["key"] as? String ?? "").isEmpty},"A group is missing its key after startup.")}
            let keys = groups.compactMap {$0["key"] as? String}.sorted {suffix($0) < suffix($1)}
            let gained = groups.filter {!($0["key"] as? String ?? "").isEmpty}.count - prior.filter {!($0["key"] as? String ?? "").isEmpty}.count
            let first:Any = keys.first as Any? ?? NSNull(),last:Any = keys.last as Any? ?? NSNull()
            result[kind] = ["count":groups.count,"gained_keys":gained,"first_key":first,"last_key":last]
        }
        try router!.closeStore();router = nil
        router = try CommandRouter(root:root,serviceLease:StorageServiceLease(root:root))
        let second = try observation(root)
        try require(try encoded(after.groups) == encoded(second.groups) && after.tickets == second.tickets,"Second startup changed group records or ticket keys.")
        result["second_start_group_records_unchanged"] = true;result["group_records_sha256"] = sha(try encoded(after.groups))
        try save()
        let files = try StorageObjectFiles(root:root)
        do {
            let budget = StorageSnapshotBudget(deadlineUptime:ProcessInfo.processInfo.systemUptime+300,canceled:{false})
            let inventory = try router!.dbQueue.read {try StorageSnapshotAuthority.inventory($0,root:root,budget:budget,retainedExists:{try files.regularOrLinkExists($0)})}
            result["inventory_object_count"] = inventory.objects.count
            result["inventory_known_file_bytes"] = inventory.objects.compactMap(\.expectedSize).reduce(0,+)
            var missing:[Object] = []
            for item in inventory.objects {if !(try files.regularOrLinkExists(item.relativePath)) {missing.append(["relative_path":item.relativePath,"authorities":item.authorities])}}
            result["missing_required_files"] = missing
        } catch {result["inventory_error"] = String(describing:error)}
        try save()
        let destination = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-backup"),command = UUID().uuidString.lowercased()
        result["backup_path"] = destination.path;result["backup_command_id"] = command
        let backupStart = ProcessInfo.processInfo.systemUptime
        do {
            let response = try router!.handle(method:"backup_create",params:["command_id":command,"path":destination.path],caller:Caller(role:"owner",installation:"owned-store-backup-qualification",projectIDs:[]))
            result["backup_seconds"] = ProcessInfo.processInfo.systemUptime - backupStart;result["backup_response"] = response
            let bytes = try Data(contentsOf:destination.appendingPathComponent("manifest.json")),manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
            result["manifest_sha256"] = sha(bytes);result["manifest_schema"] = manifest.schema
            result["manifest_object_count"] = manifest.objects.count;result["manifest_object_bytes"] = manifest.objects.map(\.size).reduce(0,+)
            result["manifest_database_bytes"] = manifest.databaseSize;result["manifest_unavailable_count"] = manifest.unavailable.count
            result["manifest_external_reference_count"] = manifest.externalReferences.count
            let verifyStart = ProcessInfo.processInfo.systemUptime
            let verified = try StorageSnapshot.reconcile(parent:destination.deletingLastPathComponent(),operation:UUID(uuidString:manifest.operationID)!,publicationName:destination.lastPathComponent,budget:.init(deadlineUptime:ProcessInfo.processInfo.systemUptime+300,canceled:{false}))
            try require(verified.manifestSHA256 == sha(bytes),"Independent reconcile returned a different manifest digest.")
            result["verification_seconds"] = ProcessInfo.processInfo.systemUptime - verifyStart;result["backup_verified"] = true
        } catch {
            result["backup_seconds"] = ProcessInfo.processInfo.systemUptime - backupStart
            result["backup_verified"] = false;result["backup_error"] = String(describing:error);result["backup_error_type"] = String(reflecting:type(of:error))
            if let error = error as? CoreError {result["backup_error_details"] = error.dictionary}
        }
        try save();try router!.closeStore();router = nil
        print("OWNED_STORE_BACKUP_QUALIFICATION " + output.path)
        return result
    }
    /// Pure diagnosis after a failed ordinary backup. Larger metadata-only
    /// ceilings expose the real inventory; they never reach backup_create.
    static func diagnoseInventory(_ root: URL) throws -> Object {
        let started = ProcessInfo.processInfo.systemUptime,files = try StorageObjectFiles(root:root)
        var budget = StorageSnapshotBudget(deadlineUptime:started+300,canceled:{false})
        budget.maximumRecords = 1_000_000;budget.maximumObjects = 1_000_000
        budget.maximumBytes = 1_099_511_627_776;budget.maximumObjectBytes = 1_099_511_627_776
        let queue = try DatabaseQueue(path:root.appendingPathComponent("checklist.sqlite").path,configuration:configuration(readonly:true));defer {try? queue.close()}
        let inventory = try queue.read {try StorageSnapshotAuthority.inventory($0,root:root,budget:budget,retainedExists:{try files.regularOrLinkExists($0)})}
        let ordinary = StorageSnapshotBudget(deadlineUptime:started+300,canceled:{false})
        var missing:[Object] = [],mismatches:[Object] = [],oversized:[Object] = [],byFamily:[String:Int] = [:],bytes:Int64 = 0
        for item in inventory.objects {
            try budget.check()
            byFamily[String(item.relativePath.split(separator:"/")[0]),default:0] += 1
            let directory:Int32,name:String
            do {(directory,name) = try files.parent(item.relativePath)}
            catch {if errno == ENOENT {missing.append(["relative_path":item.relativePath,"authorities":item.authorities]);continue};throw error}
            var info = stat();let status = fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW);Darwin.close(directory)
            if status != 0 {if errno == ENOENT {missing.append(["relative_path":item.relativePath,"authorities":item.authorities]);continue};throw StorageSnapshotFailure.io}
            let expectedMode:mode_t = item.kind == "file" ? S_IFREG : S_IFLNK
            if info.st_mode & S_IFMT != expectedMode || item.expectedSize.map({$0 != info.st_size}) == true {mismatches.append(["relative_path":item.relativePath,"actual_size":info.st_size,"expected_size":item.expectedSize as Any? ?? NSNull()])}
            bytes += info.st_size
            if info.st_size > ordinary.maximumObjectBytes {oversized.append(["relative_path":item.relativePath,"bytes":info.st_size])}
        }
        var result:Object = ["diagnostic_only":true,"ordinary_limits_unchanged":true,"objects":inventory.objects.count,"objects_by_family":byFamily,"logical_object_bytes":bytes,"unavailable_count":inventory.unavailable.count,"external_reference_count":inventory.externalReferences.count,"missing_required_files":missing,"size_or_kind_mismatches":mismatches,"objects_over_ordinary_individual_limit":oversized,"ordinary_maximum_objects":ordinary.maximumObjects,"ordinary_maximum_bytes":ordinary.maximumBytes,"ordinary_maximum_object_bytes":ordinary.maximumObjectBytes,"inventory_exceeds_ordinary_object_count":inventory.objects.count > ordinary.maximumObjects,"object_bytes_exceed_ordinary_total_limit":bytes > ordinary.maximumBytes,"seconds":ProcessInfo.processInfo.systemUptime-started,"content_hashes_reverified":false]
        let receiptPath = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-result.json")
        if let receipt = try JSONSerialization.jsonObject(with:Data(contentsOf:receiptPath)) as? Object,let command = receipt["backup_command_id"] as? String {
            let owner = Caller(role:"owner",installation:"owned-store-backup-qualification",projectIDs:[])
            let key = "storage-command:" + sha(try encoded(["principal":owner.principal,"command_id":command]))
            if let raw = try queue.read({try String.fetchOne($0,sql:"SELECT value FROM metadata WHERE key=?",arguments:[key])}),let pending = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? Object,let operation = pending["operation_id"] as? String,let id = UUID(uuidString:operation) {
                let stageName = StorageSnapshot.names(id).staging,stageURL = root.deletingLastPathComponent().appendingPathComponent(stageName),stage = try StorageObjectFiles(root:stageURL)
                let paths = try stage.listedFiles(budget:budget)
                var total:Int64 = 0,managed:Int64 = 0,database:Int64 = 0
                for path in paths {
                    let (directory,name) = try stage.parent(path);var info = stat();let status = fstatat(directory,name,&info,AT_SYMLINK_NOFOLLOW);Darwin.close(directory)
                    try require(status == 0,"Could not inspect the retained incomplete backup stage.")
                    total += info.st_size;if path.hasPrefix("managed/") {managed += info.st_size};if path == "database.sqlite" {database = info.st_size}
                }
                result["partial_backup_stage"] = ["name":stageName,"files":paths.sorted(),"manifest_produced":paths.contains("manifest.json"),"managed_object_count":paths.filter {$0.hasPrefix("managed/")}.count,"managed_object_bytes":managed,"database_bytes":database,"total_file_bytes":total]
            }
        }
        return result
    }
    private static func suffix(_ key:String) -> Int {Int(key.split(separator:"-").last?.dropFirst() ?? "") ?? 0}
}
