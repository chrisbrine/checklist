import SwiftUI

/// CL-58: a disabled control says why. The first true reason disables the control and shows as its
/// tooltip and accessibility hint; a test forbids a plain `.disabled(...)` elsewhere in the app.
struct DisabledReason: ViewModifier {
    let reason: String?
    func body(content: Content) -> some View {
        if let reason { content.disabled(true).help(reason).accessibilityHint(reason) } else { content }
    }
}

extension View {
    func checklistDisabled(_ reasons: [(Bool, String)]) -> some View {
        modifier(DisabledReason(reason: reasons.first { $0.0 }?.1))
    }
}

/// Shared reasons for actions that write to the service.
enum DisabledReasons {
    static let offline = "Checklist is offline. Changes and sending are off until it reconnects; your drafts stay on this Mac."
    static let saving = "Another change is still saving. Try again when it finishes."
    static let uncheckedChange = "The last change may already be saved. Use Check the last change first."
    static let ticketLoading = "The current version of this ticket is still loading."
}
