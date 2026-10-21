import Foundation
import GRDB

extension CommandRouter {
    func taskSessionProjection(_ db: Database,_ source: JSON) throws -> JSON {
        var link = source
        let pid = source["project_id"] as? String ?? "",sid = source["session_id"] as? String ?? ""
        let session = try? scoped(db,sid,pid,type:"session")
        let current = session.map {canReceive($0,project:pid) && $0["role"] as? String == "worker" && source["session_authorization_generation"] as? String == sessionGeneration($0) && source["execution_domain"] as? String == $0["execution_domain"] as? String} ?? false
        link["binding_current"] = current;link["current_state"] = current ? "linked" : "historical";link.removeValue(forKey:"execution_domain");return link
    }
    func attachSessionToTask(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        guard c.role == "worker",let sid = c.sessionID else { throw CoreError("FORBIDDEN","Only a bound worker connection can attach its own task context.") }
        let pid = try scope(db,p,c,write:true),task = try self.task(db,p,pid),generation = try callerSessionGeneration(db,c,project:pid)
        let session = try scoped(db,sid,pid,type:"session");guard session["role"] as? String == "worker",["codex","claude"].contains((session["provider"] as? String ?? "").lowercased()) else { throw CoreError("FORBIDDEN","Personal assistants never become work connections.") }
        let digest = hash(Data((pid+":"+(task["id"] as! String)+":"+sid+":"+generation).utf8));let chars = Array(digest.prefix(32))
        let id = String(chars[0..<8])+"-"+String(chars[8..<12])+"-"+String(chars[12..<16])+"-"+String(chars[16..<20])+"-"+String(chars[20..<32])
        if let existing = try? scoped(db,id,pid,type:"task_session") { return try taskSessionProjection(db,existing) }
        var link: JSON = ["id":id,"project_id":pid,"task_id":task["id"]!,"session_id":sid,"session_authorization_generation":generation,"purpose":"context","state":"linked","revision":1,"created_at":now(),"updated_at":now()]
        if let domain = c.executionDomain { link["execution_domain"] = domain }
        try save(db,link,type:"task_session");try event(db,caller:c,project:pid,entity:task["id"] as? String,kind:"session_context_attached",data:["task_session_id":id,"session_id":sid,"purpose":"context"]);return try taskSessionProjection(db,link)
    }
    func taskSessionList(_ db: Database,_ p: JSON,_ c: Caller) throws -> JSON {
        let pid = try scope(db,p,c)
        var sessions = try records(db,type:"session",project:pid)
        if let tid = p["task_id"] as? String {
            _ = try scoped(db,tid,pid,type:"task");var linked: Set<String> = []
            for row in try records(db,type:"task_session",project:pid) where row["task_id"] as? String == tid {
                if bool(try taskSessionProjection(db,row),"binding_current"),let sid = row["session_id"] as? String { linked.insert(sid) }
            }
            for attempt in try records(db,type:"attempt",project:pid) where attempt["task_id"] as? String == tid {
                if let sid = attempt["session_id"] as? String,let session = sessions.first(where: {$0["id"] as? String == sid}),attempt["session_authorization_generation"] as? String == sessionGeneration(session) { linked.insert(sid) }
            }
            sessions = sessions.filter {linked.contains($0["id"] as? String ?? "")}
        }
        return ["sessions":sessions.map {sessionProjection($0,project:pid,caller:c)}]
    }
}
