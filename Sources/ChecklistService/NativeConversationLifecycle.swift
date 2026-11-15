import Foundation
import Darwin
import ChecklistCore
import ChecklistBridges
import ChecklistProviders

/// Kernel/file events trigger a bounded observation. No timer, model or polling
/// loop is created; a lost MCP/XPC connection is not an event source for closure.
final class NativeLifecycleWatch {
    private var process: DispatchSourceProcess?
    private var registryDirectory: DispatchSourceFileSystemObject?
    init(registration: NativeLifecycleRegistration, queue: ServiceCommandQueue, changed: @escaping () -> Void) {
        let process = DispatchSource.makeProcessSource(identifier: registration.processID, eventMask: .exit, queue: queue.dispatchQueue)
        process.setEventHandler { queue.perform(work: "native_process_exit", changed) }; process.resume(); self.process = process
        if let path = registration.registryPath {
            let fd = open(URL(fileURLWithPath: path).deletingLastPathComponent().path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: queue.dispatchQueue)
                source.setEventHandler { queue.perform(work: "native_registry_change", changed) }; source.setCancelHandler { close(fd) }
                source.resume(); registryDirectory = source
            }
        }
    }
    deinit { process?.cancel(); registryDirectory?.cancel() }
}

final class NativeLifecycleMonitor {
    var watches: [String: NativeLifecycleWatch] = [:]
    var reconciled = Set<String>()
    var failures: [String: String] = [:]
    var inspect: (NativeLifecycleRegistration) -> NativeLifecycleObservation = { NativeLifecycleInspector.inspect($0) }
    var watchesEnabled = true
    var observationScheduled = false
    var observationStarted = false
    var observationDirty = false
    var pendingObservations: [Enrollment] = []
    var observationOffset = 0
    var connectionRequests: [(@Sendable () -> Void)?] = []
    var connectionRequestOffset = 0
    var connectionRequestScheduled = false
    var connectionTurnPending = false
    var resumptionInFlight = false
    var deferResumptions = false
    var deferredWrites: [(@Sendable () -> Void)?] = []
    var deferredWriteOffset = 0
    var deferredWriteScheduled = false
    var executingDeferredWrite = false
}

extension Coordinator {
    /// Coalesce a burst of process/registry and request hooks. Each turn inspects
    /// one enrollment; foreground requests can run before the next turn.
    func observeNativeConversationLifecycles() {
        requireCommandQueue()
        guard !nativeLifecycle.resumptionInFlight, !nativeLifecycle.deferredWriteScheduled else { return }
        guard router.writeAdmissionStatus["locked"] as? Bool != true else { return }
        if nativeLifecycle.observationScheduled {
            if nativeLifecycle.observationStarted { nativeLifecycle.observationDirty = true }
            return
        }
        nativeLifecycle.observationScheduled = true
        queue.async { [self] in
            nativeLifecycle.pendingObservations = Array(enrollments.values)
            nativeLifecycle.observationOffset = 0
            nativeLifecycle.observationStarted = true
            observeNextNativeConversationLifecycle()
        }
    }

    private func observeNextNativeConversationLifecycle() {
        requireCommandQueue()
        guard !nativeLifecycle.resumptionInFlight else {
            finishNativeLifecycleObservation(repeatDirty: false)
            return
        }
        guard router.writeAdmissionStatus["locked"] as? Bool != true else {
            finishNativeLifecycleObservation(repeatDirty: false)
            return
        }
        if nativeLifecycle.observationOffset < nativeLifecycle.pendingObservations.count {
            let enrollment = nativeLifecycle.pendingObservations[nativeLifecycle.observationOffset]
            nativeLifecycle.observationOffset += 1
            queue.activity("native_lifecycle_observation") { observeNativeConversationLifecycle(enrollment) }
        }
        if nativeLifecycle.observationOffset < nativeLifecycle.pendingObservations.count {
            queue.async { [self] in observeNextNativeConversationLifecycle() }
        } else {
            finishNativeLifecycleObservation(repeatDirty: true)
        }
    }

    private func finishNativeLifecycleObservation(repeatDirty: Bool) {
        let dirty = nativeLifecycle.observationDirty
        nativeLifecycle.observationScheduled = false
        nativeLifecycle.observationStarted = false
        nativeLifecycle.observationDirty = false
        nativeLifecycle.pendingObservations = []
        nativeLifecycle.observationOffset = 0
        if repeatDirty && dirty { observeNativeConversationLifecycles() }
    }

