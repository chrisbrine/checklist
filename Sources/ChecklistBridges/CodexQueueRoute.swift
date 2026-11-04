import Foundation
import Darwin

/// What the kernel shows about a process that can touch a Codex thread. Only an
/// exact app-server in an app bundle is the app's host; a `codex exec` that
/// resumes an app thread keeps `threads.source=vscode`, so source alone cannot tell.
public enum CodexProcessRole: String, Sendable { case appHost = "app_host", exec, unclassified }

public struct CodexProcess: Equatable, Sendable {
    public let pid: Int32
    public let executable: String
    public let role: CodexProcessRole
    public init(pid: Int32, executable: String, role: CodexProcessRole) { self.pid = pid; self.executable = executable; self.role = role }
}

public struct CodexHostScan: Equatable, Sendable {
    public let hosts: [CodexProcess]
    public let holders: [CodexProcess]
    /// A running codex process whose descriptors could not be read. It may hold the rollout.
    public let unreadable: Bool
    /// A codex process other than the app host names this thread or `--last`, and may not have opened the rollout yet.
    public let execClaim: Bool
    public init(hosts: [CodexProcess], holders: [CodexProcess], unreadable: Bool = false, execClaim: Bool = false) {
        self.hosts = hosts; self.holders = holders; self.unreadable = unreadable; self.execClaim = execClaim
    }
    public var execActive: Bool { execClaim || holders.contains { $0.role == .exec } }
    /// The process that the service would run.
    public var chosenHost: CodexProcess? { holders.first ?? hosts.first }
}

public enum CodexQueuePreflight: Equatable, Sendable {
    case allowed(CodexQueueObservation, executable: String)
    /// No second item may be sent. A later note can check whether an open is safe.
    case occupied(CodexQueueObservation, count: Int)
    case refused(CodexQueueObservation)
}

public enum CodexThreadLoad: String, Sendable { case loaded, unloaded, unknown }

public enum CodexQueueRoute {
    /// A note older than this stays in the inbox with its unchanged state.
    public static let maximumNoteAge: TimeInterval = 3600
    /// A rollout write within this time can be a running turn, so no open follows.
    public static let quietRolloutSeconds: TimeInterval = 30

    public static func noteEligible(createdAt: Date, activatedAt: Date, now: Date) -> Bool {
        createdAt >= activatedAt && createdAt <= now.addingTimeInterval(60) && now.timeIntervalSince(createdAt) <= maximumNoteAge
    }

    /// A flag this list does not know can take a value, which then reads as the
    /// subcommand. That fails closed: the process stays unclassified.
    static let valueFlags: Set<String> = ["-c","--config","-p","--profile","-m","--model","-C","--cd","-s","--sandbox",
        "-a","--ask-for-approval","-i","--image","--add-dir","--enable","--disable","--analytics-default-enabled","--remote"]
    public static func role(executable: String, arguments: [String], home: String = NSHomeDirectory()) -> CodexProcessRole {
        guard URL(fileURLWithPath:executable).lastPathComponent == "codex" else { return .unclassified }
        var index = 1
        var subcommand: String?
        while index < arguments.count {
            let word = arguments[index]
            if word == "--" { break }
            if word.hasPrefix("-") { index += valueFlags.contains(word) ? 2 : 1; continue }
            subcommand = word
            break
        }
        switch subcommand {
        case "exec","e": return .exec
        case "app-server":
            let bundled = (executable.hasPrefix("/Applications/") || executable.hasPrefix(home+"/Applications/")) && executable.contains(".app/Contents/")
            return bundled ? .appHost : .unclassified
        default: return .unclassified
        }
    }

    /// An exec takes a queue item at its turn end and deletes the row. A `--last` can
    /// resume any thread. The prompt can hold these words too, and that refuses.
    public static func execClaims(arguments: [String], threadID: String) -> Bool {
        let thread = threadID.lowercased()
        return arguments.contains { $0 == "--last" || $0.lowercased().contains(thread) }
    }

    /// Every codex process except the app host, so an unknown flag and `codex resume <id>` also count.
    public static func claims(role: CodexProcessRole, arguments: [String], threadID: String) -> Bool {
        role != .appHost && execClaims(arguments:arguments,threadID:threadID)
    }

