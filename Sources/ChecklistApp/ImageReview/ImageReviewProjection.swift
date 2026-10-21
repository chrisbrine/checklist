import Foundation
import ChecklistCore

struct ImageReviewCandidate: Identifiable {
    let file: Record
    let identity: ImageInspectionIdentity
    let viewName: String
    var id: ImageInspectionIdentity { identity }
    init(file: Record, manifestID: String, expectedSHA256: String? = nil, viewName: String? = nil) {
        self.file = file
        identity = ImageInspectionIdentity(artifactID: file.id, sha256: expectedSHA256 ?? file.string("expected_sha256", fallback: file.string("sha256")), targetManifestID: manifestID)
        self.viewName = ImageViewName.resolve(filename: file.string("name"), explicit: viewName ?? (file.string("view_name").isEmpty ? nil : file.string("view_name")))
    }
    var unavailable: String? {
        if file.string("availability") != "available" { return "Original unavailable or cleaned. A retained thumbnail cannot qualify inspection." }
        if file.bool("unlinked") { return "This original is no longer attached to the ticket." }
        if file.string("mode") != "managed" { return "Image approval requires a managed original with a recorded version." }
        if file.string("sha256") != identity.sha256 || identity.sha256.utf8.count != 64 { return "This image no longer matches the submitted target hash." }
        return nil
    }
}

struct ImageReviewGroup: Identifiable {
    let viewName: String
    let current: [ImageReviewCandidate]
    let previous: [ImageReviewCandidate]
    var id: Data { Data(viewName.utf8) }
    static func make(current: [ImageReviewCandidate], previous: [ImageReviewCandidate]) -> [Self] {
        let currentByView = Dictionary(grouping: current, by: { Data($0.viewName.utf8) })
        let previousByView = Dictionary(grouping: previous, by: { Data($0.viewName.utf8) })
        let names = Set(currentByView.keys).union(previousByView.keys).sorted { $0.lexicographicallyPrecedes($1) }
        return names.map { key in Self(viewName: String(decoding: key, as: UTF8.self), current: currentByView[key] ?? [], previous: previousByView[key] ?? []) }
    }
}

enum ImageReviewProjection {
    static func candidates(manifest: Record, review: ReviewProjection) -> [ImageReviewCandidate] {
        var seen = Set<ImageInspectionIdentity>()
        return review.artifactRefs(for: manifest).compactMap { ref in
            guard var file = review.artifact(ref), FilePreviewKind.detect(name: file.string("name"), contentType: file.string("content_type")) == .image else { return nil }
            var values = file.values; values["target_manifest_id"] = manifest.id; values["preview_presentation"] = ref.object("preview_presentation"); file = Record(values: values)
            let row = ImageReviewCandidate(file: file, manifestID: manifest.id, expectedSHA256: ref.string("sha256"), viewName: ref.string("view_name").isEmpty ? nil : ref.string("view_name"))
            return seen.insert(row.identity).inserted ? row : nil
        }
    }
    static func previous(to manifest: Record, review: ReviewProjection) -> Record? {
        if let previous = manifest.values["previous_manifest_id"] {
            guard let id = previous as? String else { return nil }
            return review.manifests.first { Data($0.id.utf8) == Data(id.utf8) }
        }
        let ordered = RecordOrdering.newestFirst(review.manifests)
        guard let index = ordered.firstIndex(where: { $0.id == manifest.id }), ordered.indices.contains(index + 1) else { return nil }
        let prior = ordered[index + 1]
        // Whole-second timestamp ties are not a reliable ordering of loaded history.
        guard !manifest.string("created_at").isEmpty, !prior.string("created_at").isEmpty,
              manifest.string("created_at") != prior.string("created_at"),
              ordered.filter({ $0.string("created_at") == manifest.string("created_at") }).count == 1,
              ordered.filter({ $0.string("created_at") == prior.string("created_at") }).count == 1 else { return nil }
        return prior
    }
    static func selection(_ values: [[String: String]]) -> Set<ImageInspectionIdentity> {
        Set(values.compactMap { row in
            guard let id = row["artifact_id"], let sha = row["sha256"], let target = row["target_manifest_id"] else { return nil }
            return ImageInspectionIdentity(artifactID: id, sha256: sha, targetManifestID: target)
        })
    }
    static func readyToApprove(_ candidates: [ImageReviewCandidate], selection: Set<ImageInspectionIdentity>, problem: String) -> Bool {
        problem.isEmpty && candidates.allSatisfy { $0.unavailable == nil && selection.contains($0.identity) }
    }
}
