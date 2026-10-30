import Foundation
import SwiftUI

@MainActor final class BackupRetentionObservation: ObservableObject {
    @Published var newestCount = 5
    @Published var dailyDays = 7
    @Published var includeUnrecorded = false
    @Published private(set) var ownerConfirmed = false
    @Published private(set) var automaticPrune = false
    @Published private(set) var lastAutomaticPrune: [String:Any] = [:]
    @Published private(set) var automaticHistory: [BackupRetentionHistoryEntry] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var preview: [String:Any] = [:]
    @Published var message = ""
    private(set) var scope = ""
    private var readID = UUID()
    private var savedNewest = 5
    private var savedDays = 7
    var dirty: Bool {newestCount != savedNewest || dailyDays != savedDays}
    var canPrune: Bool {loaded && ownerConfirmed && !dirty && !previewDigest.isEmpty && pruneCount > 0}
    var previewDigest: String {preview["preview_sha256"] as? String ?? ""}
    var pruneCount: Int {preview["prune_count"] as? Int ?? 0}
    var snapshots: [BackupRetentionSnapshot] {(preview["snapshots"] as? [[String:Any]] ?? []).map(BackupRetentionSnapshot.init)}
    func changeScope(_ value: String) {
        guard scope != value else {return}
        scope = value;cancelReads();loaded = false;ownerConfirmed = false;automaticPrune = false;lastAutomaticPrune = [:];automaticHistory = [];preview = [:];message = ""
        newestCount = 5;dailyDays = 7;savedNewest = 5;savedDays = 7;includeUnrecorded = false
    }
    func cancelReads() {readID = UUID();loading = false}
    func invalidatePreview() {readID = UUID();preview = [:];loading = false}
    func acceptSettings(_ value: [String:Any]) {
        newestCount = (value["newest_count"] as? NSNumber)?.intValue ?? 5
        dailyDays = (value["daily_days"] as? NSNumber)?.intValue ?? 7
        savedNewest = newestCount;savedDays = dailyDays
        ownerConfirmed = value["owner_confirmed"] as? Bool ?? false
        automaticPrune = value["automatic_prune"] as? Bool ?? false
        lastAutomaticPrune = value["last_automatic_prune"] as? [String:Any] ?? [:]
        automaticHistory = (value["automatic_prune_history"] as? [[String:Any]] ?? []).map(BackupRetentionHistoryEntry.init)
        loaded = true;preview = [:]
    }
    var automaticStatusText: String {
        switch lastAutomaticPrune["status"] as? String {
        case "complete":return "Last automatic retention moved \(lastAutomaticPrune["moved_count"] as? Int ?? 0) backup folders to Trash."
        case "deferred":return "Automatic retention could not finish. Existing backups stay protected; the next completed backup will retry."
        default:return ""
        }
    }
    func loadSettings(_ fetch: () async throws -> [String:Any]) async {
        let id = UUID();readID = id;loading = true;message = ""
        do {
            let value = try await fetch()
            guard readID == id,!Task.isCancelled else {return}
            acceptSettings(value);loading = false
        } catch {
            guard readID == id else {return}
            loading = false;if !(error is CancellationError) {message = PlainError.text(error)}
        }
    }
    func loadPreview(_ fetch: () async throws -> [String:Any]) async {
        let id = UUID();readID = id;loading = true;preview = [:];message = ""
        do {
            let value = try await fetch()
            guard readID == id,!Task.isCancelled else {return}
            preview = value;loading = false
        } catch {
            guard readID == id else {return}
            loading = false;if !(error is CancellationError) {message = PlainError.text(error)}
        }
    }
}

struct BackupRetentionSnapshot: Identifiable {
    let values: [String:Any]
    var id: String {path}
    var path: String {values["path"] as? String ?? ""}
    var name: String {URL(fileURLWithPath:path).lastPathComponent}
    var complete: Bool {values["state"] as? String == "complete"}
    var selected: Bool {values["prune"] as? Bool ?? false}
    var reasons: [String] {values["keep_reasons"] as? [String] ?? []}
    var pinned: Bool {reasons.contains("owner_pinned")}
    var protectedUpgrade: Bool {reasons.contains("protected_upgrade")}
    var historicalUpgrade: Bool {values["historical_upgrade_protection"] as? Bool ?? false}
    var reasonText: String {
        if selected {return "Move to Trash"}
        return reasons.map {reason in
            switch reason {
            case "newest":return "Newest backups"
            case "daily":return "Daily backup"
            case "owner_pinned":return "Kept by you"
            case "protected_upgrade":return "Protected for upgrade"
            case "unknown_capture_time":return "Capture time unknown"
            case "future_capture_time":return "Capture time is in the future"
            case "unrecorded_or_incomplete":return "Unrecorded or incomplete"
            case "missing_or_changed":return "Missing or changed folder"
            case "manifest_changed":return "Backup manifest changed"
            case "manifest_unavailable_or_in_use":return "Manifest unavailable or snapshot in use"
            case "outside_managed_backups":return "Outside managed backup folders"
            default:return "Retained: " + reason.replacingOccurrences(of:"_",with:" ")
            }
        }.joined(separator:" · ")
    }
}

struct BackupRetentionHistoryEntry: Identifiable {
    let values: [String:Any]
    var id: String {values["id"] as? String ?? ""}
    var occurredAt: String {values["occurred_at"] as? String ?? ""}
    var summary: String {
        if values["status"] as? String == "complete" {return "Moved \(values["moved_count"] as? Int ?? 0) backup folders to Trash"}
        return "Retention deferred; backups retained"
    }
}
