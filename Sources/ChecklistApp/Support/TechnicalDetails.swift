import SwiftUI

/// The one collapsed place per item for IDs, hashes, revisions and raw records (CL-55).
/// The main flow says in plain words what the owner can see and must do.
struct TechnicalDetails: View {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label + "\u{1F}" + value }
    }
    struct Raw: Identifiable {
        let title: String
        let value: Any
        let id = UUID()
    }
    /// Long service text that carries IDs or raw data, such as a prepared agent instruction.
    struct Block: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }
    let rows: [Row]
    var raw: [Raw] = []
    var blocks: [Block] = []

    init(_ rows: [(String, String)] = [], raw: [(String, Any)] = [], blocks: [(String, String)] = []) {
        self.rows = rows.filter { !$0.1.isEmpty }.map { Row(label: $0.0, value: $0.1) }
        self.raw = raw.map { Raw(title: $0.0, value: $0.1) }
        self.blocks = blocks.filter { !$0.1.isEmpty }.map { Block(title: $0.0, text: $0.1) }
    }

    var body: some View {
        if !rows.isEmpty || !raw.isEmpty || !blocks.isEmpty {
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    ForEach(rows) { row in Text("\(row.label): \(row.value)").checklistFont(.code).textSelection(.enabled) }
                    ForEach(blocks) { block in
                        Text(block.title).checklistFont(.microEmphasis)
                        ScrollView { Text(block.text).checklistFont(.codeCaption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                    }
                    ForEach(raw) { block in
                        Text(block.title).checklistFont(.microEmphasis)
                        Text(ReviewProjection.readableJSON(block.value)).checklistFont(.code).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, Spacing.compact)
            }.checklistFont(.micro).accessibilityIdentifier("technicalDetails")
        }
    }
}
