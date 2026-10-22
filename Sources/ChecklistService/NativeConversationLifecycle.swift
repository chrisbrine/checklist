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
    init(registration: NativeLifecycleRegistration, queue: DispatchQueue, changed: @escaping () -> Void) {
        let process = DispatchSource.makeProcessSource(identifier: registration.processID, eventMask: .exit, queue: queue)
        process.setEventHandler(handler: changed); process.resume(); self.process = process
        if let path = registration.registryPath {
            let fd = open(URL(fileURLWithPath: path).deletingLastPathComponent().path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                    eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: queue)
                source.setEventHandler(handler: changed); source.setCancelHandler { close(fd) }
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
}

extension Coordinator {
    /// Called on the existing command queue at startup, before requests/dispatch,
    /// and by observed native process/registry events. main.swift owns the hooks.
    func observeNativeConversationLifecycles() {
        for enrollment in Array(enrollments.values) {
            guard enrollment.automatic == true, enrollment.role == "worker", enrollment.assistantRelay != true,
                  let plugin=ProviderPluginRegistry.bundled.plugin(enrollment.provider, requiring: .registryClosure),
                  enrollment.identityVerification == plugin.nativeHost?.identityVerification,
                  let domain = enrollment.nativeExecutionDomain else { continue }
            let key = enrollment.installation + "/" + enrollment.generation
            guard !nativeLifecycle.reconciled.contains(key),
                  let parsed = NativeLifecycleRegistration(provider: enrollment.provider,
                    sessionID: enrollment.nativeSessionID ?? enrollment.sessionID, executionDomain: domain, registryPath: nil) else { continue }
            guard let path = plugin.nativeHost?.registryPath(processID:parsed.processID) else { continue }
            guard let registration = NativeLifecycleRegistration(provider: enrollment.provider,
                sessionID: enrollment.nativeSessionID ?? enrollment.sessionID, executionDomain: domain, registryPath: path) else { continue }
            if nativeLifecycle.watches[key] == nil {
                nativeLifecycle.watches[key] = NativeLifecycleWatch(registration: registration, queue: queue) { [weak self] in
                    self?.observeNativeConversationLifecycles()
                }
            }
            let observation = NativeLifecycleInspector.inspect(registration)
            guard observation.provesClosure else { continue }
            // Fence even if Core/storage reconciliation fails. Dispatch and
            // caller/automatic-bootstrap must honor this in-memory revocation.
            if enrollments[enrollment.installation]?.generation == enrollment.generation {
                var fenced = enrollment; fenced.revoked = true; enrollments[enrollment.installation] = fenced
            } else { continue }
            do {
                try saveEnrollments()
                var pending = false
                for project in enrollment.projectIDs {
                    let context = try router.handle(method: "session_list", params: ["project_id": project],
                        caller: Caller(role: "owner", installation: "native-lifecycle", projectIDs: []))
                    let sessions = (context["data"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
                    guard let session = sessions.first(where: { ($0["id"] as? String)?.utf8.elementsEqual(enrollment.sessionID.utf8) == true }),
                          let generation = session["authorization_generation"] as? String, !generation.isEmpty else {
                        throw CoreError("RECIPIENT_CHANGED", "The exact native session authorization is unavailable.")
                    }
                    let proof = VerifiedNativeClosure(projectID: project, sessionID: enrollment.sessionID,
                        installation: key, executionDomain: domain, provider: enrollment.provider,
                        authorizationGeneration: generation,
                        processState: observation.process.rawValue, registryState: observation.registry.rawValue,
                        registryDigest: observation.registryDigest)
                    let result = try router.reconcileVerifiedNativeClosure(proof,
                        caller: Caller(role: "owner", installation: "native-lifecycle", projectIDs: []))
                    if !(result["pending_attempt_ids"] as? [String] ?? []).isEmpty { pending = true }
                }
                nativeLifecycle.failures.removeValue(forKey: key)
                if !pending { nativeLifecycle.reconciled.insert(key); nativeLifecycle.watches.removeValue(forKey: key) }
            } catch {
                let detail = error.localizedDescription
                if nativeLifecycle.failures[key] != detail {
                    nativeLifecycle.failures[key] = detail
                    fputs("Verified native closure is fenced; claim release needs reconciliation: \(detail)\n", stderr)
                }
            }
        }
    }
}