    /// A reconnect can arrive before its background observation turn. Resolve
    /// only that exact earlier registration before applying the existing guards.
    func observeNativeConversationLifecycle(_ enrollment: Enrollment) {
        requireCommandQueue()
        guard !nativeLifecycle.resumptionInFlight else { return }
        guard router.writeAdmissionStatus["locked"] as? Bool != true else { return }
        guard let current = enrollments[enrollment.installation], current.generation == enrollment.generation,
              current.nativeExecutionDomain == enrollment.nativeExecutionDomain,
              enrollment.automatic == true, enrollment.role == "worker", enrollment.assistantRelay != true,
              let plugin = ProviderPluginRegistry.bundled.plugin(enrollment.provider, requiring: .registryClosure),
              enrollment.identityVerification == plugin.nativeHost?.identityVerification,
              let domain = enrollment.nativeExecutionDomain else { return }
        let key = enrollment.installation + "/" + enrollment.generation
        guard !nativeLifecycle.reconciled.contains(key),
              let parsed = NativeLifecycleRegistration(provider: enrollment.provider,
                sessionID: enrollment.nativeSessionID ?? enrollment.sessionID, executionDomain: domain, registryPath: nil),
              let path = plugin.nativeHost?.registryPath(processID: parsed.processID),
              let registration = NativeLifecycleRegistration(provider: enrollment.provider,
                sessionID: enrollment.nativeSessionID ?? enrollment.sessionID, executionDomain: domain, registryPath: path) else { return }
        if nativeLifecycle.watchesEnabled && nativeLifecycle.watches[key] == nil {
            nativeLifecycle.watches[key] = NativeLifecycleWatch(registration: registration, queue: queue) { [weak self] in
                self?.observeNativeConversationLifecycles()
            }
        }
        let observation = nativeLifecycle.inspect(registration)
        guard observation.provesClosure else { return }
        do {
            _ = try queue.activity("native_closure_reconciliation") {
                try reconcileNativeClosure(enrollment, processState: observation.process.rawValue,
                    registryState: observation.registry.rawValue, registryDigest: observation.registryDigest)
            }
        } catch {
            let detail = error.localizedDescription
            if nativeLifecycle.failures[key] != detail {
                nativeLifecycle.failures[key] = detail
                fputs("Verified native closure is fenced; claim release needs reconciliation: \(detail)\n", stderr)
            }
        }
    }

    /// The guarded bootstrap either returns current committed authority now or
    /// asks for its complete, freshly verified retry in the state-changing FIFO.
    /// Never convert an authentication failure into a registration retry.
    func attemptCurrentNativeBootstrap<T>(_ attempt: () throws -> T,
                                          retry: @escaping @Sendable () -> Void) throws -> T? {
        requireCommandQueue()
        do { return try attempt() }
        catch is NativeBootstrapRequiresWrite {
            enqueueNativeConnectionRequest(retry)
            return nil
        }
    }

    /// Bootstrap requests arriving together must not all occupy the command
    /// queue ahead of the next app read. Admit them quickly, then run one per turn.
    func enqueueNativeConnectionRequest(_ work: @escaping @Sendable () -> Void) {
        requireCommandQueue()
        nativeLifecycle.connectionRequests.append(work)
        guard !nativeLifecycle.connectionRequestScheduled else { return }
        nativeLifecycle.connectionRequestScheduled = true
        scheduleNativeConnectionTurn()
    }

    private func scheduleNativeConnectionTurn() {
        guard !nativeLifecycle.connectionTurnPending else { return }
        nativeLifecycle.connectionTurnPending = true
        queue.async { [self] in runNextNativeConnectionRequest() }
    }

    private func runNextNativeConnectionRequest() {
        requireCommandQueue()
        nativeLifecycle.connectionTurnPending = false
        guard nativeLifecycle.connectionRequestScheduled else { return }
        guard !nativeLifecycle.resumptionInFlight, !nativeLifecycle.deferredWriteScheduled else { return }
        let index = nativeLifecycle.connectionRequestOffset
        let request = nativeLifecycle.connectionRequests[index]!
        nativeLifecycle.connectionRequests[index] = nil
        nativeLifecycle.connectionRequestOffset += 1
        queue.activity("native_connection_request", request)
        guard !nativeLifecycle.resumptionInFlight else { return }
        continueNativeConnectionRequests()
    }

    private func continueNativeConnectionRequests() {
        if nativeLifecycle.connectionRequestOffset < nativeLifecycle.connectionRequests.count {
            if nativeLifecycle.connectionRequestOffset >= 64 && nativeLifecycle.connectionRequestOffset >= nativeLifecycle.connectionRequests.count / 2 {
                nativeLifecycle.connectionRequests.removeFirst(nativeLifecycle.connectionRequestOffset)
                nativeLifecycle.connectionRequestOffset = 0
            }
            scheduleNativeConnectionTurn()
        } else {
            nativeLifecycle.connectionRequests = []
            nativeLifecycle.connectionRequestOffset = 0
            nativeLifecycle.connectionRequestScheduled = false
        }
    }

    /// Core owns its writer on the worker. Queue-owned outcomes and setup writes
    /// wait here, so none can block the command queue waiting for that writer.
    func performNativeLifecycleWrite(_ work: @escaping @Sendable () -> Void) {
        requireCommandQueue()
        if nativeLifecycle.resumptionInFlight || (nativeLifecycle.deferredWriteScheduled && !nativeLifecycle.executingDeferredWrite) {
            nativeLifecycle.deferredWrites.append(work)
        } else {
            work()
        }
    }