    /// Runs off the command queue. Any doubt refuses, and this check writes nothing. The dispatch writes the fence and its release for a refusal after the fence.
    /// The signing check takes about 1 s, so the holder check runs again after it and is the last step.
    public static func preflight(registrationProven: Bool, enabled: Bool, observation: CodexQueueObservation, scan: () -> CodexHostScan?,
                                 hostVerified: (CodexProcess) -> Bool, threadItems: () -> CodexQueueStore.ThreadItems) -> CodexQueuePreflight {
        guard enabled else { return .refused(.init(reason:.routeDisabled)) }
        guard observation.host == .nativeApp else { return .refused(observation) }
        guard registrationProven else { return .refused(.init(reason:.registrationUnproven,source:observation.source)) }
        let refused: (CodexQueueReason) -> CodexQueuePreflight = { .refused(.init(reason:$0,source:observation.source)) }
        let first = scan()
        if let reason = holderRefusal(first) { return refused(reason) }
        guard let host = first?.chosenHost else { return refused(.hostNotRunning) }
        // The role comes from a path, so the signature decides whether the service runs this binary.
        guard hostVerified(host) else { return refused(.hostSignatureInvalid) }
        let occupied: Int?
        switch threadItems() {
        case .empty: occupied = nil
        case .occupied(let count): occupied = count
        case .failed(let reason): return refused(reason)
        }
        let last = scan()
        if let reason = holderRefusal(last) { return refused(reason) }
        guard last?.chosenHost == host else { return refused(.hostChanged) }
        if let occupied { return .occupied(observation,count:occupied) }
        return .allowed(observation,executable:host.executable)
    }

    private static func holderRefusal(_ scan: CodexHostScan?) -> CodexQueueReason? {
        guard let scan,!scan.unreadable else { return .holderUnreadable }
        if scan.execActive { return .holderExec }
        if scan.holders.contains(where:{ $0.role != .appHost }) { return .holderUnclassified }
        return scan.chosenHost == nil ? .hostNotRunning : nil
    }

    /// The host keeps a loaded thread's rollout open, and a loaded thread takes its
    /// queue item at its turn end. A 20 s wait there is a long turn, not an unloaded thread.
    public static func load(scan: CodexHostScan?, rolloutModified: Date?, now: Date) -> CodexThreadLoad {
        guard let scan,!scan.unreadable,!scan.execClaim,!scan.hosts.isEmpty else { return .unknown }
        if !scan.holders.isEmpty { return scan.holders.allSatisfy { $0.role == .appHost } ? .loaded : .unknown }
        guard let rolloutModified,now.timeIntervalSince(rolloutModified) >= quietRolloutSeconds else { return .unknown }
        return .unloaded
    }

    public static func rolloutModified(_ path: String?) -> Date? {
        guard let path else { return nil }
        var attributes = stat()
        guard lstat(path,&attributes) == 0,attributes.st_mode & S_IFMT == S_IFREG else { return nil }
        return Date(timeIntervalSince1970:TimeInterval(attributes.st_mtimespec.tv_sec))
    }
}

public protocol CodexProcessObserving: Sendable {
    func scan(threadID: String) -> CodexHostScan?
}

