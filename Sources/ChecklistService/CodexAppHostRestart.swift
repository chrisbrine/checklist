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
    /// Bounded, request-local retry only; fixtures inject a nonblocking fake.
    var pauseBeforeRetry: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 1) }

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

struct CodexAppHostRestartEvidence {
    let process: NativeLifecycleObservation.ProcessState
    let counts: CodexRestartScanCounts
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

    /// Closure already ended the old authority. Retry only transient verifier
    /// evidence, at most three full paired observations per stage of this request.
    /// Permanent errors and owner revocation leave immediately, without waiting.
    func verifyCodexRestartAfterClosure(old: NativeLifecycleRegistration, new: NativeLifecycleRegistration,
                                       checkOwner: () throws -> Void) throws -> CodexAppHostRestartEvidence {
        var retriesRemaining = 2
        while true {
            try checkOwner()
            let evidence: CodexAppHostRestartEvidence
            do { evidence = try verifyCodexRestartHost(old: old, new: new) }
            catch {
                try checkOwner()
                guard retriesRemaining > 0, CodexRestartRefusal.applies(error) else { throw error }
                retriesRemaining -= 1
                codexAppHostRestartEffects.pauseBeforeRetry()
                continue
            }
            try checkOwner()
            return evidence
        }
    }

    /// The owner accepted first-bootstrap thread trust, not an exclusive registry
    /// lease. Check again after closure and inside the credential commit boundary.
    func verifyCodexRestartHost(old: NativeLifecycleRegistration, new: NativeLifecycleRegistration) throws -> CodexAppHostRestartEvidence {
        let effects = codexAppHostRestartEffects
        func refusal(_ message: String, scan: CodexHostScan? = nil, extra: [CodexProcessBlocker] = []) -> ChecklistError {
            var blockers = scan?.blockers ?? []
            for process in scan?.holders ?? [] where process.pid != new.processID || process.role != .appHost {
                blockers.append(.init(process: process, reason: process.role == .exec ? .execHolder : .secondHolder))
            }
            blockers += extra
            var unique: [CodexProcessBlocker] = []
            for blocker in blockers where !unique.contains(blocker) { unique.append(blocker) }
            unique.sort { $0.pid == $1.pid ? $0.reason.rawValue < $1.reason.rawValue : $0.pid < $1.pid }
            let count = scan.map { String($0.incompleteNonCodex) } ?? "unknown"
            let identities = unique.isEmpty ? "" : " Blocking processes: " + unique.map(\.summary).joined(separator: "; ") + "."
            return CodexRestartRefusal.error(message + " (incompleteNonCodex=\(count))" + identities,
                blockingProcesses: unique.map(\.diagnostic))
        }
        let state = effects.process(old)
        guard state == .gone || state == .replaced else {
            let process = CodexProcess(pid: old.processID, executable: state == .running ? "codex" : "unknown",
                role: state == .running ? .appHost : .unclassified)
            throw refusal(state == .running
                ? "The earlier Codex app host PID and start time still identify a running process. Its connection cannot close for restart."
                : "Checklist cannot verify that the earlier Codex app host ended: its PID/start identity lookup is unreadable or incomplete.",
                extra: [.init(process: process, reason: state == .running ? .oldHostRunning : .unreadableCandidate)])
        }
        let source = effects.source(new)
        guard source.host == .nativeApp, source.reason == .sourceVscode, source.source == "vscode" else {
            throw refusal("Codex app restart requires the exact thread's source=vscode record. " + source.reason.explanation)
        }
        func host(_ scan: CodexHostScan?) throws -> (process: CodexProcess, scan: CodexHostScan) {
            guard let scan, !scan.unreadable else {
                throw refusal("The Codex process/holder observation is unreadable or incomplete; another holder cannot be excluded.", scan: scan)
            }
            guard !scan.execActive else {
                throw refusal("Another Codex process holds this conversation or names its thread or --last. Restart reconnect is refused.", scan: scan)
            }
            guard scan.holders.count == 1, let holder = scan.holders.first,
                  holder.pid == new.processID, holder.role == .appHost, scan.hosts.contains(holder) else {
                throw refusal("The new Codex app host must positively hold this thread's rollout, with no other process holding it.", scan: scan)
            }
            return (holder, scan)
        }
        let first = try host(effects.scan(new.sessionID))
        guard effects.signed(first.process) else {
            throw refusal("The new Codex app host's running signature or executable identity could not be verified; an upgrade may still be in progress.",
                scan: first.scan, extra: [.init(process: first.process, reason: .unsignedHost)])
        }
        guard effects.holds(new), effects.process(new) == .running else {
            throw refusal("The new Codex app host's PID/start identity and positive hold on this thread could not be verified.",
                scan: first.scan, extra: [.init(process: first.process, reason: .newHostUnverified)])
        }
        let last = try host(effects.scan(new.sessionID))
        guard last.scan.agreesOnCodexSafety(with: first.scan), effects.source(new) == source else {
            let changed = (first.scan.hosts + last.scan.hosts).filter { !first.scan.hosts.contains($0) || !last.scan.hosts.contains($0) }
            throw refusal("The Codex app host, holder scan or thread source changed during the restart observation."
                + " (incompleteNonCodex first=\(first.scan.incompleteNonCodex), last=\(last.scan.incompleteNonCodex))",
                scan: last.scan, extra: (changed + [last.process]).map { .init(process: $0, reason: .observationChanged) })
        }
        return .init(process: state, counts: .init(first: first.scan.incompleteNonCodex, last: last.scan.incompleteNonCodex))
    }
}
