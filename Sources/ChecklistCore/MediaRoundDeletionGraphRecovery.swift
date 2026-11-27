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
                                          work: DeletionGraph.Work, historyKey: String, historyLimit: Int) throws -> MediaGraphResumeHistory? {
        if !work.handoffOnlyIDs.isEmpty, (progress.handoffWitnessCount ?? 0) == 0 {
            throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
        }
        guard progress.next >= 0, progress.next <= work.slices.count else {
            throw StoreRecovery.required("media_deletion_graph_progress_invalid")
        }
        var expected = work.fence.records
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
                    guard let previous = expected[id], let data = change.data, let revision = change.revision else {
                        throw StoreRecovery.required("media_deletion_graph_journal_invalid")
                    }
                    expected[id] = .init(position:change.position,revision:revision,digest:MediaPreparationOverlay.digest(Data(data.utf8)),
                                         type:previous.type,project:project)
                    // The exact planned rewrite now carries historical
                    // provenance naming this round. The original incoming
                    // references were checked before that rewrite.
                    undetachedHandoffs.remove(id)
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
        let owned = Set(work.slices.flatMap(\.members).map {Data($0.utf8)})
        guard owned.count == progress.total,
              try MediaRoundDeletionFence.protectingProjects(db,ancestors:work.fence.workspaceAncestors) == work.fence.workspaceProtections else {
            throw MediaRoundDeletionFence.changed("graph_resume_authority",type:"media_round",id:Data(progress.round.utf8))
        }
        func tokens(_ raw: String) throws -> Set<Data> {
            let values = try JSONDecoder().decode([String].self,from:Data(raw.utf8))
            return Set(values.map {Data($0.utf8)})
        }
        let references = try mediaRoundDeletionReferences(db,owned:owned,retainedAttachments:work.kept,
            handoffOnlyIDs:undetachedHandoffs,needles:tokens(work.fence.tokens),
            holdDigests:tokens(work.fence.digests),deletionTasks:tokens(work.fence.tasks),
            budget:MediaRoundDeletionReferenceBudget())
        let observedHolds = Set(expected.filter { $0.value.type == Data("storage_hold".utf8) && !owned.contains($0.key) }.keys)
        if let changedHold = references.ids.symmetricDifference(observedHolds).first {
            throw MediaRoundDeletionFence.changed("changed_reference",type:"storage_hold",id:changedHold)
        }
        // A resumed attempt may have stopped because new history appeared
        // after visibility. Select it again against the original identities,
        // including ones already removed, before resuming physical deletion.
        let history = try MediaRoundDeletionHistory.select(db,project:progress.project,owned:owned,progressKey:historyKey,
                                                            continuing:true,writerLimit:historyLimit,projectFinal:true)
        guard !history.events.isEmpty || !history.commands.isEmpty else {return nil}
        let fence = try MediaRoundDeletionFence(db,ids:[],events:history.events,commands:history.commands,
                                               needles:[],pendingRequestTasks:[],holdDigests:[],filePaths:[])
        return .init(rows:history,fence:fence)

    }

    // Keep the retained proof after the ordinary work shards are retired.
    // These pages are staged in bounded passes and removed with publication.
    func prepareMediaGraphHandoffWitnesses(_ plan: MediaRoundDeletionPlan,kept: [DeletionGraph.Change],
                                           graphKey: String) throws -> [DeletionGraph.Slice] {
        guard !plan.handoffWitnessIDs.isEmpty else {return []}
        var witnesses = try Dictionary(uniqueKeysWithValues:plan.handoffWitnessIDs.map { id in
            (id,try plan.graphWitness(String(decoding:id,as:UTF8.self)))
        })
        for change in kept where plan.handoffOnlyIDs.contains(Data(change.id.utf8)) {
            let id = Data(change.id.utf8)
            guard let data = change.data,let revision = change.revision,let previous = witnesses[id] else {
                throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
            }
            witnesses[id] = .init(position:change.position,revision:revision,digest:MediaPreparationOverlay.digest(Data(data.utf8)),
                                  type:previous.type,project:previous.project)
        }
        let ordered = witnesses.sorted {$0.key.lexicographicallyPrecedes($1.key)}
        let prefix = DeletionGraph.handoffWitnessPrefix(graphKey)
        return try stride(from:0,to:ordered.count,by:DeletionGraph.rowLimit).map { offset in
            let entries = ordered[offset..<min(offset + DeletionGraph.rowLimit,ordered.count)]
            let page = Dictionary(uniqueKeysWithValues:entries.map {($0.key,$0.value)})
            let change = DeletionGraph.Change(id:prefix + String(format:"%08d",offset),data:try DeletionGraph.encode(page),revision:nil,position:0)
            return .init(kind:.audit,changes:[change])
        }
    }

    func readMediaGraphHandoffWitnesses(_ db: Database,progress: DeletionGraph.Progress,graphKey: String,
                                       hasKeptAttachments: Bool) throws -> [Data:MediaRoundDeletionFence.Record] {
        guard let count = progress.handoffWitnessCount else {
            // Old journals did not record the proof. A hidden successor with
            // kept attachments cannot reconstruct its erased handoff header.
            if progress.predecessor != nil,hasKeptAttachments {
                throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
            }
            return [:]
        }
        guard count > 0 else {return [:]}
        let prefix = DeletionGraph.handoffWitnessPrefix(graphKey)
        let pages = try Row.fetchCursor(db,sql:"SELECT key,CAST(value AS BLOB) data FROM metadata WHERE key>=? AND key<? ORDER BY key",
                                        arguments:[prefix,prefix + "~"])
        var witnesses: [Data:MediaRoundDeletionFence.Record] = [:]
        while let row = try pages.next() {
            guard witnesses.count < count,row["key"] as String == prefix + String(format:"%08d",witnesses.count),
                  let page = try? JSONDecoder().decode([Data:MediaRoundDeletionFence.Record].self,from:row["data"]),
                  page.count == min(DeletionGraph.rowLimit,count - witnesses.count) else {
                throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
            }
            for (id,witness) in page {
                guard witnesses.updateValue(witness,forKey:id) == nil else {
                    throw StoreRecovery.required("media_deletion_graph_handoff_unverified")
                }
                guard try MediaRoundDeletionFence.record(db,id:id) == witness else {
                    throw MediaRoundDeletionFence.changed("planned_record_changed",type:String(decoding:witness.type,as:UTF8.self),id:id)
                }
            }
        }
        guard witnesses.count == count else {throw StoreRecovery.required("media_deletion_graph_handoff_unverified")}
        return witnesses
    }

    func validateMediaGraphHandoffPublication(_ db: Database,context: GraphDeletionContext,
                                              witnesses: [Data:MediaRoundDeletionFence.Record]) throws {
        try context.changes.validateObservation(db,writerVersion:context.writerVersion)
        let changes = try Data.fetchCursor(db,sql:"SELECT id FROM \(context.changes.name) WHERE kind=0")
        while let id = try changes.next() {
            if let witness = witnesses[id] {
                throw MediaRoundDeletionFence.changed("planned_record_changed",type:String(decoding:witness.type,as:UTF8.self),id:id)
            }
        }
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
