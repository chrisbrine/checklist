import SwiftUI
import CryptoKit
import Darwin

@MainActor
struct TestResultEvidenceView: View {
    @EnvironmentObject var store: ChecklistStore
    let task: Record
    let manifest: Record?
    let projection: ReviewProjection

    var body: some View {
        let results = TestResultEvidenceProjection(review: projection)
        let rows = results.artifacts(in: manifest?.id) + (manifest?.id != nil && manifest?.id == projection.current?.id ? results.artifacts(in: nil) : [])
        if !rows.isEmpty {
            DisclosureGroup("Attached test results · \(rows.count)") {
                VStack(alignment: .leading, spacing: Spacing.control) {
                    Text("Read NUnit XML, TRX or plain Swift XCTest logs. Counts describe the attachment; they do not establish a gate verdict.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                    ForEach(Array(rows.prefix(20))) { artifact in
                        TestResultArtifactView(current: artifact, previous: results.previous(for: artifact)).environmentObject(store)
                    }
                    if rows.count > 20 { Text("Showing the first 20 result attachments for this target.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                }.padding(.top, Spacing.small)
            }.checklistFont(.micro)
        }
    }

}

@MainActor
private struct TestResultArtifactView: View {
    @EnvironmentObject var store: ChecklistStore
    let current: TestResultArtifact
    let previous: TestResultArtifact?
    @State private var result: TestResultSummary?
    @State private var prior: TestResultSummary?
    @State private var problem = ""
    @State private var priorProblem = ""
    @State private var reading = false
    @State private var readID = UUID()
    @State private var readTask: Task<Void, Never>?
    var observation: String { current.observation + "|" + (previous?.observation ?? "") }
    var provenance: String {
        var value = "Attachment: \(current.file.id)\nSHA-256: \(current.expectedSHA256)\nUploader: \(current.file.string("author", fallback: "Not recorded"))\nAvailability: \(current.file.string("availability"))"
        if let manifestID = current.manifestID { value += "\nTarget: \(manifestID)" }
        if let attemptID = current.reviewAttemptID { value += "\nReviewer attempt: \(attemptID)" }
        if let previous {
            value += "\nPrevious target: \(previous.manifestID ?? "Not submitted")\nPrevious attachment: \(previous.file.id)\nPrevious expected SHA-256: \(previous.expectedSHA256)\nPrevious availability: \(previous.file.string("availability"))"
            if let attemptID = previous.reviewAttemptID { value += "\nPrevious reviewer attempt: \(attemptID)" }
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(verbatim: current.file.string("name")).checklistFont(.calloutEmphasis).lineLimit(2)
            Text("\(current.manifestID.map { "Bound to target \($0.prefix(8))" } ?? "Attached; not bound to a submitted target") · \(current.file.string("origin", fallback: "Recorded uploader")) · \(relativeTime(current.file.string("created_at")))").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
            if let unavailable = current.unavailable { Text(verbatim: unavailable).checklistFont(.micro).foregroundStyle(.orange) }
            else {
                Button(result == nil ? "Read test results" : "Read again") { beginRead() }.checklistDisabled([(reading, "The result is being read."), (!store.connected, DisabledReasons.offline)])
            }
            if reading { ProgressView("Reading exact result bytes…").controlSize(.small) }
            if !problem.isEmpty { Text(verbatim: problem).checklistFont(.micro).foregroundStyle(.orange) }
            if let result {
                Text("\(result.format.rawValue) · \(result.total) total · \(result.passed) passed · \(result.failed) failed · \(result.skipped) skipped\(result.other == 0 ? "" : " · \(result.other) other")").checklistFont(.micro).monospacedDigit()
                ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in Text(verbatim: warning).checklistFont(.micro).foregroundStyle(.orange) }
                if !result.failingNames.isEmpty {
                    DisclosureGroup("Failing tests · \(result.failingNames.count)") {
                        ForEach(Array(result.failingNames.prefix(100).enumerated()), id: \.offset) { _, name in Text(verbatim: name).checklistFont(.code).textSelection(.enabled) }
                        if result.failingNames.count > 100 { Text("First 100 names shown. The original contains the complete list.").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                    }
                }
                if let prior, prior.format == result.format {
                    Text("Since previous target (parsed cases): total \(delta(result.total - prior.total)), passed \(delta(result.passed - prior.passed)), failed \(delta(result.failed - prior.failed)), skipped \(delta(result.skipped - prior.skipped)), other \(delta(result.other - prior.other)).").checklistFont(.micro)
                    ForEach(Array(prior.warnings.enumerated()), id: \.offset) { _, warning in Text(verbatim: "Previous report: " + warning).checklistFont(.micro).foregroundStyle(.orange) }
                } else if !reading {
                    Text(verbatim: priorProblem.isEmpty ? "No unambiguous same-name result from the previous target is available for comparison." : priorProblem).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                }
            }
            TechnicalDetails(provenance.split(separator: "\n").map { line in let parts = line.split(separator: ":", maxSplits: 1); return (String(parts[0]), parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "") })
        }.padding(Spacing.row).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: Radius.small))
        .onChange(of: observation) { _, _ in clear() }
        .onDisappear { clear() }
    }
    private func delta(_ value: Int) -> String { value > 0 ? "+\(value)" : String(value) }
    private func clear() { readID = UUID(); readTask?.cancel(); result = nil; prior = nil; problem = ""; priorProblem = ""; reading = false }
    private func beginRead() {
        clear(); reading = true
        let generation = readID
        readTask = Task {
            defer { if readID == generation { reading = false } }
            do {
                let parsed = try await read(current)
                try Task.checkCancellation()
                guard readID == generation else { return }
                result = parsed
                if let previous {
                    do {
                        let old = try await read(previous)
                        try Task.checkCancellation()
                        guard readID == generation else { return }
                        prior = old
                        if old.format != parsed.format { priorProblem = "Counts are not compared because the result formats differ." }
                    } catch {
                        if !Task.isCancelled { priorProblem = "Previous target could not be compared: \(PlainError.text(error))" }
                    }
                }
            } catch { if !Task.isCancelled { problem = PlainError.text(error) } }
        }
    }
    private func read(_ artifact: TestResultArtifact) async throws -> TestResultSummary {
        if let reason = artifact.unavailable { throw TestResultParseError.invalid(reason) }
        try Task.checkCancellation()
        let response = try await store.request("attachment_read", ["project_id": artifact.file.string("project_id"), "attachment_id": artifact.file.id, "representation": "original"])
        let hold = response["read_hold_id"] as? String
        do {
            let actual = Record(values: response)
            guard actual.id == artifact.file.id, actual.string("project_id") == artifact.file.string("project_id"),
                  actual.string("task_id") == artifact.file.string("task_id"), actual.string("mode") == "managed",
                  actual.string("availability") == "available", actual.string("sha256") == artifact.expectedSHA256,
                  (0...TestResultParser.maxBytes).contains(actual.integer("size", fallback: -1)),
                  let path = response["url"] as? String, path.hasPrefix("/"), hold != nil else {
                throw TestResultParseError.invalid("The service did not return the exact available managed original with a reader hold.")
            }
            let digest = artifact.expectedSHA256
            let work = Task.detached(priority: .userInitiated) { try Self.parseAuthorizedFile(path, sha256: digest) }
            let summary = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            await release(hold, projectID: artifact.file.string("project_id"))
            return summary
        } catch {
            await release(hold, projectID: artifact.file.string("project_id"))
            throw error
        }
    }
    private func release(_ hold: String?, projectID: String) async {
        guard let hold else { return }
        // Release even after the view's read was canceled. A failed release still has
        // the service's bounded reader-lease expiry; it grants no ongoing access.
        await Task { @MainActor in
            _ = try? await store.request("attachment_read_release", ["command_id": UUID().uuidString, "project_id": projectID, "read_hold_id": hold])
        }.value
    }
    nonisolated private static func parseAuthorizedFile(_ path: String, sha256: String) throws -> TestResultSummary {
        try Task.checkCancellation()
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TestResultParseError.invalid("The authorized original cannot be opened safely.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= Int64(TestResultParser.maxBytes) else { throw TestResultParseError.limit }
        var data = Data()
        while let chunk = try file.read(upToCount: min(65_536, TestResultParser.maxBytes + 1 - data.count)), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= TestResultParser.maxBytes else { throw TestResultParseError.limit }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw TestResultParseError.invalid("The result file changed after it was recorded.") }
        return try TestResultParser.parse(data, isCanceled: { Task.isCancelled })
    }
}
