import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

final class ColorContrastTests: XCTestCase {
    private struct RGB {
        let r: Double, g: Double, b: Double, a: Double
        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
        init(_ color: Color) {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
        }
        func over(_ background: RGB) -> RGB {
            RGB(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
        }
        var luminance: Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(on background: RGB) -> Double {
            let foreground = over(background).luminance, back = background.luminance
            return (max(foreground, back) + 0.05) / (min(foreground, back) + 0.05)
        }
    }

    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
    private let categories = ["active", "in_progress", "working", "review", "in_review", "done", "completed", "parked", "blocked", "draft", "canceled", "cancelled", "ready", "queued", "custom"]

    /// Resolve inside the drawing appearance, including the underlying system colors and alpha.
    private func inAppearances(_ check: (NSAppearance.Name, [(String, RGB)]) -> Void) {
        for name in appearances {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // Installed-build samples from the ticket, plus native window/control/text surfaces.
                let surfaces: [(String, RGB)] = [
                    ("installed window", dark ? RGB(42 / 255, 41 / 255, 39 / 255) : RGB(1, 1, 1)),
                    ("native window", RGB(Color(nsColor: .windowBackgroundColor))),
                    ("native control", RGB(Color(nsColor: .controlBackgroundColor))),
                    ("native text", RGB(Color(nsColor: .textBackgroundColor)))
                ]
                let backgrounds = surfaces.flatMap { label, window in
                    [(label, window), (label + " card", RGB(Card.background).over(window)),
                     (label + " selected row", RGB(Color.checklistAccent.opacity(0.1)).over(window))]
                }
                check(name, backgrounds)
            }
        }
    }

    func testSecondaryTextMeetsAAOnWindowCardAndSelectedRow() {
        inAppearances { appearance, backgrounds in
            let text = RGB(Color.checklistSecondaryText)
            XCTAssertEqual(text.a, 1, "The secondary token must not attenuate on nested surfaces")
            for (label, background) in backgrounds {
                let ratio = text.contrast(on: background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance.rawValue) \(label): \(ratio)")
                print("secondary \(appearance.rawValue) \(label): \(ratio)")
            }
        }
    }

    /// Use the actual header text token and the shared plain-button feedback, composited in sRGB.
    /// Disabled controls are exempt from AA; all enabled idle/hover/pressed states must pass.
    func testQuietTicketHeaderActionsMeetAAIncludingPressedHighContrast() {
        inAppearances { appearance, backgrounds in
            let increased = appearance == .accessibilityHighContrastAqua || appearance == .accessibilityHighContrastDarkAqua
            let text = RGB(TicketHeaderActionLabel.textColor(increasedContrast: increased))
            for (state, hovered, pressed) in [("idle", false, false), ("hover", true, false), ("pressed", true, true)] {
                let feedback = InteractionAppearance.resolve(hovered: hovered, pressed: pressed, enabled: true, focused: false, increasedContrast: increased)
                for (label, background) in backgrounds where !label.contains("card") && !label.contains("selected row") {
                    let fill = RGB(Color.primary.opacity(feedback.fillOpacity)).over(background)
                    let ratio = text.contrast(on: fill)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance.rawValue) \(label) \(state): \(ratio)")
                    print("ticket header \(appearance.rawValue) \(label) \(state): \(ratio)")
                }
            }
        }
    }

    func testInformativeViewTextUsesSecondaryToken() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChecklistApp/Views")
        // Guard the missed captions and the List header, whose system style is inherited.
        let captions: [String: [String]] = [
            "ProviderMessageReadinessView.swift": [
                "Text(context.recipientLabel)", "Text(\"Observed ",
                "Text(\"Settings readiness,", "Text(ProviderReadinessObservation.versionLimitation)",
                "Text(ProviderReadinessObservation.codexExplanation)", "Text(\"No automatic send"
            ],
            "TaskSessionsView.swift": [
                "Text(NativeCommunicationRoutes.summary)", "Text(route.reason)",
                "Text(\"Native wake unavailable"
            ],
            "ProjectSettingsView.swift": ["Text(\"Pausing retains requests."],
            "SidebarView.swift": ["header: { Text(\"Projects\")"]
        ]
        for (file, fragments) in captions {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertNil(source.range(of: #"\.(secondary|tertiary)\b"#, options: .regularExpression),
                         "Informative text in \(file) must use the shared token")
            for fragment in fragments {
                let line = try XCTUnwrap(source.split(separator: "\n").first { $0.contains(fragment) },
                                         "Missing caption in \(file): \(fragment)")
                XCTAssertTrue(line.contains(".foregroundStyle(Color.checklistSecondaryText)"),
                              "Caption in \(file) must explicitly use the shared token: \(fragment)")
            }
        }
    }

    func testEveryStatusPillMeetsAAOnItsCompositedFill() {
        inAppearances { appearance, backgrounds in
            for category in categories {
                let text = RGB(StatusPillColors.foreground(category: category))
                XCTAssertEqual(text.a, 1)
                for (label, background) in backgrounds {
                    let fill = RGB(StatusPillColors.tint(category: category).opacity(StatusPillColors.fillOpacity)).over(background)
                    let ratio = text.contrast(on: fill)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance.rawValue) \(category) \(label): \(ratio)")
                    print("pill \(appearance.rawValue) \(category) \(label): \(ratio)")
                }
            }
        }
    }

    func testStatusFamiliesKeepDistinctHues() {
        inAppearances { appearance, _ in
            let colors = ["active", "review", "done", "parked", "draft", "ready"].map {
                let rgb = RGB(StatusPillColors.foreground(category: $0))
                return [rgb.r, rgb.g, rgb.b]
            }
            XCTAssertEqual(Set(colors).count, 6, "\(appearance.rawValue): six existing semantic color families")
            XCTAssertEqual(StatusPillColors.fillOpacity, 0.11, "Keep the existing translucent fill")
        }
    }
}
