import Foundation
import Security
import ChecklistCore
import ChecklistBridges
import ChecklistProviders

/// Stated bounds of the Codex app queue route (CL-413).
enum CodexQueueBounds {
    static let queueCallsPerPass = 4
    static let queueCallsPerThreadPerPass = 1
    /// One lane runs one `codex queue` at a time. This also counts the wait after it.
    static let openDeliveries = 8
    static let retrySeconds: TimeInterval = 30
    static let cacheSeconds: TimeInterval = 30
    static let recentThreadSeconds: TimeInterval = 14*86400
    static let recentThreadLimit = 64
}

/// The check of `NativeConnections.nativeProcess` and `bundledCLI`, for the app host that the
/// service will run: the bundled Codex identifier and team, `SecCodeCheckValidity` on the running process,
/// and a file with the same code hash. `SecCodeCopyStaticCode` reads the disk code, so that hash compares two disk reads.
/// A file replaced under a running process fails the validity check, so the route refuses until a new host runs.
enum CodexHostSignature {
    static func matches(_ information: [String:Any]?, fileHash: Data?, identifier: String, team: String) -> Bool {
        guard let information,information[kSecCodeInfoIdentifier as String] as? String == identifier,
              information[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let running = information[kSecCodeInfoUnique as String] as? Data,!running.isEmpty else { return false }
        return running == fileHash
    }
    static func valid(_ host: CodexProcess) -> Bool {
        guard let expected = ProviderPluginRegistry.bundled.plugin("codex",requiring:.workSession)?.nativeHost else { return false }
        return valid(host,identifier:expected.signingIdentifier,team:expected.signingTeam)
    }
    /// A new identity each time: NativeCodeIdentity is confined to one queue, and this call is rare.
    static func valid(_ host: CodexProcess, identifier: String, team: String) -> Bool {
        let identity = NativeCodeIdentity()
        return matches(identity.signingInfo(host.pid),fileHash:identity.executable(URL(fileURLWithPath:host.executable))?.cdhash,identifier:identifier,team:team)
    }
}

struct CodexQueueRouteEffects: Sendable {
    var enabled: Bool
    var readAppThreads: @Sendable (Int64) -> Set<String>?
    var preflight: @Sendable (NativeLifecycleRegistration,Bool) -> CodexQueuePreflight
    var provesRegistration: @Sendable (NativeLifecycleRegistration) -> Bool
    var send: @Sendable (String,NativeLifecycleRegistration,CodexQueueObservation,String) throws -> CodexQueueReceipt
    var followup: @Sendable (NativeLifecycleRegistration,DispatchQueue,@escaping @Sendable () -> CodexQueueDeliveryStatus) -> CodexQueueFollowupEnvironment
    var now: @Sendable () -> Date
    var readOmittedThreads: @Sendable ([String],Int64) -> [CodexQueueStore.OmittedThread] = { _,_ in [] }

    /// Bootstrap evidence for an inherited CODEX_THREAD_ID: only the app host that holds the thread passes.
    func provesRegistrationDomain(session: String, domain: String) -> Bool {
        guard let registration = NativeLifecycleRegistration(provider:"codex",sessionID:session,executionDomain:domain,registryPath:nil) else { return false }
        return provesRegistration(registration)
    }

    /// A coordinator with no background work, as in a test, never reads the owner's Codex
    /// database or process table. A test that needs the route installs its own effects.
    static var unavailable: CodexQueueRouteEffects {
        .init(enabled:false,readAppThreads:{ _ in nil },preflight:{ _,_ in .refused(.init(reason:.routeDisabled)) },provesRegistration:{ _ in false },
            send:{ _,_,_,_ in throw NativeBridgeError.invalid("The Codex queue route is unavailable.") },
            followup:{ _,_,status in
                .init(openEnabled:false,item:{ _ in .failed(.databaseReadError) },observe:{ .init(reason:.routeDisabled) },load:{ .unknown },status:status,
                    now:{ 0 },schedule:{ _,body in body() },open:{ _,_ in throw NativeBridgeError.invalid("The Codex queue route is unavailable.") })
            },now:{ Date() })
    }

