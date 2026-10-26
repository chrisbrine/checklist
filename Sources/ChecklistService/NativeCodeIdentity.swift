import Foundation
import Security
import Darwin
import ChecklistIPC

/// Queue-confined Security objects, not cached authorization decisions. Every
/// use still checks dynamic code validity. Recreate the objects after executable
/// metadata, PID generation or path changes; never reuse a negative result.
final class NativeCodeIdentity {
    private struct FileStamp: Equatable {
        let path: Data
        let metadata: [Int64]
        init?(_ path: String) {
            var value = stat()
            guard stat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
            self.path = Data(path.utf8)
            metadata = [Int64(value.st_dev), Int64(value.st_ino), Int64(value.st_gen), Int64(value.st_uid), Int64(value.st_gid), Int64(value.st_mode), value.st_size,
                Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec), Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
        }
    }
    private struct ProcessStamp: Equatable {
        let generation: [UInt64]
        let file: FileStamp
        init?(_ pid: pid_t) {
            var bsd = proc_bsdinfo(), path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue:bsd))) == MemoryLayout.size(ofValue:bsd), bsd.pbi_uid == getuid(),
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0, let file = FileStamp(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { return nil }
            generation = [UInt64(bsd.pbi_pid), bsd.pbi_start_tvsec, bsd.pbi_start_tvusec, UInt64(bsd.pbi_uid)]
            self.file = file
        }
    }
    private struct Running {
        let stamp: ProcessStamp
        let code: SecCode
        let information: [String:Any]
    }
    private struct Executable {
        let stamp: FileStamp
        let identity: ClientBuildIdentity
    }
    private var running: [pid_t:Running] = [:]
    private var executables: [Data:Executable] = [:]

    func executable(_ url: URL) -> ClientBuildIdentity? {
        let key = Data(url.path.utf8)
        guard let stamp = FileStamp(url.path) else { executables.removeValue(forKey:key); return nil }
        if let cached = executables[key], cached.stamp == stamp { return cached.identity }
        executables.removeValue(forKey:key)
        guard let identity = ClientBuildIdentity.executable(url), FileStamp(url.path) == stamp else { return nil }
        if executables.count >= 8 { executables.removeAll() }
        executables[key] = Executable(stamp:stamp,identity:identity)
        return identity
    }

    func signingInfo(_ pid: pid_t) -> [String:Any]? {
        guard let stamp = ProcessStamp(pid) else { running.removeValue(forKey:pid); return nil }
        if let cached = running[pid], cached.stamp == stamp {
            guard SecCodeCheckValidity(cached.code, [], nil) == errSecSuccess, ProcessStamp(pid) == stamp else {
                running.removeValue(forKey:pid); return nil
            }
            return cached.information
        }
        running.removeValue(forKey:pid)
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String:NSNumber(value:pid)] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue:kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String:Any], ProcessStamp(pid) == stamp else { return nil }
        if running.count >= 64 { running.removeAll() }
        running[pid] = Running(stamp:stamp,code:code,information:info)
        return info
    }
}
