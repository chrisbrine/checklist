import Foundation
import GRDB

/// Store upgrade 0004 (CL-125): the CL-269 store upgrade rules in
/// docs/triage-orchestrators.md#store-upgrade-rules. `plan` is pure, so
/// templates cover every rule; `apply` runs it inside the migration transaction.
enum TriageMembershipUpgrade {
    static let actor = "system:store-upgrade-0004"
    struct Event { let project: String; let entity: String; let kind: String; let data: JSON }
    struct Plan { var groups: [JSON] = []; var intervals: [JSON] = []; var exits: [JSON] = []; var events: [Event] = [] }

    static func orchestrated(_ group: JSON) -> Bool { (group["orchestration"] as? JSON)?["state"] as? String == "active" }
    /// Current members, including legacy groups that kept only task_ids.
    static func members(_ group: JSON) -> [JSON] {
        var seen = Set<String>()
        let stored = group["members"] as? [JSON] ?? []
        if !stored.isEmpty { return stored.filter { ($0["task_id"] as? String).map { seen.insert($0).inserted } ?? false } }
        return (group["task_ids"] as? [String] ?? []).filter { seen.insert($0).inserted }.map { ["task_id": $0, "joined_at": group["created_at"] ?? NSNull()] }
    }
    private static func before(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    static func plan(project pid: String, groups: [JSON], now: String, id: () -> String) -> Plan {
        var result = Plan()
        var triages = groups.filter { $0["kind"] as? String == "triage" }
        var current = triages.map(members)
        var changed = Set<Int>()
        // Rule 3: a ticket in several Triages keeps the orchestrated one; if none
        // or several are orchestrated, it keeps the newest membership.
        var holders: [String: [Int]] = [:]
        for (index, list) in current.enumerated() { for member in list { if let tid = member["task_id"] as? String { holders[tid, default: []].append(index) } } }
        for tid in holders.keys.sorted(by: before) {
            let indexes = holders[tid]!
            guard indexes.count > 1 else { continue }
            let live = indexes.filter { orchestrated(triages[$0]) }
            let candidates = live.isEmpty ? indexes : live
            func stamp(_ index: Int) -> String {
                let member = current[index].first { $0["task_id"] as? String == tid }
                return (member?["joined_at"] as? String ?? "") + "|" + (triages[index]["created_at"] as? String ?? "") + "|" + (triages[index]["id"] as? String ?? "")
            }
            let kept = candidates.max { before(stamp($0), stamp($1)) }!
            for index in indexes where index != kept {
                let group = triages[index], gid = group["id"] as? String ?? ""
                guard let member = current[index].first(where: { $0["task_id"] as? String == tid }) else { continue }
                var membershipID = member["membership_id"] as? String
                if membershipID == nil {
                    let interval: JSON = [
                        "id": id(), "project_id": pid, "triage_id": gid, "triage_key": group["key"] ?? "", "triage_name": group["name"] ?? "",
                        "task_id": tid, "joined_at": member["joined_at"] ?? NSNull(), "membership_snapshot": member, "actor": actor, "revision": 1,
                        "created_at": now, "originating_triage_revision": NSNull(), "history_source": "legacy_membership_observation",
                    ]
                    result.intervals.append(interval)
                    membershipID = interval["id"] as? String
                }
                let exit: JSON = [
                    "id": id(), "project_id": pid, "triage_id": gid, "triage_key": group["key"] ?? "", "triage_name": group["name"] ?? "",
                    "membership_id": membershipID!, "task_id": tid, "exited_at": now, "reason": "upgrade_single_membership",
                    "triage_revision": int(group, "revision") + 1, "actor": actor, "previous_membership": member, "revision": 1,
                    "kept_triage_id": triages[kept]["id"] ?? NSNull(), "label": "Store upgrade kept one Triage per ticket",
                ]
                result.exits.append(exit)
                result.events.append(Event(project: pid, entity: gid, kind: "triage_member_exited", data: exit))
                result.events.append(Event(project: pid, entity: tid, kind: "task_left_triage", data: [
                    "triage_id": gid, "triage_key": group["key"] ?? "", "triage_name": group["name"] ?? "", "membership_id": membershipID!,
                    "reason": "upgrade_single_membership", "label": "Store upgrade kept one Triage per ticket"]))
                current[index].removeAll { $0["task_id"] as? String == tid }
                changed.insert(index)
            }
        }
        for index in triages.indices {
            var group = triages[index]
            // Legacy groups with only task_ids gain explicit member records.
            if (group["members"] as? [JSON] ?? []).isEmpty && !current[index].isEmpty { changed.insert(index) }
            // Rule 5: an empty Triage with no orchestrator archives, with its history kept.
            let archive = !bool(group, "archived") && !orchestrated(group) && current[index].isEmpty
            guard changed.contains(index) || archive else { continue }
            group["members"] = current[index]
            group["task_ids"] = current[index].compactMap { $0["task_id"] as? String }
            if archive {
                group["archived"] = true
                group["archived_at"] = now
                group["archive_reason"] = "upgrade_empty_without_orchestrator"
                result.events.append(Event(project: pid, entity: group["id"] as? String ?? "", kind: "triage_archived_automatically",
                                           data: ["reason": "upgrade_empty_without_orchestrator", "history_kept": true]))
            }
            group["revision"] = int(group, "revision") + 1
            group["updated_at"] = now
            triages[index] = group
            result.groups.append(group)
        }
        return result
    }

    static func apply(_ db: Database, now: String = ISO8601DateFormatter().string(from: Date())) throws {
        let projects = try String.fetchAll(db, sql: "SELECT DISTINCT CAST(project_id AS TEXT) FROM records WHERE type='group' AND project_id IS NOT NULL ORDER BY 1")
        for pid in projects {
            let groups = try Row.fetchAll(
                db, sql: "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='group' AND project_id=CAST(? AS TEXT) ORDER BY rowid",
                arguments: [Data(pid.utf8)]
            ).map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "group").object }
            let plan = plan(project: pid, groups: groups, now: now, id: { UUID().uuidString.lowercased() })
            for group in plan.groups {
                try db.execute(sql: "UPDATE records SET data=CAST(? AS TEXT),revision=? WHERE id=CAST(? AS TEXT)",
                               arguments: [Data(try jsonString(group).utf8), int(group, "revision"), Data((try StoredRecord(group, family: "group").string("id")).utf8)])
            }
            for (type, values) in [("triage_membership_interval", plan.intervals), ("triage_membership_exit", plan.exits)] {
                for value in values {
                    try db.execute(sql: "INSERT INTO records(id,project_id,type,revision,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),1,CAST(? AS TEXT))",
                                   arguments: [Data((try StoredRecord(value, family: type).string("id")).utf8), Data(pid.utf8), Data(type.utf8), Data(try jsonString(value).utf8)])
                }
            }
            for item in plan.events {
                try db.execute(sql: "INSERT INTO events(id,project_id,entity_id,actor,kind,occurred_at,data) VALUES (CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT),CAST(? AS TEXT))",
                               arguments: [Data(UUID().uuidString.lowercased().utf8), Data(item.project.utf8), Data(item.entity.utf8), Data(actor.utf8),
                                           Data(item.kind.utf8), Data(now.utf8), Data(try jsonString(item.data).utf8)])
            }
        }
    }
}
