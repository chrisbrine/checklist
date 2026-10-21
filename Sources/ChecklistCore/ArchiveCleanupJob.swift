import Foundation
import CoreFoundation

enum ArchiveCleanupJobError: Error { case invalid, stale, terminal, grace, overflow }

/// Durable job data, not deletion authority. No path, caller or filesystem action.
struct ArchiveCleanupOriginal {
    let id: ArchiveAttachmentID
    let sha256: String
    let logicalBytes: Int64
    let attachmentRevision: Int64
    init(id: String,sha256: String,logicalBytes: Int64,attachmentRevision: Int64) throws {
        guard sha256.utf8.count == 64,sha256.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),logicalBytes >= 0,attachmentRevision > 0 else {throw ArchiveCleanupJobError.invalid}
        self.id = try ArchiveAttachmentID(id);self.sha256 = sha256;self.logicalBytes = logicalBytes;self.attachmentRevision = attachmentRevision
    }
}

struct ArchiveCleanupJob {
    enum State: String { case queued, held, ready, suspended, canceled, completed }
    enum ItemState: String { case waiting, held, ready, suspended, canceled, removed, alreadyMissing = "already_missing" }
    enum Hold: String, CaseIterable, Hashable {
        case keepOriginal, activeWork, activeVerification, pendingHumanInspection, currentReview, activeReader, backupCapture, sharedLiveReference, activeBuild
        case referenceGraphUnavailable, originalUnavailable, externalOriginal, changedIdentity, policyNoLongerSelects, pendingImport
    }
    enum Failure: String { case admissionUnavailable, metadataUnavailable, identityChanged }
    struct Item {
        let original: ArchiveCleanupOriginal
        var state: ItemState = .waiting
        var holds: Set<Hold> = []
        var failure: Failure?
        var sameFailureCount = 0
        var terminal: Bool { [.canceled,.removed,.alreadyMissing].contains(state) }
    }
    /// Facts may only come from a later authoritative current service adapter.
    /// Constructing this value authenticates nothing and grants no deletion.
    struct Admission {
        let projectID: ArchiveAttachmentID
        let taskID: ArchiveAttachmentID
        let original: ArchiveCleanupOriginal
        let referencesComplete: Bool
        let holds: Set<Hold>
    }
    static let maximumItems = 256
    static let admissionStepLimit = 8
    let id: ArchiveAttachmentID
    let projectID: ArchiveAttachmentID
    let taskID: ArchiveAttachmentID
    let taskRevision: Int64
    let settingsRevision: Int64
    let previewID: ArchiveAttachmentID
    let planDigest: String
    let enqueuedAtMS: Int64
    private(set) var notBeforeMS: Int64
    private(set) var state: State = .queued
    private(set) var items: [Item]

