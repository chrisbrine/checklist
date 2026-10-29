import Foundation
import GRDB

/// One maintenance call owns this observation. Nothing is retained on the router
/// or reused by a later pass. Receipt/ticket fences and outcomes remain separate.
final class TicketCleanupDeletionCohort: TicketCleanupPrepared {
    static let receiptLimit = 32
    static let descriptorByteLimit = 16 * 1024 * 1024
    static let objectLimit = 100000
    static let continuationLimit = 2048
    static let continuationSeconds: TimeInterval = 30
    let fence: TicketCleanupFence
    var entries: [TicketCleanupPreparedDeletion]
    var backup: StorageBackupRetentionIndex?
    var current: TicketCleanupPreparedDeletion?
    var index = 0
    var turns = 0
    var started = ProcessInfo.processInfo.systemUptime
    var refused: [String:String] = [:]

    init(entries: [TicketCleanupPreparedDeletion],backup: StorageBackupRetentionIndex?) {
        precondition(!entries.isEmpty)
        self.entries = entries;self.backup = backup;fence = entries[0].fence
    }
    func revalidated(_ db: Database,router: CommandRouter) throws -> Self {
        guard let current else {return self}
        do {try current.fence.validate(db)}
        catch let error as CoreError where error.code == "CLEANUP_CONCURRENT_WRITE" {
            // A stale ticket never discards another ticket's valid preparation.
            refused[current.receipt["id"] as? String ?? ""] = error.details["reason"] as? String ?? error.code
            try router.recordTicketCleanupPreparationRefusal(db,project:current.fence.projectID,reason:error.details["reason"] as? String ?? error.code)
            self.current = nil
            index += 1
        }
        return self
    }
}

