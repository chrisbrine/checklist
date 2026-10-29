import Foundation
import Darwin
import CoreFoundation

/// A bounded, process-owned observation while startup cannot answer XPC yet.
/// This is presentation only: it never opens the store or proves a command outcome.
public struct StorageUpgradeStatus: Equatable, Sendable {
    public static let fileName = "upgrade-progress.json"
    public let stage: String
    public let estimatedRemainingSeconds: Int
    public let reason: String?

    public init?(stage: String, estimatedRemainingSeconds: Int, reason: String? = nil) {
        guard Self.stages[stage] != nil, (0...7200).contains(estimatedRemainingSeconds) else { return nil }
        self.stage = stage; self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.reason = ["source_changed_after_preparation", "preparation_unavailable", "preparation_invalid"].contains(reason ?? "") ? reason : nil
    }

    public init?(error: Error) {
        guard let error = error as? ChecklistError, error.code == "STORAGE_UPGRADING",
              error.details["state"] as? String == "upgrading", let stage = error.details["stage"] as? String,
              let seconds = Self.integer(error.details["estimated_remaining_seconds"]) else { return nil }
        self.init(stage: stage, estimatedRemainingSeconds: seconds, reason: error.details["reason"] as? String)
    }

    private static let stages = [
        "protected_snapshot": "Taking and verifying the protected pre-upgrade backup",
        "migration_rehearsal": "Rehearsing and verifying the store migration",
        "final_migration": "Applying the verified store migration",
        "preparation_validation": "Checking the prepared upgrade against the stopped store"
    ]
    public var stageTitle: String { Self.stages[stage]! }
    public var estimateText: String {
        let amount = estimatedRemainingSeconds >= 60 ? (estimatedRemainingSeconds + 59) / 60 : max(1, estimatedRemainingSeconds)
        return "Estimated remaining: about \(amount) \(estimatedRemainingSeconds >= 60 ? "minute" : "second")\(amount == 1 ? "" : "s")."
    }
    public var summary: String {
        let fallback = reason == "source_changed_after_preparation"
            ? " The store changed after preparation, so a fresh protected backup is required."
            : reason != nil ? " The prepared upgrade could not be reused; startup is preserving a fresh protected backup." : ""
        return stageTitle + ". " + estimateText + fallback
    }
    public func error(commandID: String? = nil, outcomeUnknown: Bool = false, transportReason: String? = nil) -> ChecklistError {
        var details: [String: Any] = ["state": "upgrading", "stage": stage,
            "estimated_remaining_seconds": estimatedRemainingSeconds, "command_outcome": outcomeUnknown ? "unknown" : "not_sent"]
        if let reason { details["reason"] = reason }
        if let transportReason { details["transport_reason"] = transportReason }
        if let commandID { details["command_id"] = commandID }
        let recovery = outcomeUnknown && commandID != nil ? " The earlier command outcome remains unknown; reconcile its original command ID before retrying." : ""
        return ChecklistError("STORAGE_UPGRADING", "Checklist is upgrading its store. " + summary + recovery, details: details)
    }

    /// Reject dead/stale writers, links, nonregular/oversized files and invalid
    /// fields. The only filesystem effect is a read of this instance's marker.
    public static func read(root: URL, now: Date = Date(), isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> Self? {
        let fd = open(root.appendingPathComponent(fileName).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0, info.st_size <= 16_384,
              let bytes = try? handle.read(upToCount: 16_385), bytes.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["state"] as? String == "upgrading", let stage = object["stage"] as? String,
              let seconds = integer(object["estimated_remaining_seconds"]),
              let pid = integer(object["pid"]), pid > 0, pid <= Int(Int32.max),
              let updated = object["updated_at"] as? String, updated.utf8.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.date(from: updated) ?? {
            formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: updated)
        }()
        guard let timestamp, (-60...2100).contains(now.timeIntervalSince(timestamp)), isProcessAlive(Int32(pid)) else { return nil }
        return Self(stage: stage, estimatedRemainingSeconds: seconds, reason: object["reason"] as? String)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), number == NSNumber(value: number.intValue) else { return nil }
        return number.intValue
    }
}
