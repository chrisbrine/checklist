import Foundation
import Security
import CryptoKit
import Darwin
import ChecklistCore
import ChecklistIPC
import ChecklistBridges
import ChecklistProviders

struct Enrollment: Codable {
    var installation: String
    var name: String
    var provider: String
    var role: String
    var projectIDs: [String]
    var sessionID: String
    var workspace: String?
    var profileID: String?
    var tokenDigest: String
    var generation: String
    var nativeEndpoint: String?
    var nativeDevice: UInt64?
    var nativeInode: UInt64?
    var assistantGrants: [String:[String:Bool]]?
    var automatic: Bool?
    var revoked: Bool?
    // Set only by the owner's disconnect; a verified native closure sets `revoked` alone.
    var ownerRevoked: Bool?
    var identityVerification: String?
    var nativeExecutionDomain: String?
    var assistantRelay: Bool?
    var relayPolicyRevision: Int?
    var relayPolicyRevisions: [String:Int]?
    var relaySelector: String?
    var nativeSessionID: String?
    // Prepared manual pairing remains unusable without its committed Core receipt.
    var pairingCommandID: String?
    var pairingIntentDigest: String?
    var pairingPrincipal: String?
}

/// One native write whose host status may still arrive. Kept in memory only:
/// after a restart, a late notice stays uncorrelated rather than guessed.
struct NativeInFlight {
    let deliveryID: String
    let messageID: String
    let peerPID: Int32
    let routeGeneration: String
    let startedAt: Date
    var writeRecorded = false
    var pendingStatus: (status: NativeProviderHostStatus, correlation: String)?
}

/// Storage failure stays observable over the existing local XPC route. This
/// listener never opens a database or starts enrollment, dispatch or cleanup.
final class StorageRecoveryServer: NSObject, NSXPCListenerDelegate {
    let state: StorageRecoveryReply
    let listener = NSXPCListener(machServiceName:ChecklistInstance.current.machServiceName)
    let lifetimeLease: StorageServiceLease?
    let clientIdentity = ClientCodeIdentity.bundledAdmission()
    init(error: Error) {
        state = StorageRecoveryReply(error:error)
        lifetimeLease = try? StorageServiceLease(root:ChecklistPaths.root)
        super.init();listener.delegate = self
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        return clientIdentity.accept(connection) { StorageRecoveryPeer(state: state) }
    }
}
final class StorageRecoveryPeer: NSObject, ChecklistRPC {
    let state: StorageRecoveryReply
    init(state: StorageRecoveryReply) {self.state = state}
    func execute(_ request: Data, withReply reply: @escaping (Data)->Void) {reply(state.response(to:request))}
}

