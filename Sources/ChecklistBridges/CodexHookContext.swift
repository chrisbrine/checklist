import Foundation
import Darwin
import ChecklistProviders

extension NativeSessionContext {
    /// Codex hooks can inherit the spawning conversation's CODEX_THREAD_ID. Derive the
    /// identity from a rollout that the nearest native Codex process holds by kernel file
    /// descriptor, rather than from environment variables. A `codex exec` run with subagents
    /// holds several rollouts, so the stdin session ID selects among them. It cannot name a
    /// rollout that this process does not hold: that fails closed. Limit: a subprocess of
    /// this Codex process can select any rollout that this process holds.
    public static func codexHookDiscovery(hookSessionID: String) -> NativeSessionDiscovery {
        guard let host = closestNativeHost(providerRegistry: .bundled), host.provider == "codex",
              let fence = codexHookProcessFence(host.pid),
              let home = getpwuid(getuid())?.pointee.pw_dir,
              let id = codexOpenRolloutSession(process: host.pid, rootDirectory: URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".codex/sessions").path, selecting: hookSessionID),
              codexHookProcessFence(host.pid) == fence,
              closestNativeHost(providerRegistry: .bundled)?.pid == host.pid else { return .unavailable }
        return observed(provider: "codex", environment: ["CODEX_THREAD_ID": id],
            currentDirectory: FileManager.default.currentDirectoryPath).map(NativeSessionDiscovery.available) ?? .unavailable
    }

    /// The same kernel FD/read path is exercised with an owned fixture root in
    /// tests. Production always supplies the actual user's conventional sessions.
    static func codexOpenRolloutSession(process: Int32, rootDirectory: String, selecting session: String) -> String? {
        guard let wanted = UUID(uuidString: session)?.uuidString.lowercased(),
              let held = codexRolloutFiles(process: process, rootDirectory: rootDirectory) else { return nil }
        let matching = held.filter { URL(fileURLWithPath: $0.path).lastPathComponent.hasSuffix("-\(wanted).jsonl") }
        guard matching.count == 1, let id = codexRolloutSession(matching[0]), id == wanted,
              codexRolloutFiles(process: process, rootDirectory: rootDirectory) == held else { return nil }
        return id
    }

    struct RolloutFile: Equatable {
        let path: String
        let inode: UInt64
        let device: Int32
    }

    private static func codexHookProcessFence(_ process: Int32) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid() else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    static func codexRolloutFiles(process: Int32, rootDirectory: String, requireComplete: Bool = false) -> [RolloutFile]? {
        // Foundation normalizes macOS /private aliases differently from the vnode
        // paths returned by libproc. POSIX realpath uses the same physical path.
        guard let physicalRoot = realpath(rootDirectory, nil) else { return nil }
        let root = String(cString: physicalRoot) + "/"
        free(physicalRoot)
        let needed = proc_pidinfo(process, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0, needed <= 4096 * MemoryLayout<proc_fdinfo>.size else { return nil }
        var entries = [proc_fdinfo](repeating: .init(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size + 32)
        let received = entries.withUnsafeMutableBytes { proc_pidinfo(process, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard received > 0, Int(received) < entries.count * MemoryLayout<proc_fdinfo>.size else { return nil }
        var result: [RolloutFile] = []
        for entry in entries.prefix(Int(received) / MemoryLayout<proc_fdinfo>.size) where entry.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            guard entry.proc_fd <= UInt32(Int32.max),
                  proc_pidfdinfo(process, Int32(entry.proc_fd), PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) == MemoryLayout<vnode_fdinfowithpath>.size else {
                if requireComplete { return nil }
                continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard path.hasPrefix(root), URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-"), path.hasSuffix(".jsonl") else { continue }
            let file = RolloutFile(path: path, inode: info.pvip.vip_vi.vi_stat.vst_ino, device: Int32(bitPattern: info.pvip.vip_vi.vi_stat.vst_dev))
            if !result.contains(file) { result.append(file) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func codexRolloutSession(_ file: RolloutFile) -> String? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_mode & 0o022 == 0,
              attributes.st_ino == file.inode, attributes.st_dev == file.device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 0x0a) else { return nil }
        return codexRolloutSessionHeader(Data(bytes[..<newline]), path: file.path)
    }

    static func codexRolloutSessionHeader(_ data: Data, path: String) -> String? {
        guard data.count <= 65_536,
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              header["type"] as? String == "session_meta", let payload = header["payload"] as? [String: Any],
              let raw = payload["id"] as? String, let id = UUID(uuidString: raw),
              URL(fileURLWithPath: path).lastPathComponent.hasSuffix("-\(id.uuidString.lowercased()).jsonl") else { return nil }
        return id.uuidString.lowercased()
    }
}
