import Foundation
import CoreFoundation

/// Only a closed error code and time survive; descriptions can contain private content.
struct DiagnosticErrorRecord: Encodable {
    let recordedAt: Date
    let code: String

    static let allowedCodes: Set<String> = [
        "ANSWER_INCOMPLETE", "BLOCKING_REQUEST_EXISTS", "CHILD_WRITERS_ACTIVE", "CLAIM_CONFLICT",
        "COMMAND_FAILED", "CREDENTIAL_INSTANCE_MISMATCH", "CREDENTIAL_STORE_UNAVAILABLE", "CURSOR_RESET", "DEPENDENCY_UNSATISFIED", "DESTINATION_EXISTS",
        "DIRECTION_CURSOR_REQUIRED", "DISK_FULL", "EVIDENCE_STALE", "FILE_ACCESS_REQUIRED",
        "FILE_TOO_LARGE", "FORBIDDEN", "IDEMPOTENCY_CONFLICT", "INVALID_INPUT", "INVALID_RESPONSE",
        "INVALID_TRANSITION", "KEYCHAIN_UNAVAILABLE", "NOT_FOUND", "NOT_READY", "ORIGINAL_CLEANED",
        "OUTCOME_UNKNOWN", "OWNER_CHANNEL_REQUIRED", "POLICY_ACK_REQUIRED", "POLICY_CHANGED",
        "POLICY_DENIED", "REQUEST_CHANGED", "REVISION_CONFLICT", "ROOT_MISMATCH",
        "SERVICE_REGISTRATION_FAILED", "SERVICE_SETUP_REQUIRED", "SERVICE_UNAVAILABLE",
        "SOURCE_CHANGED", "TARGET_CHANGED", "USER_DIRECTION_PENDING", "WORKSPACE_MISMATCH"
    ]

    init(code: String, recordedAt: Date = Date()) {
        self.code = Self.allowedCodes.contains(code) ? code : "OTHER_ERROR"
        self.recordedAt = recordedAt
    }
}

final class DiagnosticsRecorder: @unchecked Sendable {
    static let shared = DiagnosticsRecorder()
    private let lock = NSLock()
    private var entries: [DiagnosticErrorRecord] = []
    static let limit = 20

    func record(_ description: String?, at date: Date = Date()) {
        guard var description, !description.isEmpty else { return }
        if description.hasPrefix("Checklist service: ") { description.removeFirst("Checklist service: ".count) }
        let candidate = description.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let entry = DiagnosticErrorRecord(code: candidate, recordedAt: date)
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func snapshot() -> [DiagnosticErrorRecord] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

struct DiagnosticsReport: Encodable {
    struct Versions: Encodable {
        let app: String
        let bundle: String
        let buildID: String
        let macOS: String
        let architecture: String
    }
    struct Service: Encodable {
        let state: String
        let version: String
        let countsAvailable: Bool
    }
    let format = "checklist-diagnostics"
    let schemaVersion = 1
    let exportedAt: Date
    let versions: Versions
    let service: Service
    let recordCounts: [String: Int]
    let recentErrors: [DiagnosticErrorRecord]
    let errorHistoryScope = "owner_app_current_run"
}

/// The report is built from an allowlist rather than redacting a raw snapshot or log.
enum DiagnosticsExport {
    static let countKeys: Set<String> = [
        "project", "task", "status", "tag", "message", "request", "attachment", "attempt",
        "session", "profile", "group", "review", "review_request", "finding", "finding_resolution",
        "manifest", "source_capture", "source_execution", "checkpoint", "direction_disposition",
        "relation", "task_alias", "policy_revision", "taxonomy_revision", "project_context_revision",
        "batch", "storage_hold", "cleanup_preview", "handoff", "delegation", "other", "event", "command_receipt",
        "media_review_type", "media_review_type_revision", "media_round", "media_round_manifest",
        "media_review_context", "media_context_attention", "media_context_reconciliation",
        "media_item", "media_item_target", "media_candidate", "media_owner_decision",
        "media_suggestion", "media_rework_link", "media_intake", "media_intake_plan",
        "media_intake_row", "media_intake_chunk", "media_bulk_operation", "media_bulk_chunk"
    ]

    static func report(buildMetadata: [String: Any], appVersion: String?, bundleVersion: String?, serviceSummary: [String: Any]?, recentErrors: [DiagnosticErrorRecord], at date: Date = Date(), operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> DiagnosticsReport {
        let service = serviceSummary?["service"] as? [String: Any] ?? [:]
        let rawCounts = serviceSummary?["record_counts"] as? [String: Any] ?? [:]
        var counts: [String: Int] = [:]
        for key in countKeys {
            if let number = rawCounts[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 1_000_000_000_000, number.doubleValue.rounded() == number.doubleValue { counts[key] = number.intValue }
        }
        let responsive = service["state"] as? String == "responsive"
        return DiagnosticsReport(
            exportedAt: date,
            versions: .init(app: version(buildMetadata["version"] as? String ?? appVersion), bundle: version(bundleVersion), buildID: buildID(buildMetadata["build_id"]), macOS: "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)", architecture: architecture),
            service: .init(state: responsive ? "responsive" : "unavailable", version: version(service["version"] as? String), countsAvailable: responsive && !counts.isEmpty),
            recordCounts: responsive ? counts : [:],
            recentErrors: Array(recentErrors.suffix(DiagnosticsRecorder.limit))
        )
    }

    static func currentReport(serviceSummary: [String: Any]?, recorder: DiagnosticsRecorder = .shared) -> DiagnosticsReport {
        var metadata: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "build-info", withExtension: "json"), let bytes = try? Data(contentsOf: url), let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] { metadata = value }
        return report(buildMetadata: metadata, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, serviceSummary: serviceSummary, recentErrors: recorder.snapshot())
    }

    static func encoded(_ report: DiagnosticsReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func write(_ report: DiagnosticsReport, to destination: URL) throws {
        guard destination.isFileURL else { throw NSError(domain: "Checklist.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a local file destination."]) }
        try encoded(report).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func version(_ raw: String?) -> String {
        guard let raw, raw.utf8.count <= 32, raw.range(of: "^[0-9]+(?:\\.[0-9]+){0,3}$", options: .regularExpression) != nil else { return "unknown" }
        return raw
    }
    private static func buildID(_ raw: Any?) -> String {
        guard let value = raw as? String, value.range(of: "^[a-f0-9]{16,64}$", options: .regularExpression) != nil else { return "development" }
        return value
    }
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