    static var live: CodexQueueRouteEffects {
        let observer = MacOSCodexProcessObserver()
        return .init(enabled:CodexQueueRelay.enabled,
            readAppThreads:{ CodexQueueStore.current?.recentAppThreads(updatedSince:$0,limit:CodexQueueBounds.recentThreadLimit) },
            preflight:{ registration,proven in
                let thread = registration.sessionID
                return CodexQueueRoute.preflight(registrationProven:proven,enabled:CodexQueueRelay.enabled,
                    observation:CodexQueueRelay.observation(registration),scan:{ observer.scan(threadID:thread) },hostVerified:{ CodexHostSignature.valid($0) },
                    threadItems:{ CodexQueueStore.current?.threadItems(threadID:thread) ?? .failed(.databaseReadError) })
            },
            provesRegistration:{ observer.provesRegistration($0) },
            send:{ content,registration,observation,executable in
                try CodexQueueRelay.send(content:content,registration:registration,observation:observation,effects:MacOSCodexQueueTransportEffects(executable:executable))
            },
            followup:{ registration,lane,status in
                let thread = registration.sessionID
                return .init(openEnabled:CodexQueueRelay.openUnloadedThreads,
                    item:{ CodexQueueStore.current?.item($0,threadID:thread) ?? .failed(.databaseReadError) },
                    observe:{ CodexQueueRelay.observation(registration) },
                    load:{ CodexQueueRoute.load(scan:observer.scan(threadID:thread),
                        rolloutModified:CodexQueueRoute.rolloutModified(CodexQueueRelay.observation(registration).rolloutPath),now:Date()) },
                    status:status,now:{ ProcessInfo.processInfo.systemUptime },
                    schedule:{ delay,body in lane.asyncAfter(deadline:.now()+delay,execute:body) },
                    open:{ try MacOSCodexThreadOpenEffects().open(threadID:$0,timeout:$1) },
                    execHolder:{ observer.scan(threadID:thread)?.execActive ?? false })
            },
            now:{ Date() },
            readOmittedThreads:{ CodexQueueStore.current?.omittedAppThreads(candidates:$0,updatedSince:$1) ?? [] })
    }
}

/// Invariant: `lock` guards the thread cache and activation time. `open` and `retryAt`
/// are read and written only on the coordinator's command queue.
final class CodexQueueRouteState: @unchecked Sendable {
    let effects: CodexQueueRouteEffects
    let lane = DispatchQueue(label:"org.checklist.codex-queue")
    private let markerFile: URL
    private let lock = NSLock()
    private var threads: Set<String> = []
    private var refreshedAt: Date?
    private var refreshing = false
    private var activated: Date??
    private var omissionInputs: (selected: Set<String>,candidates: Set<String>)?
    private var loggedOmissions = Set<String>()
    private let log: @Sendable (String) -> Void
    var open = 0
    var retryAt: [String:Date] = [:]

    init(markerFile: URL, effects: CodexQueueRouteEffects = .live, log: @escaping @Sendable (String) -> Void = { fputs($0+"\n",stderr) }) {
        self.markerFile = markerFile; self.effects = effects; self.log = log
    }

    /// A bounded set. A stale copy starts one refresh off the command queue, so no
    /// command waits for the Codex database. A failed read selects no thread.
    /// `changed` runs once when a refresh changes the set: a note that came while the
    /// copy was old gets its pass then. It starts no timer, and the next refresh needs a later pass.
    func appThreads(enrolled: @autoclosure () -> Set<String> = [], changed: @escaping @Sendable () -> Void = {}) -> Set<String> {
        let current = effects.now()
        let (result,refresh): (Set<String>,Bool) = lock.withLock {
            let stale = refreshedAt.map { current.timeIntervalSince($0) >= CodexQueueBounds.cacheSeconds } ?? true
            let refresh = stale && !refreshing
            if refresh { refreshing = true }
            return (threads,refresh)
        }
        if refresh {
            let enrolled = enrolled()
            DispatchQueue.global(qos:.utility).async { [self] in
                let since = Int64(current.timeIntervalSince1970-CodexQueueBounds.recentThreadSeconds)
                let read = effects.readAppThreads(since)
                let differs = lock.withLock { () -> Bool in
                    let differs = threads != (read ?? [])
                    threads = read ?? [];refreshedAt = current;refreshing = false
                    return differs
                }
                if let read { logOmissions(enrolled:enrolled,selected:read,since:since) }
                if differs { changed() }
            }
        }
        return result
    }

