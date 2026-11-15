import Foundation
import Security
import CryptoKit
import ChecklistCore
import ChecklistIPC
import ChecklistBridges
import ChecklistProviders

extension Coordinator {
    /// Only the synchronous bootstrap stack sees this mode. Unwinding restores
    /// its caller's mode before any worker or another command can execute.
    func withDeferredNativeResumption<T>(_ body: () throws -> T) rethrows -> T {
        requireCommandQueue()
        let previous = nativeLifecycle.deferResumptions
        nativeLifecycle.deferResumptions = true
        defer { nativeLifecycle.deferResumptions = previous }
        return try body()
    }

    var nativeResumptionIsDeferred: Bool {
        nativeLifecycle.deferResumptions
    }
}

/// Queue-owned state and persistence; workers carry immutable values and return
/// every owner/enrollment check to that queue before taking any SQL/object gate.
/// A successful Core transaction is never followed by local rollback.
final class NativeBootstrapContinuation: Error, @unchecked Sendable {
    enum Kind: Sendable {
        case verifiedClosure
        case codexRestart(old: NativeLifecycleRegistration, new: NativeLifecycleRegistration, effects: CodexAppHostRestartEffects)
        case ownerAllowed
    }
    private struct Staged: Sendable {
        let enrollment: Enrollment
        let priorCredential: String?
        let resumption: NativeSessionResumption
    }
    private enum Phase {
        case prepared
        case initialProof
        case staged(Staged)
        case committed
        case finished
    }

