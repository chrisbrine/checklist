import Foundation

extension CommandRouter {
    func managedURL(_ stored: String, family: String) throws -> URL {
        let effective = family == "source-captures" ? managedCapturePaths[Data(stored.utf8)] ?? stored : stored
        let resolved: URL?
        do { resolved = try ManagedPaths.resolve(effective, family: family, root: root) }
        catch { throw CoreError("MANAGED_FILE_UNAVAILABLE", "The managed file is unavailable in this store.", details: ["reason":"managed_path_invalid_or_missing"]) }
        guard let url = resolved else {
            throw CoreError("MANAGED_FILE_UNAVAILABLE", "The managed file is unavailable in this store.", details: ["reason":"outside_store_root"])
        }
        return url
    }

    func managedRelative(_ stored: String, family: String) throws -> String {
        let effective = family == "source-captures" ? managedCapturePaths[Data(stored.utf8)] ?? stored : stored
        let resolved: String?
        do { resolved = try ManagedPaths.relative(effective, family: family, root: root) }
        catch { throw CoreError("MANAGED_FILE_UNAVAILABLE", "The managed file is unavailable in this store.", details: ["reason":"managed_path_invalid"]) }
        guard let relative = resolved else {
            throw CoreError("MANAGED_FILE_UNAVAILABLE", "The managed file is unavailable in this store.", details: ["reason":"outside_store_root"])
        }
        return relative
    }

    func managedRead(_ stored: String, family: String, maximum: Int) throws -> Data {
        try StorageObjectFiles(root:root).read(managedRelative(stored,family:family),maximum:maximum)
    }

    func managedIdentity(_ stored: String, family: String = "objects") throws -> FileIdentity? {
        try StorageObjectFiles(root:root).openRegular(managedRelative(stored,family:family)) { FileIdentity(descriptor:$0) }
    }

    /// Only the owner receives local file URLs. Durable records and replay history keep
    /// their relative descriptors. This projection runs after command receipt commit.
    func ownerManagedPathProjection(_ source: JSON, caller: Caller) -> JSON {
        guard caller.isOwner else { return source }
        func project(_ value: Any) -> Any {
            if let values = value as? [Any] { return values.map(project) }
            guard let row = value as? JSON else { return value }
            return projectRow(row)
        }
        func projectRow(_ source: JSON) -> JSON {
            var row = source
            // Event history is provenance, never an authority to open a managed file.
            if row["occurred_at"] != nil && row["actor"] != nil { return row }
            let immutableEvidence = row["digest"] != nil && row["evidence"] is JSON
            for (key, child) in row where !["events", "commands", "files"].contains(key) && !(immutableEvidence && key == "evidence") { row[key] = project(child) }
            if immutableEvidence,let evidence = row["evidence"] as? JSON,let capture = evidence["source_capture"] as? JSON {
                row["resolved_source_capture"] = project(capture)
            }
            var fields: [(String,String)] = []
            if row["mode"] as? String == "managed", row["sha256"] != nil { fields += [("path","objects"),("preview_path","objects"),("url","objects")] }
            if row["icon_asset"] != nil { fields.append(("icon_path","icons")) }
            if row["files"] != nil && row["snapshot_path"] != nil { fields.append(("snapshot_path","source-captures")) }
            if row["source_capture_id"] != nil { fields += [("output_path","source-executions"),("working_directory","source-captures")] }
            for (field, family) in fields {
                guard let stored = row[field] as? String else { continue }
                do {
                    row[field] = try managedURL(stored,family:family).path
                } catch {
                    row.removeValue(forKey: field)
                    row[field + "_unavailable_reason"] = (error as? CoreError)?.details["reason"] as? String ?? "managed_file_unavailable"
                }
            }
            return row
        }
        return projectRow(source)
    }
}