/// Reads the kernel process table and descriptors of this account's processes.
/// A process of another account cannot be read and is not counted.
public struct MacOSCodexProcessObserver: CodexProcessObserving {
    let sessionsRoot: String
    public init() {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString:$0) } ?? NSHomeDirectory()
        sessionsRoot = URL(fileURLWithPath:home).appendingPathComponent(".codex/sessions").path
    }
    init(sessionsRoot: String) { self.sessionsRoot = sessionsRoot }

    public func scan(threadID: String) -> CodexHostScan? { scan(threadID: threadID, requireComplete: false) }

    /// Restart authority uses conservative completeness, unlike transport selection.
    /// A live entry that cannot be classified/read must not disappear from the scan.
    public func scan(threadID: String, requireComplete: Bool) -> CodexHostScan? {
        guard let thread = UUID(uuidString:threadID)?.uuidString.lowercased() else { return nil }
        let suffix = "-\(thread).jsonl"
        let capacity = proc_listallpids(nil,0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating:0,count:Int(capacity)+64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress,Int32($0.count)) }
        guard count > 0, !requireComplete || count < pids.count else { return nil }
        var hosts: [CodexProcess] = [],holders: [CodexProcess] = [],unreadable = false,execClaim = false
        for pid in pids.prefix(Int(count)) where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
                if requireComplete, !Self.definitelyGone(pid) { unreadable = true }
                continue
            }
            guard info.pbi_uid == getuid() else { continue }
            guard let executable = Self.executable(pid) else {
                if requireComplete, !Self.definitelyGone(pid) { unreadable = true }
                continue
            }
            let codex = URL(fileURLWithPath:executable).lastPathComponent == "codex"
            let arguments = codex ? Self.arguments(pid) : nil
            if codex,arguments == nil,!Self.definitelyGone(pid) { unreadable = true }
            let role = codex ? CodexQueueRoute.role(executable:executable,arguments:arguments ?? []) : .unclassified
            if codex,CodexQueueRoute.claims(role:role,arguments:arguments ?? [],threadID:thread) { execClaim = true }
            let process = CodexProcess(pid:pid,executable:executable,role:role)
            if role == .appHost { hosts.append(process) }
            guard let held = NativeSessionContext.codexRolloutFiles(process:pid,rootDirectory:sessionsRoot,requireComplete:requireComplete) else {
                if (codex || requireComplete),!Self.definitelyGone(pid) { unreadable = true }
                continue
            }
            if held.contains(where:{ $0.path.hasSuffix(suffix) }) { holders.append(process) }
        }
        return .init(hosts:hosts,holders:holders,unreadable:unreadable,execClaim:execClaim)
    }

    private static func definitelyGone(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    /// True only when the exact registered process is alive, is the app's host and
    /// holds this thread's rollout. An inherited CODEX_THREAD_ID in an exec helper fails.
    public func provesRegistration(_ registration: NativeLifecycleRegistration) -> Bool {
        guard let thread = UUID(uuidString:registration.sessionID)?.uuidString.lowercased() else { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(registration.processID,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(),UInt64(info.pbi_start_tvsec) == registration.startSeconds,UInt64(info.pbi_start_tvusec) == registration.startMicroseconds,
              let executable = Self.executable(registration.processID),let arguments = Self.arguments(registration.processID),
              CodexQueueRoute.role(executable:executable,arguments:arguments) == .appHost,
              let held = NativeSessionContext.codexRolloutFiles(process:registration.processID,rootDirectory:sessionsRoot) else { return false }
        return held.contains { $0.path.hasSuffix("-\(thread).jsonl") }
    }

    static func executable(_ pid: pid_t) -> String? {
        var path = [CChar](repeating:0,count:4096)
        guard proc_pidpath(pid,&path,UInt32(path.count)) > 0 else { return nil }
        return String(decoding:path.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
    }

    static func arguments(_ pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN,KERN_PROCARGS2,pid]
        var size = 0
        guard sysctl(&name,3,nil,&size,nil,0) == 0,size > MemoryLayout<Int32>.size,size <= 4*1024*1024 else { return nil }
        var bytes = [UInt8](repeating:0,count:size)
        guard sysctl(&name,3,&bytes,&size,nil,0) == 0,size > MemoryLayout<Int32>.size else { return nil }
        return parseArguments(Array(bytes.prefix(size)))
    }

    /// KERN_PROCARGS2: argc, the executable path, NUL padding, then argc strings.
    static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 + Int($1.element) << (8*$1.offset) }
        guard argc > 0,argc <= 4096 else { return nil }
        var index = 4
        while index < bytes.count,bytes[index] != 0 { index += 1 }
        while index < bytes.count,bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while index < bytes.count,result.count < argc {
            let start = index
            while index < bytes.count,bytes[index] != 0 { index += 1 }
            result.append(String(decoding:bytes[start..<index],as:UTF8.self))
            index += 1
        }
        return result.count == argc ? result : nil
    }
}
