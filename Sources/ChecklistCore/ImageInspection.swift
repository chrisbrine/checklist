import CoreFoundation
import Foundation
import GRDB

public struct ImageInspectionError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Identity of an inspected original, scoped to the immutable target. This is an
/// explicit reviewer statement, not evidence that displaying a view ran a check.
public struct ImageInspectionIdentity: Hashable, Sendable {
    public let artifactID: String
    public let sha256: String
    public let targetManifestID: String
    public init(artifactID: String, sha256: String, targetManifestID: String) {
        self.artifactID = artifactID
        self.sha256 = sha256
        self.targetManifestID = targetManifestID
    }
    public var record: [String: String] { ["artifact_id": artifactID, "sha256": sha256, "target_manifest_id": targetManifestID] }
    public static func == (a: Self, b: Self) -> Bool {
        Data(a.artifactID.utf8) == Data(b.artifactID.utf8) && Data(a.sha256.utf8) == Data(b.sha256.utf8) && Data(a.targetManifestID.utf8) == Data(b.targetManifestID.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(artifactID.utf8))
        hasher.combine(Data(sha256.utf8))
        hasher.combine(Data(targetManifestID.utf8))
    }

    public static let maximumImages = 1000
    public static func validated(_ raw: Any?, expected: [Self], requireComplete: Bool) throws -> [Self] {
        guard expected.count <= maximumImages, let rows = raw as? [[String: Any]] ?? (raw == nil ? [] : nil), rows.count <= maximumImages else {
            throw ImageInspectionError("Use at most 1,000 exact inspected-image references.")
        }
        let allowed = Set(expected)
        var result: [Self] = []
        var seen = Set<Self>()
        for row in rows {
            guard Set(row.keys) == Set(["artifact_id", "sha256", "target_manifest_id"]),
                let id = row["artifact_id"] as? String, let sha = row["sha256"] as? String, let target = row["target_manifest_id"] as? String,
                !id.isEmpty, !target.isEmpty, sha.utf8.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw ImageInspectionError("An inspected image needs its exact attachment, SHA-256 and target manifest.") }
            let value = Self(artifactID: id, sha256: sha, targetManifestID: target)
            guard allowed.contains(value), seen.insert(value).inserted else {
                throw ImageInspectionError("Inspection marks must be distinct images of this exact target and hash.")
            }
            result.append(value)
        }
        guard !requireComplete || allowed.isSubset(of: seen) else { throw ImageInspectionError("Inspect and explicitly mark every candidate image before approving this target.") }
        return result
    }
}

public enum ImageViewName {
    public static func resolve(filename: String, explicit: String? = nil) -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(explicit.prefix(256)) }
        let stem = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let value = stem.replacingOccurrences(of: "(?i)[ _.-]+(?:round|r|v)[ _-]*[0-9]+$", with: "", options: .regularExpression)
        return value.isEmpty ? "Unnamed view" : String(value.prefix(256))
    }
}

public struct SpriteSheetLayout: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let frameCount: Int
    public let framesPerSecond: Double
    public init(columns: Int, rows: Int, frameCount: Int? = nil, framesPerSecond: Double = 8) throws {
        guard columns > 0, rows > 0, columns <= ImageInspectionIdentity.maximumImages / rows,
            let count = frameCount ?? Optional(columns * rows), count > 0, count <= columns * rows,
            framesPerSecond.isFinite, (0.1...60).contains(framesPerSecond)
        else { throw ImageInspectionError("Use a positive grid of at most 1,000 cells, a valid frame count and 0.1–60 frames per second.") }
        self.columns = columns
        self.rows = rows
        self.frameCount = count
        self.framesPerSecond = framesPerSecond
    }
    public static func parse(_ metadata: [String: Any]) throws -> Self {
        func integer(_ key: String, optional: Bool = false) throws -> Int? {
            if metadata[key] == nil, optional { return nil }
            guard let n = metadata[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                n.doubleValue.rounded() == n.doubleValue, (1...1000).contains(n.doubleValue)
            else { throw ImageInspectionError("Sprite grid values must be exact positive integers.") }
            return n.intValue
        }
        var fps = 8.0
        if let raw = metadata["frames_per_second"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw ImageInspectionError("Sprite frame rate must be a finite number.") }
            fps = n.doubleValue
        }
        guard let columns = try integer("columns"), let rows = try integer("rows") else { throw ImageInspectionError("Sprite grid values must be exact positive integers.") }
        return try Self(columns: columns, rows: rows, frameCount: integer("frame_count", optional: true), framesPerSecond: fps)
    }
    public func frameRect(index: Int, width: Int, height: Int) throws -> CGRect {
        guard (0..<frameCount).contains(index), width > 0, height > 0, width % columns == 0, height % rows == 0 else {
            throw ImageInspectionError("The grid must divide the original image into whole pixels and the selected frame must exist.")
        }
        let w = width / columns
        let h = height / rows
        return CGRect(x: (index % columns) * w, y: (index / columns) * h, width: w, height: h)
    }
}

