import Foundation
import GRDB

extension CommandRouter {
    /// A definite failed command must not leave a manifest-bearing directory
    /// advertised as a completed backup. Unknown SQL/publication outcomes keep
    /// their original location for reconciliation; no earlier copy is removed.
    func quarantineFailedBackupPublication(params: JSON,caller: Caller,error: Error) {
        if let failure = error as? CoreError {
            guard ["BACKUP_DEADLINE_EXCEEDED","BACKUP_CAPACITY_EXCEEDED"].contains(failure.code) else {return}
        } else if let failure = error as? StorageSnapshotFailure {
            switch failure {case .deadline,.canceled,.io,.systemCall,.incomplete,.sourceChanged:break;default:return}
        } else {return}
        guard let command = params["command_id"] as? String else {return}
        do {
            try ArchiveStorageGate.withExclusive(root:root) {_ in
                let pending = try self.pendingStorageCommandKey(principal:caller.principal,command:command)
                let operation: String? = try self.dbQueue.read {db in
                    guard let raw = try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:[pending]),let operation = jsonObject(raw)["operation_id"] as? String,
                          try String.fetchOne(db,sql:"SELECT value FROM metadata WHERE key=?",arguments:["backup-generation:" + operation]) == nil else {return nil}
                    return operation
                }
                guard let operation else {return}
                let destination: URL
                if caller.isOwner,let path = params["path"] as? String {destination = URL(fileURLWithPath:path).standardizedFileURL}
                else {
                    let label = params["qualification_name"] as? String ?? ""
                    destination = self.root.appendingPathComponent("backups/" + (label.isEmpty ? "" : "qualification-" + label + "/") + "snapshot-" + command.lowercased())
                }
                let parent = try StorageObjectFiles(root:destination.deletingLastPathComponent())
                var destinationInfo = stat()
                guard fstatat(parent.descriptor,destination.lastPathComponent,&destinationInfo,AT_SYMLINK_NOFOLLOW) == 0,
                      destinationInfo.st_mode & S_IFMT == S_IFDIR else {return}
                let use = try StorageBackupUseLease(root:destination,exclusive:true)
                let bytes = try use.files.read("manifest.json",maximum:StorageSnapshotBudget.manifestByteLimit)
                let manifest = try JSONDecoder().decode(StorageSnapshotManifest.self,from:bytes)
                guard manifest.operationID == operation,manifest.sourceRoot.utf8.elementsEqual(self.root.path.utf8) else {return}
                try use.requireCurrent()
                let marker: JSON = ["state":"failed","operation_id":operation,"manifest_sha256":hash(bytes),"error_code":(error as? CoreError)?.code ?? String(describing:error),"recorded_at":now()]
                if try !use.files.regularOrLinkExists(".backup-failed.json") {try use.files.writeNew(".backup-failed.json",bytes:Data((try jsonString(marker)).utf8))}
                try parent.publish(destination.lastPathComponent,as:".snapshot-failed-" + operation + "-" + uuid())
            }
        } catch {
            // The original error remains truthful. A failed best-effort marker
            // never permits deletion, a fabricated completion, or a competing UUID.
            fputs("Failed backup publication could not be quarantined; retained for reconciliation.\n",stderr)
        }
    }
}