    init(id: String,projectID: String,taskID: String,taskRevision: Int64,settingsRevision: Int64,previewID: String,planDigest: String,enqueuedAtMS: Int64,notBeforeMS: Int64,originals: [ArchiveCleanupOriginal]) throws {
        guard taskRevision > 0,settingsRevision > 0,enqueuedAtMS >= 0,notBeforeMS > enqueuedAtMS,!originals.isEmpty,originals.count <= Self.maximumItems,
              planDigest.utf8.count == 64,planDigest.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),Set(originals.map(\.id)).count == originals.count else {throw ArchiveCleanupJobError.invalid}
        self.id = try ArchiveAttachmentID(id);self.projectID = try ArchiveAttachmentID(projectID);self.taskID = try ArchiveAttachmentID(taskID)
        self.taskRevision = taskRevision;self.settingsRevision = settingsRevision;self.previewID = try ArchiveAttachmentID(previewID);self.planDigest = planDigest
        self.enqueuedAtMS = enqueuedAtMS;self.notBeforeMS = notBeforeMS;self.items = originals.map {Item(original:$0)}
        _ = try logicalTotals()
    }
    /// Cancel preserves already removed/missing outcomes. It cannot restore bytes.
    @discardableResult mutating func cancel() -> Bool {
        guard state != .canceled && state != .completed else {return false}
        for index in items.indices where !items[index].terminal {items[index].state = .canceled;items[index].holds = [];items[index].failure = nil;items[index].sameFailureCount = 0}
        state = .canceled;return true
    }
    /// Only explicit owner retry can reset a suspended failure. Canceled jobs never restart.
    mutating func retry(nowMS: Int64,notBeforeMS: Int64) throws {
        guard state == .suspended else {throw ArchiveCleanupJobError.terminal}
        guard nowMS >= enqueuedAtMS,notBeforeMS > nowMS else {throw ArchiveCleanupJobError.grace}
        for index in items.indices where !items[index].terminal {
            items[index].state = .waiting;items[index].holds = [];items[index].failure = nil;items[index].sameFailureCount = 0
        }
        self.notBeforeMS = notBeforeMS;state = .queued
    }
    mutating func recordFailure(id: ArchiveAttachmentID,code: Failure) throws {
        guard ![.canceled,.completed,.suspended].contains(state),let index = items.firstIndex(where: {$0.original.id == id}),!items[index].terminal else {throw ArchiveCleanupJobError.terminal}
        items[index].sameFailureCount = items[index].failure == code ? min(2,items[index].sameFailureCount + 1) : 1
        items[index].failure = code;items[index].state = items[index].sameFailureCount == 2 ? .suspended : .held
        items[index].holds = [.referenceGraphUnavailable]
        recomputeState()
    }
    /// Only the descriptor-gated executor records a physical observation.
    mutating func recordDeletion(id: ArchiveAttachmentID,alreadyMissing: Bool) throws {
        guard ![.canceled,.completed,.suspended].contains(state),let index = items.firstIndex(where: {$0.original.id == id}),items[index].state == .ready else {throw ArchiveCleanupJobError.terminal}
        items[index].state = alreadyMissing ? .alreadyMissing : .removed
        items[index].holds = [];items[index].failure = nil;items[index].sameFailureCount = 0
        recomputeState()
    }
    /// A bounded metadata observation only. Even .ready needs a fresh gate+hold check at actual unlink.
    mutating func observe(_ facts: [Admission],nowMS: Int64) throws {
        guard ![.canceled,.completed,.suspended].contains(state) else {throw ArchiveCleanupJobError.terminal}
        guard nowMS >= notBeforeMS else {throw ArchiveCleanupJobError.grace}
        guard facts.count <= Self.admissionStepLimit,Set(facts.map {$0.original.id}).count == facts.count else {throw ArchiveCleanupJobError.invalid}
        var changed = items
        for fact in facts {
            guard fact.projectID == projectID,fact.taskID == taskID,let index = changed.firstIndex(where: {$0.original.id == fact.original.id}),!changed[index].terminal else {throw ArchiveCleanupJobError.stale}
            let original = changed[index].original
            guard original.sha256 == fact.original.sha256,original.logicalBytes == fact.original.logicalBytes,original.attachmentRevision == fact.original.attachmentRevision else {throw ArchiveCleanupJobError.stale}
            let holds = fact.referencesComplete ? fact.holds : fact.holds.union([.referenceGraphUnavailable])
            changed[index].holds = holds;changed[index].state = holds.isEmpty ? .ready : .held
            changed[index].failure = nil;changed[index].sameFailureCount = 0
        }
        items = changed;recomputeState()
    }
    private mutating func recomputeState() {
        if items.contains(where: {$0.state == .suspended}) {state = .suspended}
        else if items.allSatisfy(\.terminal) {state = .completed}
        else if items.contains(where: {$0.state == .ready}) {state = .ready}
        else if items.contains(where: {$0.state == .held}) {state = .held}
        else {state = .queued}
    }
    func logicalTotals() throws -> (selected: Int64,removed: Int64,alreadyMissing: Int64) {
        func sum(_ values: [Int64]) throws -> Int64 {
            try values.reduce(0) {a,b in let (n,overflow) = a.addingReportingOverflow(b);guard !overflow else {throw ArchiveCleanupJobError.overflow};return n}
        }
        return try (sum(items.map {$0.original.logicalBytes}),sum(items.filter {$0.state == .removed}.map {$0.original.logicalBytes}),sum(items.filter {$0.state == .alreadyMissing}.map {$0.original.logicalBytes}))
    }
    // Codec accepts complete service records only; revisions are the enclosing Store's responsibility.
    func record(revision: Int64) throws -> [String:Any] {
        guard revision > 0 else {throw ArchiveCleanupJobError.invalid}
        return ["record_type":"cleanup_job","schema_version":1,"id":id.text,"project_id":projectID.text,"task_id":taskID.text,"revision":revision,
                "task_revision":taskRevision,"settings_revision":settingsRevision,"preview_id":previewID.text,"plan_sha256":planDigest,"enqueued_at_ms":enqueuedAtMS,"not_before_ms":notBeforeMS,"state":state.rawValue,
                "items":items.map {item -> [String:Any] in
                    var value: [String:Any] = ["attachment_id":item.original.id.text,"sha256":item.original.sha256,"logical_bytes":item.original.logicalBytes,"attachment_revision":item.original.attachmentRevision,"state":item.state.rawValue,"holds":Hold.allCases.filter(item.holds.contains).map(\.rawValue),"same_failure_count":item.sameFailureCount]
                    if let failure = item.failure {value["failure_code"] = failure.rawValue};return value
                }]
    }
    static func integer(_ raw: Any?) throws -> Int64 {
        guard let n = raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let value = Int64(n.stringValue) else {throw ArchiveCleanupJobError.invalid};return value
    }
    init(record: [String:Any]) throws {
        let keys: Set<String> = ["record_type","schema_version","id","project_id","task_id","revision","task_revision","settings_revision","preview_id","plan_sha256","enqueued_at_ms","not_before_ms","state","items"]
        guard Set(record.keys) == keys,record["record_type"] as? String == "cleanup_job",try Self.integer(record["schema_version"]) == 1,try Self.integer(record["revision"]) > 0,
              let id = record["id"] as? String,let project = record["project_id"] as? String,let task = record["task_id"] as? String,let preview = record["preview_id"] as? String,let digest = record["plan_sha256"] as? String,let name = record["state"] as? String,let jobState = State(rawValue:name),let rows = record["items"] as? [[String:Any]],!rows.isEmpty,rows.count <= Self.maximumItems else {throw ArchiveCleanupJobError.invalid}
        let parsed: [Item] = try rows.map {row in
            let base: Set<String> = ["attachment_id","sha256","logical_bytes","attachment_revision","state","holds","same_failure_count"]
            guard Set(row.keys).isSubset(of:base.union(["failure_code"])),base.isSubset(of:Set(row.keys)),let id = row["attachment_id"] as? String,let digest = row["sha256"] as? String,let name = row["state"] as? String,let state = ItemState(rawValue:name),let reasons = row["holds"] as? [String],Set(reasons).count == reasons.count else {throw ArchiveCleanupJobError.invalid}
            let holds = reasons.compactMap(Hold.init(rawValue:));guard holds.count == reasons.count else {throw ArchiveCleanupJobError.invalid}
            let count = try Self.integer(row["same_failure_count"]);guard (0...2).contains(count) else {throw ArchiveCleanupJobError.invalid}
            let failure: Failure?
            if let raw = row["failure_code"] {guard let code = raw as? String,let known = Failure(rawValue:code),count > 0 else {throw ArchiveCleanupJobError.invalid};failure = known}
            else {guard count == 0 else {throw ArchiveCleanupJobError.invalid};failure = nil}
            switch state {
            case .waiting,.ready,.canceled,.removed,.alreadyMissing:
                guard holds.isEmpty,count == 0,failure == nil else {throw ArchiveCleanupJobError.invalid}
            case .held:
                guard !holds.isEmpty,count < 2 else {throw ArchiveCleanupJobError.invalid}
            case .suspended:
                guard !holds.isEmpty,count == 2,failure != nil else {throw ArchiveCleanupJobError.invalid}
            }
            return Item(original:try .init(id:id,sha256:digest,logicalBytes:Self.integer(row["logical_bytes"]),attachmentRevision:Self.integer(row["attachment_revision"])),state:state,holds:Set(holds),failure:failure,sameFailureCount:Int(count))
        }
        try self.init(id:id,projectID:project,taskID:task,taskRevision:Self.integer(record["task_revision"]),settingsRevision:Self.integer(record["settings_revision"]),previewID:preview,planDigest:digest,enqueuedAtMS:Self.integer(record["enqueued_at_ms"]),notBeforeMS:Self.integer(record["not_before_ms"]),originals:parsed.map(\.original))
        self.items = parsed
        if jobState == .canceled {guard parsed.allSatisfy(\.terminal) else {throw ArchiveCleanupJobError.invalid};state = .canceled}
        else {recomputeState();guard state == jobState else {throw ArchiveCleanupJobError.invalid}}
    }
}