extension CommandRouter {
    /// Uses the existing immutable artifact refs; no competing round/candidate store.
    func imageInspectionTargets(_ db: Database, task: JSON, manifest: JSON) throws -> [JSON] {
        let refs = (manifest["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []
        guard refs.count <= ImageInspectionIdentity.maximumImages else {
            throw CoreError("IMAGE_INSPECTION_REQUIRED", "Split submissions above 1,000 artifacts into bounded review targets.")
        }
        var result: [JSON] = []
        var seen = Set<Data>()
        for ref in refs {
            let id = try text(ref, "artifact_id")
            guard seen.insert(Data(id.utf8)).inserted else { continue }
            let file = try scoped(db, id, try StoredRecord(task, family: "task").string("project_id"), type: "attachment")
            guard FilePreviewKind.detect(name: file["name"] as? String ?? "", contentType: file["content_type"] as? String ?? "") == .image else { continue }
            var row = file
            row["target_manifest_id"] = manifest["id"]
            row["expected_sha256"] = ref["sha256"]
            row["view_name"] = ImageViewName.resolve(filename: file["name"] as? String ?? "", explicit: ref["view_name"] as? String)
            row["preview_presentation"] = ref["preview_presentation"] as? JSON ?? [:]
            if file["sha256"] as? String != ref["sha256"] as? String { row["availability"] = "unavailable" }
            result.append(row)
        }
        return result
    }
    func validatedImageInspections(_ db: Database, params: JSON, task: JSON, manifest: JSON, requireComplete: Bool) throws -> [JSON] {
        let targets = try imageInspectionTargets(db, task: task, manifest: manifest)
        let expected = try targets.map {
            ImageInspectionIdentity(
                artifactID: try StoredRecord($0, family: "attachment").string("id"), sha256: $0["expected_sha256"] as? String ?? "",
                targetManifestID: try StoredRecord(manifest, family: "manifest").string("id"))
        }
        do { return try ImageInspectionIdentity.validated(params["inspected_images"], expected: expected, requireComplete: requireComplete).map { $0.record as JSON } } catch {
            throw CoreError("IMAGE_INSPECTION_REQUIRED", error.localizedDescription)
        }
    }
    func requestImageInspections(_ db: Database, params: JSON, request: JSON, answers: [JSON], complete: Bool) throws -> [JSON] {
        guard complete else { return [] }
        let approves = answers.contains { $0["result"] as? String == "approved" }
        let task = try scoped(db, try StoredRecord(request, family: "request").string("task_id"), try StoredRecord(request, family: "request").string("project_id"), type: "task")
        if let mid = request["target_manifest_id"] as? String {
            let manifest = try scoped(db, mid, try StoredRecord(request, family: "request").string("project_id"), type: "manifest")
            return try validatedImageInspections(db, params: params, task: task, manifest: manifest, requireComplete: approves)
        }
        // Non-gate image requests retain the request form as their exact target scope.
        if let id = request["target_attachment_id"] as? String {
            let file = try scoped(db, id, try StoredRecord(request, family: "request").string("project_id"), type: "attachment")
            if FilePreviewKind.detect(name: file["name"] as? String ?? "") == .image {
                let expected = [
                    ImageInspectionIdentity(artifactID: id, sha256: request["target_sha256"] as? String ?? "", targetManifestID: "request:" + (try requestFormIdentity(request)))
                ]
                do { return try ImageInspectionIdentity.validated(params["inspected_images"], expected: expected, requireComplete: approves).map { $0.record as JSON } } catch {
                    throw CoreError("IMAGE_INSPECTION_REQUIRED", error.localizedDescription)
                }
            }
        }
        if params["inspected_images"] != nil { _ = try ImageInspectionIdentity.validated(params["inspected_images"], expected: [], requireComplete: false) }
        return []
    }
    func requestImageReviewContext(_ db: Database, request: JSON, task: JSON, caller: Caller) throws -> JSON {
        guard let mid = request["target_manifest_id"] as? String else { return [:] }
        let manifest = try scoped(db, mid, try StoredRecord(task, family: "task").string("project_id"), type: "manifest")
        var context: JSON = ["manifest_id": mid, "images": try imageInspectionTargets(db, task: task, manifest: manifest).map { imageReviewFileProjection($0) }]
        // Internal insertion order identifies the actual immediately preceding submission;
        // no global sequence is exposed to the client.
        if let old = try previousImageReviewManifest(db, task: task, manifestID: mid) {
            context["previous_manifest_id"] = old["id"]
            do { context["previous_images"] = try imageInspectionTargets(db, task: task, manifest: old).map { imageReviewFileProjection($0) } } catch {
                context["previous_problem"] = "Previous-round original metadata is unavailable; no replacement was selected."
            }
        }
        return context
    }
    private func imageReviewFileProjection(_ row: JSON) -> JSON {
        let fields = Set([
            "id", "project_id", "task_id", "sha256", "expected_sha256", "size", "mode", "availability", "unlinked", "revision", "created_at", "origin", "author",
            "author_session_id", "target_manifest_id", "view_name",
        ])
        var result = row.filter { fields.contains($0.key) }
        result["name"] = String((row["name"] as? String ?? "").prefix(512))
        let raw = row["preview_presentation"] as? JSON ?? [:]
        let resolved = FilePreviewPresentation.resolved(kind: .image, metadata: raw)
        var presentation: JSON = ["scale": resolved.scale.rawValue, "nearest_neighbor": raw["nearest_neighbor"] as? Bool ?? true, "accessible_label": resolved.accessibleLabel]
        if let sprite = raw["sprite_sheet"] as? JSON {
            if let grid = try? SpriteSheetLayout.parse(sprite) {
                presentation["sprite_sheet"] = ["columns": grid.columns, "rows": grid.rows, "frame_count": grid.frameCount, "frames_per_second": grid.framesPerSecond]
            } else {
                presentation["sprite_sheet"] = ["invalid": true]
            }
        }
        result["preview_presentation"] = presentation
        return result
    }
}

extension CommandRouter {
    /// Exact predecessor in this ticket's insertion order, independent of timestamps
    /// and content hashes. The internal order never leaves the service.
    private func previousImageReviewManifest(_ db: Database, task: JSON, manifestID: String) throws -> JSON? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT " + Self.canonicalRecordColumns
                + " FROM records WHERE type='manifest' AND project_id=CAST(? AS TEXT) AND json_extract(data,'$.task_id')=CAST(? AS TEXT) AND rowid < (SELECT "
                + "rowid FROM records WHERE type='manifest' AND id=CAST(? AS TEXT)) ORDER BY rowid DESC LIMIT 1",
            arguments: [
                Data((try StoredRecord(task, family: "task").string("project_id")).utf8), Data((try StoredRecord(task, family: "task").string("id")).utf8), Data(manifestID.utf8),
            ])
        return try row.map { try GRDBRecordEnvelopeAdapter.decode($0, expectedType: "manifest").object }
    }

