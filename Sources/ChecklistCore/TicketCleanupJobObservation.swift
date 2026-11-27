import Foundation
import GRDB

/// Selected-ticket accounting only, built and consumed in one read snapshot.
/// Full job payloads are validated once and discarded; no history is truncated
/// to infer that a ticket has no pending or previously retained objects.
struct TicketCleanupJobObservation {
    struct Limits {
        var rowBytes = TicketCleanupInventory.rowByteLimit
        var ticketJobs = 4096
        var ticketObjects = 100000
        var ticketBytes = TicketCleanupInventory.byteLimit
        var totalObjects = 200000
        var totalBytes = TicketCleanupBatchInventory.byteLimit
    }
    fileprivate struct Signature: Hashable {
        let path: String?
        let sha: String?
        let reasons: [String]
        init(_ object: JSON) {
            path = object["stored_path"] as? String
            sha = object["sha256"] as? String
            reasons = strings(object,"reasons")
        }
        var charge: Int {
            (path?.utf8.count ?? 0) + (sha?.utf8.count ?? 0) + reasons.reduce(0) {$0 + $1.utf8.count + 32} + 256
        }
    }
    struct Entry {
        fileprivate let project: Data
        fileprivate var retained = Set<Signature>()
        fileprivate var jobs = 0
        fileprivate var bytes = 0
        fileprivate(set) var pending = false
        func retains(_ object: JSON) -> Bool {retained.contains(Signature(object))}
    }
    private var entries: [Data:Entry] = [:]
    private var selectionError: CoreError?
    private var errors: [Data:CoreError] = [:]
    private var retainedObjects = 0
    private var retainedBytes = 0

    func entry(task: String,project: String) throws -> Entry {
        if let selectionError {throw selectionError}
        let key = Data(task.utf8)
        if let error = errors[key] {throw error}
        guard let entry = entries[key],entry.project == Data(project.utf8) else {
            throw Self.limit("A same-snapshot, exact-ticket job observation is required.")
        }
        return entry
    }
    private static func limit(_ message: String) -> CoreError {CoreError("CLEANUP_INVENTORY_LIMIT",message)}
    fileprivate mutating func fail(_ tasks: Set<Data>,message: String = "Selected cleanup job history exceeds its bound; this ticket is deferred.") {
        for task in tasks where errors[task] == nil {
            errors[task] = Self.limit(message)
            if let entry = entries.removeValue(forKey:task) {
                retainedObjects -= entry.retained.count;retainedBytes -= entry.bytes
            }
        }
    }
    fileprivate mutating func observe(_ db: Database,_ job: JSON,project: Data,limits: Limits) {
        guard job["cause"] as? String == "done_evidence",let task = job["task_id"] as? String else {return}
        let key = Data(task.utf8)
        guard var entry = entries[key],entry.project == project else {return}
        entry.jobs += 1
        guard entry.jobs <= limits.ticketJobs else {fail([key]);return}
        entry.pending = entry.pending || job["state"] as? String == "pending"
        func observeObject(_ object: JSON) throws {
            guard object["state"] as? String == "retained" else {return}
            let signature = Signature(object)
            guard !entry.retained.contains(signature) else {return}
            let charge = signature.charge
            guard entry.retained.count < limits.ticketObjects,entry.bytes + charge <= limits.ticketBytes,
                  retainedObjects < limits.totalObjects,retainedBytes + charge <= limits.totalBytes else {
                throw Self.limit("Selected cleanup job history exceeds its bound; this ticket is deferred.")
            }
            entry.retained.insert(signature);entry.bytes += charge
            retainedObjects += 1;retainedBytes += charge
        }
        do {
            if job["descriptor_page_generation"] is String {
                try CommandRouter.visitTicketObjectDeletionObjects(db,receipt:job,observeObject)
            } else {
                for object in job["objects"] as? [JSON] ?? [] {try observeObject(object)}
            }
            entries[key] = entry
        } catch {
            // Publish the local charges before releasing the refused ticket.
            // Missing pages cannot be read as an empty history.
            entries[key] = entry;fail([key])
        }
    }

    fileprivate init(tasks: [JSON],limits: Limits) throws {
        guard tasks.count <= 32 else {throw CoreError("PURGE_LIMIT","Cleanup selects at most 32 tickets per observation.")}
        for task in tasks {
            let stored = StoredRecord(task,family:"task"),tid = Data(try stored.string("id").utf8),pid = Data(try stored.string("project_id").utf8)
            if let previous = entries[tid] {
                guard previous.project == pid else {throw Self.limit("A selected ticket has inconsistent job scope.")}
                continue
            }
            let charge = tid.count + pid.count + 192
            guard charge <= limits.ticketBytes,charge <= limits.rowBytes,retainedBytes + charge <= limits.totalBytes else {
                selectionError = Self.limit("Selected cleanup job identities exceed their memory bound; this selection is deferred.")
                entries.removeAll();retainedBytes = 0;break
            }
            entries[tid] = Entry(project:pid,bytes:charge);retainedBytes += charge
        }
    }
    fileprivate var scopes: [Data:Set<Data>] {
        entries.reduce(into:[:]) {$0[$1.value.project,default:[]].insert($1.key)}
    }
}

extension CommandRouter {
    func ticketCleanupJobObservation(_ db: Database,tasks: [JSON],limits: TicketCleanupJobObservation.Limits = .init()) throws -> TicketCleanupJobObservation {
        var result = try TicketCleanupJobObservation(tasks:tasks,limits:limits)
        let scopes = result.scopes
        for project in scopes.keys.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
            // octet_length reads the size of a column without loading its payload.
            let bounded = "CASE WHEN octet_length(data)<=\(limits.rowBytes) THEN data END"
            let id = "CASE WHEN octet_length(data)<=\(limits.rowBytes) OR octet_length(id)<=\(TicketCleanupJobOwner.fieldLimit) THEN id END"
            let sql = """
                SELECT rowid,\(id) AS id,typeof(id) AS id_type,project_id,type,revision,\(bounded) AS data,
                    CAST(\(id) AS BLOB) AS _envelope_id_bytes,CAST(project_id AS BLOB) AS _envelope_project_id_bytes,
                    CAST(type AS BLOB) AS _envelope_type_bytes,CAST(\(bounded) AS BLOB) AS _envelope_data_bytes,
                    octet_length(data) AS original_size,typeof(data) AS original_type
                FROM records INDEXED BY records_scope WHERE project_id=CAST(? AS TEXT) AND type='storage_job' ORDER BY rowid
                """
            let cursor = try Row.fetchCursor(db,sql:sql,arguments:[project])
            let selected = scopes[project] ?? []
            while let row = try cursor.next() {
                try autoreleasepool {
                    let text = row["original_type"] as String == "text"
                    guard let size: Int = row["original_size"],size <= limits.rowBytes else {
                        let task = text ? TicketCleanupJobOwner.task(db,row:row,project:project) : nil
                        let affected = task.map {selected.intersection([$0])} ?? selected
                        result.fail(affected,message:"A cleanup job exceeds the \(limits.rowBytes)-byte payload bound; this ticket is deferred.")
                        return
                    }
                    guard text else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.sqlData))}
                    let envelope = try GRDBRecordEnvelopeAdapter.decode(row,expectedType:"storage_job")
                    guard envelope.projectID.map({Data($0.utf8)}) == project else {throw GRDBRecordEnvelopeAdapter.failure(EnvelopeFailure(.identityMismatch))}
                    result.observe(db,envelope.object,project:project,limits:limits)
                }
            }
        }
        return result
    }
}