extension CommandRouter {
    /// Select a single project's bounded cohort in queue order. A later call
    /// freshly observes all authority; verified manifests never become a cache
    /// across passes. Oversize receipts retain bytes under the existing bounds.
    func prepareTicketObjectDeletionCohort(_ db: Database) throws -> TicketCleanupDeletionCohort? {
        let ready = "type='storage_job' AND (" + Self.ticketObjectDeletionReadySQL + ") AND NOT EXISTS(SELECT 1 FROM metadata m WHERE m.key='ticket-cleanup-preparation:'||records.project_id AND json_valid(m.value) AND json_extract(m.value,'$.next_attempt_at')>?)"
        guard let project = try String.fetchOne(db,sql:"SELECT project_id FROM records WHERE " + ready + " ORDER BY rowid LIMIT 1",arguments:[now()]) else {return nil}
        try beginTicketCleanupPreparation(project:project)
        let admissible = "length(CAST(data AS BLOB))<=\(TicketCleanupDeletionCohort.descriptorByteLimit) AND COALESCE(json_array_length(data,'$.objects'),0)<=\(TicketCleanupDeletionCohort.objectLimit)"
        if try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM records WHERE " + ready + " AND project_id=? AND NOT (" + admissible + "))",arguments:[now(),project]) == true {
            try recordTicketCleanupPreparationRefusal(project:project,reason:"individual byte receipt exceeds its descriptor bound")
        }
        // Filter individual overflows before LIMIT: even a run of oversized
        // receipts cannot hide a later bounded sibling in this project.
        let rows = try Row.fetchCursor(db,sql:"SELECT " + Self.canonicalRecordColumns + ",length(CAST(data AS BLOB)) AS cleanup_bytes FROM records WHERE " + ready + " AND project_id=? AND " + admissible + " ORDER BY rowid LIMIT ?",arguments:[now(),project,TicketCleanupDeletionCohort.receiptLimit])
        var receipts: [JSON] = [],bytes = 0,count = 0
        while let raw = try rows.next() {
            let size: Int = raw["cleanup_bytes"]
            guard size <= TicketCleanupDeletionCohort.descriptorByteLimit,bytes + size <= TicketCleanupDeletionCohort.descriptorByteLimit else {break}
            var receipt = try GRDBRecordEnvelopeAdapter.decode(raw).object
            var objects = receipt["objects"] as? [JSON] ?? []
            guard objects.count <= TicketCleanupDeletionCohort.objectLimit,count + objects.count <= TicketCleanupDeletionCohort.objectLimit else {break}
            if receipt["state"] as? String == "completed" {
                receipt["_cohort_reactivated"] = true
                for i in objects.indices where objects[i]["state"] as? String == "retained" {
                    let reasons = Set(objects[i]["reasons"] as? [String] ?? [])
                    if !reasons.isEmpty,reasons.isSubset(of:Self.ticketObjectDeletionRetryReasons) {objects[i]["state"] = "pending";objects[i].removeValue(forKey:"reasons")}
                }
                receipt["objects"] = objects;receipt["state"] = "pending";receipt["summary"] = Self.ticketObjectDeletionSummary(objects)
            }
            if receipt["cause"] as? String == "task_purge" {receipt["cleanup_policy_version"] = 2}
            receipts.append(receipt);bytes += size;count += objects.count
        }
        guard !receipts.isEmpty else {throw CoreError("CLEANUP_INVENTORY_LIMIT","The selected byte receipt exceeds its cohort bound; bytes retained.")}
        let inventories = try ticketCleanupDeletionInventories(db,receipts:receipts)
        let generation = try ticketCleanupBackupGenerationRow(db)
        // Only pending objects can gain unlink authority in this cohort.
        // Historical retained/removed descriptors still participate in each
        // inventory/fence, but must not exhaust the shared backup proof budget.
        // Reactivated purge objects were made pending before this observation.
        let pendingObjects = receipts.flatMap {$0["objects"] as? [JSON] ?? []}.filter {$0["state"] as? String == "pending"}
        let backup = try? ticketCleanupBackupRetentionIndex(db,objects:pendingObjects)
        let mediaComplete = (try? ticketCleanupValidateMediaAuthority(db)) != nil
        var entries: [TicketCleanupPreparedDeletion] = [],referenceBytes = 0
        for var receipt in receipts {
            let id = try StoredRecord(receipt,family:"receipt").string("id")
            guard let inventory = inventories.inventories[id] else {continue}
            let reactivated = bool(receipt,"_cohort_reactivated");receipt.removeValue(forKey:"_cohort_reactivated")
            let graph = try ticketCleanupDeletionReferences(db,receipt:receipt,inventory:inventory)
            let historicalOwners = receipt["cause"] as? String == "done_evidence" ? Set((receipt["owned_record_fingerprints"] as? [String:String] ?? [:]).keys.map {Data($0.utf8)}) : []
            let references = try TicketObjectDeletionReferenceIndex(graph,tokens:inventory.tokens,historicalOwners:historicalOwners)
            let charge = references.reverse.reduce(0) {$0 + $1.key.count + 96 + $1.value.count * 32}
            guard referenceBytes + charge <= TicketCleanupBatchInventory.byteLimit else {
                try recordTicketCleanupPreparationRefusal(project:project,reason:"byte cohort reference index budget")
                continue
            }
            referenceBytes += charge
            let fence = try TicketCleanupFence(db,inventory:inventory,project:project,ids:[id,try StoredRecord(receipt,family:"receipt").string("task_id"),project])
            entries.append(.init(fence:fence,receipt:receipt,reactivated:reactivated,backupGenerationRow:generation,references:references,backup:nil,mediaAuthorityComplete:mediaComplete,candidatePaths:[],verifications:[:],verificationFailures:[:]))
        }
        guard !entries.isEmpty else {throw inventories.errors.values.first ?? CoreError("CLEANUP_INVENTORY_LIMIT","No byte receipt fits its inventory bound.")}
        let cohort = TicketCleanupDeletionCohort(entries:entries,backup:backup)
        return try continueTicketObjectDeletionCohort(db,cohort:cohort)
    }

    func continueTicketObjectDeletionCohort(_ db: Database,cohort: TicketCleanupDeletionCohort) throws -> TicketCleanupDeletionCohort? {
        guard cohort.turns < TicketCleanupDeletionCohort.continuationLimit,
              cohort.turns == 0 || ProcessInfo.processInfo.systemUptime-cohort.started < TicketCleanupDeletionCohort.continuationSeconds else {return nil}
        guard cohort.index < cohort.entries.count else {return nil}
        let entry = cohort.entries[cohort.index]
        if let current = cohort.current {
            // Consume the preverified candidates across as many 25 ms writer
            // chunks as necessary, without hashing their manifest/payload again.
            let remaining = (entry.receipt["objects"] as? [JSON] ?? []).contains {object in
                object["state"] as? String == "pending" && (object["relative_path"] as? String).map {current.candidatePaths.contains($0)} == true
            }
            if remaining {
                cohort.current = .init(fence:entry.fence,receipt:entry.receipt,reactivated:false,backupGenerationRow:entry.backupGenerationRow,references:entry.references,backup:current.backup,mediaAuthorityComplete:entry.mediaAuthorityComplete,candidatePaths:current.candidatePaths,verifications:current.verifications,verificationFailures:current.verificationFailures)
                return cohort
            }
        }
        // At most 256 pinned payloads survive candidate admission. Manifests
        // retain exact digests/identities for this cohort only (<=1024 generations).
        cohort.current = nil
        cohort.backup?.checkedCopies.removeAll(keepingCapacity:true)
        cohort.backup?.verifiedCopies.removeAll(keepingCapacity:true)
        cohort.current = try prepareTicketObjectDeletionCandidates(db,receipt:entry.receipt,reactivated:entry.reactivated,backupGenerationRow:entry.backupGenerationRow,references:entry.references,backup:&cohort.backup,mediaComplete:entry.mediaAuthorityComplete,fence:entry.fence)
        return cohort
    }

    @discardableResult
    func runTicketObjectDeletionCohort() throws -> Bool {
        var found = false
        try withTicketCleanupPreparation({db in
            let cohort = try self.prepareTicketObjectDeletionCohort(db);found = cohort != nil;return cohort
        },continuing:{db,cohort in try self.continueTicketObjectDeletionCohort(db,cohort:cohort)}) {db,permit,cohort in
            guard let prepared = cohort.current else {return}
            let before = prepared.receipt
            // This exact executor changes only deletion accounting; the original
            // TEMP journal continues to observe every intervening command.
            let outcome = try TicketCleanupChanges.deletionAccounting(db) {
                try self.processTicketObjectDeletionIntents(db,permit:permit,prepared:prepared)
            }
            cohort.turns += 1
            let pending = (outcome["objects"] as? [JSON] ?? []).contains {$0["state"] as? String == "pending"}
            // A failed/no-progress chunk is bounded, not retried in a tight loop.
            let changes = zip(before["objects"] as? [JSON] ?? [],outcome["objects"] as? [JSON] ?? [])
            let unchanged = !changes.contains {a,b in a["state"] as? String != b["state"] as? String || int(a,"failures") != int(b,"failures")}
            // A failed verification/unlink/outcome gets one attempt this call.
            // Preserve its durable retry for another call/restart; continuing a
            // successful sibling never spends this receipt's second failure.
            let failed = changes.contains {a,b in int(b,"failures") > int(a,"failures")}
            if !pending || unchanged || failed {cohort.index += 1;cohort.current = nil}
            else {
                cohort.entries[cohort.index] = .init(fence:prepared.fence,receipt:outcome,reactivated:false,backupGenerationRow:prepared.backupGenerationRow,references:prepared.references,backup:nil,mediaAuthorityComplete:prepared.mediaAuthorityComplete,candidatePaths:[],verifications:[:],verificationFailures:[:])
            }
        }
        return found
    }
}
