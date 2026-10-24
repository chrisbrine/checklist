import Foundation

struct StorageSettingsSummary {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String {label}
    }
    static func bytes(_ value: Any?) -> String {
        guard let number = value as? NSNumber else {return "Not measured"}
        return ByteCountFormatter.string(fromByteCount:number.int64Value,countStyle:.file)
    }
    static func timestamp(_ value: Any?) -> String {
        guard let text = value as? String,!text.isEmpty else {return "Not recorded"}
        return text
    }
    static func observation(_ raw: Any?) -> [Row] {
        guard let info = raw as? [String:Any] else {return [Row(label:"Verification",value:"None recorded")]}
        let usage = info["usage"] as? [String:Any] ?? [:]
        let checks = ["manifest_database_managed_files":"Database and managed files", "copy_integrity_and_authority_fencing":"Restore copy and authority checks", "migration_rehearsal_committed":"Pre-upgrade database migration", "legacy_complete_receipt":"Historical complete-backup receipt"]
        return [Row(label:"Check",value:checks[info["verification"] as? String ?? ""] ?? "Verified receipt"),
                Row(label:"Verified",value:timestamp(info["verified_at"])),
                Row(label:"Captured",value:timestamp(info["captured_at"])),
                Row(label:"Source",value:info["source_root"] as? String ?? "Not recorded"),
                Row(label:"Copy",value:info["path"] as? String ?? "Not recorded"),
                Row(label:"Logical file lengths",value:bytes(usage["logical_bytes"])),
                Row(label:"Allocated file blocks",value:bytes(usage["allocated_file_bytes"]))]
    }
    static func retained(_ raw: Any?) -> [Row] {
        let info = raw as? [String:Any] ?? [:]
        return [Row(label:"Measured copies",value:(info["observed_copy_count"] as? NSNumber)?.stringValue ?? "0"),
                Row(label:"Older backups without measurements",value:(info["unmeasured_backup_count"] as? NSNumber)?.stringValue ?? "0"),
                Row(label:"Recorded logical file lengths",value:bytes(info["logical_bytes_at_verification"])),
                Row(label:"Recorded allocated file blocks",value:bytes(info["allocated_file_bytes_at_verification"])),
                Row(label:"Exclusive physical storage",value:"Not measured"),
                Row(label:"Space reclaimable by deletion",value:"Not measured")]
    }
    static func preview(_ info: [String:Any]) -> [Row] {
        [Row(label:"Backup folder",value:info["path"] as? String ?? "Not recorded"),
         Row(label:"Source installation",value:info["source_root"] as? String ?? "Not recorded"),
         Row(label:"Source store",value:info["store_id"] as? String ?? "Not recorded"),
         Row(label:"Captured",value:timestamp(info["captured_at"])),
         Row(label:"Verified now",value:timestamp(info["verified_at"]))]
    }
}
