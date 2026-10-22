import AppKit
import SwiftUI

/// Autosave synchronizes drafts before returning. Quit verifies the exact current
/// snapshot off the main thread; it never sends/replays a pending service command.
struct CaptureTerminationCheck {
    let verify: () throws -> Void
    let isCurrent: @MainActor () -> Bool
}

@MainActor protocol CaptureTerminationParticipant: AnyObject {
    func captureTerminationCheck() -> CaptureTerminationCheck
}

@MainActor final class CaptureTerminationCoordinator {
    static let shared = CaptureTerminationCoordinator()
    private struct WeakParticipant { weak var value: CaptureTerminationParticipant? }
    private var participants: [ObjectIdentifier: WeakParticipant] = [:]
    private var attempt: UUID?
    private let timeout: TimeInterval
    private let verify: (@escaping () throws -> Void, @escaping (Bool) -> Void) -> Void

    init(timeout: TimeInterval = 3,
         verify: @escaping (@escaping () throws -> Void, @escaping (Bool) -> Void) -> Void = { check, complete in
             DispatchQueue.global(qos: .userInitiated).async {
                 do { try check(); complete(true) } catch { complete(false) }
             }
         }) {
        self.timeout = timeout; self.verify = verify
    }

    func register(_ participant: CaptureTerminationParticipant) {
        participants[ObjectIdentifier(participant)] = WeakParticipant(value: participant)
    }

    func request(reply: @escaping (Bool) -> Void, failure: @escaping (String) -> Void) -> NSApplication.TerminateReply {
        guard attempt == nil else { return .terminateLater }
        let id = UUID(); attempt = id
        participants = participants.filter { $0.value.value != nil }
        let checks = participants.values.compactMap { $0.value?.captureTerminationCheck() }
        let watchdog = DispatchWorkItem { [weak self] in
            self?.finish(id, saved: false, message: "Checking your capture draft took too long. Checklist stayed open to protect it. Retry Quit when storage is available.", reply: reply, failure: failure)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        verify({ for check in checks { try check.verify() } }) { [weak self] saved in
            // Also works during AppKit's termination modal run loop. Never reply
            // inline before applicationShouldTerminate has returned terminateLater.
            DispatchQueue.main.async {
                guard self?.attempt == id else { return }
                watchdog.cancel()
                self?.finish(id, saved: saved && checks.allSatisfy { $0.isCurrent() }, message: "Your capture draft could not be confirmed saved. Checklist stayed open to protect it. Check its save error or retry after storage is available.", reply: reply, failure: failure)
            }
        }
        return .terminateLater
    }

    private func finish(_ id: UUID, saved: Bool, message: String, reply: (Bool) -> Void, failure: (String) -> Void) {
        guard attempt == id else { return }
        attempt = nil
        reply(saved)
        if !saved { failure(message) }
    }
}

/// SwiftUI sheets otherwise silently veto terminate: before the app delegate can
/// check the already durable capture draft. Only capture opts out of that veto.
struct CaptureAllowsQuit: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.4, *) {
            content.presentationPreventsAppTermination(false)
        } else {
            content.background(CaptureQuitWindowPolicy())
        }
    }
}

private struct CaptureQuitWindowPolicy: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}
