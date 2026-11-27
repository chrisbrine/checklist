import Foundation
import GRDB

enum MediaRoundDeletionWriterBudget: Error {
    case history
    case graph(String)
}

extension CommandRouter {
    typealias DeletionGraph = MediaRoundDeletionGraph
    static let mediaGraphWriterBudget: TimeInterval = 0.25

    struct GraphDeletionContext {
        let params: JSON
        let caller: Caller
        let expectedAuthorizationGeneration: String?
        let command: String
        let digest: String
        let project: String
        let round: String
        let historyKey: String
        let observer: DatabaseQueue
        let changes: MediaRoundDeletionChanges
        let writerVersion: Int64

        var key: String { DeletionGraph.key(historyKey) }
    }

    func prepareMediaDeletionGraph(_ plan: MediaRoundDeletionPlan, audit: JSON,
                                   receipt: String) throws -> DeletionGraph.Work {
        let kept = try plan.keptAttachments.map { attachment -> [(DeletionGraph.Change,Int)] in
            let id = try StoredRecord(attachment,family:"attachment").string("id")
            let witness = try plan.graphWitness(id)
            let data = try jsonString(attachment)
            return [(.init(id:id,data:data,revision:Int64(int(attachment,"revision")),position:witness.position),data.utf8.count)]
        }
        let media = try plan.records.filter {MediaRecordRegistry.families.contains($0.type)}.map { row in
            let witness = try plan.graphWitness(row.id)
            return [(try DeletionGraph.detachMedia(row,witness),plan.recordSizes[row.key,default:0])]
        }
        let erase = try DeletionGraph.eraseGroups(plan.records,round:plan.round).map { group in
            try group.map { row -> (DeletionGraph.Change,Int) in
                let witness = try plan.graphWitness(row.id)
                return (.init(id:row.id,data:nil,revision:nil,position:witness.position),plan.recordSizes[row.key,default:0])
            }
        }
        let receiptWork = try prepareMediaGraphReceipt(project:plan.project,round:plan.round,receiptID:receipt,audit:audit,bytes:plan.bytes)
        let slices = receiptWork + DeletionGraph.slices(.detach,groups:kept) + DeletionGraph.slices(.detach,groups:media)
            + DeletionGraph.slices(.erase,groups:erase)
        return .init(slices:slices,fence:plan.fence,
                     kept:Set(plan.keptAttachments.compactMap {($0["id"] as? String).map {Data($0.utf8)}}),
                     handoffOnlyIDs:plan.handoffOnlyIDs)
    }