final class Coordinator: NSObject, NSXPCListenerDelegate {
    let router: CommandRouter
    let listener = NSXPCListener(machServiceName: ChecklistInstance.current.machServiceName)
    let queue = DispatchQueue(label: "org.checklist.commands")
    var enrollments: [String: Enrollment] = [:]
    var waiters: [UUID: () -> Void] = [:]
    var nativeListener: NativeReplyListener?
    var nativeLifecycle = NativeLifecycleMonitor()
    var storageWake: DispatchWorkItem?
    var attemptedDeliveries = Set<String>()
    var nativeInFlight: [String: NativeInFlight] = [:]
    var workHealthWake: DispatchWorkItem?
    var workHealthFailures = 0
    let enrollmentFile = ChecklistPaths.root.appendingPathComponent("connections.json")
    let expectedOwnerPath: String
    let expectedOwnerHash: Data?
    let clientIdentity = ClientCodeIdentity.bundledAdmission()
    init(router: CommandRouter) {
        self.router = router
        let gui=ChecklistPaths.serviceExecutable.deletingLastPathComponent().appendingPathComponent("ChecklistApp").resolvingSymlinksInPath()
        self.expectedOwnerPath=gui.path
        var code:SecStaticCode?
        var info:CFDictionary?
        if SecStaticCodeCreateWithPath(gui as CFURL,[],&code)==errSecSuccess,let code {
            _ = SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)
        }
        self.expectedOwnerHash=(info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data
        super.init()
        if let data = try? Data(contentsOf: enrollmentFile), let records = try? JSONDecoder().decode([String: Enrollment].self, from: data) { enrollments = records }
        listener.delegate = self
        queue.async { [weak self] in self?.observeNativeConversationLifecycles();self?.armStorageWake();self?.runWorkHealth() }
    }
    /// Advisory database supervision only; never launches or polls a model.
    /// One bounded page per wake; persisted deadlines survive sleep/restart.
    func runWorkHealth() {
        workHealthWake?.cancel(); workHealthWake = nil
        do {
            let result = try router.runWorkHealthChecks()
            workHealthFailures = 0
            if (result["changed"] as? Int ?? 0) > 0 { changed() }
            guard result["enabled"] as? Bool == true else { return }
            let work = DispatchWorkItem { [weak self] in self?.runWorkHealth() }
            workHealthWake = work
            queue.asyncAfter(deadline: .now() + ((result["has_more"] as? Bool == true) ? 0.1 : 30), execute: work)
        } catch {
            workHealthFailures += 1
            fputs("Work health check deferred; durable requests and claims retained: \(error.localizedDescription)\n", stderr)
            guard workHealthFailures < 2 else { return }
            let work = DispatchWorkItem { [weak self] in self?.runWorkHealth() }
            workHealthWake = work; queue.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    /// One-shot durable cleanup deadline. Held work waits for a relevant
    /// command or an actual lease deadline; this is not a model/pickup loop.
    func armStorageWake() {
        storageWake?.cancel();storageWake = nil
        guard let deadline = try? router.nextArchiveCleanupDeadline() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return };self.storageWake = nil
            do { try self.router.runStorageMaintenance() }
            catch { fputs("Storage maintenance deferred; its durable state was retained.\n",stderr) }
            self.armStorageWake()
        }
        storageWake = work
        queue.asyncAfter(deadline:.now() + max(0.05,deadline.timeIntervalSinceNow),execute:work)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        return clientIdentity.accept(connection) { Peer(coordinator: self, connection: connection) }
    }
    func saveEnrollments() throws {
        let data = try JSONEncoder().encode(enrollments)
        try data.write(to: enrollmentFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: enrollmentFile.path)
    }
    func owner(_ connection: NSXPCConnection) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(connection.processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        guard URL(fileURLWithPath:path).resolvingSymlinksInPath().path == expectedOwnerPath, path.hasSuffix(ChecklistInstance.current.ownerPathSuffix) else { return false }
        var guest: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess, let guest else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(ChecklistInstance.current.ownerRequirement as CFString, [], &requirement) == errSecSuccess else { return false }
        guard SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,let expectedOwnerHash else { return false }
        var info:CFDictionary?
        var staticGuest:SecStaticCode?
        guard SecCodeCopyStaticCode(guest,[],&staticGuest)==errSecSuccess,let staticGuest,
              SecCodeCopySigningInformation(staticGuest,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              let hash=(info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        return hash == expectedOwnerHash
    }
    func caller(_ request: [String: Any], connection: NSXPCConnection) throws -> Caller {
        if request["owner_channel"] as? Bool == true {
            guard owner(connection) else { throw ChecklistError("OWNER_CHANNEL_REQUIRED", "Only the signed native Checklist app can author human actions.") }
            return Caller(role: "owner", installation: "native-app", projectIDs: [], sessionID: nil, workspace: nil)
        }
        let installation = request["installation"] as? String ?? "default"
        guard let enrollment = enrollments[installation], let credential = request["credential"] as? String,
              constantEqual(SHA256.hash(data: Data(credential.utf8)).map { String(format:"%02x", $0) }.joined(), enrollment.tokenDigest) else {
            if request["method"] as? String == "service_info" {
                return Caller(role: "worker", installation: installation, projectIDs: [], sessionID: nil, workspace: nil)
            }
            throw ChecklistError("SETUP_REQUIRED", "Use Checklist from a Codex or Claude thread in this project's workspace to connect automatically.")
        }
        guard enrollment.revoked != true else { throw ChecklistError("CONNECTION_REVOKED", enrollment.ownerRevoked == true ? "This connection was disconnected by the owner." : "This connection ended. Connect again from its conversation; an owner disconnect stays final.") }
        guard ProviderPluginRegistry.bundled.plugin(enrollment.provider, requiring: .pickup) != nil else {
            throw ChecklistError("ADAPTER_UNAVAILABLE", "This provider plugin is disabled, incompatible or unqualified. Existing grants and pending messages are retained for recovery.")
        }
        var callerWorkspace=enrollment.workspace
        if enrollment.automatic == true { callerWorkspace = try verifyAutomatic(enrollment, request:request, connection:connection) }
        else if let bound = enrollment.workspace {
            guard let supplied = request["workspace"] as? String,
                  URL(fileURLWithPath: supplied).resolvingSymlinksInPath().standardizedFileURL.path == bound else {
                throw ChecklistError("WORKSPACE_MISMATCH", "This installation is bound to a different workspace. Use its actual --workspace binding.")
            }
        }
        guard let pid = enrollment.projectIDs.first else { throw ChecklistError("CONNECTION_REPAIR_REQUIRED", "This connection has no registered project.") }
        try requireCommittedRegistration(enrollment, project: pid, caller: Caller(role: "owner", installation: "connection-consistency", projectIDs: []))
        return Caller(role: enrollment.role, installation: enrollment.installation + "/" + enrollment.generation, projectIDs: enrollment.projectIDs, sessionID: enrollment.sessionID, workspace: enrollment.assistantRelay == true ? nil:callerWorkspace, assistantGrants:enrollment.assistantGrants ?? [:],executionDomain:enrollment.nativeExecutionDomain)
    }
    func constantEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x,y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    enum Routed { case done([String: Any]); case router(method: String, params: [String: Any], caller: Caller) }
    func execute(_ request: [String: Any], connection: NSXPCConnection) throws -> [String: Any] {
        switch try route(request, connection: connection) {
        case .done(let result): return result
        case .router(let method, let params, let caller): return try router.handle(method:method,params:params,caller:caller)
        }
    }
    /// Resolves the caller and every coordinator-owned operation on the serial queue.
    /// A routed command needs only the router, which serializes its own writes.
    func route(_ request: [String: Any], connection: NSXPCConnection) throws -> Routed {
        observeNativeConversationLifecycles()
        if request["method"] as? String == "connection_bootstrap" {
            return .done(try bootstrap(request["params"] as? [String:Any] ?? [:], connection:connection))
        }
        let caller = try caller(request, connection: connection)
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "connection_list" {
            guard caller.role == "owner" else { throw ChecklistError("FORBIDDEN", "Connection setup is owner-only.") }
            return .done(["data": ["connections": enrollments.values.sorted { $0.name < $1.name }.map { e -> [String:Any] in
                ["installation":e.installation,"name":e.name,"provider":e.provider,"role":e.role,"project_ids":e.projectIDs,"session_id":e.sessionID,"workspace":e.workspace ?? "","profile_id":e.profileID ?? "","generation":e.generation,"native_endpoint":e.nativeEndpoint ?? "","native_push":e.nativeEndpoint != nil && e.revoked != true && ProviderPluginRegistry.bundled.plugin(e.provider, requiring: .nativePeer) != nil,"assistant_grants":e.assistantGrants ?? [:],"automatic":e.automatic ?? false,"revoked":e.revoked ?? false,"identity_verification":e.identityVerification ?? "owner_enrolled"]
            }]])
        }
        if method == "task_handoff_prepare" { return .done(try prepareHandoff(params, caller:caller)) }
        if method == "connection_pair" {
            guard caller.role == "owner" else { throw ChecklistError("FORBIDDEN", "Pairing requires the native owner channel.") }
            guard let installation = params["installation"] as? String, installation.range(of:"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$", options:.regularExpression) != nil else { throw ChecklistError("INVALID_INPUT", "Use a short installation identifier with letters, digits, dots or dashes.") }
            let role = params["role"] as? String ?? "worker"
            guard ["worker","assistant"].contains(role), let projects = params["project_ids"] as? [String], !projects.isEmpty, Set(projects).count == projects.count else { throw ChecklistError("INVALID_INPUT", "Choose worker or assistant and one or more distinct projects.") }
            let snapshot = try router.handle(method:"snapshot", params:[:], caller:caller)
            let snapshotData = snapshot["data"] as? [String:Any] ?? snapshot
            let validProjects = Set((snapshotData["projects"] as? [[String:Any]] ?? []).compactMap { $0["id"] as? String ?? $0["project_id"] as? String })
            guard Set(projects).isSubset(of:validProjects) else { throw ChecklistError("PROJECT_NOT_FOUND", "One of the selected projects is unavailable.") }
            let workspace = (params["workspace"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath:$0).resolvingSymlinksInPath().standardizedFileURL.path }
            if role == "worker", workspace == nil { throw ChecklistError("WORKSPACE_REQUIRED", "Workers need an explicit actual workspace.") }
            let originalIntent = params
            var priorEnrollment: Enrollment?, priorCredential: String?, snapshotTaken = false
            return .done(try router.commitConnectionRegistration(intent: originalIntent, caller: caller, preparePersistence: { operation in
                priorEnrollment = enrollments[installation]
                priorCredential = try ChecklistKeychain.read(installation)
                snapshotTaken = true
                var random = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw ChecklistError("RANDOM_FAILURE", "Could not generate a pairing credential.") }
                let token = Data(random).base64EncodedString()
                let suppliedSession = originalIntent["session_id"] as? String
                var enrollment = Enrollment(installation: installation, name: originalIntent["name"] as? String ?? installation, provider: originalIntent["provider"] as? String ?? ProviderPolicyDefaults.defaultReviewProvider, role: role, projectIDs: projects, sessionID: suppliedSession.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased(), workspace: workspace, profileID: originalIntent["profile_id"] as? String, tokenDigest: SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined(), generation: UUID().uuidString)
                guard ProviderPluginRegistry.bundled.plugin(enrollment.provider, requiring: .pickup) != nil else { throw ChecklistError("ADAPTER_UNAVAILABLE", "This provider plugin is disabled, incompatible or unqualified.") }
                if role == "assistant" {
                    guard let profile=enrollment.profileID,!profile.isEmpty else { throw ChecklistError("PROFILE_REQUIRED","Choose a named profile for this assistant connection.") }
                    let supplied=originalIntent["assistant_grants"] as? [String:[String:Bool]] ?? [:]
                    let allowed:Set<String>=["read","create_drafts_on_request","post_notes_on_request","receive_messages","receive_notifications"]
                    guard Set(supplied.keys).isSubset(of:Set(projects)),supplied.values.allSatisfy({Set($0.keys).isSubset(of:allowed)}) else { throw ChecklistError("INVALID_GRANTS","Grants must use the selected project IDs and supported permission fields.") }
                    enrollment.assistantGrants=Dictionary(uniqueKeysWithValues:projects.map { pid in
                        let grants=supplied[pid] ?? [:]
                        return (pid,["read":true,"create_drafts_on_request":grants["create_drafts_on_request"] ?? false,"post_notes_on_request":grants["post_notes_on_request"] ?? false,"receive_messages":grants["receive_messages"] ?? true,"receive_notifications":grants["receive_notifications"] ?? false])
                    })
                }
                if let endpoint=originalIntent["native_endpoint"] as? String,!endpoint.isEmpty {
                    guard NativeProviderTransport.validatesEndpoint(provider:enrollment.provider,endpoint:endpoint) else { throw ChecklistError("UNSUPPORTED_ROUTE","Only an explicitly selected current Claude local socket is supported. Codex uses MCP pickup.") }
                    var attributes=stat()
                    guard lstat(endpoint,&attributes)==0, attributes.st_mode & S_IFMT == S_IFSOCK, attributes.st_uid==getuid(), attributes.st_mode & 0o077==0 else { throw ChecklistError("RECIPIENT_UNAVAILABLE","Select a current same-user private native Claude socket.") }
                    enrollment.nativeEndpoint=endpoint;enrollment.nativeDevice=UInt64(attributes.st_dev);enrollment.nativeInode=UInt64(attributes.st_ino)
                }
                enrollment.pairingCommandID = operation.commandID
                enrollment.pairingIntentDigest = operation.digest
                enrollment.pairingPrincipal = caller.installation + ":" + (caller.sessionID ?? caller.role)
                var registration: [String: Any] = ["project_id": projects[0], "project_ids": projects, "session_id": enrollment.sessionID, "installation": installation + "/" + enrollment.generation, "provider": enrollment.provider, "name": enrollment.name, "role": role, "workspace": workspace ?? ""]
                if let profile = enrollment.profileID { registration["profile_id"] = profile }
                if let grants = enrollment.assistantGrants { registration["assistant_grants"] = grants }
                try ChecklistKeychain.write(installation, token)
                enrollments[installation] = enrollment
                try saveEnrollments()
                return ConnectionRegistrationPreparation(sessionParameters: registration, installation: installation, mcpExecutable: ChecklistPaths.serviceExecutable.deletingLastPathComponent().appendingPathComponent("checklist").path)
            }, rollback: {
                guard snapshotTaken else { return }
                try ConnectionCommit.restore(enrollment: { enrollments[installation] = priorEnrollment; try saveEnrollments() }, credential: {
                    if let priorCredential { try ChecklistKeychain.write(installation, priorCredential) }
                    else { try ChecklistKeychain.removeChecked(installation) }
                })
            }))
        }
        if method == "connection_revoke" {
            guard caller.role == "owner", let installation = params["installation"] as? String else { throw ChecklistError("FORBIDDEN", "Disconnect requires the owner.") }
            guard let commandID = params["command_id"] as? String, UUID(uuidString: commandID) != nil else { throw ChecklistError("INVALID_INPUT", "Disconnect requires a UUID command_id.") }
            if let prior=enrollments[installation],let pid=prior.projectIDs.first {
                let result=try router.handle(method:"session_list",params:["project_id":pid],caller:caller)
                let body=result["data"] as? [String:Any] ?? result
                if let session=(body["sessions"] as? [[String:Any]])?.first(where:{$0["id"] as? String == prior.sessionID}) {
                    _ = try router.handle(method:"session_update",params:["command_id":UUID().uuidString.lowercased(),"project_id":pid,"session_id":prior.sessionID,"expected_revision":session["revision"] ?? 0,"state":"revoked"],caller:caller)
                }
            }
            if var prior=enrollments[installation],prior.automatic == true { prior.revoked=true;prior.ownerRevoked=true;enrollments[installation]=prior }
            else { enrollments.removeValue(forKey:installation) }
            try saveEnrollments(); ChecklistKeychain.remove(installation)
            return .done(["data":["disconnected":true], "command_id":commandID])
        }
        return .router(method:method,params:params,caller:caller)
    }
    func changed() { for callback in Array(waiters.values) { callback() } }
    func startNativeReplies() {
        let directory=URL(fileURLWithPath:"/tmp/cc-socks",isDirectory:true)
        if !FileManager.default.fileExists(atPath:directory.path) { try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
        do { nativeListener=try NativeReplyListener(path:directory.appendingPathComponent("\(getpid()).sock").path) }
        catch { fputs("Native reply listener unavailable: \(error.localizedDescription)\n",stderr);return }
        DispatchQueue.global(qos:.utility).async { [self] in
            guard let listener = nativeListener else { return }
            NativeReplyLoop.run(shouldContinue: { self.nativeListener != nil },
                receive: { try listener.receiveFrame(timeout: 50) },
                onFrame: { frame in queue.async { self.recordNativeReply(frame) } },
                onError: { error in fputs("Native reply rejected: \(error.localizedDescription)\n", stderr) })
        }
    }
    func dispatchNative() {
        observeNativeConversationLifecycles()
        guard let listener=nativeListener else { return }
        let bridge=Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        guard let result=try? router.handle(method:"delivery_pending",params:[:],caller:bridge),let data=result["data"] as? [String:Any],let pending=data["deliveries"] as? [[String:Any]] else { return }
        for delivery in pending {
            guard let id=delivery["id"] as? String,!attemptedDeliveries.contains(id), delivery["push_state"] as? String == "unavailable",
                  let sid=delivery["recipient_session_id"] as? String,
                  let enrollment=enrollments.values.first(where:{$0.sessionID==sid && $0.nativeEndpoint != nil && $0.revoked != true}),let endpoint=enrollment.nativeEndpoint,
                  let message=delivery["message"] as? [String:Any],let mid=message["id"] as? String,let body=message["body"] as? String else { continue }
            // Owner and agent ticket notes both use the relay. It always states its own restricted class
            // (prompting) and the real author; it never claims an originating agent's permission class.
            guard let origin=NativeRelayOrigin(rawValue:message["origin"] as? String ?? "") else { continue }
            var attrs=stat()
            guard lstat(endpoint,&attrs)==0,UInt64(attrs.st_dev)==enrollment.nativeDevice,UInt64(attrs.st_ino)==enrollment.nativeInode else { continue }
            attemptedDeliveries.insert(id)
            // Persist an uncertainty fence BEFORE external I/O. A process crash never retries the same native write.
            do { _ = try router.handle(method:"delivery_record",params:["command_id":UUID().uuidString.lowercased(),"delivery_id":id,"state":"uncertain","receipt":["stage":"native_send_started","route_generation":enrollment.generation]],caller:bridge) }
            catch { fputs("Native dispatch paused: its durable send fence could not be committed.\n",stderr);continue }
            // Offer a native reply only to the exact allowance holder and generation the service will accept;
            // other recipients of a fanned-out note get no invitation. The agent decides whether to use it.
            let replyPermitted=message["reply_allowed"] as? Bool == true && message["reply_used"] as? Bool != true
                && message["reply_recipient_session_id"] as? String == sid
                && message["reply_recipient_authorization_generation"] as? String == delivery["recipient_authorization_generation"] as? String
            let peerPID=NativeProviderTransport.endpointPID(provider:enrollment.provider,endpoint:endpoint) ?? 0
            // Registered before I/O: Claude can report a hold before this write's outcome is recorded.
            nativeInFlight[id]=NativeInFlight(deliveryID:id,messageID:mid,peerPID:peerPID,routeGeneration:enrollment.generation,startedAt:Date())
            DispatchQueue.global(qos:.utility).async { [self] in
                let state:String;let receipt:[String:Any]
                do {
                    let stillAuthorized=queue.sync { () -> Bool in
                        guard self.enrollments[enrollment.installation]?.generation == enrollment.generation,
                              self.enrollments[enrollment.installation]?.revoked != true,
                              let current=try? self.router.handle(method:"delivery_pending",params:[:],caller:bridge),let data=current["data"] as? [String:Any],let deliveries=data["deliveries"] as? [[String:Any]] else { return false }
                        return deliveries.contains { $0["id"] as? String == id }
                    }
                    guard stillAuthorized else { throw ChecklistError("RECIPIENT_REVOKED","Native send canceled before I/O because the route was revoked.") }
                    guard enrollment.automatic == true,
                          let plugin=ProviderPluginRegistry.bundled.plugin(enrollment.provider, requiring: .nativePeer),
                          enrollment.identityVerification == plugin.nativeHost?.identityVerification,
                          peerPID > 1,let domain = enrollment.nativeExecutionDomain,
                          let registration = NativeLifecycleRegistration(provider:enrollment.provider,
                            sessionID:enrollment.nativeSessionID ?? enrollment.sessionID,executionDomain:domain,
                            registryPath:plugin.nativeHost?.registryPath(processID:peerPID)) else {
                        throw ChecklistError("NATIVE_REGISTRATION_UNPROVEN","Native push requires the current verified native registration; this note remains available through Checklist pickup.")
                    }
                    let content=try NativeRelayContent.render(origin:origin,messageID:mid,authorDisplayName:message["author_display"] as? String ?? "unknown session",body:body,subject:delivery["subject"] as? [String:Any],ticket:delivery["ticket"] as? [String:Any],permittedReply:replyPermitted ? NativeRelayReply(address:listener.address):nil)
                    let sent=try NativeProviderTransport.send(provider:enrollment.provider,content:content,messageID:mid,replyAddress:listener.address,displayName:"Checklist",endpoint:endpoint,expectedPeerPID:peerPID,expectedRegistration:registration)
                    state="transport_written";receipt=["bytes":sent.byteCount,"socket_device":sent.socketDevice,"socket_inode":sent.socketInode,"route_generation":enrollment.generation]
                } catch {
                    state=(error as? NativeBridgeError)?.deliveryMayHaveOccurred == true ? "uncertain":"failed"
                    receipt=["reason":PublicErrorText.describe(error),"route_generation":enrollment.generation]
                }
                queue.async { [self] in
                    nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":state,"receipt":receipt],deliveryID:id,routeGeneration:enrollment.generation)
                    if state == "failed" { nativeInFlight.removeValue(forKey:id) }
                    else if var entry=nativeInFlight[id] {
                        entry.writeRecorded=true;nativeInFlight[id]=entry
                        if let pending=entry.pendingStatus { applyHostStatus(entry,pending.status,correlation:pending.correlation) }
                    }
                    changed()
                }
            }
        }
    }
    /// Native outcome writes retry storage failures and never drop a failure silently (CL-80).
    func nativeOutcomes()->NativeOutcomeRecorder {
        let bridge=Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        return NativeOutcomeRecorder(handle:{ [router] method,params in try router.handle(method:method,params:params,caller:bridge) },log:{ fputs("ChecklistService: \($0)\n",stderr) })
    }
    func recordNativeReply(_ frame:NativeReplyFrame) {
        guard let object=(try? JSONSerialization.jsonObject(with:frame.data)) as? [String:Any] else { return }
        // Kernel peer identity selects one current qualified adapter before any
        // provider frame is decoded. Disabling native I/O leaves MCP pickup intact.
        let providers=Set(enrollments.values.compactMap { enrollment -> String? in
            guard enrollment.revoked != true,let endpoint=enrollment.nativeEndpoint,
                  NativeProviderTransport.endpointPID(provider:enrollment.provider,endpoint:endpoint) == frame.peerPID else { return nil }
            return enrollment.provider
        })
        guard providers.count == 1,let provider=providers.first else { return }
        if let status=NativeProviderTransport.parseHostStatus(provider:provider,object:object) { recordHostStatus(status,peerPID:frame.peerPID);return }
        guard let (mid,body)=NativeProviderTransport.parseReply(provider:provider,object:object) else { return }
        let bridge=Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let pending:[String:Any]
        do { pending=try router.handle(method:"delivery_pending",params:["include_acknowledged":true],caller:bridge) }
        catch { fputs("ChecklistService: native reply to message \(mid) was not recorded; its deliveries could not be read (\((error as? CoreError)?.code ?? "COMMAND_FAILED")).\n",stderr);return }
        guard let data=pending["data"] as? [String:Any],let deliveries=data["deliveries"] as? [[String:Any]] else { return }
        // A note can fan out to a handler, child and coordinator. Pick the recipient by kernel peer only;
        // the core then accepts the reply only from the exact allowance holder.
        let forMessage=deliveries.filter { $0["message_id"] as? String == mid }
        let routes=forMessage.compactMap { d -> (sessionID:String,endpoint:String)? in
            guard let sid=d["recipient_session_id"] as? String,let enrollment=enrollments.values.first(where:{$0.sessionID==sid && $0.provider==provider && $0.revoked != true}),let endpoint=enrollment.nativeEndpoint,NativeProviderTransport.endpointPID(provider:provider,endpoint:endpoint) == frame.peerPID else { return nil }
            return (sid,endpoint)
        }
        let sessions=Set(routes.map(\.sessionID))
        guard sessions.count == 1,let sid=sessions.first,
              let d=forMessage.first(where:{$0["recipient_session_id"] as? String == sid}),let pid=d["project_id"] as? String,
              let enrolled=enrollments.values.first(where:{$0.sessionID==sid}),let deliveryID=d["id"] as? String else {
            fputs("ChecklistService: native reply to message \(mid) matches no delivery for its kernel peer; it was not recorded.\n",stderr);return
        }
        nativeOutcomes().record("native_reply_record",params:["project_id":pid,"reply_to":mid,"recipient_session_id":sid,"body":body,"source_evidence":["native_peer_pid":frame.peerPID,"native_peer_uid":frame.peerUID,"route_generation":enrolled.generation]],deliveryID:deliveryID,routeGeneration:enrolled.generation)
        changed()
    }
    /// Claude sends `peer_message_status` to the relay's `from` socket on a new connection.
    /// Correlate it only with an in-flight write whose recipient is the kernel-reported notifier
    /// and whose message ID Claude echoed exactly. Anything else stays uncorrelated.
    func recordHostStatus(_ status:NativeProviderHostStatus,peerPID:Int32) {
        let cutoff=Date().addingTimeInterval(-300)
        nativeInFlight=nativeInFlight.filter { $0.value.startedAt > cutoff }
        let matches=nativeInFlight.values.filter { status.refers(to:$0.messageID,recipientPID:$0.peerPID,notifierPID:peerPID) }
        guard matches.count == 1,let entry=matches.first else {
            fputs("Native host status \(status.status) matches no single in-flight delivery; left uncorrelated.\n",stderr);return
        }
        guard entry.writeRecorded else { nativeInFlight[entry.deliveryID]?.pendingStatus=(status,"orig_msg_id");return }
        applyHostStatus(entry,status,correlation:"orig_msg_id")
    }
    func applyHostStatus(_ entry:NativeInFlight,_ status:NativeProviderHostStatus,correlation:String) {
        nativeInFlight[entry.deliveryID]?.pendingStatus=nil
        var receipt:[String:Any]=["host_status":status.status,"native_peer_pid":entry.peerPID,"correlation":correlation,"route_generation":entry.routeGeneration]
        if let id=status.originalMessageID { receipt["orig_msg_id"]=id }
        if let id=status.noticeID { receipt["notice_msg_id"]=id }
        if let version=status.protocolVersion { receipt["protocol_version"]=version }
        if let reason=status.reason { receipt["host_reason"]=reason }
        nativeOutcomes().record("delivery_host_status",params:["delivery_id":entry.deliveryID,"status":status.status,"receipt":receipt],deliveryID:entry.deliveryID,routeGeneration:entry.routeGeneration)
        changed()
    }
}

final class Peer: NSObject, ChecklistRPC {
    let coordinator: Coordinator
    weak var connection: NSXPCConnection?
    init(coordinator: Coordinator, connection: NSXPCConnection) { self.coordinator=coordinator;self.connection=connection }
    func execute(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= 4 * 1024 * 1024 else { reply(Data("{\"error\":{\"code\":\"TOO_LARGE\",\"message\":\"Command is larger than 4 MiB.\"}}".utf8));return }
        coordinator.queue.async { [self] in
            if let object = try? JSONSerialization.jsonObject(with:request) as? [String:Any], object["method"] as? String == "changes_wait", let connection {
                let id = UUID()
                let finish: () -> Void = { [self] in
                    do {
                        let result = try coordinator.execute(object,connection:connection)
                        let payload = result["data"] as? [String:Any] ?? result
                        if payload["changed"] as? Bool == true {
                            coordinator.waiters.removeValue(forKey:id)
                            reply((try? JSONSerialization.data(withJSONObject:result)) ?? Data("{}".utf8))
                        }
                    } catch {
                        coordinator.waiters.removeValue(forKey:id)
                        reply(Self.errorBytes(error))
                    }
                }
                coordinator.waiters[id] = finish
                finish()
                coordinator.queue.asyncAfter(deadline:.now()+8) { [self] in
                    guard coordinator.waiters.removeValue(forKey:id) != nil else { return }
                    do { let result=try coordinator.execute(object,connection:connection);reply((try? JSONSerialization.data(withJSONObject:result)) ?? Data("{}".utf8)) }
                    catch { reply(Self.errorBytes(error)) }
                }
                return
            }
            let routed: Coordinator.Routed
            do {
                guard let connection, let object = try JSONSerialization.jsonObject(with: request) as? [String:Any] else { throw ChecklistError("INVALID_INPUT","Invalid command envelope.") }
                routed = try coordinator.route(object,connection:connection)
            } catch { finish(["error":Self.publicError(error)],reply:reply);return }
            switch routed {
            case .done(let result): finish(result,reply:reply)
            case .router(let method,let params,let caller) where CommandRouter.runsOutsideSerialQueue(method):
                // CL-71/72: file work and pure reads do not hold the serial queue; the router
                // serializes writes itself. Retain the original reply until handle returns
                // its committed receipt, however long preparation takes. A client deadline
                // never cancels it; a same-ID retry uses the router's stored receipt.
                // Hooks return to the serial queue after the reply.
                let router = coordinator.router
                DispatchQueue.global(qos:.userInitiated).async { [self] in
                    let result: [String:Any]
                    do { result = try router.handle(method:method,params:params,caller:caller) } catch { result = ["error":Self.publicError(error)] }
                    reply((try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])) ?? Data("{}".utf8))
                    coordinator.queue.async { [self] in afterCommand(result) }
                }
            case .router(let method,let params,let caller):
                let result: [String:Any]
                do { result = try coordinator.router.handle(method:method,params:params,caller:caller) } catch { result = ["error":Self.publicError(error)] }
                finish(result,reply:reply)
            }
        }
    }
    /// On the serial queue.
    func finish(_ result:[String:Any],reply:(Data)->Void) {
        reply((try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])) ?? Data("{}".utf8))
        afterCommand(result)
    }
    func afterCommand(_ result:[String:Any]) {
        if result["error"] == nil {
            coordinator.changed();coordinator.dispatchNative()
            coordinator.armStorageWake()
            if coordinator.workHealthWake == nil && coordinator.workHealthFailures < 2 { coordinator.runWorkHealth() }
        } else {
            // A failed/canceled backup also releases its retention barrier. Resume
            // deferred cleanup after either outcome, without waking during capture.
            coordinator.armStorageWake()
        }
    }
    static func errorBytes(_ error:Error)->Data {
        (try? JSONSerialization.data(withJSONObject:["error":publicError(error)])) ?? Data("{}".utf8)
    }
    /// Client-visible failure. SQL and storage-engine text stay in the service log only.
    static func publicError(_ error:Error)->[String:Any] {
        if PublicErrorText.containsSQL(String(describing:error)) { fputs("ChecklistService: storage failure withheld from client: \(error)\n",stderr) }
        if let e=error as? ChecklistError { return ["code":e.code,"message":PublicErrorText.scrubbed(e.message),"details":PublicErrorText.scrubbedValue(e.details)] }
        return PublicErrorText.payload(error)
    }
}

