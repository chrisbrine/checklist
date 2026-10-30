import Darwin
import Foundation

/// Startup headroom for the service's normal IPC, SQLite and filesystem work.
/// Cleanup must still bound its own descriptor lifetime at the inherited limit.
enum ServiceDescriptorLimit {
    struct Limits: Equatable {
        var soft: rlim_t
        var hard: rlim_t
    }

    struct Adjustment: Equatable {
        let previous: rlim_t
        let current: rlim_t
    }

    struct SystemFailure: Error, CustomStringConvertible {
        let operation: String
        let code: Int32
        var description: String { "\(operation) failed (errno \(code))" }
    }

    static func raiseForStartup() throws -> Adjustment? {
        try raiseForStartup(readLimits: {
            var value = rlimit(rlim_cur:0,rlim_max:0)
            guard getrlimit(RLIMIT_NOFILE,&value) == 0 else {
                throw SystemFailure(operation:"getrlimit(RLIMIT_NOFILE)",code:errno)
            }
            return Limits(soft:value.rlim_cur,hard:value.rlim_max)
        }, readKernelMaximum: {
            var maximum: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("kern.maxfilesperproc",&maximum,&size,nil,0) == 0 else {
                throw SystemFailure(operation:"sysctl(kern.maxfilesperproc)",code:errno)
            }
            guard size == MemoryLayout<Int32>.size, maximum > 0 else {
                throw SystemFailure(operation:"sysctl(kern.maxfilesperproc)",code:EINVAL)
            }
            return rlim_t(maximum)
        }, writeLimits: { limits in
            var value = rlimit(rlim_cur:limits.soft,rlim_max:limits.hard)
            guard setrlimit(RLIMIT_NOFILE,&value) == 0 else {
                throw SystemFailure(operation:"setrlimit(RLIMIT_NOFILE)",code:errno)
            }
        })
    }

    /// Injected OS boundary keeps tests from changing their process-wide limit.
    static func raiseForStartup(
        readLimits: () throws -> Limits,
        readKernelMaximum: () throws -> rlim_t,
        writeLimits: (Limits) throws -> Void
    ) throws -> Adjustment? {
        let limits = try readLimits()
        let maximum = try readKernelMaximum()
        guard maximum > 0 else {
            throw SystemFailure(operation:"sysctl(kern.maxfilesperproc)",code:EINVAL)
        }
        let target = min(limits.hard,maximum)
        // Never lower either limit, including an already-higher inherited soft
        // limit. RLIM_INFINITY naturally takes the finite kernel ceiling here.
        guard target > limits.soft else { return nil }
        try writeLimits(Limits(soft:target,hard:limits.hard))
        return Adjustment(previous:limits.soft,current:target)
    }
}
