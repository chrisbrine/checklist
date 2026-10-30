import Foundation
import GRDB

/// Durable failure identities for a deferred attempt. Keep the historical
/// reason/code projection while retaining the engine or syscall that failed;
/// a generic preparation code alone cannot diagnose resource exhaustion.
enum TicketCleanupFailureDiagnostics {
    static func details(_ error: Error) -> JSON {
        if let failure = error as? CoreError {
            var result: JSON = ["code":failure.code]
            for key in ["operation","reason","posix_errno","sqlite_result_code","sqlite_extended_result_code","error_domain","error_code"] {
                if let value = failure.details[key] as? String {result[key] = String(value.prefix(512))}
                else if let value = failure.details[key] as? NSNumber {result[key] = value}
            }
            return result
        }
        if let failure = error as? DatabaseError {
            return ["code":"CLEANUP_PREPARATION_UNAVAILABLE","sqlite_result_code":failure.resultCode.rawValue,"sqlite_extended_result_code":failure.extendedResultCode.rawValue]
        }
        let failure = error as NSError
        var result: JSON = ["code":"CLEANUP_PREPARATION_UNAVAILABLE","error_domain":String(failure.domain.prefix(512)),"error_code":failure.code]
        if failure.domain == NSPOSIXErrorDomain {result["posix_errno"] = failure.code}
        return result
    }
}
