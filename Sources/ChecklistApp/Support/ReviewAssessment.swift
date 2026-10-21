import Foundation

/// Recorded reviewer judgment stays separate from optional check logs and host preparation.
struct AgentReviewAssessmentProjection {
    let assessment: Record
    var rows: [Record] {
        let contract = Record(values:assessment.object("contract"))
        var result: [Record] = []
        for section in ["acceptance","project_requirements"] {
            let text = Dictionary(uniqueKeysWithValues:contract.records(section).map {($0.id,$0.string("text"))})
            result += assessment.records(section).map {row in var value = row.values;value["requirement"] = text[row.string("requirement_id")] ?? row.string("requirement_id");value["section"] = section;return Record(values:value)}
        }
        return result + assessment.records("additional_requirements")
    }
}
