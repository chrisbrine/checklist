import SwiftUI

struct ProjectWorkspaceTabs: View {
    @EnvironmentObject var store: ChecklistStore
    var body: some View {
        HStack(spacing: Spacing.tight) {
            tab("Tickets", page: .tasks)
            tab("Epics", page: .epics)
            MediaProjectTab(model:store.mediaReview)
            Spacer()
        }.checklistActionScroll().padding(.horizontal, Spacing.page).padding(.top, Spacing.control).overlay(alignment: .bottom) { Divider() }
    }
    func tab(_ title: String, page: Page) -> some View {
        let selected = page == .tasks ? [.tasks, .archived].contains(store.page) : store.page == page
        return Button {
            store.select(page,project:store.projectID)
        } label: {
            // The unselected title stays readable (the system secondary color measures 3.95:1 on white).
            Text(title).checklistFont(selected ? .bodyStrong : .bodyEmphasis).foregroundStyle(selected ? Color.checklistAccentText : Color.primary.opacity(0.72))
                .padding(.horizontal, Spacing.group).padding(.top, Spacing.small).padding(.bottom, Spacing.control)
                // A one-point corner keeps the two-point selection underline pill-shaped.
                .overlay(alignment: .bottom) { if selected { RoundedRectangle(cornerRadius: 1).fill(Color.checklistAccentText).frame(height: 2) } }
        }.buttonStyle(.checklistPlain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("projectTab-\(title)")
    }
}
