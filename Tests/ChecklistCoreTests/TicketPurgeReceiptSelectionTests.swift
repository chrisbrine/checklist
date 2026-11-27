import XCTest
import Foundation
import GRDB
@testable import ChecklistCore

final class TicketPurgeReceiptSelectionTests: XCTestCase {
    func testCL520ReceiptSelectorsAgainstOldManualSelection() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),router = f.router!
        let projectID = try XCTUnwrap(project["id"] as? String),taskID = try XCTUnwrap(task["id"] as? String)
        let foreignProject = uuid()
        var unchanged = Set<String>(),keptNow = Set<String>(),retiredNow = Set<String>(),fixtureIDs = Set<String>()
        try router.dbQueue.write {db in
            func insert(_ payload: String,method: String?,scope: String?,error: Bool = false,legacyOwnerPreview: Bool = false) throws -> String {
                let command = uuid(),operationID = CommandRouter.commandOperationID(principal:f.owner.principal,command:command)
                let receiptID = error ? CommandRouter.commandOperationID(principal:f.owner.principal,command:"error:" + operationID) : command
                let digest = ChecklistCore.hash(Data(command.utf8))
                if let method {
                    var operation: JSON = ["operation_id":operationID,"command_id":command,"principal":f.owner.principal,
                        "digest":digest,"method":method,"state":error ? "failed" : "succeeded","incarnation":router.incarnation]
                    operation["project_id"] = scope
                    if error {operation["error_result_command_id"] = receiptID}
                    if legacyOwnerPreview {operation["caller"] = ["role":"owner"]}
                    try router.saveOperation(db,operation)
                }
                let receiptDigest = error ? ChecklistCore.hash(Data(("operation-error:" + digest).utf8)) : digest
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",
                    arguments:[f.owner.principal,receiptID,receiptDigest,payload])
                fixtureIDs.insert(receiptID)
                return receiptID
            }

            // Exercise values, dictionary keys, embedded text, and absent IDs
            // in each scope. Ordinary successful replies still need an exact ID.
            let payloads: [(Any,Bool)] = [
                (["rows":[["task_id":taskID]]],true), (["rows":[[taskID:"exact key"]]],true),
                (["text":"Private text mentioning " + taskID],false), (["ids":[uuid(),uuid()]],false),
            ]
            for scope in [projectID,foreignProject,nil] {
                for (payload,exact) in payloads {
                    let raw = try jsonString(payload)
                    for method: String? in [nil,"attachment_cleanup_preview","import_preview"] {
                        let id = try insert(raw,method:method,scope:scope)
                        if exact || method == "import_preview" {unchanged.insert(id)}
                    }
                    let error = try insert(raw,method:"attachment_cleanup_preview",scope:scope,error:true)
                    if scope == foreignProject && !exact {keptNow.insert(error)}
                    else {unchanged.insert(error)}
                }
            }
            let large = String(repeating:"x",count:TicketCleanupInventory.rowByteLimit)
            for (scope,exact) in [(projectID,false),(foreignProject,true),(foreignProject,false)] {
                let raw = try jsonString(["text":large,"notes":[exact ? taskID : uuid()]])
                let id = try insert(raw,method:"media_intake_confirm",scope:scope)
                if scope == foreignProject && !exact {keptNow.insert(id)}
                else {unchanged.insert(id)}
            }
            let largeKey = try insert(try jsonString(["text":large,"notes":[taskID:"exact key"]]),method:"media_intake_confirm",scope:foreignProject)
            unchanged.insert(largeKey)
            let invalid = try insert("invalid JSON",method:nil,scope:nil)
            retiredNow.insert(invalid)
            let oldOwnerPreview = try insert(try jsonString(["error":["message":"Legacy selected source is unknown"]]),
                method:"media_intake_preview",scope:foreignProject,error:true,legacyOwnerPreview:true)
            unchanged.insert(oldOwnerPreview)
        }
        try router.readers!.read {db in
            let plan = try router.ticketPurgePlan(db,task:task)
            func ids(_ rows: [Row]) -> Set<String> {Set(rows.map {$0["command_id"] as String}).intersection(fixtureIDs)}
            let old = try ids(oldManualSelector(db,task:task,plan:plan))
            let manual = try ids(router.ticketPurgeExpiringCommands(db,task:task,plan:plan))
            let automatic = try router.ticketPurgeExpiringCommands(db,tasks:[task],plans:[taskID:plan])
            XCTAssertTrue(automatic.errors.isEmpty)
            XCTAssertEqual(old,unchanged.union(keptNow))
            XCTAssertEqual(manual,unchanged.union(retiredNow))
            XCTAssertEqual(ids(automatic.commands[taskID] ?? []),manual)
        }
    }

    func testCL520ExactReceiptReferenceSurvivesCanonicallyEquivalentDictionaryKeys() throws {
        let f = try StorageFixture(fast:true),project = try f.project(),task = try f.task(project),router = f.router!
        let taskID = try XCTUnwrap(task["id"] as? String)
        let command = uuid(),other = uuid(),retained = uuid()
        // JSONSerialization preserves both byte spellings in NSDictionary.
        // Bridging this nested object into a Swift dictionary loses a key.
        let payloads = [
            command: #"{"rows":[{"é":"\#(taskID)","e\u0301":"\#(other)"}]}"#,
            retained: #"{"rows":[{"é":"not-\#(taskID)","e\u0301":"\#(other)"}]}"#,
        ]
        try router.dbQueue.write {db in
            for (id,payload) in payloads {
                try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",arguments:[f.owner.principal,id,"fixture",payload])
            }
        }
        try router.readers!.read {db in
            let plan = try router.ticketPurgePlan(db,task:task)
            let selected = try router.ticketPurgeExpiringCommands(db,task:task,plan:plan)
            let ids = Set(selected.map {$0["command_id"] as String})
            XCTAssertTrue(ids.contains(command))
            XCTAssertFalse(ids.contains(retained))
        }
    }

    // The previous manual selector from a928e8b, with the router qualified for this fixture.
    private func oldManualSelector(_ db: Database,task: JSON,plan: TicketPurgePlan) throws -> [Row] {
        let removedIDs = Set(plan.removed.map(\.key)).union([Data(((try StoredRecord(task, family: "task").string("id"))).utf8)])
        let keys = try jsonString(removedIDs.map {String(decoding:$0,as:UTF8.self)})
        let columns = """
            rowid AS cleanup_row,principal,command_id,CAST(principal AS BLOB) AS cleanup_principal,
            CAST(command_id AS BLOB) AS cleanup_command_id,length(CAST(result AS BLOB)) AS result_bytes
            """
        var selected: [Row] = [],positions = Set<Int64>(),bytes = 0
        func admit(_ row: Row,bytes charge: Int) throws {
            let position: Int64 = row["cleanup_row"]
            guard !positions.contains(position) else {return}
            guard selected.count < CommandRouter.ticketCleanupSelectedHistoryRowLimit else {throw CommandRouter.ticketCleanupSelectedHistoryLimit(commands:true)}
            bytes += charge
            guard bytes <= TicketCleanupInventory.byteLimit else {throw CoreError("CLEANUP_INVENTORY_LIMIT","Selected command results exceed the 16 MiB cleanup bound.")}
            positions.insert(position);selected.append(row.copy())
        }
        func admitPrivateReceipt(principal: Data,command: Data) throws {
            if let row = try Row.fetchOne(db,sql:"SELECT " + columns + " FROM commands WHERE principal=CAST(? AS TEXT) AND command_id=CAST(? AS TEXT) AND result<>?",arguments:[principal,command,CommandRouter.prunedResult]) {
                try admit(row,bytes:min(row["result_bytes"] as Int,TicketCleanupInventory.rowByteLimit))
            }
        }
        // Import previews contain source IDs and operation errors can contain
        // private text without a ticket ID. Expire their live cached results.
        // Stream metadata and admit only receipts that still need scrubbing.
        let operations = try Row.fetchCursor(db,sql:"""
            SELECT CAST(json_extract(value,'$.principal') AS BLOB) AS principal,
                   CAST(json_extract(value,'$.command_id') AS BLOB) AS command,
                   CAST(json_extract(value,'$.error_result_command_id') AS BLOB) AS error_command,
                   json_extract(value,'$.method') AS method
            FROM metadata WHERE key GLOB 'command-operation:*'
              AND CASE WHEN json_valid(value) THEN
                json_extract(value,'$.method')='import_preview' OR json_type(value,'$.error_result_command_id')='text'
              ELSE 0 END
            """)
        while let row = try operations.next() {
            try autoreleasepool {
                guard let principal = row["principal"] as Data?,let command = row["command"] as Data? else {throw StoreRecovery.required("command_operation_invalid")}
                if row["method"] as String? == "import_preview" {try admitPrivateReceipt(principal:principal,command:command)}
                if let error = row["error_command"] as Data? {try admitPrivateReceipt(principal:principal,command:error)}
            }
        }
        let receipts = try Row.fetchCursor(db,sql:"SELECT " + columns + """
            , CASE WHEN length(CAST(result AS BLOB))<=? THEN result END AS result
            FROM commands WHERE result<>?
            """,arguments:[TicketCleanupInventory.rowByteLimit,CommandRouter.prunedResult])
        func containsRemoved(_ value: Any) -> Bool {
            if let s = value as? String {return removedIDs.contains(Data(s.utf8))}
            if let a = value as? [Any] {return a.contains {containsRemoved($0)}}
            if let d = value as? JSON {return d.contains {removedIDs.contains(Data($0.key.utf8)) || containsRemoved($0.value)}}
            return false
        }
        while let row = try receipts.next() {
            try autoreleasepool {
                let position: Int64 = row["cleanup_row"]
                guard !positions.contains(position) else {return}
                if let result: String = row["result"] {
                    if containsRemoved(jsonObject(result)) {try admit(row,bytes:row["result_bytes"])}
                    return
                }
                // Larger operation receipts can be expired by identity without
                // ever copying their private payload across the SQL boundary.
                let operation = try Bool.fetchOne(db,sql:"""
                    SELECT EXISTS(SELECT 1 FROM metadata WHERE key GLOB 'command-operation:*'
                      AND CASE WHEN json_valid(value) THEN
                        CAST(json_extract(value,'$.principal') AS BLOB)=? AND
                        (CAST(json_extract(value,'$.command_id') AS BLOB)=? OR
                         CAST(json_extract(value,'$.error_result_command_id') AS BLOB)=?) AND
                        json_type(value,'$.method')='text'
                      ELSE 0 END)
                    """,arguments:[row["cleanup_principal"] as Data,row["cleanup_command_id"] as Data,row["cleanup_command_id"] as Data]) == true
                if operation {try admit(row,bytes:0);return}
                let matches = try CommandRouter.ticketCleanupMatchingPayloadKeys(db,payloadSQL:"SELECT result AS payload FROM commands WHERE rowid=?",position:position,keys:keys)
                guard matches?.isEmpty == true else {throw CoreError("CLEANUP_INVENTORY_LIMIT","A selected command result exceeds the 4 MiB payload bound.")}
            }
        }
        return selected.sorted {($0["cleanup_row"] as Int64) < ($1["cleanup_row"] as Int64)}
    }
}