    /// Make an independent backup admission and writer acquisition for each
    /// durable transition. A refused or interrupted writer transaction leaves
    /// its cursor unchanged, including when committing throws.
    private func writeMediaDeletionGraph(_ context: GraphDeletionContext, phase: String,
                                         from current: DeletionGraph.Progress?, to next: DeletionGraph.Progress?,
                                         apply: (Database) throws -> Void) throws {
        let passStarted = ProcessInfo.processInfo.systemUptime
        let pass = next?.pass ?? ((current?.pass ?? 0) + 1)
        var seconds: TimeInterval?, committed = false
        defer {
            if let seconds {
                StoragePhaseTiming.writerHold(operation:phase,command:context.command,pass:pass,seconds:seconds,committed:committed,
                    elapsedSeconds:ProcessInfo.processInfo.systemUptime - passStarted,interruptedStep:committed ? nil : phase)
                mediaRoundDeletionWriterProbe?(phase,seconds,committed)
            }
        }
        let encoded = try next.map(DeletionGraph.encode)
        // The visibility write and a resumed history pass may still carry
        // the last history batch. Give them the same budget as other history.
        let budget = ["media_round_graph_hide","media_round_history_pass"].contains(phase)
            ? Self.mediaDeletionWriterBudget : Self.mediaGraphWriterBudget
        try ArchiveStorageGate.withExclusive(root:root) { _ in
            try self.withMediaRoundDeletionWrite {
                try self.dbQueue.writeWithoutTransaction { db in
                    let started = ProcessInfo.processInfo.systemUptime
                    defer {seconds = ProcessInfo.processInfo.systemUptime - started}
                    let finished = try Self.withPruneStepBudget(db,seconds:budget) {
                        try self.withValidatedDomainTransaction(db) {
                            let project = try self.mediaAccess(db,context.params,context.caller,write:true)
                            if let expectedGeneration = context.expectedAuthorizationGeneration {
                                _ = try self.backupWriteAuthorization(db,params:context.params,caller:context.caller,
                                                                      expectedGeneration:expectedGeneration)
                            }
                            try self.requirePendingCommandIntent(db,command:context.command,digest:context.digest,caller:context.caller)
                            try self.requireAgentEditAuthority(db,project:self.record(db,project,type:"project"),caller:context.caller)
                            guard EnvelopeStorageIdentity.equal(project,context.project),
                                  try DeletionGraph.load(db,context.key,as:DeletionGraph.Progress.self) == current else {
                                throw MediaRoundDeletionFence.changed("graph_progress",type:"media_round",id:Data(context.round.utf8))
                            }
                            try apply(db)
                            if let encoded {
                                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                                               arguments:[context.key,encoded])
                            } else {
                                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[context.key])
                            }
                            guard ProcessInfo.processInfo.systemUptime - started < budget else {
                                throw MediaRoundDeletionWriterBudget.graph(phase)
                            }
                            return .commit
                        }
                        return true
                    }
                    guard finished == true else {throw MediaRoundDeletionWriterBudget.graph(phase)}
                    committed = true
                }
            }
        }
    }

    func startMediaDeletionGraph(_ context: GraphDeletionContext, plan: MediaRoundDeletionPlan, audit: JSON) throws -> JSON {
        let receipt = uuid()
        let (work,payload) = try { () -> (DeletionGraph.Work, Data) in
            let timing = StoragePhaseTiming(operation:"media_round_graph_prepare_journal",command:context.command,
                                           uptime:{ProcessInfo.processInfo.systemUptime})
            var result = "failed"
            timing.record("journal_encoding")
            defer {timing.record(result,terminal:true)}
            let work = try prepareMediaDeletionGraph(plan,audit:audit,receipt:receipt)
            let payload = try JSONEncoder().encode(work)
            result = "complete"
            return (work,payload)
        }()
        let members = work.slices.flatMap(\.members)
        let count = max((payload.count + DeletionGraph.journalChunkBytes - 1) / DeletionGraph.journalChunkBytes,
                        (members.count + DeletionGraph.rowLimit - 1) / DeletionGraph.rowLimit)
        let revision = try plan.graphWitness(context.round).revision
        var progress = DeletionGraph.Progress(project:context.project,round:context.round,predecessor:plan.predecessor,
                                              revision:Int(revision),receipt:receipt,
                                              visibilityPrincipal:context.caller.principal,visibilityCommand:context.command,visibilityEpoch:uuid(),
                                              total:members.count,slices:work.slices.count,pass:plan.historyProgress ?? 0,
                                              handoffWitnessCount:0)
        var previous: DeletionGraph.Progress?
        for index in 0..<count {
            let offset = min(index * DeletionGraph.journalChunkBytes,payload.count)
            let end = min(offset + DeletionGraph.journalChunkBytes,payload.count)
            let first = min(index * DeletionGraph.rowLimit,members.count)
            let last = min(first + DeletionGraph.rowLimit,members.count)
            let shard = try DeletionGraph.encode(DeletionGraph.Shard(bytes:payload.subdata(in:offset..<end),members:Array(members[first..<last])))
            let memberIDs = try jsonString(Array(members[first..<last]))
            progress.pass += 1
            progress.staged += 1
            try writeMediaDeletionGraph(context,phase:"media_round_graph_stage",from:previous,to:progress) { db in
                if !work.handoffOnlyIDs.isEmpty {
                    try work.fence.validate(db,changes:context.changes,writerVersion:context.writerVersion)
                }
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?)",arguments:[DeletionGraph.shardKey(context.key,index),shard])
                try db.execute(sql:"""
                    INSERT INTO metadata(key,value)
                    SELECT '\(DeletionGraph.memberPrefix)'||value,? FROM json_each(?)
                    """,arguments:[context.key,memberIDs])
            }
            previous = progress
        }
        let history = try plan.history.prepareWrites()
        let owned = Set(members.map {Data($0.utf8)})
        let successorKey = try mediaGraphSuccessorKey(context,predecessor:progress.predecessor)
        progress.phase = .deleting
        progress.pass += 1
        try writeMediaDeletionGraph(context,phase:"media_round_graph_hide",from:previous,to:progress) { db in
            try work.fence.validate(db,changes:context.changes,writerVersion:context.writerVersion)
            try plan.history.validateResultDependents(db,journal:context.changes.name,removed:owned)
            try context.changes.apply(db) {
                try plan.history.apply(db,writes:history)
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                               arguments:[context.historyKey,String(progress.pass)])
                if let successorKey {
                    try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?)",arguments:[successorKey,context.round])
                }
                // Prepared operations from before visibility cannot republish a
                // payload for the graph after its history has been redacted.
                try CommandOperationPurgeEpoch.advance(db,project:context.project,epoch:progress.visibilityEpoch)
            }
        }
        return try continueMediaDeletionGraph(context,progress:progress,work:work)
    }

    private func mediaGraphSuccessorKey(_ context: GraphDeletionContext,predecessor: String?) throws -> String? {
        // Keep the refusal addressable after the successor's round row is erased.
        guard let predecessor else {return nil}
        return try DeletionGraph.successorPrefix(project:context.project,predecessor:predecessor) + context.round
    }

    func loadMediaDeletionGraph(_ db: Database,_ progress: DeletionGraph.Progress,
                                context: GraphDeletionContext) throws -> DeletionGraph.Work {
        var data = Data()
        for index in 0..<progress.staged {
            guard let shard = try DeletionGraph.load(db,DeletionGraph.shardKey(context.key,index),as:DeletionGraph.Shard.self) else {
                throw StoreRecovery.required("media_deletion_graph_journal_missing")
            }
            data.append(shard.bytes)
        }
        guard let work = try? JSONDecoder().decode(DeletionGraph.Work.self,from:data),
              work.slices.count == progress.slices else {throw StoreRecovery.required("media_deletion_graph_journal_invalid")}
        return work
    }

    func discardStagedMediaDeletionGraph(_ context: GraphDeletionContext, progress: DeletionGraph.Progress) throws {
        var cursor = progress
        while cursor.staged > 0 {
            let key = DeletionGraph.shardKey(context.key,cursor.staged - 1)
            let ids = try context.observer.read { db -> String in
                guard let shard = try DeletionGraph.load(db,key,as:DeletionGraph.Shard.self) else {
                    throw StoreRecovery.required("media_deletion_graph_journal_missing")
                }
                return try jsonString(shard.members)
            }
            let before = cursor
            cursor.staged -= 1
            cursor.pass += 1
            try writeMediaDeletionGraph(context,phase:"media_round_graph_discard_stage",from:before,to:cursor.staged == 0 ? nil : cursor) { db in
                try self.removeMediaGraphMembers(db,context:context,ids:ids)
                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key])
            }
        }
    }

    func scrubResumedMediaGraphHistory(_ context: GraphDeletionContext, progress: DeletionGraph.Progress,
                                      work: DeletionGraph.Work, history: MediaGraphResumeHistory) throws {
        var next = progress
        next.pass += 1
        let writes = try history.rows.prepareWrites()
        let graph = try MediaRoundDeletionFence.VisibleGraph(work)
        try writeMediaDeletionGraph(context,phase:"media_round_history_pass",from:progress,to:next) { db in
            try work.fence.validate(db,changes:context.changes,writerVersion:context.writerVersion,graph:graph)
            try history.fence.validate(db,changes:context.changes,writerVersion:context.writerVersion)
            try history.rows.validateResultDependents(db,journal:context.changes.name,removed:graph.owned)
            try history.rows.apply(db,writes:writes)
        }
    }

    func continueMediaDeletionGraph(_ context: GraphDeletionContext, progress: DeletionGraph.Progress,
                                     work: DeletionGraph.Work?) throws -> JSON {
        var cursor = progress
        if cursor.phase == .deleting, let work {
            let graph = try MediaRoundDeletionFence.VisibleGraph(work)
            var batchLimit = DeletionGraph.rowLimit
            while cursor.next < work.slices.count {
                try mediaRoundDeletionGraphProbe?()
                let source = work.slices[cursor.next]
                let end = source.batchEnd(after:cursor.sliceOffset,limit:batchLimit)
                guard cursor.sliceOffset < end, end <= source.changes.count else {
                    throw StoreRecovery.required("media_deletion_graph_progress_invalid")
                }
                let slice = DeletionGraph.Slice(kind:source.kind,changes:Array(source.changes[cursor.sliceOffset..<end]))
                let ids = try jsonString(slice.members)
                let positions = try jsonString(slice.changes.map(\.position))
                let updates = slice.kind == .detach ? try DeletionGraph.encode(slice.changes) : nil
                // Kept attachments and owned media tombstones occupy separate slices.
                let kept = slice.kind == .detach && work.kept.contains(Data(slice.changes[0].id.utf8))
                if kept,
                   !slice.changes.allSatisfy({$0.data != nil && $0.revision != nil && work.kept.contains(Data($0.id.utf8))}) {
                    throw StoreRecovery.required("media_deletion_graph_journal_invalid")
                }
                var next = cursor
                if end == source.changes.count {
                    next.next += 1
                    next.sliceOffset = 0
                } else { next.sliceOffset = end }
                next.pass += 1
                next.removed += slice.members.count
                let operation = "media_round_graph_" + slice.kind.rawValue
                do {
                    try writeMediaDeletionGraph(context,phase:operation,from:cursor,to:next) { db in
                        try work.fence.validate(db,changes:context.changes,writerVersion:context.writerVersion,graph:graph)
                        try context.changes.apply(db) {
                            if kept,let updates {try self.detachKeptMediaGraphAttachments(db,context:context,updates:updates)}
                            else {try self.applyMediaGraphSlice(db,context:context,slice:slice,ids:ids,positions:positions,updates:updates)}
                        }
                    }
                    cursor = next
                } catch let budget as MediaRoundDeletionWriterBudget {
                    let smaller = max(1,(end - cursor.sliceOffset) / 2)
                    guard source.batchEnd(after:cursor.sliceOffset,limit:smaller) < end else {throw budget}
                    batchLimit = smaller
                }
            }
            let before = cursor
            cursor.phase = .retiring
            if cursor.handoffWitnessCount == nil {cursor.handoffWitnessCount = 0}
            cursor.pass += 1
            try writeMediaDeletionGraph(context,phase:"media_round_graph_retire",from:before,to:cursor) { _ in }
        }
        guard cursor.phase == .retiring, cursor.removed == cursor.total else {
            throw StoreRecovery.required("media_deletion_graph_progress_invalid")
        }
        // Drop work and its private identity inventory in the same bounded
        // shards used to persist it. The early receipt owns bytes throughout.
        while cursor.staged > 0 {
            let before = cursor, key = DeletionGraph.shardKey(context.key,cursor.staged - 1)
            cursor.staged -= 1
            cursor.pass += 1
            try writeMediaDeletionGraph(context,phase:"media_round_graph_retire_journal",from:before,to:cursor) { db in
                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key])
                guard db.changesCount == 1 else {throw StoreRecovery.required("media_deletion_graph_journal_missing")}
            }
        }
        // Older graphs kept copies of selection witnesses in separate pages.
        // Retire them a page at a time. Visibility already committed the proof.
        while let count = cursor.handoffWitnessCount,count > 0 {
            let before = cursor
            let offset = (count - 1) / DeletionGraph.rowLimit * DeletionGraph.rowLimit
            let key = DeletionGraph.handoffWitnessPrefix(context.key) + String(format:"%08d",offset)
            cursor.handoffWitnessCount = offset
            cursor.pass += 1
            try writeMediaDeletionGraph(context,phase:"media_round_graph_retire_journal",from:before,to:cursor) { db in
                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[key])
                guard db.changesCount == 1 else {throw StoreRecovery.required("media_deletion_graph_handoff_unverified")}
            }
        }
        return try publishMediaGraphDeletion(context,progress:cursor)
    }

    private func removeMediaGraphMembers(_ db: Database,context: GraphDeletionContext,ids: String) throws {
        try db.execute(sql:"""
            DELETE FROM metadata WHERE key IN (
                SELECT '\(DeletionGraph.memberPrefix)'||value FROM json_each(?)
            ) AND value=?
            """,arguments:[ids,context.key])
    }

    private func detachKeptMediaGraphAttachments(_ db: Database,context: GraphDeletionContext,updates: String) throws {
        // Apply only links to this graph and their provenance. Ticket-side
        // edits, import recovery and availability changes keep their values.
        func ownsLink(_ field: String) -> String {
            "EXISTS (SELECT 1 FROM metadata WHERE key='\(DeletionGraph.memberPrefix)'||json_extract(r.data,'$.\(field)') AND value=:graph)"
        }
        // Drive the join from the bounded slice. The record key's storage
        // collation compares exact bytes and uses the primary-key index.
        try db.execute(sql:"""
            WITH selected AS MATERIALIZED (
                SELECT r.rowid AS position,r.data,r.revision,json_extract(j.value,'$.data') AS planned,
                       \(ownsLink("attachment_owner_id")) AS owner,
                       \(ownsLink("storage_job_id")) AS job,
                       \(ownsLink("media_cleanup_round_id")) AS marker
                FROM json_each(:updates) j CROSS JOIN records r ON r.id=CAST(json_extract(j.value,'$.id') AS TEXT)
                WHERE r.type='attachment' AND r.project_id=:project
            ), detached AS MATERIALIZED (
                SELECT position,revision+1 AS revision,planned,
                       owner OR job OR json_type(data,'$.media_capture_history') IS NULL AS set_history,
                       json_remove(data,CASE WHEN owner THEN '$.attachment_owner_id' ELSE '$[0]' END,
                                        CASE WHEN job THEN '$.storage_job_id' ELSE '$[0]' END,
                                        CASE WHEN marker THEN '$.media_cleanup_round_id' ELSE '$[0]' END) AS data
                FROM selected WHERE owner OR job OR marker OR json_type(data,'$.media_capture_history') IS NULL
            )
            UPDATE records SET revision=detached.revision,
                data=json_set(CASE WHEN set_history THEN json_set(detached.data,'$.media_capture_history',
                    json_extract(planned,'$.media_capture_history')) ELSE detached.data END,
                    '$.revision',detached.revision,'$.updated_at',:updated)
            FROM detached WHERE records.rowid=detached.position
            """,arguments:["graph":context.key,"updates":updates,"project":context.project,"updated":now()])
    }

    private func applyMediaGraphSlice(_ db: Database,context: GraphDeletionContext,slice: DeletionGraph.Slice,
                                      ids: String, positions: String, updates: String?) throws {
        switch slice.kind {
        case .audit:
            for change in slice.changes {
                guard let data = change.data else {throw StoreRecovery.required("media_deletion_graph_journal_invalid")}
                try db.execute(sql:"INSERT INTO metadata(key,value) VALUES(?,?)",arguments:[change.id,data])
            }
        case .descriptor,.receipt:
            for change in slice.changes {
                guard let data = change.data,let revision = change.revision else {throw StoreRecovery.required("media_deletion_graph_journal_invalid")}
                try db.execute(sql:"INSERT INTO records(id,project_id,type,revision,data) VALUES(?,?,'storage_job',?,?)",
                               arguments:[change.id,context.project,revision,data])
                if slice.kind == .descriptor {
                    try markTicketObjectDeletionBackupGeneration(db,receipt:change.id,generation:ticketCleanupBackupGenerationRow(db))
                }
            }
        case .detach:
            guard let updates else {throw StoreRecovery.required("media_deletion_graph_journal_invalid")}
            try db.execute(sql:"""
                WITH selected AS MATERIALIZED (
                    SELECT json_extract(value,'$.position') position,json_extract(value,'$.id') id,
                           json_extract(value,'$.revision') revision,json_extract(value,'$.data') data
                    FROM json_each(?)
                )
                UPDATE records SET data=selected.data,revision=selected.revision FROM selected
                WHERE records.rowid=selected.position AND records.id=selected.id COLLATE BINARY
                """,arguments:[updates])
            guard db.changesCount == slice.changes.count else {
                throw MediaRoundDeletionFence.changed("graph_detach",type:"media_round",id:Data(context.round.utf8))
            }
        case .erase:
            try db.execute(sql:"DELETE FROM records WHERE rowid IN (SELECT value FROM json_each(?))",arguments:[positions])
            guard db.changesCount == slice.changes.count else {
                throw MediaRoundDeletionFence.changed("graph_erase",type:"media_round",id:Data(context.round.utf8))
            }
            try removeMediaGraphMembers(db,context:context,ids:ids)
        }
    }

    private func publishMediaGraphDeletion(_ context: GraphDeletionContext, progress: DeletionGraph.Progress) throws -> JSON {
        let marker: JSON = [DeletionGraph.firstReceiptField:progress.receipt,"round_id":context.round,"project_id":context.project]
        let (reply,audit) = try context.observer.read { db in
            let first = try self.mediaGraphFirstReply(db,marker)
            let receipt = try self.record(db,progress.receipt,type:"storage_job")
            guard let audit = receipt["deletion"] as? JSON else {throw StoreRecovery.required("media_deletion_graph_receipt_invalid")}
            // A legacy journal without any proof could have hidden a
            // successor before exact handoff membership was required.
            if progress.handoffWitnessCount == nil,progress.predecessor != nil,int(audit,"kept_attachment_count") > 0 {
                throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
            }
            return (first,audit)
        }
        let encoded = try jsonString(marker)
        let successorKey = try mediaGraphSuccessorKey(context,predecessor:progress.predecessor)
        try writeMediaDeletionGraph(context,phase:"media_round_graph_publish",from:progress,to:nil) { db in
            try db.execute(sql:"""
                UPDATE records SET data=json_set(data,'$.state',json_extract(data,'$.media_graph_cleanup_state'),
                    '$.parent_principal',?,'$.parent_command_id',?,'$.intent_digest',?)
                WHERE id=? AND type='storage_job' AND project_id=? AND json_extract(data,'$.state')='deleting'
                """,arguments:[context.caller.principal,context.command,context.digest,progress.receipt,context.project])
            guard db.changesCount == 1 else {throw StoreRecovery.required("media_deletion_graph_receipt_invalid")}
            try self.markTicketObjectDeletionBackupGeneration(db,receipt:progress.receipt,generation:self.ticketCleanupBackupGenerationRow(db))
            try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[context.historyKey])
            if let successorKey {
                try db.execute(sql:"DELETE FROM metadata WHERE key=?",arguments:[successorKey])
            }
            try CommandOperationPurgeEpoch.advance(db,project:context.project)
            try self.event(db,caller:context.caller,project:context.project,entity:context.round,kind:"media_round_deleted",data:audit)
            try db.execute(sql:"INSERT INTO commands(principal,command_id,digest,result) VALUES (?,?,?,?)",
                           arguments:[context.caller.principal,context.command,context.digest,encoded])
        }
        return reply
    }
}
