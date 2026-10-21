import Foundation
import CoreFoundation

enum ArchiveRetentionError: Error { case invalid(String), arithmeticOverflow }

/// A private value shape for the future canonical project setting; no policy/Store hook.
struct ArchiveRetentionConfiguration: Equatable {
    enum Preset: String, Equatable { case cleanLargeManagedOnArchive = "clean_large_managed_on_archive", keepOriginals = "keep_originals" }
    let preset: Preset
    let largeOriginalBytes: Int64
    let retainedBudgetBytes: Int64
    static let defaults = try! Self(preset:.cleanLargeManagedOnArchive,largeOriginalBytes:20 * 1024 * 1024,retainedBudgetBytes:50 * 1024 * 1024)
    init(preset: Preset,largeOriginalBytes: Int64,retainedBudgetBytes: Int64) throws {
        guard largeOriginalBytes > 0,retainedBudgetBytes >= 0 else {throw ArchiveRetentionError.invalid("Use a positive original threshold and nonnegative retained budget.")}
        self.preset = preset;self.largeOriginalBytes = largeOriginalBytes;self.retainedBudgetBytes = retainedBudgetBytes
    }
    /// Omission resets to documented defaults. Present values are complete, never partial patches.
    static func parse(_ raw: Any?) throws -> Self {
        guard let raw else {return .defaults}
        guard let value = raw as? [String:Any],Set(value.keys) == ["preset","large_original_bytes","retained_budget_bytes"],
              let name = value["preset"] as? String,let preset = Preset(rawValue:name) else {
            throw ArchiveRetentionError.invalid("Provide one complete retention configuration.")
        }
        func integer(_ raw: Any?) throws -> Int64 {
            guard let n = raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let v = Int64(n.stringValue) else {
                throw ArchiveRetentionError.invalid("Retention bytes must be exact whole numbers in Int64 range.")
            }
            return v
        }
        return try Self(preset:preset,largeOriginalBytes:integer(value["large_original_bytes"]),retainedBudgetBytes:integer(value["retained_budget_bytes"]))
    }
    var jsonValue: [String:Any] {["preset":preset.rawValue,"large_original_bytes":largeOriginalBytes,"retained_budget_bytes":retainedBudgetBytes]}
}

/// Stable opaque identities use exact UTF-8; Unicode canonical equivalence is not aliasing.
struct ArchiveAttachmentID: Hashable, Comparable {
    let text: String
    private let bytes: Data
    init(_ text: String) throws {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count <= 256 else {
            throw ArchiveRetentionError.invalid("Use a bounded nonblank attachment identity.")
        }
        self.text = text;self.bytes = Data(text.utf8)
    }
    static func == (lhs: Self,rhs: Self) -> Bool {lhs.bytes == rhs.bytes}
    static func < (lhs: Self,rhs: Self) -> Bool {lhs.bytes.lexicographicallyPrecedes(rhs.bytes)}
    func hash(into hasher: inout Hasher) {hasher.combine(bytes)}
}

enum ArchiveProtectionReason: String, CaseIterable, Hashable {
    case keepOriginal, activeWork, activeVerification, pendingHumanInspection, currentReview
    case activeReader, backupCapture, sharedLiveReference, activeBuild, otherAuthoritativeHold
}

/// Inputs are facts from a future authoritative service adapter. Constructing this value
/// does not authenticate a hold, resolve references, grant deletion, or inspect any path.
struct ArchiveAttachmentFact {
    enum Mode: Equatable { case managed, externalReference }
    enum Availability: Equatable { case available, originalCleaned, missing }
    let id: ArchiveAttachmentID
    let logicalOriginalBytes: Int64
    let mode: Mode
    let availability: Availability
    let protectionReasons: Set<ArchiveProtectionReason>
    init(id: String,logicalOriginalBytes: Int64,mode: Mode = .managed,availability: Availability = .available,
         protectionReasons: Set<ArchiveProtectionReason> = []) throws {
        guard logicalOriginalBytes >= 0 else {throw ArchiveRetentionError.invalid("An original cannot have a negative logical byte count.")}
        self.id = try ArchiveAttachmentID(id);self.logicalOriginalBytes = logicalOriginalBytes
        self.mode = mode;self.availability = availability;self.protectionReasons = protectionReasons
    }
}