do {
    try ChecklistPaths.prepare()
    // Held through process lifetime, including queued native/cleanup filesystem work.
    let storageLease: StorageServiceLease
    do { storageLease = try StorageServiceLease(root:ChecklistPaths.root) }
    catch let error as CoreError where error.code == "STORE_BUSY" { exit(0) }
    // A development source binding belongs to this installed build, never another installation.
    let infoURL = ChecklistPaths.serviceExecutable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/build-info.json")
    if let bytes=try? Data(contentsOf:infoURL), let info=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any], let source=info["source_root"] as? String { setenv("CHECKLIST_PROJECT_ROOT",source,1) }
    let router = try CommandRouter(root: ChecklistPaths.root,serviceLease:storageLease,cliCommand:ChecklistInstance.current.cliCommand)
    if ChecklistInstance.current.slot == nil, let source=ProcessInfo.processInfo.environment["CHECKLIST_PROJECT_ROOT"], FileManager.default.fileExists(atPath:source) {
        let bootstrap=Caller(role:"owner",installation:"installation-bootstrap",projectIDs:[])
        let current=try router.handle(method:"project_list",params:[:],caller:bootstrap)
        let data=current["data"] as? [String:Any] ?? current
        if (data["projects"] as? [[String:Any]] ?? []).isEmpty {
            _ = try router.handle(method:"project_create",params:["name":"Checklist","key_prefix":"CL","root_path":source,"icon":"checklist","command_id":"c5e31e8c-a9e8-4108-b3bd-14d4acff9245"],caller:bootstrap)
        }
    }
    let coordinator = Coordinator(router:router)
    coordinator.startNativeReplies()
    coordinator.listener.resume()
    signal(SIGPIPE,SIG_IGN)
    print("ChecklistService ready (local XPC)")
    RunLoop.current.run()
} catch {
    let recovery = StorageRecoveryServer(error:error)
    fputs("ChecklistService: storage recovery required; original data retained.\n",stderr)
    recovery.listener.resume()
    withExtendedLifetime(recovery) {RunLoop.current.run()}
}
