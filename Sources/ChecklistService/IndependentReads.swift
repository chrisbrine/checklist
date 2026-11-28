import Darwin
import Foundation
import ChecklistCore
import ChecklistIPC
import ChecklistProviders

extension Coordinator {
    private func currentReadEnrollment(_ committed: Enrollment?, staged: Enrollment?, readsOnly: Bool) throws -> Enrollment? {
        guard let staged, staged.revoked != true, staged.generation != committed?.generation,
              let project = staged.projectIDs.first else {return committed}
        let owner = Caller(role:"owner",installation:"connection-consistency",projectIDs:[])
        do {
            try requireCommittedRegistration(staged,project:project,caller:owner,readsOnly:readsOnly)
            return staged
        } catch let error as ChecklistError where error.code == "CONNECTION_REPAIR_REQUIRED" {return committed}
        catch let error as CoreError where error.code == "PROJECT_NOT_FOUND" || error.code == "NOT_FOUND" {return committed}
    }

    private func currentReadEnrollments(readsOnly: Bool) throws -> [String:Enrollment] {
        let snapshot = enrollmentSnapshot()
        var current = snapshot.committed
        for (installation,prepared) in snapshot.staged {
            current[installation] = try currentReadEnrollment(current[installation],staged:prepared,readsOnly:readsOnly)
        }
        return current
    }

    func connectionList(_ caller: Caller, readsOnly: Bool = false) throws -> [String: Any] {
        guard caller.role == "owner" else {throw ChecklistError("FORBIDDEN","Connection setup is owner-only.")}
        let enrollments = try currentReadEnrollments(readsOnly:readsOnly).values.sorted {$0.name < $1.name}
        let connections = try enrollments.compactMap { enrollment -> [String: Any]? in
            if enrollment.revoked != true {
                guard let project = enrollment.projectIDs.first else {return nil}
                do {try requireCommittedRegistration(enrollment,project:project,caller:caller,readsOnly:readsOnly)}
                catch let error as ChecklistError where error.code == "CONNECTION_REPAIR_REQUIRED" {return nil}
                catch let error as CoreError where error.code == "PROJECT_NOT_FOUND" || error.code == "NOT_FOUND" {return nil}
            }
            return ["installation":enrollment.installation,"name":enrollment.name,"provider":enrollment.provider,
                "role":enrollment.role,"project_ids":enrollment.projectIDs,"session_id":enrollment.sessionID,
                "workspace":enrollment.workspace ?? "","profile_id":enrollment.profileID ?? "","generation":enrollment.generation,
                "native_endpoint":enrollment.nativeEndpoint ?? "","native_push":enrollment.nativeEndpoint != nil && enrollment.revoked != true
                    && ProviderPluginRegistry.bundled.plugin(enrollment.provider,requiring:.nativePeer) != nil,
                "assistant_grants":enrollment.assistantGrants ?? [:],"automatic":enrollment.automatic ?? false,
                "revoked":enrollment.revoked ?? false,"identity_verification":enrollment.identityVerification ?? "owner_enrolled"]
        }
        return ["data":["connections":connections]]
    }

    func readRequest(_ request: [String: Any],method: String,peerPID: pid_t,timing: ServiceCallTiming?) throws -> [String: Any] {
        let params = request["params"] as? [String: Any] ?? [:]
        if method == "connection_bootstrap" {
            return try ServiceCallTiming.measure(timing,"bootstrap_verification_ms") {
                let native = try ServiceCallTiming.measure(timing,"bootstrap_native_peer_ms") {
                    try verifiedNativeWorkspace(params,peerPID:peerPID)
                }
                return try bootstrapVerifiedWorkspace(params,native:native,readCredential:{ installation in
                    guard let stored = try credentials.readCurrent(installation) else {throw NativeBootstrapRequiresWrite()}
                    return stored
                },currentConnectionOnly:true,timing:timing,readEnrollments:currentReadEnrollments(readsOnly:true)).reply
            }
        }
        let installation = request["installation"] as? String ?? "default"
        var generation: String?
        let caller = try ServiceCallTiming.measure(timing,"bootstrap_verification_ms") {
            let snapshot = enrollmentSnapshot()
            let enrollment = try currentReadEnrollment(snapshot.committed[installation],
                staged:request["credential"] == nil || request["owner_channel"] as? Bool == true ? nil : snapshot.staged[installation],readsOnly:true)
            return try verifiedCaller(request,peerPID:peerPID,installation:installation,enrollment:enrollment,
                timing:timing,readsOnly:true,observeSessionGeneration:{generation = $0})
        }
        return try ServiceCallTiming.measure(timing,"execution_ms") {
            switch method {
            case "connection_list": return try connectionList(caller,readsOnly:true)
            case "task_handoff_prepare": return try prepareHandoff(params,caller:caller,readsOnly:true)
            default:
                return try router.handleIndependentRead(method:method,params:params,caller:caller,
                    expectedAuthorizationGeneration:generation,observeOperationWriterWait:timing.map {$0.recordOperationWriterWait})
            }
        }
    }
}

/// The subscription queue owns only scheduling state. Database reads and XPC
/// replies happen on the read lane. Each waiter keeps at most one read in flight.
final class ServiceChangeSubscriptions: @unchecked Sendable {
    private struct Subscription {
        let worker: DispatchQueue
        let check: @Sendable (Bool) -> Bool
        var running = false
        var dirty = false
        var expired = false
    }
    private let queue = DispatchQueue(label:"org.checklist.change-subscriptions")
    private var subscriptions: [UUID:Subscription] = [:]

    func add(on worker: DispatchQueue, check: @escaping @Sendable (Bool) -> Bool) {
        queue.async { [self] in
            let id = UUID()
            subscriptions[id] = Subscription(worker:worker,check:check)
            start(id)
            queue.asyncAfter(deadline:.now() + .seconds(8)) { [self] in
                subscriptions[id]?.expired = true
                start(id)
            }
        }
    }

    func changed() {
        queue.async { [self] in
            for id in Array(subscriptions.keys) {
                subscriptions[id]?.dirty = true
                start(id)
            }
        }
    }

    private func start(_ id: UUID) {
        guard let subscription = subscriptions[id], !subscription.running else {return}
        subscriptions[id]?.running = true
        subscriptions[id]?.dirty = false
        subscription.worker.async { [self] in
            let done = subscription.check(subscription.expired)
            queue.async { [self] in
                if done {subscriptions.removeValue(forKey:id);return}
                subscriptions[id]?.running = false
                if let next = subscriptions[id], next.dirty || next.expired {start(id)}
            }
        }
    }
}