    private let coordinator: Coordinator
    private var baseline: Enrollment
    private let project: String
    private let oldExecutionDomain: String
    private let executionDomain: String
    private let binding: String?
    private let process: pid_t
    private let endpoint: String?
    private let kind: Kind
    private let owner = Caller(role: "owner", installation: "native-thread-bootstrap", projectIDs: [])
    private let worker = DispatchQueue(label: "org.checklist.native-bootstrap", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var phase: Phase = .prepared
    private var completion: ((Result<Coordinator.BootstrapResult, Error>) -> Void)?

    init(coordinator: Coordinator, existing: Enrollment, project: String, oldExecutionDomain: String, executionDomain: String,
         binding: String?, process: pid_t, endpoint: String?, kind: Kind) {
        self.coordinator = coordinator; self.baseline = existing; self.project = project
        self.oldExecutionDomain = oldExecutionDomain
        self.executionDomain = executionDomain; self.binding = binding; self.process = process
        self.endpoint = endpoint; self.kind = kind
    }

    /// The dispatcher pauses coordinator-owned writers before calling start and
    /// resumes them only after this exactly-once callback on its command queue.
    func start(completion: @escaping (Result<Coordinator.BootstrapResult, Error>) -> Void) {
        coordinator.requireCommandQueue()
        guard case .prepared = phase else { preconditionFailure("A native bootstrap continuation starts once.") }
        self.completion = completion
        phase = .initialProof
        worker.async { [self] in autoreleasepool {
            do {
                if case .codexRestart(let old, let new, let effects) = kind {
                    _ = try Coordinator.verifyCodexRestartAfterClosure(effects: effects, old: old, new: new,
                        checkOwner: { try self.checkOwnerFromWorker(staged: nil) })
                }
                coordinator.queue.async { [self] in stageRegistration() }
            } catch {
                coordinator.queue.async { [self] in finish(.failure(error)) }
            }
        } }
    }

    private var ownerAllowed: Bool {
        if case .ownerAllowed = kind { return true }
        return false
    }

    private func checkOwnerFromWorker(staged: Enrollment?) throws {
        try coordinator.queue.sync { try checkOwnerOnQueue(staged: staged) }
    }

    private func checkOwnerOnQueue(staged: Enrollment?, committed: Bool = false) throws {
        coordinator.requireCommandQueue()
        let expected = staged ?? baseline
        guard let current = coordinator.enrollments[baseline.installation],
              current.generation == expected.generation,
              current.nativeExecutionDomain == expected.nativeExecutionDomain,
              current.tokenDigest == expected.tokenDigest else {
            throw CoreError("RECIPIENT_CHANGED", "The native enrollment changed before resumption.")
        }
        // Explicit Allow again supersedes the saved enrollment's earlier owner
        // flag. Core's current permission is still checked below and at commit.
        let allowedSavedOwnerFlag = ownerAllowed && staged == nil && baseline.ownerRevoked == true
        if current.ownerRevoked == true && !allowedSavedOwnerFlag {
            baseline.ownerRevoked = true; baseline.revoked = true
            if committed { try fenceCommittedOwnerRevocation(current) }
            throw ownerDisconnected()
        }
        if let session = try coordinator.router.connectionSession(sessionID: baseline.sessionID, project: project, caller: owner) {
            let ownerPermission = session["owner_reconnect_allowed"] as? Bool == true && session["owner_revoked"] as? Bool != true
            if session["owner_revoked"] as? Bool == true || (session["state"] as? String == "revoked" && !(ownerAllowed && ownerPermission)) || (ownerAllowed && !committed && !ownerPermission) {
                baseline.ownerRevoked = true; baseline.revoked = true
                if committed { try fenceCommittedOwnerRevocation(current) }
                throw ownerDisconnected()
            }
        }
        if staged != nil && current.revoked == true { throw ownerDisconnected() }
    }

    private func ownerDisconnected() -> ChecklistError {
        ChecklistError("CONNECTION_REVOKED", "The owner disconnected this thread in Checklist. It cannot reconnect automatically.")
    }

    /// A later owner fence keeps the committed new identity. Persistence failure
    /// is recovery-required; it never restores credentials from the old identity.
    private func fenceCommittedOwnerRevocation(_ current: Enrollment) throws {
        var fenced = current
        fenced.revoked = true; fenced.ownerRevoked = true
        coordinator.enrollments[fenced.installation] = fenced
        do { try coordinator.saveEnrollments() }
        catch {
            throw ChecklistError("CONNECTION_RECOVERY_REQUIRED", "The owner disconnect is enforced, but its local enrollment could not be saved.",
                details: ["owner_revoked": true, "registration_committed": true])
        }
    }

    private func stageRegistration() {
        coordinator.requireCommandQueue()
        do {
            try checkOwnerOnQueue(staged: nil)
            guard baseline.workspace == binding, baseline.projectIDs == [project] else {
                throw ChecklistError("BINDING_CHANGED", "The registered workspace changed. Review this connection in Checklist before reconnecting.")
            }
            let priorCredential: String?
            do { priorCredential = try coordinator.credentials.read(baseline.installation) }
            catch { if ownerAllowed { priorCredential = nil } else { throw error } }
            if !ownerAllowed {
                guard let priorCredential,
                      SHA256.hash(data: Data(priorCredential.utf8)).map({ String(format: "%02x", $0) }).joined() == baseline.tokenDigest else { throw ownerDisconnected() }
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ChecklistError("RANDOM_FAILURE", "Could not create the thread connection.")
            }
            let token = Data(bytes).base64EncodedString()
            var resumed = baseline
            if case .codexRestart = kind { resumed.codexAppHostProven = true }
            else { resumed.codexAppHostProven = baseline.provider == "codex" ? coordinator.provesCodexAppRegistration(session: baseline.nativeSessionID ?? baseline.sessionID, domain: executionDomain) : nil }
            resumed.generation = UUID().uuidString; resumed.nativeExecutionDomain = executionDomain
            resumed.revoked = false; resumed.ownerRevoked = false
            resumed.tokenDigest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            resumed.nativeEndpoint = nil; resumed.nativeDevice = nil; resumed.nativeInode = nil
            if ProviderPluginRegistry.bundled.plugin(baseline.provider, requiring: .nativePeer) != nil, let endpoint {
                try coordinator.bindProviderEndpoint(&resumed, endpoint: endpoint, process: process)
            }
            let staged = Staged(enrollment: resumed, priorCredential: priorCredential,
                resumption: NativeSessionResumption(projectID: project, sessionID: baseline.sessionID, provider: baseline.provider,
                    oldInstallation: baseline.installation + "/" + baseline.generation, oldExecutionDomain: oldExecutionDomain,
                    newInstallation: resumed.installation + "/" + resumed.generation, newExecutionDomain: executionDomain))
            try ConnectionCommit.perform(saveCredential: { try coordinator.credentials.write(baseline.installation, token) },
                saveEnrollment: { coordinator.enrollments[baseline.installation] = resumed; try coordinator.saveEnrollments() },
                registerSession: {}, rollback: { try restore(staged, includingUnstaged: true) })
            phase = .staged(staged)
            worker.async { [self] in commit(staged) }
        } catch { finish(.failure(error)) }
    }

    private func commit(_ staged: Staged) {
        autoreleasepool {
            do {
                let evidence: CodexAppHostRestartEvidence?
                if case .codexRestart(let old, let new, let effects) = kind {
                    evidence = try Coordinator.verifyCodexRestartAfterClosure(effects: effects, old: old, new: new,
                        checkOwner: { try self.checkOwnerFromWorker(staged: staged.enrollment) })
                } else {
                    try checkOwnerFromWorker(staged: staged.enrollment)
                    evidence = nil
                }
                // No queue synchronization occurs inside this admitted atomic
                // transaction. It rechecks Core-owned owner/session authority.
                guard let _ = try coordinator.router.withImmediateWriteAccess({
                    if ownerAllowed { _ = try coordinator.router.reconnectOwnerAllowedSession(staged.resumption, caller: owner) }
                    else { _ = try coordinator.router.resumeVerifiedNativeSession(staged.resumption, caller: owner, codexRestartScanCounts: evidence?.counts) }
                }) else { throw CoreError("BACKUP_SERVICE_CALL_DEFERRED", "Connection registration waits for the accepted backup write queue.") }
                coordinator.queue.async { [self] in completeCommitted(staged) }
            } catch {
                let original = error
                coordinator.queue.async { [self] in
                    do { try restore(staged, includingUnstaged: false); finish(.failure(original)) }
                    catch { finish(.failure(recoveryFailure(original: original))) }
                }
            }
        }
    }

    private func completeCommitted(_ staged: Staged) {
        coordinator.requireCommandQueue()
        phase = .committed
        do {
            try checkOwnerOnQueue(staged: staged.enrollment, committed: true)
            try coordinator.requireCommittedRegistration(staged.enrollment, project: project, caller: owner)
            finish(.success(.init(reply: coordinator.connectionResult(staged.enrollment, project: project), changed: true)))
        } catch { finish(.failure(error)) }
    }

    private func restore(_ staged: Staged, includingUnstaged: Bool) throws {
        coordinator.requireCommandQueue()
        guard let current = coordinator.enrollments[baseline.installation] else { return }
        let matchesStaged = current.generation == staged.enrollment.generation && current.nativeExecutionDomain == staged.enrollment.nativeExecutionDomain && current.tokenDigest == staged.enrollment.tokenDigest
        let matchesBaseline = current.generation == baseline.generation && current.nativeExecutionDomain == baseline.nativeExecutionDomain && current.tokenDigest == baseline.tokenDigest
        guard matchesStaged || (includingUnstaged && matchesBaseline) else { return }
        var restored = baseline
        if current.ownerRevoked == true { restored.ownerRevoked = true; restored.revoked = true }
        try ConnectionCommit.restore(enrollment: { coordinator.enrollments[baseline.installation] = restored; try coordinator.saveEnrollments() }, credential: {
            if let prior = staged.priorCredential { try coordinator.credentials.write(baseline.installation, prior) }
            else { try coordinator.credentials.removeChecked(baseline.installation) }
        })
    }

    private func recoveryFailure(original: Error) -> ChecklistError {
        ChecklistError("CONNECTION_RECOVERY_REQUIRED", "Pairing could not restore its previous local state. Original failure: " + original.localizedDescription,
            details: ["command_outcome": "unknown", "original_failure": original.localizedDescription, "rollback_failed": true])
    }

    private func finish(_ result: Result<Coordinator.BootstrapResult, Error>) {
        coordinator.requireCommandQueue()
        guard let completion else { return }
        self.completion = nil; phase = .finished
        completion(result)
    }
}
