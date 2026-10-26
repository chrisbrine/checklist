import ChecklistApplication
import ChecklistDomain
import GRDB

extension CommandRouter {
    /// Called only by dispatch inside execute's validated domain transaction.
    /// No plan is published before its event, Epic projection and principal receipt commit.
    func taskCreate(_ db: Database, _ p: JSON, _ c: Caller) throws -> JSON {
        let pid = try scope(db, p, c, write: true)
        var project = try record(db, pid, type: "project")
        if c.role == CallerRole.assistant.rawValue,
           p["planned_assignee"] != nil || p["key"] != nil || p["epic_id"] != nil {
            throw CoreError("FORBIDDEN", "Assistants capture Drafts without work assignment.")
        }
        try assistantPermission(c, pid, "create_drafts_on_request")
        guard let title = p["title"] as? String else {
            throw CoreError("INVALID_INPUT", "title is required.")
        }
        try captureOperation { try TicketCapture.validateTitle(title) }
        guard let kind = TicketKind(rawValue: p["kind"] as? String ?? TicketKind.work.rawValue) else {
            throw CoreError("INVALID_INPUT", "Unsupported task kind.")
        }
        let queued = try status(db, pid, TicketStatusCategory.queued.rawValue)
        let input = TicketCaptureInput(title: title, kind: kind, requestedKey: p["key"] as? String,
                                       tagIDs: strings(p, "tag_ids"))
        let state = TicketCaptureState(
            projectID: pid, keyPrefix: project["key_prefix"] as? String ?? "TASK",
            nextNumber: int(project, "next_number", default: 1),
            existingKeys: Set(try records(db, type: "task", project: pid).compactMap { $0["key"] as? String }),
            queuedStatusID: queued["id"] as! String, ticketID: uuid(), timestamp: now()
        )
        let plan = try captureOperation { try TicketCapture.plan(input, state: state) }
        // Preserve legacy optional/null and open owner-input behavior. No codec or digest changes.
        var task: JSON = [
            "id": state.ticketID, "project_id": state.projectID, "key": plan.key,
            "title": input.title, "brief": try text(p, "brief", required: false),
            "acceptance": p["acceptance"] ?? [], "acceptance_revision": 1,
            "kind": input.kind.rawValue, "readiness": plan.readiness, "status_id": state.queuedStatusID,
            "priority": p["priority"] ?? "normal", "tag_ids": input.tagIDs,
            "revision": 1, "archived": false, "trashed": false,
            "created_at": state.timestamp, "updated_at": state.timestamp
        ]
        if let assignment = p["planned_assignee"] {
            try validateAssignment(assignment)
            task["planned_assignee"] = assignment
        }
        if let fields = try validatedStarterFields(p["starter_fields"], kind: kind.rawValue) {
            task["starter_fields"] = fields
        }
        let epicID = try requiredEpicID(db, project: pid, value: p["epic_id"])
        task["epic_id"] = epicID
        let epic = try scoped(db, epicID, pid, type: "group")
        guard epic["kind"] as? String == "epic", !bool(epic, "archived") else {
            throw CoreError("INVALID_INPUT", "Choose a current Epic in this project.")
        }
        for tag in input.tagIDs { _ = try scoped(db, tag, pid, type: "tag") }
        try validateTaskPolicyAssignment(db, project: project, task: &task, input: p, caller: c)
        task["created_by"] = c.principal
        task["origin"] = c.isOwner ? "human_ui" : c.role
        project["next_number"] = plan.nextNumber
        try save(db, project, type: "project")
        try save(db, task, type: "task")
        _ = try syncEpic(db, try scoped(db, epicID, pid, type: "group"))
        try event(db, caller: c, project: pid, entity: state.ticketID, kind: "task_created", data: ["key": plan.key])
        return try taskProjection(db, task)
    }

    private func captureOperation<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch TicketCaptureFailure.invalidTitle {
            throw CoreError("INVALID_INPUT", "title must contain text and be at most 2000 bytes.")
        } catch TicketCaptureFailure.keyConflict {
            throw CoreError("KEY_CONFLICT", "This ticket key is already in this project.")
        }
    }
}