    /// One line per thread per service run. The read runs only when its inputs change.
    private func logOmissions(enrolled: Set<String>, selected: Set<String>, since: Int64) {
        let candidates = enrolled.subtracting(selected)
        let check = lock.withLock { () -> Bool in
            if let inputs = omissionInputs,inputs.selected == selected,inputs.candidates == candidates { return false }
            omissionInputs = (selected,candidates)
            return true
        }
        guard check,!candidates.isEmpty else { return }
        for thread in effects.readOmittedThreads(candidates.sorted(),since) where lock.withLock({ loggedOmissions.insert(thread.id).inserted }) {
            let reason = thread.stale ? "no update in \(Int(CodexQueueBounds.recentThreadSeconds/86400)) days" : "ranked past the newest \(CodexQueueBounds.recentThreadLimit) threads"
            log("ChecklistService: Codex queue route leaves out enrolled app thread \(thread.id): \(reason). Its notes stay in the inbox.")
        }
    }
    /// The route's first enabled selection on this store sets the time, once. No
    /// note before it can ever pass. A failed write keeps the route off this pass.
    func activatedAt() -> Date? {
        lock.withLock {
            if let activated { return activated }
            let formatter = ISO8601DateFormatter()
            if let data = try? Data(contentsOf:markerFile),let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let raw = object["activated_at"] as? String,let date = formatter.date(from:raw) {
                activated = date;return date
            }
            let date = effects.now()
            guard let data = try? JSONSerialization.data(withJSONObject:["activated_at":formatter.string(from:date)]),
                  (try? data.write(to:markerFile,options:.atomic)) != nil else { return nil }
            let stored = formatter.date(from:formatter.string(from:date))
            activated = stored
            return stored
        }
    }
}

struct CodexQueuePass {
    var total = 0
    var threads = Set<String>()
}

struct CodexQueueStart: Sendable {
    let deliveryID: String
    let messageID: String
    let enrollment: Enrollment
    let registration: NativeLifecycleRegistration
    let origin: NativeRelayOrigin
    let author: String
    let body: String
    let subject: Data?
    let ticket: Data?
    let createdAt: String
}

extension Coordinator {
    /// Only sessions that can pass: an enrolled, recent, unarchived app thread. No
    /// query here reads all sessions. The note age bound narrows the store read.
    func codexQueueSelection() -> (ids:[String],createdMin:String)? {
        let route = codexRoute
        guard route.effects.enabled,enrollments.values.contains(where:{ $0.provider == "codex" && $0.automatic == true && $0.nativeEndpoint == nil && $0.revoked != true }),
              let activated = route.activatedAt() else { return nil }
        let threads = route.appThreads(enrolled:Set(enrollments.values.compactMap { e -> String? in
            e.provider == "codex" && e.nativeEndpoint == nil && e.revoked != true && e.automatic == true ? (e.nativeSessionID ?? e.sessionID).lowercased() : nil
        })) { [self] in
            queue.async { [self] in if nativeListener != nil { dispatchNative() } }
        }
        guard !threads.isEmpty else { return nil }
        let ids = enrollments.values.compactMap { e -> String? in
            guard e.provider == "codex",e.nativeEndpoint == nil,e.revoked != true,e.automatic == true,
                  threads.contains((e.nativeSessionID ?? e.sessionID).lowercased()),Self.codexQueueRegistration(e) != nil else { return nil }
            return e.sessionID
        }
        guard !ids.isEmpty else { return nil }
        // Whole minutes keep one snapshot-cache key. The exact bound runs in admission.
        let floor = max(activated.timeIntervalSince1970,route.effects.now().timeIntervalSince1970-CodexQueueRoute.maximumNoteAge)
        return (ids,ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:(floor/60).rounded(.down)*60)))
    }

    func codexQueueAdmit(threadID: String, delivery: [String:Any], message: [String:Any], pass: inout CodexQueuePass) -> Bool {
        let route = codexRoute,current = route.effects.now()
        // A service timer starts no Codex turn: a work health request stays on session_inbox pickup, unchanged.
        guard message["origin"] as? String != "system",route.effects.enabled,let activated = route.activatedAt(),pass.total < CodexQueueBounds.queueCallsPerPass,
              route.open < CodexQueueBounds.openDeliveries,!pass.threads.contains(threadID),delivery["hook_state"] == nil,
              (route.retryAt[threadID] ?? .distantPast) <= current,
              let raw = message["created_at"] as? String,let created = ISO8601DateFormatter().date(from:raw),
              CodexQueueRoute.noteEligible(createdAt:created,activatedAt:activated,now:current) else { return false }
        pass.total += 1;pass.threads.insert(threadID)
        return true
    }

    /// Every step runs on the route's lane. A refusal writes nothing: the delivery
    /// keeps its label and state, and a later dispatch can try again within the bounds.
    func startCodexQueueDelivery(_ start: CodexQueueStart) {
        requireCommandQueue()
        let route = codexRoute,id = start.deliveryID,thread = start.registration.sessionID,generation = start.enrollment.generation
        route.open += 1
        attemptedDeliveries.insert(id)
        route.lane.async { [self] in
            // A thread proven once stays proven, also while it is unloaded. Others get a live check.
            let stored = start.enrollment.codexAppHostProven == true
            let proven = stored || route.effects.provesRegistration(start.registration)
            if proven,!stored { queue.async { [self] in storeCodexAppHostProof(installation:start.enrollment.installation,generation:generation) } }
            let refuse: @Sendable (CodexQueueObservation) -> Void = { [self] observation in
                fputs("ChecklistService: Codex queue route refused delivery \(id): \(observation.reason.rawValue).\n",stderr)
                queue.async { [self] in
                    attemptedDeliveries.remove(id);route.open -= 1
                    // No later check can repair this by itself, so the receipt states the reason.
                    if observation.reason == .registrationUnproven {
                        let receipt: [String:Any] = ["route":"codex_app_queue","route_generation":generation,"result":"refused","reason_code":observation.reason.rawValue,
                            "reason":"The app host never proved that it holds this thread. No queue call or open ran. The note stays in the inbox.",
                            "queue_poll_result":"not_started","open_result":"not_started"]
                        nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":"unavailable","queue_refusal_receipt":true,"receipt":receipt],deliveryID:id,routeGeneration:generation)
                    }
                    route.retryAt[thread] = route.effects.now().addingTimeInterval(CodexQueueBounds.retrySeconds)
                }
            }
            let first = route.effects.preflight(start.registration,proven)
            if case .refused(let observation) = first { return refuse(observation) }
            let fenceFailure = queue.sync { codexQueueFence(deliveryID:id,enrollment:start.enrollment) }
            if let fenceFailure { return refuse(.init(reason:fenceFailure)) }
            // The holder can change while the fence commits, so this check is the last step before the call.
            let last = route.effects.preflight(start.registration,proven)
            guard case .allowed(let observation,let executable) = last else {
                queue.sync { [self] in
                    _ = nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":"unavailable","release_queue_fence":true],deliveryID:id,routeGeneration:generation)
                }
                if case .refused(let refusal) = last { refuse(refusal) }
                return
            }
            let finish: @Sendable (String,Data) -> Void = { [self] state,bytes in
                queue.async { [self] in
                    let receipt = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
                    nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":state,"receipt":receipt],deliveryID:id,routeGeneration:generation)
                    route.open -= 1
                    changed()
                    // A second note to this thread waited for a later pass.
                    if nativeListener != nil { dispatchNative() }
                }
            }
            do {
                let content = try NativeRelayContent.render(origin:start.origin,messageID:start.messageID,authorDisplayName:start.author,body:start.body,
                    subject:start.subject.flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] },
                    ticket:start.ticket.flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] },permittedReply:nil,deliveryID:id,noteCreatedAt:start.createdAt,codexQueueTurn:true)
                let sent = try route.effects.send(content,start.registration,observation,executable)
                var accepted: [String:Any] = ["stage":"codex_queue_command_exited_zero","exit_status":sent.exitStatus,"bytes":sent.byteCount,
                    "route_generation":generation,"model_acknowledged":false,"route":"codex_app_queue","result":"provider_accepted",
                    "observer":"codex_state_5_threads_source","source":"vscode","reason_code":"source_vscode",
                    "queue_poll_result":"not_started","open_result":"not_started"]
                if let item = sent.itemID { accepted["queued_item_id"] = item }
                let acceptedBytes = try JSONSerialization.data(withJSONObject:accepted)
                // Preserve queue acceptance before the wait. A crash cannot send this again or mint acknowledgment.
                let recorded = queue.sync { [self] () -> Bool in
                    let fields = (try? JSONSerialization.jsonObject(with:acceptedBytes)) as? [String:Any] ?? [:]
                    if case .recorded = nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":"provider_accepted","receipt":fields],deliveryID:id,routeGeneration:generation) { changed();return true }
                    return false
                }
                guard recorded else {
                    accepted["queue_poll_result"] = "authorization_changed";accepted["open_result"] = "authorization_changed"
                    return finish("provider_accepted",(try? JSONSerialization.data(withJSONObject:accepted)) ?? acceptedBytes)
                }
                let status: @Sendable () -> CodexQueueDeliveryStatus = { [self] in queue.sync { codexQueueDeliveryStatus(id:id,enrollment:start.enrollment) } }
                CodexQueueFollowup.run(itemID:sent.itemID,registration:start.registration,environment:route.effects.followup(start.registration,route.lane,status)) { result in
                    var fields = (try? JSONSerialization.jsonObject(with:acceptedBytes)) as? [String:Any] ?? [:]
                    fields.merge(result.metadata) { _,new in new }
                    finish("provider_accepted",(try? JSONSerialization.data(withJSONObject:fields)) ?? acceptedBytes)
                }
            } catch {
                let state = (error as? NativeBridgeError)?.deliveryMayHaveOccurred == true ? "uncertain" : "failed"
                let failure: [String:Any] = ["reason":PublicErrorText.describe(error),"route_generation":generation,"route":"codex_app_queue","result":state,
                    "observer":"codex_state_5_threads_source","source":"vscode","reason_code":state == "uncertain" ? "queue_outcome_unknown" : "queue_command_failed",
                    "queue_poll_result":"not_started","open_result":"refused"]
                finish(state,(try? JSONSerialization.data(withJSONObject:failure)) ?? Data("{}".utf8))
            }
        }
    }

    /// Persists an uncertainty fence BEFORE external I/O. A crash never retries this write.
    /// Returns the true reason when the fence is not written.
    func codexQueueFence(deliveryID id: String, enrollment: Enrollment) -> CodexQueueReason? {
        requireCommandQueue()
        let generation = enrollment.generation
        guard enrollments[enrollment.installation]?.generation == generation,enrollments[enrollment.installation]?.revoked != true else { return .authorizationChanged }
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        let receipt: [String:Any] = ["stage":"native_send_started","route_generation":generation,"route":"codex_app_queue","result":"uncertain",
            "observer":"codex_state_5_threads_source","source":"vscode","reason_code":"queue_outcome_unknown","queue_poll_result":"not_started","open_result":"not_started"]
        do {
            return try router.handleIfWriteAvailable(method:"delivery_record",params:["command_id":UUID().uuidString.lowercased(),"delivery_id":id,"state":"uncertain","receipt":receipt],caller:bridge) == nil ? .fenceNotRecorded : nil
        } catch {
            fputs("ChecklistService: Codex queue fence of delivery \(id) failed: \(PublicErrorText.describe(error))\n",stderr)
            return .fenceNotRecorded
        }
    }

    /// Only a true result is stored. A false proof never replaces an earlier true one here.
    func storeCodexAppHostProof(installation: String, generation: String) {
        requireCommandQueue()
        guard enrollments[installation]?.generation == generation,enrollments[installation]?.codexAppHostProven != true else { return }
        enrollments[installation]?.codexAppHostProven = true
        do { try saveEnrollments() } catch { fputs("ChecklistService: Codex queue proof not saved: \(error).\n",stderr) }
    }

    /// One exact record read. It never expands the session's open deliveries.
    func codexQueueDeliveryStatus(id: String, enrollment: Enrollment) -> CodexQueueDeliveryStatus {
        requireCommandQueue()
        guard enrollments[enrollment.installation]?.generation == enrollment.generation,enrollments[enrollment.installation]?.revoked != true else { return .changed }
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        guard let result = try? router.handle(method:"delivery_pending",params:["delivery_id":id],caller:bridge),
              let data = result["data"] as? [String:Any] else { return .changed }
        switch data["route_state"] as? String {
        case "current": return .current
        case "acknowledged": return .acknowledged
        default: return .changed
        }
    }

    /// A wait lives in memory, so a restart ends it with no open. Each such delivery
    /// gets a final receipt state. The note stays in the inbox.
    func recordInterruptedCodexQueueFollowups() {
        requireCommandQueue()
        let bridge = Caller(role:"owner",installation:"native-bridge",projectIDs:[])
        guard let result = try? router.handle(method:"delivery_pending",params:["codex_queue_open_followups":true],caller:bridge),
              let rows = (result["data"] as? [String:Any])?["deliveries"] as? [[String:Any]] else { return }
        for row in rows {
            guard let id = row["id"] as? String,let state = row["push_state"] as? String,var receipt = row["transport_receipt"] as? [String:Any] else { continue }
            receipt["queue_poll_result"] = "service_restarted"
            nativeOutcomes().record("delivery_record",params:["delivery_id":id,"state":state,"receipt":receipt],deliveryID:id,routeGeneration:receipt["route_generation"] as? String)
        }
    }
}
