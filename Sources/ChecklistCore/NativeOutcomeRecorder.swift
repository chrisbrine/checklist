import Foundation
import GRDB

/// Records a native delivery outcome (write result, host status or native reply) for the
/// bundled delivery service. It never drops a failed write silently:
/// - A storage failure is retried a bounded number of times with the same command ID, so a
///   write that did commit replays its receipt instead of running twice.
/// - When every attempt fails, the failure is logged with its delivery ID and the delivery
///   is marked `delivery_uncertain` with a receipt that names the lost write.
/// - A refusal on the merits (for example a used reply allowance) is logged and not retried.
public struct NativeOutcomeRecorder {
    public typealias Handle = (_ method: String, _ params: [String: Any]) throws -> [String: Any]
    public enum Outcome: Equatable {
        case recorded(attempts: Int)
        case refused(code: String)
        case markedUncertain
        case lost
    }

    public static let attemptLimit = 3
    /// Router codes that say the storage outcome is unknown or temporarily unavailable.
    static let transientCodes: Set<String> = ["OUTCOME_UNKNOWN", "STORAGE_DRAINING", "STORAGE_NOT_READY", "STORE_BUSY"]

    let handle: Handle
    let log: (String) -> Void
    let pause: (Int) -> Void

    public init(handle: @escaping Handle, log: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }, pause: @escaping (Int) -> Void = { usleep(useconds_t($0 * 1000)) }) {
        self.handle = handle; self.log = log; self.pause = pause
    }

    @discardableResult
    public func record(_ method: String, params input: [String: Any], deliveryID: String, routeGeneration: String? = nil) -> Outcome {
        var params = input
        params["command_id"] = (input["command_id"] as? String) ?? UUID().uuidString.lowercased()
        let first = attempt(method, params, deliveryID: deliveryID)
        switch first {
        case .success(let count): return .recorded(attempts: count)
        case .refusal(let code):
            log("Native \(method) for delivery \(deliveryID) was refused (\(code)); the delivery keeps its recorded state.")
            return .refused(code: code)
        case .failure(let code):
            log("Native \(method) for delivery \(deliveryID) failed after \(Self.attemptLimit) attempts (\(code)).")
        }
        guard !(method == "delivery_record" && input["state"] as? String == "uncertain") else {
            log("Delivery \(deliveryID) has no recorded native outcome; its last durable state stays in place.")
            return .lost
        }
        var receipt: [String: Any] = ["stage": Self.stage(method), "failed_write": method, "attempts": Self.attemptLimit]
        if let routeGeneration { receipt["route_generation"] = routeGeneration }
        if method == "delivery_host_status", let status = input["status"] as? String { receipt["host_status"] = status }
        let fallback: [String: Any] = ["command_id": UUID().uuidString.lowercased(), "delivery_id": deliveryID, "state": "uncertain", "receipt": receipt]
        switch attempt("delivery_record", fallback, deliveryID: deliveryID) {
        case .success:
            log("Delivery \(deliveryID) is marked delivery_uncertain because its \(method) write was lost.")
            return .markedUncertain
        case .refusal(let code), .failure(let code):
            log("Delivery \(deliveryID) could not be marked delivery_uncertain (\(code)); its last durable state stays in place.")
            return .lost
        }
    }

    static func stage(_ method: String) -> String {
        switch method {
        case "delivery_record": return "write_result_record_failed"
        case "delivery_host_status": return "host_status_record_failed"
        case "native_reply_record": return "native_reply_record_failed"
        default: return "native_record_failed"
        }
    }

    private enum Attempt { case success(Int), refusal(String), failure(String) }

    /// Every failed attempt is logged with its delivery ID, also when a later retry succeeds.
    /// The log names the method, attempt and code only; never a body or claim token.
    private func attempt(_ method: String, _ params: [String: Any], deliveryID: String) -> Attempt {
        var lastCode = "UNKNOWN"
        for number in 1...Self.attemptLimit {
            do { _ = try handle(method, params); return .success(number) }
            catch let error as CoreError where !Self.transientCodes.contains(error.code) { return .refusal(error.code) }
            catch let error as CoreError { lastCode = error.code }
            catch let error as DatabaseError { lastCode = "SQLITE_\(error.resultCode.rawValue)" }
            catch { lastCode = "COMMAND_FAILED" }
            log("Native \(method) for delivery \(deliveryID): attempt \(number) of \(Self.attemptLimit) failed (\(lastCode))" + (number < Self.attemptLimit ? "; retrying with the same command ID." : "."))
            if number < Self.attemptLimit { pause(number == 1 ? 50 : 200) }
        }
        return .failure(lastCode)
    }
}
