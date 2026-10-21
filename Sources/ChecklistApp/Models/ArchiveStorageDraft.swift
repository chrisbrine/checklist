import Foundation

struct ArchiveStorageDraft: Equatable {
    static func holdLabel(_ value: String) -> String {
        ["keepOriginal":"Keep original","activeWork":"active work","activeVerification":"active verification","pendingHumanInspection":"pending human inspection","currentReview":"current review","activeReader":"active reader","backupCapture":"backup capture","sharedLiveReference":"shared live reference","activeBuild":"active build","referenceGraphUnavailable":"reference graph unavailable","originalUnavailable":"original unavailable","externalOriginal":"external original","changedIdentity":"changed identity","policyNoLongerSelects":"current policy keeps it","pendingImport":"pending durable import","otherAuthoritativeHold":"other current hold"][value] ?? value
    }
    var preset = "clean_large_managed_on_archive"
    var threshold = "20"
    var budget = "50"
    var unit: Int64 = 1_048_576
    init(_ value: [String:Any] = [:]) {
        preset = value["preset"] as? String ?? preset
        let a = (value["large_original_bytes"] as? NSNumber)?.int64Value ?? 20 * 1_048_576
        let b = (value["retained_budget_bytes"] as? NSNumber)?.int64Value ?? 50 * 1_048_576
        unit = a % 1_048_576 == 0 && b % 1_048_576 == 0 ? 1_048_576 : 1
        threshold = String(a / unit);budget = String(b / unit)
    }
    var value: [String:Any]? {
        guard ["clean_large_managed_on_archive","keep_originals"].contains(preset),[1,1_048_576].contains(unit),
              !threshold.isEmpty,!budget.isEmpty,threshold.utf8.allSatisfy({48...57 ~= $0}),budget.utf8.allSatisfy({48...57 ~= $0}),
              let a = Int64(threshold),let b = Int64(budget),a > 0,b >= 0 else { return nil }
        let x = a.multipliedReportingOverflow(by:unit),y = b.multipliedReportingOverflow(by:unit)
        guard !x.overflow,!y.overflow else { return nil }
        return ["preset":preset,"large_original_bytes":x.partialValue,"retained_budget_bytes":y.partialValue]
    }
}
