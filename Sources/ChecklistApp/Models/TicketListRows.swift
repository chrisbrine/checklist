import Foundation

/// One independently sized child per lazy-list row. A whole expanded Triage must not
/// become a single variable-height child whose estimate includes all of its tickets.
struct TicketListRow: Identifiable {
    let id: ID

    enum ID: Hashable {
        case requestHeading, request(String), triage(String), triagePurpose(String), triageEmpty(String)
        case triageMember(triageID: String, taskID: String)
        case heading(String), ticket(String), triageSeparator(String), sectionSeparator(String), clearFilters

        // Human section labels retain text semantics. Record cases retain their
        // original values but compare exact preserved IDs within this list only.
        private enum Key: Hashable {
            case fixed(Int), record(Int, [RecordIdentity]), text(Int, String)
        }
        private var key: Key {
            switch self {
            case .requestHeading: return .fixed(0)
            case .clearFilters: return .fixed(1)
            case .request(let id): return .record(0, [RecordIdentity(id)])
            case .triage(let id): return .record(1, [RecordIdentity(id)])
            case .triagePurpose(let id): return .record(2, [RecordIdentity(id)])
            case .triageEmpty(let id): return .record(3, [RecordIdentity(id)])
            case .triageMember(let triage, let task): return .record(4, [RecordIdentity(triage), RecordIdentity(task)])
            case .ticket(let id): return .record(5, [RecordIdentity(id)])
            case .triageSeparator(let id): return .record(6, [RecordIdentity(id)])
            case .heading(let name): return .text(0, name)
            case .sectionSeparator(let name): return .text(1, name)
            }
        }
        static func == (left: Self, right: Self) -> Bool { left.key == right.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }
    let content: Content

    enum Content {
        case requestHeading(Int)
        case request(Record)
        case triage(InlineTriageSection)
        case triagePurpose(String)
        case triageEmpty(String)
        case triageMember(Record)
        case heading(String, Int)
        case ticket(Record)
        case separator(isTriage: Bool)
        case clearFilters
    }
}

enum TicketListRows {
    static func make(triages: [InlineTriageSection], expandedIDs: Set<String>, ordinaryGroups: [(String, [Record])], requests: [Record] = [], showClearFilters: Bool = false) -> [TicketListRow] {
        make(triages: triages, expandedRecordIDs: RecordIdentitySet(Array(expandedIDs)), ordinaryGroups: ordinaryGroups, requests: requests, showClearFilters: showClearFilters)
    }
    static func make(triages: [InlineTriageSection], expandedRecordIDs: RecordIdentitySet, ordinaryGroups: [(String, [Record])], requests: [Record] = [], showClearFilters: Bool = false) -> [TicketListRow] {
        var rows: [TicketListRow] = []
        if !requests.isEmpty {
            rows.append(.init(id: .requestHeading, content: .requestHeading(requests.count)))
            rows += requests.prefix(3).map { .init(id: .request($0.id), content: .request($0)) }
        }
        for section in triages {
            rows.append(.init(id: .triage(section.id), content: .triage(section)))
            if expandedRecordIDs.contains(section.id) {
                let purpose = section.triage.string("purpose")
                if !purpose.isEmpty { rows.append(.init(id: .triagePurpose(section.id), content: .triagePurpose(purpose))) }
                if section.visibleMembers.isEmpty {
                    let text = section.totalCount == 0 ? "No tickets in this Triage. Add tickets from its More menu." : "No tickets match the current filters. The Triage still contains \(section.totalCount)."
                    rows.append(.init(id: .triageEmpty(section.id), content: .triageEmpty(text)))
                }
                for task in section.visibleMembers {
                    rows.append(.init(id: .triageMember(triageID: section.id, taskID: task.id), content: .triageMember(task)))
                }
            }
            rows.append(.init(id: .triageSeparator(section.id), content: .separator(isTriage: true)))
        }
        for (name, tickets) in ordinaryGroups {
            rows.append(.init(id: .heading(name), content: .heading(name, tickets.count)))
            rows += tickets.map { .init(id: .ticket($0.id), content: .ticket($0)) }
            rows.append(.init(id: .sectionSeparator(name), content: .separator(isTriage: false)))
        }
        if showClearFilters { rows.append(.init(id: .clearFilters, content: .clearFilters)) }
        return rows
    }
}
