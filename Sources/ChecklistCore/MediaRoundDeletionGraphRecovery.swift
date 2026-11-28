import Foundation
import GRDB

extension CommandRouter {
    struct MediaGraphResumeHistory {
        let rows: MediaRoundDeletionHistory
        let fence: MediaRoundDeletionFence
    }

    /// TEMP triggers cover a running attempt. Reopen checks the durable witness
    /// against a new reader snapshot before it uses any saved row positions.
    func validateMediaDeletionGraphResume(_ db: Database,progress: DeletionGraph.Progress,
                                          work: DeletionGraph.Work, historyKey: String, historyLimit: Int,
                                          command: String) throws -> MediaGraphResumeHistory? {
        let timing = StoragePhaseTiming(operation:"media_round_graph_resume",command:command,
                                       uptime:{ProcessInfo.processInfo.systemUptime})
        var outcome = "failed"
        timing.record("graph_selection")
        defer {timing.record(outcome,terminal:true)}
        if !work.handoffOnlyIDs.isEmpty, progress.handoffWitnessCount == nil {
            throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
        }
        guard progress.next >= 0, progress.next <= work.slices.count else {
            throw StoreRecovery.required("media_deletion_graph_progress_invalid")
        }
        let owned = Set(work.slices.flatMap(\.members).map {Data($0.utf8)})
        var expected = work.fence.records.filter {owned.contains($0.key)}
        var erased = Set<Data>()
        var undetachedHandoffs = work.handoffOnlyIDs
        let project = Data(progress.project.utf8)
        var applied = Array(work.slices.prefix(progress.next))
        if progress.sliceOffset > 0 {
            let slice = work.slices[progress.next]
            guard progress.sliceOffset < slice.changes.count, slice.groupEnds.contains(progress.sliceOffset) else {
                throw StoreRecovery.required("media_deletion_graph_progress_invalid")
            }
            applied.append(.init(kind:slice.kind,changes:Array(slice.changes.prefix(progress.sliceOffset))))
        }
        for slice in applied {
            for change in slice.changes {
                let id = Data(change.id.utf8)
                switch slice.kind {
                case .erase:
                    erased.insert(id)
                    expected.removeValue(forKey:id)
                case .detach:
                    if work.kept.contains(id) {
                        // A kept attachment can change independently. This
                        // pass has already cleared its links to the graph.
                        undetachedHandoffs.remove(id)
                        continue
                    }
                    guard let previous = expected[id], let data = change.data, let revision = change.revision else {
                        throw StoreRecovery.required("media_deletion_graph_journal_invalid")
                    }
                    expected[id] = .init(position:change.position,revision:revision,digest:MediaPreparationOverlay.digest(Data(data.utf8)),
                                         type:previous.type,project:project)
                case .audit:
                    let value = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[change.id])
                    guard value == change.data else {throw StoreRecovery.required("media_deletion_graph_receipt_invalid")}
                case .descriptor,.receipt:
                    guard let data = change.data, let revision = change.revision,
                          let current = try MediaRoundDeletionFence.record(db,id:id),
                          current.type == Data("storage_job".utf8), current.project == project, current.revision == revision,
                          current.digest == MediaPreparationOverlay.digest(Data(data.utf8)) else {
                        throw MediaRoundDeletionFence.changed("graph_receipt_changed",type:"storage_job",id:id)
                    }
                }
            }
        }
        guard erased.count == progress.removed else {throw StoreRecovery.required("media_deletion_graph_progress_invalid")}
        for id in erased where try MediaRoundDeletionFence.record(db,id:id) != nil {
            throw MediaRoundDeletionFence.changed("graph_identity_reappeared",type:"record",id:id)
        }
        for (id,witness) in expected where try MediaRoundDeletionFence.record(db,id:id) != witness {
            throw MediaRoundDeletionFence.changed("planned_record_changed",type:String(decoding:witness.type,as:UTF8.self),id:id)
        }
        guard owned.count == progress.total else {throw StoreRecovery.required("media_deletion_graph_progress_invalid")}
        let tokens = try JSONDecoder().decode([String].self,from:Data(work.fence.tokens.utf8))
        let needles = Set(tokens.map {Data($0.utf8)})
        let kept = work.kept, handoffs = undetachedHandoffs
        let budget = MediaRoundDeletionReferenceBudget()
        timing.record("reference_and_history_scan",rowsRead:owned.count)
        @Sendable func observeReferences(_ reader: Database,partition: TicketCleanupRowRange? = nil) throws -> MediaRoundDeletionReferences {
            try self.mediaRoundDeletionReferences(reader,owned:owned,retainedAttachments:kept,
                handoffOnlyIDs:handoffs,needles:needles,holdDigests:[],deletionTasks:[],partition:partition,budget:budget)
        }
        // A resumed attempt may have stopped because new history appeared
        // after visibility. Select it again against the original identities,
        // including ones already removed, before resuming physical deletion.
        @Sendable func observeHistory(_ reader: Database) throws -> MediaRoundDeletionHistory {
            try MediaRoundDeletionHistory.select(reader,project:progress.project,owned:owned,progressKey:historyKey,
                                                  continuing:true,writerLimit:historyLimit,projectFinal:true)
        }
        let ranges = try TicketCleanupRowRange.split(db,count:MediaRoundDeletionReadWork.partitions)
        var scanRows = 0
        var history: MediaRoundDeletionHistory?
        if let pieces = try MediaRoundDeletionReadWork.perform(db,read:{reader,index in
            let started = ProcessInfo.processInfo.systemUptime
            if index < ranges.count {
                return .references(try observeReferences(reader,partition:ranges[index]),ProcessInfo.processInfo.systemUptime - started)
            }
            return .history(try observeHistory(reader),ProcessInfo.processInfo.systemUptime - started)
        }) {
            for piece in pieces {
                switch piece {
                case .references(let rows,_): scanRows += rows.rowsRead
                case .history(let value,_): history = value
                }
            }
        }
        if history == nil {
            // A failed fanout shares no admitted byte charges with the serial
            // fallback. Its snapshot remains the one pinned by the caller.
            scanRows = try mediaRoundDeletionReferences(db,owned:owned,retainedAttachments:kept,
                handoffOnlyIDs:handoffs,needles:needles,holdDigests:[],deletionTasks:[],
                budget:MediaRoundDeletionReferenceBudget()).rowsRead
            history = try observeHistory(db)
        }
        timing.record("fence_observation",rowsRead:scanRows)
        guard let history, !history.events.isEmpty || !history.commands.isEmpty else {
            outcome = "complete"
            return nil
        }
        let fence = try MediaRoundDeletionFence(db,ids:[],events:history.events,commands:history.commands,
                                               needles:[],pendingRequestTasks:[],holdDigests:[],filePaths:[])
        outcome = "complete"
        return .init(rows:history,fence:fence)

    }

    /// A deletion can advance its own epoch and later stop on a graph fence.
    /// A different removal still expires the older operation's error receipt.
    func mediaDeletionVisibilityEpoch(_ db: Database,method: String,params: JSON,caller: Caller,command: String) throws -> String? {
        guard method == "media_round_delete",let project = params["project_id"] as? String,
              let round = params["round_id"] as? String else {return nil}
        let key = DeletionGraph.key(try MediaRoundDeletionHistory.progressKey(project:project,round:round))
        guard let progress = try DeletionGraph.load(db,key,as:DeletionGraph.Progress.self),progress.phase != .staging,
              EnvelopeStorageIdentity.equal(progress.visibilityPrincipal,caller.principal),
              EnvelopeStorageIdentity.equal(progress.visibilityCommand,command) else {return nil}
        try progress.validate(project:project,round:round)
        return progress.visibilityEpoch
    }

}
