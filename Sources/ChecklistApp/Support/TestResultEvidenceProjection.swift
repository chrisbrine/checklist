import Foundation

/// Display-only selection. Service-minted reviewer bindings remain authoritative
/// before a verdict references them; they never become new unsubmitted uploads.
struct TestResultEvidenceProjection {
    let review: ReviewProjection

    func artifacts(in manifestID: String?) -> [TestResultArtifact] {
        var refs: [Record] = []
        if let manifestID {
            guard let target = review.manifests.first(where: { $0.id == manifestID }) else { return [] }
            refs = review.artifactRefs(for: target)
            for verdict in review.reviews where verdict.string("manifest_id") == manifestID {
                refs += reviewRefs(verdict)
            }
            refs += review.attachments.filter { $0.string("target_manifest_id") == manifestID }.map(Self.reference)
        } else {
            let bound = Set(review.manifests.flatMap { review.artifactRefs(for: $0) }.map { $0.string("artifact_id") }
                            + review.reviews.flatMap { reviewRefs($0) }.map { $0.string("artifact_id") })
            refs = review.attachments.filter { !Self.hasReviewerBinding($0) && !bound.contains($0.id) }.map(Self.reference)
        }
        var seen = Set<String>()
        return refs.compactMap { ref in
            guard let file = review.artifact(ref), file.string("task_id") == review.task.id,
                  file.string("project_id") == review.task.string("project_id"), !file.bool("unlinked"), Self.isResultFile(file) else { return nil }
            let explicit = Self.hasReviewerBinding(file)
            // A reference from another round cannot relabel immutable reviewer evidence.
            if explicit && (manifestID == nil || file.string("target_manifest_id") != manifestID) { return nil }
            var bindingProblem: String?
            let attemptID = file.string("review_attempt_id")
            if explicit {
                if attemptID.isEmpty || file.string("target_manifest_id").isEmpty {
                    bindingProblem = "Reviewer target or attempt metadata is incomplete; no comparison is available."
                } else if let attempt = review.attempts.first(where: { $0.id == attemptID }),
                          attempt.string("phase") != "review" || attempt.string("manifest_id") != manifestID {
                    bindingProblem = "Reviewer attempt and target metadata disagree; no comparison is available."
                }
                // Older attempts may be outside the loaded history. The service-minted
                // target/attempt pair still retains attribution without a verdict ref.
            }
            let row = TestResultArtifact(file: file, expectedSHA256: ref.string("sha256"), manifestID: manifestID,
                                         reviewAttemptID: explicit ? attemptID : nil, bindingProblem: bindingProblem)
            return seen.insert(row.id).inserted ? row : nil
        }
    }

    func previous(for current: TestResultArtifact) -> TestResultArtifact? {
        guard current.bindingProblem == nil else { return nil }
        let ordered = RecordOrdering.newestFirst(review.manifests)
        let previousID: String?
        if let id = current.manifestID {
            guard let index = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(index + 1) else { return nil }
            let currentTime = ordered[index].string("created_at"), previousTime = ordered[index + 1].string("created_at")
            // UUID presentation ties are not evidence of which round came first.
            guard !currentTime.isEmpty, !previousTime.isEmpty, currentTime != previousTime,
                  ordered.filter({ $0.string("created_at") == currentTime }).count == 1,
                  ordered.filter({ $0.string("created_at") == previousTime }).count == 1 else { return nil }
            previousID = ordered[index + 1].id
        } else {
            guard !Self.hasReviewerBinding(current.file) else { return nil }
            previousID = review.current?.id
        }
        guard let previousID else { return nil }
        let matches = artifacts(in: previousID).filter { $0.file.string("name") == current.file.string("name") && $0.bindingProblem == nil }
        return matches.count == 1 ? matches[0] : nil
    }

    private func reviewRefs(_ verdict: Record) -> [Record] {
        Record(values: verdict.object("review_assessment")).records("evidence_refs")
            + verdict.records("checks").flatMap { $0.records("evidence_refs") }
    }
    private static func reference(_ file: Record) -> Record {
        Record(values: ["artifact_id": file.id, "sha256": file.string("sha256")])
    }
    private static func hasReviewerBinding(_ file: Record) -> Bool {
        file.values["target_manifest_id"] != nil || file.values["review_attempt_id"] != nil
    }
    private static func isResultFile(_ file: Record) -> Bool {
        let extensions = [URL(fileURLWithPath: file.string("name")).pathExtension.lowercased(), URL(fileURLWithPath: file.string("path")).pathExtension.lowercased()]
        return extensions.contains { ["xml", "trx", "txt", "log", "out"].contains($0) }
    }
}

struct TestResultArtifact: Identifiable {
    let file: Record
    let expectedSHA256: String
    let manifestID: String?
    let reviewAttemptID: String?
    let bindingProblem: String?
    var id: String { [manifestID ?? "unsubmitted", file.id, expectedSHA256].joined(separator: ":") }
    var observation: String { [id, reviewAttemptID ?? "", bindingProblem ?? "", String(file.integer("revision")), file.string("availability"), file.string("mode"), file.string("sha256"), String(file.integer("size", fallback: -1))].joined(separator: ":") }
    var unavailable: String? {
        if let bindingProblem { return bindingProblem }
        if file.string("availability") != "available" { return "Original unavailable. Retained metadata is not a test result." }
        if file.string("mode") != "managed" { return "Attach a managed copy to read test results here. External references are not opened automatically." }
        if expectedSHA256.count != 64 || file.string("sha256") != expectedSHA256 { return "Attachment identity differs from the captured evidence." }
        if !(0...TestResultParser.maxBytes).contains(file.integer("size", fallback: -1)) { return "Read results from a complete UTF-8 file of at most 4 MiB." }
        return nil
    }
}
