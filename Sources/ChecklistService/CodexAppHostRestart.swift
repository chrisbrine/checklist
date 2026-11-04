import Foundation
import ChecklistIPC
import ChecklistCore
import ChecklistBridges

/// Read-only evidence only. Independent of queue transport enablement/slot consent:
/// reconnect grants the same bootstrap authority and never queues or opens a turn.
struct CodexAppHostRestartEffects: Sendable {
    var available: Bool
    var process: @Sendable (NativeLifecycleRegistration) -> NativeLifecycleObservation.ProcessState
    var source: @Sendable (NativeLifecycleRegistration) -> CodexQueueObservation
    var scan: @Sendable (String) -> CodexHostScan?
    var signed: @Sendable (CodexProcess) -> Bool
    var holds: @Sendable (NativeLifecycleRegistration) -> Bool

    static var unavailable: Self {
        .init(available: false, process: { _ in .unknown }, source: { _ in .init(reason: .registrationUnproven) },
              scan: { _ in nil }, signed: { _ in false }, holds: { _ in false })
    }
    static var live: Self {
        let observer = MacOSCodexProcessObserver()
        return .init(available: true, process: { NativeLifecycleInspector.processState($0) },
            source: { CodexQueueRelay.observation($0) },
            scan: { observer.scan(threadID: $0, requireComplete: true) },
            signed: { CodexHostSignature.valid($0) }, holds: { observer.provesRegistration($0) })
    }
}

extension Coordinator {
    /// Registration provenance is read-only and independent of relay consent.
    /// Synthetic coordinators retain the existing injected queue proof seam.
    func provesCodexAppRegistration(session: String, domain: String) -> Bool {
        let effects = codexAppHostRestartEffects
        guard effects.available else { return codexRoute.effects.provesRegistrationDomain(session: session, domain: domain) }
        guard let registration = NativeLifecycleRegistration(provider: "codex", sessionID: session, executionDomain: domain, registryPath: nil) else { return false }
        let observation = effects.source(registration)
        return observation.host == .nativeApp && observation.reason == .sourceVscode && observation.source == "vscode"
            && effects.process(registration) == .running && effects.holds(registration)
    }

    /// The owner accepted first-bootstrap thread trust, not an exclusive registry
    /// lease. Check again after closure and inside the credential commit boundary.
    func verifyCodexRestartHost(old: NativeLifecycleRegistration, new: NativeLifecycleRegistration) throws -> NativeLifecycleObservation.ProcessState {
        let effects = codexAppHostRestartEffects
        let state = effects.process(old)
        guard state == .gone || state == .replaced else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", state == .running
                ? "The earlier Codex app host PID and start time still identify a running process. Its connection cannot close for restart."
                : "Checklist cannot verify that the earlier Codex app host ended: its PID/start identity lookup is unreadable or incomplete.")
        }
        let source = effects.source(new)
        guard source.host == .nativeApp, source.reason == .sourceVscode, source.source == "vscode" else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "Codex app restart requires the exact thread's source=vscode record. " + source.reason.explanation)
        }
        func host(_ scan: CodexHostScan?) throws -> CodexProcess {
            guard let scan, !scan.unreadable else {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "The Codex process/holder observation is unreadable or incomplete; another holder cannot be excluded.")
            }
            guard !scan.execActive else {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "Another Codex process holds this conversation or names its thread or --last. Restart reconnect is refused.")
            }
            guard scan.holders.count == 1, let holder = scan.holders.first,
                  holder.pid == new.processID, holder.role == .appHost, scan.hosts.contains(holder) else {
                throw ChecklistError("NATIVE_SESSION_MISMATCH", "The new Codex app host must positively hold this thread's rollout, with no other process holding it.")
            }
            return holder
        }
        let first = try host(effects.scan(new.sessionID))
        guard effects.signed(first) else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "The new Codex app host's running signature or executable identity could not be verified; an upgrade may still be in progress.")
        }
        guard effects.holds(new), effects.process(new) == .running else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "The new Codex app host's PID/start identity and positive hold on this thread could not be verified.")
        }
        guard try host(effects.scan(new.sessionID)) == first, effects.source(new) == source else {
            throw ChecklistError("NATIVE_SESSION_MISMATCH", "The Codex app host or thread source changed during the restart observation.")
        }
        return state
    }
}
