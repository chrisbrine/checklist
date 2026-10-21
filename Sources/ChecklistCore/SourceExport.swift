import Foundation

extension CommandRouter {
    func portableSourceCapture(_ capture: JSON) -> JSON {
        var portable = capture
        portable["snapshot_path"] = "source-captures/" + (capture["id"] as! String) + "/source"
        portable.removeValue(forKey: "source_root"); portable.removeValue(forKey: "token_hash"); portable.removeValue(forKey: "incarnation")
        return portable
    }

    func exportSourceCapture(_ capture: JSON, directory: URL) throws -> JSON {
        try validateCapturedFiles(capture)
        let id = capture["id"] as! String
        let relative = "source-captures/" + id + "/source", destination = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in capture["files"] as? [JSON] ?? [] {
            let path = try text(file, "path", max: 4000)
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw CoreError("SOURCE_CHANGED", "An exported source entry is outside its capture.") }
            if file["kind"] as? String == "deleted" { continue }
            let target = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file["kind"] as? String == "symlink" {
                let link = try text(file, "target", max: 4000)
                guard !link.hasPrefix("/"), containsPath(destination.path, target.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path), hash(Data(link.utf8)) == file["sha256"] as? String else { throw CoreError("SOURCE_CHANGED", "An exported source symlink is outside its capture or has changed.") }
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else {
                let relativeSource = try managedRelative(capture["snapshot_path"] as! String,family:"source-captures") + "/" + path
                let bytes = try StorageObjectFiles(root:root).read(relativeSource,maximum:512 * 1024 * 1024)
                guard hash(bytes) == file["sha256"] as? String else { throw CoreError("SOURCE_CHANGED", "Captured source failed export checksum validation.") }
                try bytes.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: bool(file, "executable") ? 0o555 : 0o444], ofItemAtPath: target.path)
            }
        }
        let portable = portableSourceCapture(capture)
        try Data((try jsonString(portable)).utf8).write(to: destination.deletingLastPathComponent().appendingPathComponent("manifest.json"), options: .atomic)
        return portable
    }

    func exportSourceManifest(_ manifest: JSON) throws -> JSON {
        guard var evidence = manifest["evidence"] as? JSON, let capture = evidence["source_capture"] as? JSON else { return manifest }
        var portable = manifest
        evidence["source_capture"] = portableSourceCapture(capture)
        portable["evidence"] = evidence
        // The original digest remains provenance for the reviewed submission. Path normalization is export data, not a fresh gate verdict.
        portable["export_path_rewrites"] = true
        portable["export_evidence_sha256"] = hash(Data((try jsonString(evidence)).utf8))
        return portable
    }

    func exportSourceExecution(_ execution: JSON, directory: URL) throws -> JSON {
        guard let path = execution["output_path"] as? String else {
            var portable = execution
            portable.removeValue(forKey: "working_directory")
            portable["output_availability"] = "not_recorded"
            return portable
        }
        let bytes = try managedRead(path,family:"source-executions",maximum:500 * 1024 * 1024)
        guard hash(bytes) == execution["output_sha256"] as? String else { throw CoreError("SOURCE_CHANGED", "The source execution log failed export checksum validation.") }
        let relative = "source-executions/" + (execution["id"] as! String) + "/output.log", target = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        var portable = execution
        portable["output_path"] = relative
        portable["working_directory"] = "source-captures/" + (execution["source_capture_id"] as! String) + "/source"
        portable.removeValue(forKey: "token_hash"); portable.removeValue(forKey: "incarnation")
        return portable
    }
}
