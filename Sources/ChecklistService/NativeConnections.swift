import Foundation
import Security
import CryptoKit
import Darwin
import ChecklistCore
import ChecklistIPC

// Automatic worker connections have a native process boundary. A thread ID is
// host-exported context, not a cryptographically attested thread identity.
extension Coordinator {
    func bootstrap(_ context:[String:Any], connection:NSXPCConnection) throws -> [String:Any] {
        guard bundledCLI(connection.processIdentifier) else { throw ChecklistError("NATIVE_CLIENT_REQUIRED","Connect through the installed Checklist executable inside a Codex or Claude thread.") }
        guard let provider=context["provider"] as? String,["codex","claude"].contains(provider),
              let sid=context["native_session_id"] as? String,UUID(uuidString:sid) != nil else { throw ChecklistError("NATIVE_SESSION_REQUIRED","This process does not expose a supported native thread identity.") }
        let process = try nativeProcess(connection.processIdentifier, provider:provider)
        let executionDomain=try processDomain(process,provider:provider)
        let workspace = try currentDirectory(connection.processIdentifier)
        if let supplied=context["workspace_path"] as? String,canonical(supplied) != workspace { throw ChecklistError("WORKSPACE_MISMATCH","The supplied workspace differs from this process's actual working directory.") }
        if provider == "claude" { try verifyClaudeRegistry(process,session:sid,workspace:workspace,endpoint:context["native_endpoint"] as? String) }
        let owner=Caller(role:"owner",installation:"native-thread-bootstrap",projectIDs:[])
        let relay=context["mode"] as? String == "assistant_relay"
        guard context["mode"] == nil || relay else { throw ChecklistError("INVALID_CONNECTION_MODE","Use worker or personal-assistant relay access.") }
        if relay && provider != "codex" { throw ChecklistError("ADAPTER_UNAVAILABLE","The personal-assistant helper currently uses native Codex.") }
        let resolved=try router.handle(method:relay ? "project_list":"project_resolve",params:relay ? [:]:["workspace_path":workspace],caller:owner)
        let body=resolved["data"] as? [String:Any] ?? resolved
        var projects=body["projects"] as? [[String:Any]] ?? []
        if relay {
            guard let reference=context["project_ref"] as? String,!reference.isEmpty else { throw ChecklistError("PROJECT_REQUIRED","Personal assistant helpers explicitly choose a granted project.") }
            if reference == "@enabled" { projects=projects.filter { $0["archived"] as? Bool != true && ((($0["policy"] as? [String:Any])?["assistant_relay_grants"] as? [String:Bool])?["read"] == true) } }
            else { projects=projects.filter { ($0["id"] as? String) == reference || ($0["name"] as? String)?.localizedCaseInsensitiveCompare(reference) == .orderedSame };guard projects.count <= 1 else { throw ChecklistError("AMBIGUOUS_PROJECT","Use the stable ID for one of these identically named projects.") } }
            projects.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        }
        guard (relay ? !projects.isEmpty:projects.count == 1),let project=projects.first,
              project["archived"] as? Bool != true,let pid=project["id"] as? String else { throw ChecklistError("PROJECT_SETUP_REQUIRED","Add this workspace as a project in Checklist first. Existing checklists are never imported automatically.") }
        let projectRoot=project["root_path"] as? String ?? ""
        guard relay || !projectRoot.isEmpty else { throw ChecklistError("PROJECT_SETUP_REQUIRED","This project needs a workspace folder.") }
        let projectIDs=projects.compactMap{$0["id"] as? String}
        var grantMap:[String:[String:Bool]]=[:],grantRevisions:[String:Int]=[:]
        if relay { for item in projects { if let id=item["id"] as? String { grantMap[id]=try relayGrants(item);grantRevisions[id]=(item["policy_revision"] as? NSNumber)?.intValue ?? 1 } } }
        let selector=relay && context["project_ref"] as? String == "@enabled" ? "@enabled":pid
        let selectorDigest=SHA256.hash(data:Data(selector.utf8)).map{String(format:"%02x",$0)}.joined()
        let boundSessionID=relay ? "assistant-\(sid)-\(selectorDigest.prefix(10))":sid
        let binding=relay ? nil:canonical(projectRoot)
        let identity=relay ? "\(provider)|\(sid)|\(selector)|assistant_relay":"\(provider)|\(sid)|\(pid)"
        let digest=SHA256.hash(data:Data(identity.utf8)).map{String(format:"%02x",$0)}.joined()
        let installation="auto-\(provider)-\(digest.prefix(40))"
        guard !enrollments.values.contains(where:{$0.sessionID == boundSessionID && $0.installation != installation}) else { throw ChecklistError("BINDING_CHANGED","This reported session is already bound to another connection. Use a thread created for this project.") }
        if var existing=enrollments[installation] {
            if existing.revoked == true || existing.nativeExecutionDomain != executionDomain {
                // A host resumed this conversation in a new process; never borrow the old generation.
                let resumed=try resumeAfterVerifiedClosure(existing,project:pid,executionDomain:executionDomain,binding:binding,process:process,endpoint:context["native_endpoint"] as? String,owner:owner)
                return connectionResult(resumed,project:pid)
            }
            guard existing.sessionID == boundSessionID,existing.workspace == binding,existing.provider == provider,relay || existing.projectIDs == [pid] else { throw ChecklistError("BINDING_CHANGED","The registered workspace changed. Review this connection in Checklist before reconnecting.") }
            guard (existing.assistantRelay == true) == relay else { throw ChecklistError("CONNECTION_MODE_MISMATCH","This native thread cannot change its access role.") }
            // Ordinary MCP/client restarts do not rotate claims, deliveries or grants.
            guard let credential = try ChecklistKeychain.read(installation), SHA256.hash(data: Data(credential.utf8)).map({ String(format: "%02x", $0) }).joined() == existing.tokenDigest else { throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "This thread's saved credential does not match its enrollment. Repair it in Checklist.") }
            let current=try router.handle(method:"session_list",params:["project_id":pid],caller:owner)
            let sessions=(current["data"] as? [String:Any] ?? current)["sessions"] as? [[String:Any]] ?? []
            if let session=sessions.first(where:{$0["id"] as? String == boundSessionID}) {
                guard !["revoked","ended"].contains(session["state"] as? String ?? "") else { throw ChecklistError("CONNECTION_REVOKED","This thread was ended or disconnected. Its authority cannot be resumed automatically.") }
                guard ConnectionCommit.registrationMatches(session, sessionID: existing.sessionID, installation: existing.installation, generation: existing.generation, role: existing.role, provider: existing.provider, projects: existing.projectIDs) else { throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "This prepared connection does not match its committed session. Repair it in Checklist.") }
            } else {
                // Repair only an interrupted initial registration. Existing generations stay intact.
                _ = try registerAutomatic(existing,project:pid,caller:owner)
            }
            if relay,(existing.assistantGrants != grantMap || existing.relayPolicyRevisions != grantRevisions || existing.projectIDs != projectIDs) {
                existing.assistantGrants=grantMap;existing.relayPolicyRevisions=grantRevisions;existing.relaySelector=selector;existing.projectIDs=projectIDs;existing.generation=UUID().uuidString
                _ = try registerAutomatic(existing,project:pid,caller:owner)
                enrollments[installation]=existing;try saveEnrollments()
            }
            try requireCommittedRegistration(existing, project: pid, caller: owner)
            return connectionResult(existing, project:pid)
        }
        let snapshot=try router.handle(method:"snapshot",params:[:],caller:owner)
        let records=(snapshot["data"] as? [String:Any] ?? snapshot)["sessions"] as? [[String:Any]] ?? []
        guard !records.contains(where:{$0["id"] as? String == boundSessionID}) else { throw ChecklistError("SESSION_ID_CONFLICT","This reported session identifier already belongs to another connection. It cannot replace that connection.") }
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else { throw ChecklistError("RANDOM_FAILURE","Could not create the thread connection.") }
        let token=Data(bytes).base64EncodedString()
        let label=relay ? "Personal assistant helper · \(sid.prefix(8))":"\(provider == "codex" ? "Codex":"Claude") thread \(sid.prefix(8))"
        var enrollment=Enrollment(installation:installation,name:label,provider:provider,role:relay ? "assistant":"worker",projectIDs:projectIDs,sessionID:boundSessionID,workspace:binding,profileID:nil,tokenDigest:SHA256.hash(data:Data(token.utf8)).map{String(format:"%02x",$0)}.joined(),generation:UUID().uuidString)
        enrollment.nativeSessionID=sid
        enrollment.automatic=true;enrollment.revoked=false;enrollment.identityVerification=provider == "codex" ? "native_process_verified_thread_observed":"native_process_and_session_registry_verified"
        enrollment.nativeExecutionDomain=executionDomain
        enrollment.assistantRelay=relay
        if relay { enrollment.assistantGrants=grantMap;enrollment.relayPolicyRevisions=grantRevisions;enrollment.relaySelector=selector;enrollment.identityVerification="native_codex_helper_not_dot_identity" }
        if provider == "claude",let endpoint=context["native_endpoint"] as? String { try bindClaudeEndpoint(&enrollment,endpoint:endpoint,process:process) }
        // Save no caller-supplied role, projects, profile, title or human provenance.
        _ = try ConnectionCommit.perform(
            saveCredential: { try ChecklistKeychain.write(installation, token) },
            saveEnrollment: { enrollments[installation] = enrollment; try saveEnrollments() },
            registerSession: { try registerAutomatic(enrollment, project: pid, caller: owner) },
            rollback: { try ConnectionCommit.restore(enrollment: { enrollments.removeValue(forKey: installation); try saveEnrollments() }, credential: { try ChecklistKeychain.removeChecked(installation) }) })
        try requireCommittedRegistration(enrollment, project: pid, caller: owner)
        return connectionResult(enrollment,project:pid)
    }

    func requireCommittedRegistration(_ enrollment: Enrollment, project: String, caller: Caller) throws {
        let result = try router.handle(method: "session_list", params: ["project_id": project], caller: caller)
        let sessions = (result["data"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
        guard sessions.contains(where: { ConnectionCommit.registrationMatches($0, sessionID: enrollment.sessionID, installation: enrollment.installation, generation: enrollment.generation, role: enrollment.role, provider: enrollment.provider, projects: enrollment.projectIDs) }) else {
            throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "The saved connection does not match its committed registration. No authority was resumed.")
        }
        if let command = enrollment.pairingCommandID {
            guard let digest = enrollment.pairingIntentDigest, let principal = enrollment.pairingPrincipal,
                  try router.connectionRegistrationIsCurrent(commandID: command, digest: digest, sessionID: enrollment.sessionID, installation: enrollment.installation, receiptPrincipal: principal, caller: caller) else {
                throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "Pairing preparation has no matching committed receipt. Reconcile its original command before repair.")
            }
        }
    }

    private func bindClaudeEndpoint(_ enrollment:inout Enrollment,endpoint:String,process:pid_t) throws {
        let expected="/tmp/cc-socks/\(process).sock"
        var attrs=stat()
        guard endpoint == expected,lstat(endpoint,&attrs)==0,attrs.st_mode & S_IFMT == S_IFSOCK,attrs.st_uid == getuid(),attrs.st_mode & 0o077 == 0 else { throw ChecklistError("NATIVE_ROUTE_MISMATCH","Claude's local route does not belong to this native process.") }
        enrollment.nativeEndpoint=endpoint;enrollment.nativeDevice=UInt64(attrs.st_dev);enrollment.nativeInode=UInt64(attrs.st_ino)
    }

    /// A host such as Claude Code can resume a conversation (same native session ID)
    /// in a new process. After the verified closure of the earlier process released
    /// its work, the thread gets a new credential and authorization generation.
    /// Released claims and queued deliveries stay with the ended generation; an owner
    /// disconnect stays final.
    private func resumeAfterVerifiedClosure(_ existing:Enrollment,project:String,executionDomain:String,binding:String?,process:pid_t,endpoint:String?,owner:Caller) throws -> Enrollment {
        let ownerDisconnected=ChecklistError("CONNECTION_REVOKED","The owner disconnected this thread in Checklist. It cannot reconnect automatically.")
        // Verified closure applies only to these enrollments; any other revocation is the owner's.
        guard existing.automatic == true,existing.role == "worker",existing.assistantRelay != true,existing.provider == "claude",
              existing.identityVerification == "native_process_and_session_registry_verified",let oldDomain=existing.nativeExecutionDomain else {
            if existing.revoked == true { throw ownerDisconnected }
            throw ChecklistError("NATIVE_SESSION_MISMATCH","This reported thread was connected by a different native host process. Its claims and messages cannot be borrowed.")
        }
        guard existing.ownerRevoked != true else { throw ownerDisconnected }
        // execute() observed native lifecycles before this request, so an unfenced
        // enrollment means the earlier process has no verified closure yet.
        guard existing.revoked == true else { throw ChecklistError("NATIVE_SESSION_MISMATCH","This thread's earlier process has no verified closure yet. Its claims and messages cannot be borrowed.") }
        // The same live process cannot have a verified closure, so its revocation is the owner's.
        guard oldDomain != executionDomain else { throw ownerDisconnected }
        guard existing.workspace == binding,existing.projectIDs == [project] else { throw ChecklistError("BINDING_CHANGED","The registered workspace changed. Review this connection in Checklist before reconnecting.") }
        // An owner disconnect before this build removed the saved credential; a verified closure kept it.
        let priorCredential=try ChecklistKeychain.read(existing.installation)
        guard let priorCredential,SHA256.hash(data:Data(priorCredential.utf8)).map({String(format:"%02x",$0)}).joined() == existing.tokenDigest else {
            throw ownerDisconnected
        }
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else { throw ChecklistError("RANDOM_FAILURE","Could not create the thread connection.") }
        let token=Data(bytes).base64EncodedString()
        var resumed=existing
        resumed.generation=UUID().uuidString;resumed.nativeExecutionDomain=executionDomain;resumed.revoked=false
        resumed.tokenDigest=SHA256.hash(data:Data(token.utf8)).map{String(format:"%02x",$0)}.joined()
        resumed.nativeEndpoint=nil;resumed.nativeDevice=nil;resumed.nativeInode=nil
        if let endpoint { try bindClaudeEndpoint(&resumed,endpoint:endpoint,process:process) }
        let resumption=NativeSessionResumption(projectID:project,sessionID:existing.sessionID,provider:existing.provider,
            oldInstallation:existing.installation+"/"+existing.generation,oldExecutionDomain:oldDomain,
            newInstallation:resumed.installation+"/"+resumed.generation,newExecutionDomain:executionDomain)
        _ = try ConnectionCommit.perform(
            saveCredential: { try ChecklistKeychain.write(existing.installation, token) },
            saveEnrollment: { enrollments[existing.installation] = resumed; try saveEnrollments() },
            registerSession: { try router.resumeVerifiedNativeSession(resumption, caller: owner) },
            rollback: { try ConnectionCommit.restore(enrollment: { enrollments[existing.installation] = existing; try saveEnrollments() }, credential: { try ChecklistKeychain.write(existing.installation, priorCredential) }) })
        try requireCommittedRegistration(resumed, project: project, caller: owner)
        return resumed
    }

    private func registerAutomatic(_ e:Enrollment,project:String,caller:Caller) throws -> [String:Any] {
        var params:[String:Any]=["command_id":UUID().uuidString.lowercased(),"project_id":project,"project_ids":e.projectIDs,"session_id":e.sessionID,"installation":e.installation+"/"+e.generation,"provider":e.provider,"role":e.role,"workspace":e.workspace ?? "","name":e.name,"execution_domain":e.nativeExecutionDomain ?? ""]
        if let grants=e.assistantGrants { params["assistant_grants"]=grants }
        return try router.handle(method:"session_register",params:params,caller:caller)
    }

    func verifyAutomatic(_ e:Enrollment,request:[String:Any],connection:NSXPCConnection) throws -> String {
        guard bundledCLI(connection.processIdentifier),let context=request["native_context"] as? [String:Any],context["provider"] as? String == e.provider,context["native_session_id"] as? String == (e.nativeSessionID ?? e.sessionID) else { throw ChecklistError("NATIVE_SESSION_REQUIRED","Use this connection from its actual native thread. An installation label cannot select a different thread.") }
        let native=try nativeProcess(connection.processIdentifier,provider:e.provider)
        guard try processDomain(native,provider:e.provider) == e.nativeExecutionDomain else { throw ChecklistError("NATIVE_SESSION_MISMATCH","This connection belongs to another native host process.") }
        let workspace=try currentDirectory(connection.processIdentifier)
        guard let supplied=request["workspace"] as? String,canonical(supplied) == workspace else { throw ChecklistError("WORKSPACE_MISMATCH","This process differs from its claimed working directory.") }
        if e.assistantRelay == true {
            guard context["mode"] as? String == "assistant_relay",let selector=e.relaySelector else { throw ChecklistError("CONNECTION_MODE_MISMATCH","Use the personal-assistant helper access mode for this connection.") }
            let result=try router.handle(method:"project_list",params:[:],caller:Caller(role:"owner",installation:"relay-grant-check",projectIDs:[]))
            let data=result["data"] as? [String:Any] ?? result
            let candidates=(data["projects"] as? [[String:Any]] ?? []).filter { item in selector == "@enabled" ? (item["archived"] as? Bool != true && ((item["policy"] as? [String:Any])?["assistant_relay_grants"] as? [String:Bool])?["read"] == true):item["id"] as? String == selector }
            var current:[String:[String:Bool]]=[:],revisions:[String:Int]=[:]
            for project in candidates { if let id=project["id"] as? String { current[id]=try relayGrants(project);revisions[id]=(project["policy_revision"] as? NSNumber)?.intValue ?? 1 } }
            guard !current.isEmpty,e.assistantGrants == current,e.relayPolicyRevisions == revisions,Set(e.projectIDs) == Set(current.keys) else { throw ChecklistError("ASSISTANT_GRANTS_CHANGED","The owner changed project assistant access. Reconnect to apply it; cached access is unavailable.") }
        } else {
            guard context["mode"] == nil,let bound=e.workspace,contains(bound,workspace) else { throw ChecklistError("WORKSPACE_MISMATCH","This process is outside the connection's bound workspace.") }
        }
        if e.provider == "claude" { try verifyClaudeRegistry(native,session:e.sessionID,workspace:workspace,endpoint:context["native_endpoint"] as? String) }
        return workspace
    }

    private func verifyClaudeRegistry(_ process:pid_t,session:String,workspace:String,endpoint:String?) throws {
        let file=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions/\(process).json")
        var attrs=stat()
        guard lstat(file.path,&attrs)==0,attrs.st_mode & S_IFMT == S_IFREG,attrs.st_uid == getuid(),attrs.st_mode & 0o022 == 0,attrs.st_size <= 65_536,
              let bytes=try? Data(contentsOf:file),let record=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
              (record["pid"] as? NSNumber)?.int32Value == process,record["sessionId"] as? String == session,
              let root=record["cwd"] as? String,contains(canonical(root),workspace) else { throw ChecklistError("NATIVE_SESSION_MISMATCH","Claude's current session registry does not match this native process and workspace.") }
        if let endpoint { guard record["messagingSocketPath"] as? String == endpoint else { throw ChecklistError("NATIVE_ROUTE_MISMATCH","Claude's route differs from its current session registry.") } }
    }

    func connectionResult(_ enrollment:Enrollment,project:String)->[String:Any] {
        ["data":["installation":enrollment.installation,"project_id":project,"project_ids":enrollment.projectIDs,"session_id":enrollment.sessionID,"native_session_id":enrollment.nativeSessionID ?? enrollment.sessionID,"workspace":enrollment.workspace ?? "","provider":enrollment.provider,"role":enrollment.role,"connected":true,"identity_verification":enrollment.identityVerification ?? "owner_enrolled","connection_mode":enrollment.assistantRelay == true ? "assistant_relay":"automatic_on_use","dot_identity_verified":false]]
    }

    private func relayGrants(_ project:[String:Any]) throws -> [String:Bool] {
        guard project["archived"] as? Bool != true,let policy=project["policy"] as? [String:Any],let requested=policy["assistant_relay_grants"] as? [String:Bool],requested["read"] == true else { throw ChecklistError("ASSISTANT_ACCESS_DISABLED","Enable Personal assistant access in this project's Checklist settings first.") }
        let keys:Set<String>=["read","create_drafts_on_request","post_notes_on_request","receive_messages","receive_notifications"]
        guard Set(requested.keys).isSubset(of:keys),requested["receive_notifications"] != true else { throw ChecklistError("UNSUPPORTED_ASSISTANT_GRANT","Direct Dot event notifications are not available through the on-demand helper.") }
        return Dictionary(uniqueKeysWithValues:keys.map{($0,requested[$0] ?? false)})
    }

    func prepareHandoff(_ p:[String:Any],caller:Caller) throws -> [String:Any] {
        guard caller.role == "owner",let provider=p["provider"] as? String,["codex","claude"].contains(provider),let pid=p["project_id"] as? String,let tid=p["task_id"] as? String else { throw ChecklistError("INVALID_HANDOFF","Choose a task and Codex or Claude from the native app.") }
        let result=try router.handle(method:"task_get",params:["project_id":pid,"task_id":tid],caller:caller)
        let task=result["data"] as? [String:Any] ?? result
        let projectResult=try router.handle(method:"project_settings_get",params:["project_id":pid],caller:caller)
        let project=projectResult["data"] as? [String:Any] ?? projectResult
        let root=project["root_path"] as? String ?? ""
        let key=task["key"] as? String ?? tid
        let instruction=try ChecklistHandoff.instruction(key:key,title:task["title"] as? String ?? "task",root:root,projectID:pid,taskID:tid,cliCommand:ChecklistInstance.current.cliCommand)
        var response:[String:Any]=["provider":provider,"task_key":key,"title":task["title"] as? String ?? "","instruction":instruction,"connection_mode":"automatic_on_use","launch_available":false,"limitation":"Checklist cannot start a native desktop turn directly. A native Codex agent can create a thread with this context; the new thread then attaches itself to the ticket."]
        var directory:ObjCBool=false
        if provider == "codex",root.hasPrefix("/"),FileManager.default.fileExists(atPath:root,isDirectory:&directory),directory.boolValue {
            var components=URLComponents();components.scheme="codex";components.host="threads";components.path="/new";components.queryItems=[URLQueryItem(name:"prompt",value:instruction),URLQueryItem(name:"path",value:root)]
            if let url=components.url { response["compose_url"]=url.absoluteString;response["limitation"]="The prepared Codex chat opens with the ticket context filled in. Press Send there to start; the new thread connects and attaches itself automatically. Opening a composer alone does not create or connect a session." }
        }
        return ["data":response]
    }

    private func canonical(_ path:String)->String { URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path }
    private func contains(_ root:String,_ path:String)->Bool { path == root || path.hasPrefix(root+"/") }

    private func bundledCLI(_ pid:pid_t)->Bool {
        let expected=ChecklistPaths.serviceExecutable.deletingLastPathComponent().appendingPathComponent("checklist")
        var buffer=[CChar](repeating:0,count:4096)
        guard proc_pidpath(pid,&buffer,UInt32(buffer.count)) > 0,canonical(String(cString:buffer)) == canonical(expected.path) else { return false }
        var code:SecStaticCode?;var expectedInfo:CFDictionary?
        guard SecStaticCodeCreateWithPath(expected as CFURL,[],&code)==errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,[],nil)==errSecSuccess,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&expectedInfo)==errSecSuccess,
              let expectedHash=(expectedInfo as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,
              let actual=signingInfo(pid),actual[kSecCodeInfoIdentifier as String] as? String == "org.checklist.checklist",
              let actualHash=actual[kSecCodeInfoUnique as String] as? Data else { return false }
        return actualHash == expectedHash
    }

    private func signingInfo(_ pid:pid_t)->[String:Any]? {
        var code:SecCode?;var staticCode:SecStaticCode?;var info:CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess,let code,
              SecCodeCheckValidity(code,[],nil)==errSecSuccess,
              SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess else { return nil }
        return info as? [String:Any]
    }

    private func nativeProcess(_ pid:pid_t,provider:String) throws -> pid_t {
        var current=pid
        for _ in 0..<16 {
            var bsd=proc_bsdinfo()
            guard proc_pidinfo(current,PROC_PIDTBSDINFO,0,&bsd,Int32(MemoryLayout.size(ofValue:bsd))) == MemoryLayout.size(ofValue:bsd),bsd.pbi_uid == getuid() else { break }
            if let info=signingInfo(current),let identifier=info[kSecCodeInfoIdentifier as String] as? String,let team=info[kSecCodeInfoTeamIdentifier as String] as? String {
                if provider == "codex",identifier == "codex",team == "2DC432GLL2" { return current }
                if provider == "claude",identifier == "com.anthropic.claude-code",team == "Q6L2SF6YDW" { return current }
            }
            let parent=pid_t(bsd.pbi_ppid);if parent <= 1 || parent == current { break };current=parent
        }
        throw ChecklistError("NATIVE_HOST_REQUIRED","This command must run inside a signed native \(provider == "codex" ? "Codex":"Claude") work session.")
    }

    private func currentDirectory(_ pid:pid_t) throws -> String {
        var info=proc_vnodepathinfo()
        guard proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&info,Int32(MemoryLayout.size(ofValue:info))) == MemoryLayout.size(ofValue:info) else { throw ChecklistError("WORKSPACE_UNAVAILABLE","Cannot verify this process's actual workspace.") }
        let path=withUnsafePointer(to:&info.pvi_cdir.vip_path) { pointer in pointer.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)) { String(cString:$0) } }
        guard !path.isEmpty,path.hasPrefix("/") else { throw ChecklistError("WORKSPACE_UNAVAILABLE","The native process has no accessible workspace.") }
        return canonical(path)
    }

    private func processDomain(_ pid:pid_t,provider:String) throws -> String {
        var info=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout.size(ofValue:info))) == MemoryLayout.size(ofValue:info),info.pbi_uid == getuid() else { throw ChecklistError("NATIVE_HOST_UNAVAILABLE","The verified native host process is no longer available.") }
        return "\(provider):\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
}
