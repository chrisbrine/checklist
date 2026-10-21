import SwiftUI
import CoreFoundation

struct DisplayEvidenceMeasure: Identifiable {
    let name: String
    let unit: String
    let limit: Double
    let before: Double
    let after: Double
    var id: String { name }
    var overLimit: Bool { after > limit }
    init?(_ row: Record) {
        func number(_ key: String) -> Double? {
            guard let n = row.values[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else { return nil }
            if !["d","f"].contains(String(cString:n.objCType)),String(format:"%.0f",locale:Locale(identifier:"en_US_POSIX"),n.doubleValue) != n.stringValue { return nil }
            return n.doubleValue
        }
        guard !row.string("name").isEmpty,!row.string("unit").isEmpty,let limit = number("limit"),let before = number("before"),let after = number("after") else { return nil }
        name = row.string("name");unit = row.string("unit");self.limit = limit;self.before = before;self.after = after
    }
}

struct EvidenceMeasureSnapshot: Identifiable {
    let id: String
    let manifestID: String
    let attemptID: String?
    let title: String
    let author: String
    let sha256: String
    let measures: [DisplayEvidenceMeasure]
    var isSubmission: Bool { attemptID == nil }
}

struct EvidenceMeasuresProjection {
    let review: ReviewProjection
    init(review: ReviewProjection,history: [String:Any] = [:]) {
        guard !history.isEmpty else { self.review = review;return }
        func merge(_ name: String,_ current: [Record]) -> [[String:Any]] {
            let prior = (history[name] as? [[String:Any]] ?? []).map(Record.init)
            let known = Set(prior.map(\.id))
            return (prior + current.filter { !known.contains($0.id) }).map(\.values)
        }
        self.review = ReviewProjection(task:review.task,project:review.project,data:["manifests":merge("manifests",review.manifests),"attempts":merge("attempts",review.attempts),"attachments":merge("attachments",review.attachments)])
    }
    var snapshots: [EvidenceMeasureSnapshot] {
        let submissions = review.manifests.map { manifest in
            EvidenceMeasureSnapshot(id:manifest.id,manifestID:manifest.id,attemptID:nil,title:"Submission",author:manifest.string("author_principal"),sha256:manifest.string("digest"),measures:Record(values:manifest.object("evidence")).records("measures").compactMap(DisplayEvidenceMeasure.init))
        }
        let reports = review.attachments.compactMap { file -> EvidenceMeasureSnapshot? in
            guard file.values["measures"] != nil,!file.string("target_manifest_id").isEmpty,!file.string("review_attempt_id").isEmpty,
                  let attempt = review.attempts.first(where: { $0.id == file.string("review_attempt_id") }),attempt.string("manifest_id") == file.string("target_manifest_id"),attempt.string("phase") == "review" else { return nil }
            return EvidenceMeasureSnapshot(id:file.id,manifestID:file.string("target_manifest_id"),attemptID:attempt.id,title:file.string("name"),author:file.string("author"),sha256:file.string("sha256"),measures:file.records("measures").compactMap(DisplayEvidenceMeasure.init))
        }
        return submissions + reports
    }
    /// Compare only an unambiguous matching report in the immediately previous
    /// review attempt (or submission). Missing loaded history stays unknown.
    func previous(for current: EvidenceMeasureSnapshot) -> EvidenceMeasureSnapshot? {
        let all = snapshots
        if current.isSubmission {
            guard let index = review.manifests.firstIndex(where: { $0.id == current.manifestID }),index > 0 else { return nil }
            return all.first { $0.isSubmission && $0.manifestID == review.manifests[index - 1].id }
        }
        guard let active = review.attempts.first(where: { $0.id == current.attemptID }) else { return nil }
        let attempts = review.attempts.filter { $0.string("phase") == "review" && $0.string("gate") == active.string("gate") }
        guard let index = attempts.firstIndex(where: { $0.id == current.attemptID }),index > 0 else { return nil }
        let prior = attempts[index - 1]
        let matches = all.filter { $0.attemptID == prior.id && $0.title == current.title }
        return matches.count == 1 ? matches[0] : nil
    }
    func previousMeasure(_ measure: DisplayEvidenceMeasure, in snapshot: EvidenceMeasureSnapshot) -> DisplayEvidenceMeasure? {
        let matches = previous(for:snapshot)?.measures.filter { $0.name == measure.name && $0.unit == measure.unit } ?? []
        return matches.count == 1 ? matches[0] : nil
    }
}

struct EvidenceMeasuresView: View {
    @EnvironmentObject var store: ChecklistStore
    let manifest: Record?
    let projection: ReviewProjection
    var body: some View {
        let history = store.selectedReviewData(projection.task)["evidence_measure_history"] as? [String:Any] ?? [:]
        let values = EvidenceMeasuresProjection(review:projection,history:history)
        let snapshots = values.snapshots.filter { $0.manifestID == manifest?.id && !$0.measures.isEmpty }
        if !snapshots.isEmpty {
            VStack(alignment:.leading,spacing:Spacing.small) {
                ForEach(snapshots) { snapshot in
                    let overruns = snapshot.measures.filter(\.overLimit)
                    if !overruns.isEmpty {
                        Label("\(snapshot.title): \(overruns.count) measure\(overruns.count == 1 ? " is" : "s are") over budget",systemImage:"exclamationmark.triangle").checklistFont(.microEmphasis).foregroundStyle(.orange)
                    }
                    DisclosureGroup("Measures · \(snapshot.title)") {
                        VStack(alignment:.leading,spacing:Spacing.control) {
                            Text("Upper limits are advisory. Observations do not establish a review verdict.").checklistFont(.micro).foregroundStyle(.secondary)
                            ForEach(snapshot.measures) { measure in
                                VStack(alignment:.leading,spacing:Spacing.tight) {
                                    Text(verbatim:measure.name).checklistFont(.microEmphasis)
                                    Text("\(number(measure.before)) → \(number(measure.after)) \(measure.unit) · limit \(number(measure.limit)) \(measure.unit)").checklistFont(.micro).monospacedDigit()
                                    if measure.overLimit { Text("After value exceeds the limit by \(number(measure.after - measure.limit)) \(measure.unit).").checklistFont(.micro).foregroundStyle(.orange) }
                                    if let prior = values.previousMeasure(measure,in:snapshot) {
                                        Text("Previous round: \(number(prior.before)) → \(number(prior.after)) \(prior.unit), limit \(number(prior.limit)). After change: \(signed(measure.after - prior.after)) \(measure.unit).\(prior.limit == measure.limit ? "" : " The limit changed.")").checklistFont(.micro).foregroundStyle(.secondary)
                                    } else { Text("No unambiguous matching name and unit in the previous loaded round.").checklistFont(.micro).foregroundStyle(.secondary) }
                                }
                            }
                            TechnicalDetails([("Source",snapshot.id),("Target",snapshot.manifestID),("Author",snapshot.author),("SHA-256",snapshot.sha256)] + (values.previous(for:snapshot).map { [("Previous source",$0.id),("Previous target",$0.manifestID),("Previous SHA-256",$0.sha256)] } ?? []))
                        }.padding(.top,Spacing.small)
                    }.checklistFont(.micro)
                }
            }
        }
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.significantDigits(1...12))) }
    private func signed(_ value: Double) -> String { value > 0 ? "+" + number(value) : number(value) }
}
