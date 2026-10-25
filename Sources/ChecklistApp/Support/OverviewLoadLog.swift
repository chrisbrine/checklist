import OSLog

/// CL-177: content-free Overview loader notices for check runners. Only the fixed surface
/// vocabulary, window-local visit numbers, outcome words, counts and elapsed times leave
/// the process; no row, project or ticket content is logged.
enum OverviewLoadLog {
    private static let logger = Logger(subsystem: "org.checklist.app", category: "OverviewLoad")
    static func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
}
