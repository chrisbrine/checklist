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
    var observationWaitingForClosure = false
    let closureQueue = DispatchQueue(label: "org.checklist.native-closure", qos: .userInitiated, autoreleaseFrequency: .workItem)
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
        if nativeLifecycle.observationScheduled {
            if nativeLifecycle.observationStarted { nativeLifecycle.observationDirty = true }
            return
        }
        guard !nativeLifecycle.resumptionInFlight, !nativeLifecycle.deferredWriteScheduled else { return }
        guard router.writeAdmissionStatus["locked"] as? Bool != true else { return }
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
            queue.activity("native_lifecycle_observation") { observeNativeConversationLifecycle(enrollment, deferClosure: true) }
            if nativeLifecycle.observationWaitingForClosure { return }
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
    func observeNativeConversationLifecycle(_ enrollment: Enrollment, deferClosure: Bool = false) {
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
            try queue.activity("native_closure_reconciliation") {
                if deferClosure {
                    let work = try prepareNativeClosure(enrollment, processState: observation.process.rawValue,
                        registryState: observation.registry.rawValue, registryDigest: observation.registryDigest)
                    startObservedNativeClosure(work)
                } else {
                    _ = try reconcileNativeClosure(enrollment, processState: observation.process.rawValue,
                        registryState: observation.registry.rawValue, registryDigest: observation.registryDigest)
                }
            }
        } catch {
            recordNativeClosureFailure(error,key:key)
        }
    }

    private func recordNativeClosureFailure(_ error: Error, key: String) {
        let detail = error.localizedDescription
        if nativeLifecycle.failures[key] != detail {
            nativeLifecycle.failures[key] = detail
            fputs("Verified native closure is fenced; claim release needs reconciliation: \(detail)\n", stderr)
        }
    }

    private func startObservedNativeClosure(_ work: NativeClosureWork) {
        requireCommandQueue()
        nativeLifecycle.resumptionInFlight = true
        nativeLifecycle.observationWaitingForClosure = true
        nativeLifecycle.closureQueue.async { [self] in
            let outcome = applyNativeClosure(work)
            queue.async(work: "native_closure_finish") { [self] in
                finishNativeBootstrapWork {
                    do { _ = try finishNativeClosure(work,outcome:outcome) }
                    catch { recordNativeClosureFailure(error,key:work.key) }
                }
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
        if nativeLifecycle.observationWaitingForClosure {
            nativeLifecycle.observationWaitingForClosure = false
            // Resume the existing sweep. A pending closure can require a later
            // command or registry event; this completion does not mark it dirty.
            queue.async { [self] in observeNextNativeConversationLifecycle() }
        } else { observeNativeConversationLifecycles() }
        dispatchNative()
        if nativeLifecycle.connectionRequestScheduled { continueNativeConnectionRequests() }
    }

    struct NativeClosureWork: Sendable {
        let enrollment: Enrollment
        let domain: String
        let processState: String
        let registryState: String
        let registryDigest: String?
        let basis: NativeClosureBasis
        let replacementDomain: String?

        var key: String { enrollment.installation + "/" + enrollment.generation }
    }

    struct NativeClosureOutcome: Sendable {
        let release: Result<Bool,Error>
        let changed: Bool
    }

    /// One service-owned fence/release path for registry closure and the owner's
    /// narrow Codex app restart rule. Failures retain the fenced old generation.
    @discardableResult
    func reconcileNativeClosure(_ enrollment: Enrollment, processState: String, registryState: String,
                                registryDigest: String?, basis: NativeClosureBasis = .processAndRegistry,
                                replacementDomain: String? = nil) throws -> Bool {
        let work = try prepareNativeClosure(enrollment,processState:processState,registryState:registryState,
            registryDigest:registryDigest,basis:basis,replacementDomain:replacementDomain)
        return try finishNativeClosure(work,outcome:applyNativeClosure(work))
    }

    /// Fence the exact enrollment before its Core claim and delivery settlement.
    /// No worker owns or consults the coordinator's mutable enrollment map.
    func prepareNativeClosure(_ enrollment: Enrollment, processState: String, registryState: String,
                              registryDigest: String?, basis: NativeClosureBasis = .processAndRegistry,
                              replacementDomain: String? = nil) throws -> NativeClosureWork {
        requireCommandQueue()
        guard var current = enrollments[enrollment.installation], current.generation == enrollment.generation,
              let domain = enrollment.nativeExecutionDomain, current.nativeExecutionDomain == domain else {
            throw CoreError("RECIPIENT_CHANGED", "The native enrollment changed before closure.")
        }
        current.revoked = true; enrollments[enrollment.installation] = current
        try saveEnrollments()
        return .init(enrollment:current,domain:domain,processState:processState,registryState:registryState,
            registryDigest:registryDigest,basis:basis,replacementDomain:replacementDomain)
    }

    func applyNativeClosure(_ work: NativeClosureWork) -> NativeClosureOutcome {
        var committed = false
        let release = Result {
            try ServiceHoldWatchdog.withWorkLabel("native_closure_reconciliation") {
                try router.withNativeLifecycleCommitNotification({try applyNativeClosureProjects(work)}, onCommit: {committed = true})
            }
        }
        return .init(release:release,changed:committed)
    }

    private func applyNativeClosureProjects(_ work: NativeClosureWork) throws -> Bool {
        let enrollment = work.enrollment
        var pending = false
        for project in enrollment.projectIDs {
            let caller = Caller(role: "owner", installation: "native-lifecycle", projectIDs: [])
            guard let session = try router.connectionSession(sessionID: enrollment.sessionID, project: project, caller: caller),
                  let generation = session["authorization_generation"] as? String, !generation.isEmpty else {
                throw CoreError("RECIPIENT_CHANGED", "The exact native session authorization is unavailable.")
            }
            let proof = VerifiedNativeClosure(projectID: project, sessionID: enrollment.sessionID,
                installation: work.key, executionDomain: work.domain, provider: enrollment.provider,
                authorizationGeneration: generation, processState: work.processState, registryState: work.registryState,
                registryDigest: work.registryDigest, basis: work.basis, replacementExecutionDomain: work.replacementDomain)
            guard let result = try router.withImmediateWriteAccess({ try router.reconcileVerifiedNativeClosure(proof, caller: caller) }) else {
                throw CoreError("NATIVE_CLOSURE_PENDING", "Closure must finish after the current storage operation before this thread can reconnect.")
            }
            if !(result["pending_attempt_ids"] as? [String] ?? []).isEmpty { pending = true }
        }
        return !pending
    }

    func finishNativeClosure(_ work: NativeClosureWork, outcome: NativeClosureOutcome) throws -> Bool {
        requireCommandQueue()
        defer {if outcome.changed {changed()}}
        let released = try outcome.release.get()
        guard let current = enrollments[work.enrollment.installation], current.generation == work.enrollment.generation,
              current.nativeExecutionDomain == work.domain else {
            throw CoreError("RECIPIENT_CHANGED", "The native enrollment changed during closure settlement.")
        }
        nativeLifecycle.failures.removeValue(forKey: work.key)
        if released {
            nativeLifecycle.reconciled.insert(work.key)
            nativeLifecycle.watches.removeValue(forKey: work.key)
        }
        return released
    }
}
