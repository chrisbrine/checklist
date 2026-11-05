import Foundation
import Darwin

struct CodexProcessAccount: Sendable {
    let effective: uid_t
    let real: uid_t
    let command: String
    func belongs(to account: uid_t) -> Bool { effective == account || real == account }
}

/// Known paths survive an incomplete table/vnode read: a readable competing
/// holder must still be reported even when an unrelated descriptor is unknown.
struct CodexProcessDescriptors: Sendable {
    var paths: [String] = []
    var complete: Bool = false
}

/// Only the strict restart scanner uses this seam. Fake readers need no kernel,
/// files, sockets, signing or Codex-store effects.
protocol CodexProcessTableReading: Sendable {
    func processIDs() -> [pid_t]?
    func bsdAccount(_ pid: pid_t) -> CodexProcessAccount?
    func kernelAccount(_ pid: pid_t) -> CodexProcessAccount?
    func executable(_ pid: pid_t) -> String?
    func arguments(_ pid: pid_t) -> [String]?
    func descriptors(_ pid: pid_t) -> CodexProcessDescriptors
    func definitelyGone(_ pid: pid_t) -> Bool
}

extension MacOSCodexProcessObserver {
    func strictScan(threadID: String, accountID: uid_t, table: any CodexProcessTableReading) -> CodexHostScan? {
        guard let thread = UUID(uuidString: threadID)?.uuidString.lowercased(), let pids = table.processIDs() else { return nil }
        var hosts: [CodexProcess] = [], holders: [CodexProcess] = []
        var blockers: [CodexProcessBlocker] = []
        var unreadable = false, execClaim = false, incompleteNonCodex = 0
        func unknown(_ pid: pid_t, executable: String = "unknown", role: CodexProcessRole = .unclassified) {
            unreadable = true
            blockers.append(.init(process: .init(pid: pid, executable: executable, role: role), reason: .unreadableCandidate))
        }
        for pid in pids where pid > 1 {
            guard let account = table.bsdAccount(pid) ?? table.kernelAccount(pid) else {
                if !table.definitelyGone(pid) { unknown(pid) }
                continue
            }
            guard account.belongs(to: accountID) else { continue }
            let path = table.executable(pid)
            // With no executable path, p_comm supplies an independent Codex
            // candidate signal even when argv[0] was changed by the process.
            let identity = path == nil ? table.kernelAccount(pid) : account
            guard let identity, identity.belongs(to: accountID), path != nil || !identity.command.isEmpty,
                  let arguments = table.arguments(pid),
                  let argv0 = arguments.first, !argv0.isEmpty else {
                if !table.definitelyGone(pid) { unknown(pid, executable: path ?? account.command) }
                continue
            }
            let executable = path ?? argv0
            let codex = URL(fileURLWithPath: executable).lastPathComponent == "codex"
                || URL(fileURLWithPath: argv0).lastPathComponent == "codex" || identity.command == "codex"
            let candidate = codex || CodexQueueRoute.execClaims(arguments: arguments, threadID: thread)
            let role = candidate ? CodexQueueRoute.role(executable: executable, arguments: arguments) : .unclassified
            let process = CodexProcess(pid: pid, executable: executable, role: role,
                diagnosticExecutable: path == nil ? identity.command : nil)
            if candidate, CodexQueueRoute.claims(role: role, arguments: arguments, threadID: thread) {
                execClaim = true
                if arguments.contains("--last") { blockers.append(.init(process: process, reason: .namesLast)) }
                if arguments.contains(where: { $0.lowercased().contains(thread) }) { blockers.append(.init(process: process, reason: .namesThread)) }
            }
            if role == .appHost { hosts.append(process) }
            let descriptors = table.descriptors(pid)
            // No filesystem open/realpath: match all rollout filenames for this
            // UUID, including outside the conventional root. This only adds
            // conservative refusals. Positive host proof is checked separately.
            if descriptors.paths.contains(where: {
                URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix("-\(thread).jsonl")
            }) { holders.append(process) }
            if !descriptors.complete, !table.definitelyGone(pid) {
                if candidate { unknown(pid, executable: path ?? identity.command, role: role) } else { incompleteNonCodex += 1 }
            }
        }
        // Kernel enumeration order carries no authority; both samples compare
        // the same sorted safety facts and the incomplete-non-Codex count.
        return .init(hosts: hosts.sorted { $0.pid < $1.pid }, holders: holders.sorted { $0.pid < $1.pid },
                     unreadable: unreadable, execClaim: execClaim, incompleteNonCodex: incompleteNonCodex,
                     blockers: blockers.sorted { $0.pid == $1.pid ? $0.reason.rawValue < $1.reason.rawValue : $0.pid < $1.pid })
    }
}

/// Read-only kernel metadata. This does not open a rollout, a database, or any
/// file and does not send signals (even signal 0).
struct MacOSCodexProcessTableReader: CodexProcessTableReading {
    func processIDs() -> [pid_t]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else { return nil }
        return Array(pids.prefix(Int(count)))
    }
    func bsdAccount(_ pid: pid_t) -> CodexProcessAccount? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let command = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return .init(effective: info.pbi_uid, real: info.pbi_ruid, command: command)
    }
    private func kernelInfo(_ pid: pid_t) -> (info: kinfo_proc?, gone: Bool) {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        errno = 0
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        if result == 0, size == 0 { return (nil, true) }
        if result != 0 { return (nil, errno == ESRCH) }
        return size == MemoryLayout<kinfo_proc>.stride ? (info, false) : (nil, false)
    }
    func kernelAccount(_ pid: pid_t) -> CodexProcessAccount? {
        guard var info = kernelInfo(pid).info else { return nil }
        let command = withUnsafeBytes(of: &info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return .init(effective: info.kp_eproc.e_ucred.cr_uid, real: info.kp_eproc.e_pcred.p_ruid, command: command)
    }
    func definitelyGone(_ pid: pid_t) -> Bool { kernelInfo(pid).gone }
    func executable(_ pid: pid_t) -> String? { MacOSCodexProcessObserver.executable(pid) }
    func arguments(_ pid: pid_t) -> [String]? { MacOSCodexProcessObserver.arguments(pid, requireComplete: true) }
    func descriptors(_ pid: pid_t) -> CodexProcessDescriptors {
        let width = MemoryLayout<proc_fdinfo>.size
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0, needed <= 4096 * width else { return .init() }
        var entries = [proc_fdinfo](repeating: .init(), count: Int(needed) / width + 32)
        let received = entries.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard received > 0, Int(received) <= entries.count * width, Int(received) % width == 0 else { return .init() }
        var observation = CodexProcessDescriptors(complete: Int(received) < entries.count * width)
        for entry in entries.prefix(Int(received) / width) where entry.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard entry.proc_fd <= UInt32(Int32.max),
                  proc_pidfdinfo(pid, Int32(entry.proc_fd), PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) == MemoryLayout<vnode_fdinfowithpath>.size else {
                observation.complete = false; continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            observation.paths.append(path)
        }
        return observation
    }
}