    /// Read-only presentation context, deliberately separate from current action
    /// authority. At most two targets and 1,000 artifact refs per target are read.
    func reviewTargetHistory(_ db: Database, task: JSON, caller: Caller) throws -> JSON {
        guard let mid = task["current_manifest_id"] as? String else { return [:] }
        let pid = try StoredRecord(task, family: "task").string("project_id")
        let tid = try StoredRecord(task, family: "task").string("id")
        let current = try scoped(db, mid, pid, type: "manifest")
        guard SnapshotRecordIdentity(current["task_id"] as? String ?? "") == SnapshotRecordIdentity(tid) else {
            throw CoreError("INVALID_TARGET", "The current submission does not belong to this ticket.")
        }
        let previous = try previousImageReviewManifest(db, task: task, manifestID: mid)
        var manifests: [JSON] = []
        var attachments: [JSON] = []
        var seen = Set<Data>()
        var problem = ""
        for source in [previous, current].compactMap({ $0 }) {
            var manifest = contextRecord(source, type: "manifest", caller: caller)
            // A null value also says explicitly that no predecessor was loaded.
            manifest["previous_manifest_id"] = source["id"] as? String == mid ? (previous?["id"] ?? NSNull()) : NSNull()
            manifests.append(manifest)
            let refs = (source["evidence"] as? JSON)?["artifact_refs"] as? [JSON] ?? []
            guard refs.count <= ImageInspectionIdentity.maximumImages else {
                problem = "This submission exceeds the 1,000-artifact comparison limit. Its omitted originals cannot be inspected here."
                continue
            }
            for ref in refs {
                guard let id = ref["artifact_id"] as? String, seen.insert(Data(id.utf8)).inserted else { continue }
                guard let file = try? scoped(db, id, pid, type: "attachment"), SnapshotRecordIdentity(file["task_id"] as? String ?? "") == SnapshotRecordIdentity(tid) else {
                    problem = "Some submitted original metadata is unavailable. No replacement file was selected."
                    continue
                }
                attachments.append(contextRecord(file, type: "attachment", caller: caller))
            }
        }
        return ["manifests": manifests, "attachments": attachments, "problem": problem]
    }
}
