import Foundation

struct StorageSettingsSummary {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String {label}
    }
    /// A row whose ID is its own key, not its display label, so two keys
    /// with the same label stay distinct.
    struct KeyedRow: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }
    /// The restore preview's unavailable content: exact totals per reason and
    /// the first `unavailableShown` entries. A backup can hold up to 500,000
    /// managed paths, so the sheet never lists every entry.
    struct UnavailableSummary: Equatable {
        let total: Int
        let reasons: [KeyedRow]
        let shown: [KeyedRow]
    }
    static let unavailableShown = 50
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
    /// Record families with at least one record, in family-key order.
    static func recordFamilies(_ info: [String:Any]) -> [KeyedRow] {
        let families = info["record_families"] as? [String:Int] ?? [:]
        return families.keys.sorted().compactMap {family in
            guard let count = families[family],count > 0 else {return nil}
            return KeyedRow(id:family,label:GlossaryText.humanize(family).capitalized,value:String(count))
        }
    }
    static func unavailable(_ info: [String:Any],limit: Int = unavailableShown) -> UnavailableSummary {
        let entries = info["unavailable"] as? [[String:Any]] ?? []
        var counts: [String:Int] = [:]
        for entry in entries {counts[entry["reason"] as? String ?? "Unavailable",default:0] += 1}
        let reasons = counts.keys.sorted().map {KeyedRow(id:$0,label:GlossaryText.humanize($0).capitalized,value:String(counts[$0] ?? 0))}
        let shown = entries.prefix(max(0,limit)).enumerated().map {offset,entry in
            let authority = entry["authority"] as? String ?? "Unknown original"
            return KeyedRow(id:"\(offset):\(authority)",label:authority,value:GlossaryText.humanize(entry["reason"] as? String ?? "Unavailable"))
        }
        return UnavailableSummary(total:entries.count,reasons:reasons,shown:shown)
    }
}
