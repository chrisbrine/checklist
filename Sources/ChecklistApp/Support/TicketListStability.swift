import Foundation
import Combine

/// Freeze row identities at the interaction boundary while still refreshing their content.
/// Removed rows remain in place until Apply updates or the interaction ends.
enum StableTicketRows {
    static func holding(_ prior: [TicketListRow], current: [TicketListRow], visibleTicketIDs: Set<String>? = nil) -> [TicketListRow] {
        holding(prior, current: current, isVisible: visibleTicketIDs.map { ids in { ids.contains($0) } })
    }
    static func holding(_ prior: [TicketListRow], current: [TicketListRow], visibleRecordIDs: RecordIdentitySet) -> [TicketListRow] {
        holding(prior, current: current, isVisible: { visibleRecordIDs.contains($0) })
    }
    private static func holding(_ prior: [TicketListRow], current: [TicketListRow], isVisible: ((String) -> Bool)?) -> [TicketListRow] {
        let latest = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        guard let isVisible else { return prior.map { latest[$0.id] ?? $0 } }
        func visible(_ row: TicketListRow) -> Bool {
            switch row.content {
            case .ticket(let task), .triageMember(let task): return isVisible(task.id)
            // A header that is still current stays. A removed header stays only while a member is visible.
            case .triage(let section): return latest[row.id] != nil || memberIDs(section).contains { isVisible($0) }
            default: return true
            }
        }
        let visibilityRemovedRows = prior.contains { !visible($0) }
        let scopedPrior = prior.filter { row in
            guard visible(row) else { return false }
            // Once closed rows leave, remove their empty headings/containers immediately too.
            guard visibilityRemovedRows, latest[row.id] == nil else { return true }
            switch row.content {
            case .heading, .triage, .triagePurpose, .triageEmpty, .separator: return false
            default: return true
            }
        }
        return scopedPrior.map { latest[$0.id] ?? $0 }
    }
    /// The snapshot list supplies complete task_ids. A bounded page summary supplies only
    /// page_member_ids (members_complete:false), so use the same members that built the rows.
    private static func memberIDs(_ section: InlineTriageSection) -> [String] {
        section.visibleMembers.map(\.id) + section.allMembers.map(\.id)
            + section.triage.strings("task_ids") + section.triage.strings("page_member_ids")
    }
}

@MainActor
final class TicketListStability: ObservableObject {
    @Published private var held: [TicketListRow]?
    private var pointerInside = false
    private var keyboardGeneration = 0

    func rows(_ current: [TicketListRow], visibleTicketIDs: Set<String>? = nil) -> [TicketListRow] { held.map { StableTicketRows.holding($0, current: current, visibleTicketIDs: visibleTicketIDs) } ?? current }
    func rows(_ current: [TicketListRow], visibleRecordIDs: RecordIdentitySet) -> [TicketListRow] { held.map { StableTicketRows.holding($0, current: current, visibleRecordIDs: visibleRecordIDs) } ?? current }
    func pending(_ current: [TicketListRow]) -> Bool { held.map { $0.map(\.id) != current.map(\.id) } ?? false }
    func pointer(_ inside: Bool, rows: [TicketListRow]) {
        pointerInside = inside
        if inside { if held == nil { held = rows } }
        else { held = nil }
    }
    func keyboard(rows: [TicketListRow]) {
        if held == nil { held = rows }
        keyboardGeneration += 1
        let expected = keyboardGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.keyboardGeneration == expected, !self.pointerInside else { return }
            self.held = nil
        }
    }
    func apply(_ current: [TicketListRow]) { held = pointerInside ? current : nil }
    func reset() { keyboardGeneration += 1; held = nil }
}