struct ArchiveRetentionPlan {
    enum SelectionReason: Equatable { case largeOriginal, aggregateOverflow }
    struct Selection {let id: ArchiveAttachmentID;let logicalBytes: Int64;let reason: SelectionReason}
    struct Protection {let id: ArchiveAttachmentID;let logicalBytes: Int64;let reasons: [ArchiveProtectionReason]}
    let selected: [Selection]
    let protected: [Protection]
    let externalReferenceIDs: [ArchiveAttachmentID]
    let unavailableOriginalIDs: [ArchiveAttachmentID]
    let logicalOriginalBytes: Int64
    let selectedLogicalBytes: Int64
    let retainedLogicalBytes: Int64
    let protectedLogicalBytes: Int64
    let unprotectedRetainedLogicalBytes: Int64
    let retainedBudgetExcessBytes: Int64
    let keptByProjectPreset: Bool
    /// A plan never reports actual unlink, physical allocation, preview or backup storage.
    let accounting = "logical_available_managed_originals_only"
}

enum ArchiveRetentionPlanner {
    static func make(configuration: ArchiveRetentionConfiguration,facts: [ArchiveAttachmentFact]) throws -> ArchiveRetentionPlan {
        var identities = Set<ArchiveAttachmentID>()
        for fact in facts {
            guard identities.insert(fact.id).inserted else {throw ArchiveRetentionError.invalid("Duplicate attachment identity makes the retention input ambiguous.")}
        }
        func sum(_ values: [Int64]) throws -> Int64 {
            try values.reduce(Int64(0)) { partial,next in
                let (value,overflow) = partial.addingReportingOverflow(next)
                guard !overflow else {throw ArchiveRetentionError.arithmeticOverflow};return value
            }
        }
        let available = facts.filter {$0.mode == .managed && $0.availability == .available}
        let protected = available.filter {!$0.protectionReasons.isEmpty}.sorted {$0.id < $1.id}
        let candidates = available.filter {$0.protectionReasons.isEmpty}.sorted {
            $0.logicalOriginalBytes == $1.logicalOriginalBytes ? $0.id < $1.id : $0.logicalOriginalBytes > $1.logicalOriginalBytes
        }
        let total = try sum(available.map(\.logicalOriginalBytes)),protectedBytes = try sum(protected.map(\.logicalOriginalBytes))
        var retained = total,selections: [ArchiveRetentionPlan.Selection] = []
        if configuration.preset == .cleanLargeManagedOnArchive {
            for fact in candidates {
                if fact.logicalOriginalBytes >= configuration.largeOriginalBytes {
                    selections.append(.init(id:fact.id,logicalBytes:fact.logicalOriginalBytes,reason:.largeOriginal));retained -= fact.logicalOriginalBytes
                } else if retained > configuration.retainedBudgetBytes,fact.logicalOriginalBytes > 0 {
                    selections.append(.init(id:fact.id,logicalBytes:fact.logicalOriginalBytes,reason:.aggregateOverflow));retained -= fact.logicalOriginalBytes
                }
            }
        }
        return ArchiveRetentionPlan(selected:selections,protected:protected.map {
            .init(id:$0.id,logicalBytes:$0.logicalOriginalBytes,reasons:ArchiveProtectionReason.allCases.filter($0.protectionReasons.contains))
        },externalReferenceIDs:facts.filter {$0.mode == .externalReference}.map(\.id).sorted(),
        unavailableOriginalIDs:facts.filter {$0.mode == .managed && $0.availability != .available}.map(\.id).sorted(),
        logicalOriginalBytes:total,selectedLogicalBytes:total-retained,retainedLogicalBytes:retained,
        protectedLogicalBytes:protectedBytes,unprotectedRetainedLogicalBytes:retained-protectedBytes,
        retainedBudgetExcessBytes:max(0,retained-configuration.retainedBudgetBytes),keptByProjectPreset:configuration.preset == .keepOriginals)
    }
}
