import Foundation
import GRDB

extension CommandRouter {
    func defaultCaptureSettings() -> JSON {
        ["enabled_kinds":Self.policyKinds,"default_kind":"work","starter_overrides":[]]
    }

    /// Settings are project data. Personal views, alert permissions and delivery state stay separate.
    func validateProjectSettingsPatch(_ p: JSON, project: inout JSON) throws {
        if p["name"] != nil { project["name"] = try text(p,"name",max:200) }
        if let raw = p["key_prefix"] {
            guard let prefix = raw as? String, prefix.range(of:"^[A-Z][A-Z0-9]{0,11}$",options:.regularExpression) != nil else { throw CoreError("INVALID_INPUT","Use a short uppercase letter/number ticket prefix.") }
            project["key_prefix"] = prefix
        }
        if let raw = p["icon"] { guard let symbol = raw as? String, ["folder","checklist","gamecontroller","app","leaf","tram","sparkles","hammer","moon.stars","film"].contains(symbol) else { throw CoreError("INVALID_INPUT","Choose a supported built-in icon.") }; project["icon"] = symbol }
        if let raw = p["accent"] { guard let accent = raw as? String, ["system","teal","blue","purple","orange","green","pink"].contains(accent) else { throw CoreError("INVALID_INPUT","Choose a supported project accent.") }; project["accent"] = accent }
        if p["brief"] != nil { project["brief"] = try text(p,"brief",required:false) }
        if let raw = p["pinned_decisions"] { guard let decisions = raw as? [Any], decisions.count <= 25, decisions.allSatisfy({ $0 is String || $0 is JSON }) else { throw CoreError("INVALID_INPUT","Provide at most 25 bounded pinned decisions.") }; project["pinned_decisions"] = decisions }
        if let raw = p["default_view"] {
            guard let view = raw as? JSON, Set(view.keys) == ["group_by","order_by"], ["none","status","epic"].contains(view["group_by"] as? String ?? ""), ["manual","priority","updated_desc"].contains(view["order_by"] as? String ?? "") else { throw CoreError("INVALID_INPUT","Choose a bounded project grouping and order.") }
            project["default_view"] = view
        }
        if let raw = p["alert_override"] { guard let alerts = raw as? String, ["inherit","needs_you","quiet"].contains(alerts) else { throw CoreError("INVALID_INPUT","Choose inherited, actionable, or quiet desktop alerts.") }; project["alert_override"] = alerts }
        if let raw = p["capture_defaults"] {
            guard let capture = raw as? JSON, Set(capture.keys).isSubset(of:["enabled_kinds","default_kind","starter_overrides"]), let kinds = capture["enabled_kinds"] as? [String], Set(kinds).count == kinds.count, kinds.contains("work"), Set(kinds).isSubset(of:Set(Self.policyKinds)), let defaultKind = capture["default_kind"] as? String, kinds.contains(defaultKind), let hints = capture["starter_overrides"] as? [JSON], hints.count <= 5 else { throw CoreError("INVALID_INPUT","Capture defaults need unique enabled kinds, Work fallback, an enabled default and bounded starter hints.") }
            var seen = Set<String>()
            for hint in hints {
                guard Set(hint.keys).isSubset(of:["kind","brief_hint","outcome_hint"]), let kind = hint["kind"] as? String, Self.policyKinds.contains(kind), seen.insert(kind).inserted, hint["brief_hint"] != nil || hint["outcome_hint"] != nil else { throw CoreError("INVALID_INPUT","Each kind has at most one starter hint.") }
                for key in ["brief_hint","outcome_hint"] where hint[key] != nil { _ = try text(hint,key,max:400) }
            }
            project["capture_defaults"] = capture
        }
    }

    func projectSettingsSave(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        try owner(c); let pid = try scope(db,p,c,write:true), current = try record(db,pid,type:"project"); try revision(p,current)
        var draft = current; try validateProjectSettingsPatch(p,project:&draft)
        draft = try prepareProjectContextChange(db,old:current,updated:draft,caller:c)
        // Validate the entire draft before any policy effects, messages or identity changes are saved.
        if p["policy"] != nil { guard p["policy_proposal_id"] == nil else { throw CoreError("INVALID_INPUT","Use a policy object or its unchanged proposal, not both.") }; _ = try normalizedPolicy(p["policy"] as? JSON ?? [:]) }
        var updated: JSON
        if p["policy"] != nil || p["policy_proposal_id"] != nil {
            var params: JSON = ["project_id":pid,"expected_revision":current["revision"]!,"mode":p["mode"] ?? "future_attempts"]
            if let policy = p["policy"] { params["policy"] = policy }
            if let proposal = p["policy_proposal_id"] { params["proposal_id"] = proposal; params["digest"] = p["policy_digest"] }
            updated = try policyCommand(db,params,c,"policy_apply")
            for key in ["name","key_prefix","icon","accent","brief","pinned_decisions","context_revision","brief_revision","decisions_revision","previous_context_revision_id","context_approved_by","default_view","alert_override","capture_defaults"] { if let value = draft[key] { updated[key] = value } }
        } else { updated = revised(draft) }
        updated["settings_revision"] = int(current,"settings_revision",default:1) + 1
        try save(db,updated,type:"project"); try propagateProjectContextChange(db,old:current,updated:updated,caller:c)
        try event(db,caller:c,project:pid,entity:pid,kind:"project_settings_saved",data:["atomic":true]); return updated
    }
}
