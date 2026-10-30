import Foundation
import GRDB

struct StorageSnapshotObject: Codable, Equatable {
    let relativePath: String
    let kind: String
    let expectedSHA256: String?
    let expectedSize: Int64?
    let executable: Bool
    let linkTarget: String?
    var authorities: [String]
}
struct StorageSnapshotAbsence: Codable, Equatable {
    let authority: String
    let reason: String
}
struct StorageSnapshotInventory {
    var objects: [StorageSnapshotObject]
    var unavailable: [StorageSnapshotAbsence]
    var externalReferences: [String]
}

enum StorageSnapshotAuthority {
    /// Resolve only captured descriptors, never filesystem links. Every hop
    /// stays within its own immutable capture and terminates at an included file.
    static func validateCapturedLinks(_ objects: [StorageSnapshotObject]) throws {
        let entries = Dictionary(uniqueKeysWithValues: objects.map { ($0.relativePath, $0) })
        for link in objects where link.kind == "symlink" {
            _ = try capturedLinkClosure(link.relativePath,entries:entries)
        }
    }

    /// Shared by snapshot validation and deletion. Include every captured hop
    /// and the final file without following live filesystem links.
    static func capturedLinkClosure(_ initialPath: String,entries: [String:StorageSnapshotObject]) throws -> [String] {
        let initial = try StorageObjectFiles.parts(initialPath)
        guard initial.count >= 5, initial[0] == "source-captures", initial[3] == "source" else { throw StorageSnapshotFailure.unsupportedAuthority }
        let capturePrefix = Array(initial.prefix(4))
        var path = initialPath, visited: Set<String> = [], hops = 0, closure: [String] = []
        while true {
            guard visited.insert(path).inserted, let entry = entries[path] else { throw StorageSnapshotFailure.unsupportedAuthority }
            closure.append(path)
            if entry.kind == "file" { return closure }
            guard entry.kind == "symlink", hops < 32, let target = entry.linkTarget,
                  !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0"),
                  StorageObjectFiles.sha(Data(target.utf8)) == entry.expectedSHA256 else { throw StorageSnapshotFailure.unsupportedAuthority }
            var components = try StorageObjectFiles.parts(path); components.removeLast()
            for component in target.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard components.count > capturePrefix.count else { throw StorageSnapshotFailure.unsupportedAuthority }
                    components.removeLast()
                } else { components.append(String(component)) }
            }
            guard components.count > capturePrefix.count, Array(components.prefix(4)) == capturePrefix else { throw StorageSnapshotFailure.unsupportedAuthority }
            path = components.joined(separator: "/"); hops += 1
        }
    }

    // Closed current authority catalog, not a permission grant from a path.
    static var knownTypes: Set<String> { Set(EnvelopeFamily.catalog.keys) }

    static func inventory(_ db: Database, root: URL, budget: StorageSnapshotBudget, objectRoot: URL? = nil, retainedExists: (String) throws -> Bool) throws -> StorageSnapshotInventory {
        var objects: [String: StorageSnapshotObject] = [:]
        var unavailable: [StorageSnapshotAbsence] = [], external: [String] = []
        let relocation = try ManagedPathRelocation.snapshotPlan(db, root: root, budget: budget, objectRoot: objectRoot)
        var recordCount = 0
        let databaseBytes = budget.measurement.metadataBytes
        var declaredObjectBytes: Int64 = 0
        func text(_ record: [String: Any], _ key: String) throws -> String {
            guard let value = record[key] as? String, !value.isEmpty else { throw StorageSnapshotFailure.unsupportedAuthority }; return value
        }
        func digest(_ value: Any?) throws -> String {
            guard let value = value as? String, value.utf8.count == 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StorageSnapshotFailure.unsupportedAuthority }
            return value
        }
        // Done cleanup keeps canonical evidence. Its durable exact outcomes explain
        // unavailable bytes without modifying immutable manifests or capture lists.
        let cleanedRows = try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records WHERE type='storage_job' AND json_extract(data,'$.cause')='done_evidence'")
        var cleaned: [String:[JSON]] = [:],cleanedEnvelopes: [String:DecodedEnvelope] = [:]
        while let row = try cleanedRows.next() {
            try budget.check()
            let envelope = try GRDBRecordEnvelopeAdapter.decode(row),receipt = envelope.object
            guard cleanedEnvelopes.count < budget.maximumRecords else { throw StorageSnapshotFailure.limit }
            cleanedEnvelopes[envelope.id] = envelope
            for object in receipt["objects"] as? [JSON] ?? [] where ["removed","already_missing"].contains(object["state"] as? String ?? "") {
                if let path = object["relative_path"] as? String {cleaned[path,default:[]].append(object)}
            }
        }
        func add(_ value: StorageSnapshotObject) throws {
            if cleaned[value.relativePath]?.contains(where: {object in
                (value.expectedSHA256 == nil || object["sha256"] as? String == value.expectedSHA256) &&
                (value.expectedSize == nil || (object["size"] as? NSNumber)?.int64Value == value.expectedSize) &&
                object["kind"] as? String == value.kind
            }) == true, try !retainedExists(value.relativePath) {
                for authority in value.authorities {unavailable.append(.init(authority:authority,reason:"evidence_cleaned"))}
                return
            }
            if var prior = objects[value.relativePath] {
                guard prior.kind == value.kind,
                      prior.expectedSHA256 == nil || value.expectedSHA256 == nil || prior.expectedSHA256 == value.expectedSHA256,
                      prior.expectedSize == nil || value.expectedSize == nil || prior.expectedSize == value.expectedSize,
                      prior.executable == value.executable,prior.linkTarget == value.linkTarget else { throw StorageSnapshotFailure.unsupportedAuthority }
                prior = .init(relativePath:prior.relativePath,kind:prior.kind,expectedSHA256:prior.expectedSHA256 ?? value.expectedSHA256,expectedSize:prior.expectedSize ?? value.expectedSize,executable:prior.executable,linkTarget:prior.linkTarget,authorities:prior.authorities)
                prior.authorities = Array(Set(prior.authorities + value.authorities)).sorted(); objects[value.relativePath] = prior
            } else {
                objects[value.relativePath] = value
                let sum = declaredObjectBytes.addingReportingOverflow(value.expectedSize ?? Int64(value.linkTarget?.utf8.count ?? 0))
                guard !sum.overflow else { throw StorageSnapshotFailure.limit }
                declaredObjectBytes = sum.partialValue
            }
            budget.measurement.objects = objects.count
            let logical = databaseBytes.addingReportingOverflow(declaredObjectBytes)
            guard !logical.overflow else { throw StorageSnapshotFailure.limit }
            budget.measurement.bytes = logical.partialValue
            budget.measurement.lowerBound = true
            guard objects.count <= budget.maximumObjects else { throw budget.capacityFailure("snapshot_object_capacity") }
        }
        func regular(path: String, family: String, sha: String?, size: Int64?, executable: Bool = false, authority: String) throws {
            if let size, size < 0 { throw StorageSnapshotFailure.unsupportedAuthority }
            let decision = try relocation.decision(path, family: family, root: root)
            guard let relative = decision.relative else { unavailable.append(.init(authority: authority, reason: "outside_store_root")); return }
            try add(StorageSnapshotObject(relativePath: relative, kind: "file", expectedSHA256: sha,
                expectedSize: size, executable: executable, linkTarget: nil, authorities: [authority]))
            if let size, size > budget.maximumObjectBytes { throw budget.capacityFailure("snapshot_object_bytes") }
        }
        func capture(_ value: [String: Any], attribution: String) throws {
            let id = try text(value, "id"), project = try text(value, "project_id")
            let path = try text(value, "snapshot_path")
            let decision = try relocation.decision(path, family: "source-captures", root: root)
            let pathParts = try StorageObjectFiles.parts(path, absolute: path.hasPrefix("/"))
            guard let familyIndex = pathParts.lastIndex(of: "source-captures") else { throw StorageSnapshotFailure.unsupportedAuthority }
            let family = decision.relative ?? pathParts[familyIndex...].joined(separator: "/")
            if decision.relative == nil { unavailable.append(.init(authority: attribution, reason: "outside_store_root")) }
            let legacy = "source-captures/" + project + "/" + id + "/source"
            let current = "source-captures/project-" + hash(Data(project.utf8)) + "/" + id + "/source"
            guard family.utf8.elementsEqual(legacy.utf8) || family.utf8.elementsEqual(current.utf8),
                  let files = value["files"] as? [[String: Any]] else { throw StorageSnapshotFailure.unsupportedAuthority }
            var entries: [String: [String: Any]] = [:]
            for file in files {
                let name = try text(file, "path"); _ = try StorageObjectFiles.parts(name)
                guard entries[name] == nil else { throw StorageSnapshotFailure.unsupportedAuthority }; entries[name] = file
            }
            var captured: [StorageSnapshotObject] = []
            for (name, file) in entries {
                let kind = try text(file, "kind"), authority = attribution + ":" + id + ":" + name
                if kind == "deleted" { unavailable.append(.init(authority: authority, reason: "captured_deleted")); continue }
                let sha = try digest(file["sha256"]), source = family + "/" + name
                if kind == "file" {
                    guard let size = (file["size"] as? NSNumber)?.int64Value, size >= 0 else { throw StorageSnapshotFailure.unsupportedAuthority }
                    captured.append(.init(relativePath: source, kind: "file", expectedSHA256: sha, expectedSize: size,
                        executable: file["executable"] as? Bool == true, linkTarget: nil, authorities: [authority]))
                } else if kind == "symlink" {
                    let target = try text(file, "target")
                    guard !target.hasPrefix("/"), !target.contains("\0"), StorageObjectFiles.sha(Data(target.utf8)) == sha else { throw StorageSnapshotFailure.unsupportedAuthority }
                    captured.append(.init(relativePath: source, kind: "symlink", expectedSHA256: sha, expectedSize: nil,
                        executable: false, linkTarget: target, authorities: [authority]))
                } else { throw StorageSnapshotFailure.unsupportedAuthority }
            }
            // Available links are checked once in the complete deduplicated
            // inventory below. Unavailable captures still require a valid graph.
            guard decision.relative != nil else { try validateCapturedLinks(captured); return }
            for object in captured {
                try add(object)
                if let size = object.expectedSize, size > budget.maximumObjectBytes { throw budget.capacityFailure("snapshot_object_bytes") }
            }
        }
        try MediaRecordRegistry.validate(MediaRecordRegistry.envelopes(db,limit:budget.maximumRecords,check:budget.check))
        let rows = try Row.fetchCursor(db, sql: "SELECT " + CommandRouter.canonicalRecordColumns + " FROM records ORDER BY id")
        while let row = try rows.next() {
            try budget.check(); recordCount += 1
            guard recordCount <= budget.maximumRecords else { throw StorageSnapshotFailure.limit }
            let envelope: DecodedEnvelope
            if let bytes: Data = row["_envelope_id_bytes"],let id = String(data:bytes,encoding:.utf8),let previous = cleanedEnvelopes[id],previous.original == (try GRDBRecordEnvelopeAdapter.input(row)) {
                envelope = previous
            } else { envelope = try GRDBRecordEnvelopeAdapter.decode(row) }
            let id = envelope.id, type = envelope.type, value = envelope.object
            guard knownTypes.contains(type) else { throw StorageSnapshotFailure.unsupportedAuthority }
            // Keep the relocation plan's original field validation in this
            // single decode pass, even when no new relocation can be established.
            for field in try ManagedPathRelocation.fields(value,type:type) {
                _ = try relocation.decision(field.stored,family:field.family,root:root)
            }
            let authority = type + ":" + id
            switch type {
            case "attachment":
                let mode = try text(value, "mode")
                if mode == "external_reference" { external.append(authority); continue }
                guard mode == "managed" else { throw StorageSnapshotFailure.unsupportedAuthority }
                _ = try text(value, "project_id")
                let availability = try text(value, "availability")
                if availability == "available" {
                    guard let size = (value["size"] as? NSNumber)?.int64Value else { throw StorageSnapshotFailure.unsupportedAuthority }
                    try regular(path: try text(value, "path"), family: "objects",
                        sha: try digest(value["sha256"]), size: size, authority: authority + ":original")
                } else if ["original_cleaned", "original_missing", "unavailable", "damaged"].contains(availability) {
                    unavailable.append(.init(authority: authority, reason: availability))
                } else { throw StorageSnapshotFailure.unsupportedAuthority }
                if value["preview_path"] != nil {
                    let preview = try text(value, "preview_path")
                    try regular(path: preview, family: "objects", sha: nil, size: nil, authority: authority + ":preview")
                }
            case "project":
                if let rawAsset = value["icon_asset"] {
                    guard let asset = rawAsset as? [String: Any] else { throw StorageSnapshotFailure.unsupportedAuthority }
                    _ = try text(asset, "id")
                    try regular(path: try text(value, "icon_path"), family: "icons",
                        sha: try digest(asset["sha256"]), size: nil, authority: authority + ":icon")
                } else if value["icon_path"] != nil { throw StorageSnapshotFailure.unsupportedAuthority }
            case "storage_job":
                let kind = try text(value, "kind")
                if kind == CommandRouter.ticketObjectDeletionKind {
                    guard let entries = value["objects"] as? [JSON],entries.count <= 100000 else {throw StorageSnapshotFailure.unsupportedAuthority}
                    for entry in entries where ["pending","retained"].contains(entry["state"] as? String ?? "") {
                        if entry["representation"] as? String == "source_build_cache" {
                            guard let path = entry["relative_path"] as? String else {throw StorageSnapshotFailure.unsupportedAuthority}
                            let parts = try StorageObjectFiles.parts(path)
                            guard parts.count >= 2,parts[0] == "source-build-cache",parts[1].range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else {throw StorageSnapshotFailure.unsupportedAuthority}
                            // Rebuildable cache is not required backup payload.
                            // Preserve its durable ownership/outcome metadata.
                            unavailable.append(.init(authority:authority + ":" + path,reason:"rebuildable_source_build_cache"));continue
                        }
                        guard let path = entry["relative_path"] as? String,let sha = entry["sha256"] as? String,let size = (entry["size"] as? NSNumber)?.int64Value else {continue}
                        guard path.hasPrefix("objects/") || path.hasPrefix("source-captures/"),size >= 0 else {throw StorageSnapshotFailure.unsupportedAuthority}
                        if try retainedExists(path) {
                            try add(.init(relativePath:path,kind:try text(entry,"kind"),expectedSHA256:try digest(sha),expectedSize:entry["kind"] as? String == "symlink" ? nil : size,executable:entry["executable"] as? Bool == true,linkTarget:entry["link_target"] as? String,authorities:[authority + ":pending_deletion"]))
                        } else {unavailable.append(.init(authority:authority + ":" + path,reason:"deletion_object_absent"))}
                    }
                    break
                }
                if ["archive_cleanup_delete", "archive_cleanup_cursor", "media_attachment_owner"].contains(kind) { break }
                guard kind == "attachment_import", let state = value["state"] as? String,
                      ["reserved", "staging", "finalized", "committed", "repair_required", "settled"].contains(state) else { throw StorageSnapshotFailure.unsupportedAuthority }
                if value["attachment_owner_id"] is String {
                    // Media staging is not committed ownership. Preserve job/plan metadata,
                    // and retain already published finals only as uncommitted recovery bytes.
                    // Successful reconciliation settles committed imports without a
                    // reason. Canceled/abandoned settled jobs remain recovery-only.
                    // Repair-required jobs also belong to canonical attachments,
                    // whose availability is authoritative for backup.
                    let captured = ["committed","repair_required"].contains(state) || state == "settled" && value["settled_reason"] == nil
                    if !captured, let raw = value["objects"] {
                        guard let entries = raw as? [JSON] else { throw StorageSnapshotFailure.unsupportedAuthority }
                        for object in entries {
                            let final = try text(object,"final")
                            guard final.hasPrefix("objects/") else { throw StorageSnapshotFailure.unsupportedAuthority }
                            _ = try StorageObjectFiles.parts(final)
                            if try retainedExists(final) {
                                guard let size = object["size"] as? NSNumber else { throw StorageSnapshotFailure.unsupportedAuthority }
                                try regular(path:root.appendingPathComponent(final).path,family:"objects",sha:try digest(object["sha256"]),size:size.int64Value,authority:authority + ":uncommitted_recovery:" + (object["representation"] as? String ?? ""))
                            }
                        }
                        unavailable.append(.init(authority:authority,reason:"uncommitted_media_capture_staging_excluded"))
                    }
                    break
                }
                // Receipt-less finalization is retained authority. Missing pending
                // stages are absence, never permission to sweep unrelated files.
                if ["reserved", "staging", "finalized"].contains(state) {
                    if let raw = value["objects"] {
                        guard let entries = raw as? [JSON] else { throw StorageSnapshotFailure.unsupportedAuthority }
                        for object in entries {
                            let sha = try digest(object["sha256"])
                            guard let size = object["size"] as? NSNumber else { throw StorageSnapshotFailure.unsupportedAuthority }
                            for field in ["stage", "final"] {
                                let path = try text(object,field)
                                guard path.hasPrefix(field == "stage" ? "staging/attachment-imports/" : "objects/") else { throw StorageSnapshotFailure.unsupportedAuthority }
                                _ = try StorageObjectFiles.parts(path)
                                if try retainedExists(path) {
                                    try regular(path: root.appendingPathComponent(path).path, family: field == "stage" ? "staging" : "objects", sha: sha, size: size.int64Value, authority: authority + ":" + field + ":" + (object["representation"] as? String ?? ""))
                                } else {
                                    guard !(state == "finalized" && field == "final" && object["representation"] as? String == "original") else { throw StorageSnapshotFailure.incomplete }
                                    unavailable.append(.init(authority:authority + ":" + field + ":" + (object["representation"] as? String ?? ""), reason:"pending_not_materialized"))
                                }
                            }
                        }
                    } else if state == "finalized" { throw StorageSnapshotFailure.unsupportedAuthority }
                }
            case "source_capture": try capture(value, attribution: authority)
            case "manifest":
                if let rawEvidence = value["evidence"] {
                    guard let evidence = rawEvidence as? [String: Any] else { throw StorageSnapshotFailure.unsupportedAuthority }
                    if let rawSource = evidence["source_capture"] {
                        guard let source = rawSource as? [String: Any] else { throw StorageSnapshotFailure.unsupportedAuthority }
                        try capture(source, attribution: authority)
                    }
                }
            case "source_execution":
                let state = try text(value, "state")
                guard ["passed", "failed", "stale", "completed", "canceled", "stopped"].contains(state),
                      value["process_stop_unverified"] as? Bool != true else { throw StorageSnapshotFailure.unsupportedAuthority }
                if value["output_path"] != nil {
                    let output = try text(value, "output_path")
                    _ = try text(value, "project_id")
                    try regular(path: output, family: "source-executions",
                        sha: try digest(value["output_sha256"]), size: nil, authority: authority + ":output")
                } else { unavailable.append(.init(authority: authority, reason: "output_not_recorded")) }
            default: break
            }
        }
        // Schema5 summaryless legacy receipts keep their exact historical list
        // as a managed immutable catalog. It is history, never backup-copy authority.
        let catalogs = try Row.fetchCursor(db,sql:"SELECT key,value AS catalog FROM metadata WHERE key GLOB 'backup-historical-catalog:*'")
        while let row = try catalogs.next() {
            let catalog = jsonObject(row["catalog"] as String)
            guard let path = catalog["path"] as? String,path.hasPrefix("objects/backup-catalogs/"),let sha = catalog["sha256"] as? String,
                  let size = catalog["size"] as? NSNumber,size.int64Value >= 0 else {throw StorageSnapshotFailure.unsupportedAuthority}
            try regular(path:path,family:"objects",sha:try digest(sha),size:size.int64Value,authority:"metadata:" + (row["key"] as String) + ":historical_catalog")
        }
        let ordered = objects.values.sorted { $0.relativePath < $1.relativePath }
        try validateCapturedLinks(ordered)
        return .init(objects: ordered,
            unavailable: unavailable.sorted { $0.authority < $1.authority }, externalReferences: external.sorted())
    }
}