    func startNativeBootstrapContinuation(_ continuation: NativeBootstrapContinuation,
                                         completion: @escaping @Sendable (Result<BootstrapResult, Error>) -> Void) {
        requireCommandQueue()
        precondition(!nativeLifecycle.resumptionInFlight)
        nativeLifecycle.resumptionInFlight = true
        continuation.start { [self] result in
            queue.async { [self] in finishNativeBootstrapWork { completion(result) } }
        }
    }

    func finishNativeBootstrapWork(_ completion: () -> Void) {
        requireCommandQueue()
        precondition(nativeLifecycle.resumptionInFlight)
        nativeLifecycle.resumptionInFlight = false
        let deferred = nativeLifecycle.deferredWriteOffset < nativeLifecycle.deferredWrites.count
        nativeLifecycle.deferredWriteScheduled = deferred
        completion()
        if deferred {
            queue.async { [self] in drainNativeLifecycleWrites() }
        } else {
            finishNativeLifecycleWrites()
        }
    }

    private func drainNativeLifecycleWrites() {
        requireCommandQueue()
        guard !nativeLifecycle.resumptionInFlight else { return }
        let index = nativeLifecycle.deferredWriteOffset
        let work = nativeLifecycle.deferredWrites[index]!
        nativeLifecycle.deferredWrites[index] = nil
        nativeLifecycle.deferredWriteOffset += 1
        nativeLifecycle.executingDeferredWrite = true
        queue.activity("native_deferred_write", work)
        nativeLifecycle.executingDeferredWrite = false
        if nativeLifecycle.deferredWriteOffset < nativeLifecycle.deferredWrites.count {
            if nativeLifecycle.deferredWriteOffset >= 64 && nativeLifecycle.deferredWriteOffset >= nativeLifecycle.deferredWrites.count / 2 {
                nativeLifecycle.deferredWrites.removeFirst(nativeLifecycle.deferredWriteOffset)
                nativeLifecycle.deferredWriteOffset = 0
            }
            queue.async { [self] in drainNativeLifecycleWrites() }
        } else {
            nativeLifecycle.deferredWrites = []
            nativeLifecycle.deferredWriteOffset = 0
            nativeLifecycle.deferredWriteScheduled = false
            finishNativeLifecycleWrites()
        }
    }

    private func finishNativeLifecycleWrites() {
        observeNativeConversationLifecycles()
        dispatchNative()
        if nativeLifecycle.connectionRequestScheduled { continueNativeConnectionRequests() }
    }

    /// One service-owned fence/release path for registry closure and the owner's
    /// narrow Codex app restart rule. Failures retain the fenced old generation.
    @discardableResult
    func reconcileNativeClosure(_ enrollment: Enrollment, processState: String, registryState: String,
                                registryDigest: String?, basis: NativeClosureBasis = .processAndRegistry,
                                replacementDomain: String? = nil) throws -> Bool {
        requireCommandQueue()
        return try router.withNativeLifecycleCommitNotification({
            try reconcileNativeClosureOnQueue(enrollment, processState: processState, registryState: registryState,
                registryDigest: registryDigest, basis: basis, replacementDomain: replacementDomain)
        }, onCommit: { changed() })
    }

    private func reconcileNativeClosureOnQueue(_ enrollment: Enrollment, processState: String, registryState: String,
                                              registryDigest: String?, basis: NativeClosureBasis,
                                              replacementDomain: String?) throws -> Bool {
        let key = enrollment.installation + "/" + enrollment.generation
        guard var current = enrollments[enrollment.installation], current.generation == enrollment.generation,
              current.nativeExecutionDomain == enrollment.nativeExecutionDomain else {
            throw CoreError("RECIPIENT_CHANGED", "The native enrollment changed before closure.")
        }
        current.revoked = true; enrollments[enrollment.installation] = current
        try saveEnrollments()
        var pending = false
        for project in enrollment.projectIDs {
            let caller = Caller(role: "owner", installation: "native-lifecycle", projectIDs: [])
            guard let session = try router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: caller),
                  let generation = session["authorization_generation"] as? String, !generation.isEmpty else {
                throw CoreError("RECIPIENT_CHANGED", "The exact native session authorization is unavailable.")
            }
            let proof = VerifiedNativeClosure(projectID: project, sessionID: enrollment.sessionID,
                installation: key, executionDomain: enrollment.nativeExecutionDomain!, provider: enrollment.provider,
                authorizationGeneration: generation, processState: processState, registryState: registryState,
                registryDigest: registryDigest, basis: basis, replacementExecutionDomain: replacementDomain)
            guard let result = try router.withImmediateWriteAccess({ try router.reconcileVerifiedNativeClosure(proof, caller: caller) }) else {
                throw CoreError("NATIVE_CLOSURE_PENDING", "Closure must finish after the current storage operation before this thread can reconnect.")
            }
            if !(result["pending_attempt_ids"] as? [String] ?? []).isEmpty { pending = true }
        }
        nativeLifecycle.failures.removeValue(forKey: key)
        if !pending { nativeLifecycle.reconciled.insert(key); nativeLifecycle.watches.removeValue(forKey: key) }
        return !pending
    }

}
