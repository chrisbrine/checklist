import XCTest
import SwiftUI
import AppKit
@testable import ChecklistApp

final class InteractionStyleTests: XCTestCase {
    private func resolve(hovered: Bool = false, pressed: Bool = false, enabled: Bool = true, focused: Bool = false, increasedContrast: Bool = false) -> InteractionAppearance {
        InteractionAppearance.resolve(hovered: hovered, pressed: pressed, enabled: enabled, focused: focused, increasedContrast: increasedContrast)
    }

    func testIdleControlDrawsNoFeedbackAndFullContent() {
        let idle = resolve()
        XCTAssertEqual(idle.fillOpacity, 0)
        XCTAssertEqual(idle.borderWidth, 0)
        XCTAssertEqual(idle.focusRingWidth, 0)
        XCTAssertEqual(idle.contentOpacity, 1)
    }

    func testHoverAndPressDrawIncreasingFill() {
        let hovered = resolve(hovered: true)
        let pressed = resolve(hovered: true, pressed: true)
        XCTAssertGreaterThan(hovered.fillOpacity, 0)
        XCTAssertGreaterThan(pressed.fillOpacity, hovered.fillOpacity)
        XCTAssertEqual(resolve(pressed: true), pressed, "Press feedback does not depend on hover")
        XCTAssertEqual(hovered.contentOpacity, 1)
    }

    func testIncreasedContrastUsesStrongerFillAndVisibleBorder() {
        for (normal, strong) in [(resolve(hovered: true), resolve(hovered: true, increasedContrast: true)),
                                 (resolve(pressed: true), resolve(pressed: true, increasedContrast: true))] {
            XCTAssertGreaterThan(strong.fillOpacity, normal.fillOpacity)
            XCTAssertEqual(normal.borderWidth, 0)
            XCTAssertGreaterThanOrEqual(strong.borderWidth, 1)
            XCTAssertGreaterThanOrEqual(strong.borderOpacity, 0.5)
        }
        XCTAssertGreaterThan(resolve(focused: true, increasedContrast: true).focusRingWidth, resolve(focused: true).focusRingWidth)
    }

    func testDisabledControlIgnoresHoverPressAndFocusAndDimsContent() {
        for contrast in [false, true] {
            let disabled = resolve(hovered: true, pressed: true, enabled: false, focused: true, increasedContrast: contrast)
            XCTAssertEqual(disabled.fillOpacity, 0)
            XCTAssertEqual(disabled.borderWidth, 0)
            XCTAssertEqual(disabled.focusRingWidth, 0)
            XCTAssertLessThan(disabled.contentOpacity, 1)
        }
        XCTAssertGreaterThan(resolve(enabled: false, increasedContrast: true).contentOpacity, resolve(enabled: false).contentOpacity)
    }

    func testFocusRingIsIndependentOfHoverAndPress() {
        XCTAssertEqual(resolve(focused: true).focusRingWidth, 2)
        XCTAssertEqual(resolve(hovered: true, focused: true).focusRingWidth, 2)
        XCTAssertEqual(resolve(pressed: true, focused: true).focusRingWidth, 2)
        XCTAssertEqual(resolve(hovered: true, focused: true).fillOpacity, resolve(hovered: true).fillOpacity)
    }

    func testReduceMotionRemovesAnimation() {
        XCTAssertNil(InteractionAppearance.animation(reduceMotion: true))
        XCTAssertNotNil(InteractionAppearance.animation(reduceMotion: false))
    }

    /// Review finding 2b7a5a6a: icon-only menus must keep the 22-point icon hit area.
    @MainActor func testIconOnlyMenuKeepsTheIconHitTarget() {
        let menu = Menu { Button("Action") {} } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(.checklistIcon).menuIndicator(.hidden)
        let size = NSHostingView(rootView: menu).fittingSize
        XCTAssertGreaterThanOrEqual(size.width, HitTarget.icon)
        XCTAssertGreaterThanOrEqual(size.height, HitTarget.icon)
    }

    /// Non-text contrast: the focus ring needs at least 3:1 against the window background in both appearances.
    /// Backgrounds are the values sampled from installed build 52 screenshots (light 255,255,255; dark 42,41,39).
    private func contrastAgainstWindow(_ color: Color, light: (Double, Double, Double) = (1, 1, 1), dark: (Double, Double, Double) = (42 / 255, 41 / 255, 39 / 255)) -> [(NSAppearance.Name, Double)] {
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            let la = luminance(a), lb = luminance(b)
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }
        let cases: [(NSAppearance.Name, (Double, Double, Double))] = [(.aqua, light), (.darkAqua, dark)]
        return cases.map { name, background in
            var resolved = (0.0, 0.0, 0.0)
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let ns = NSColor(color).usingColorSpace(.sRGB)!
                resolved = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
            }
            return (name, contrast(resolved, background))
        }
    }

    /// Review finding 8dd25fee: on a selected chip the accent ring would sit on the accent fill (about 1.4:1 light,
    /// 2.0:1 dark), so a chip draws its ring outside the fill, on the window background tested below.
    func testChipFocusRingSitsOutsideTheFill() {
        XCTAssertGreaterThan(InteractionAppearance.focusRingOutset(chip: true, ringWidth: 2), 2, "Ring width plus a gap")
        XCTAssertEqual(InteractionAppearance.focusRingOutset(chip: false, ringWidth: 2), 0, "Other controls keep their inside ring")
    }

    func testFocusRingKeepsThreeToOneContrastInLightAndDark() {
        for (name, ratio) in contrastAgainstWindow(.checklistFocusRing) {
            XCTAssertGreaterThanOrEqual(ratio, 3, "\(name.rawValue)")
        }
    }

    /// Selected tab titles and other accent text are small text: 4.5:1. The fill accent fails in dark (2.96:1).
    func testAccentTextKeepsTextContrastInLightAndDark() {
        for (name, ratio) in contrastAgainstWindow(.checklistAccentText) {
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue)")
        }
        // Pop-up and menu titles draw in this tint on the control fill (sampled from installed captures).
        for (name, ratio) in contrastAgainstWindow(.checklistAccentText, light: (228 / 255, 230 / 255, 230 / 255), dark: (52 / 255, 54 / 255, 54 / 255)) {
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "control fill \(name.rawValue)")
        }
        let fill = Dictionary(uniqueKeysWithValues: contrastAgainstWindow(.checklistAccent).map { ($0.0, $0.1) })
        XCTAssertLessThan(fill[.darkAqua]!, 3, "The fill accent stays a fill: it is not readable as dark-mode text")
    }

    /// Finding 534648f0: a selected chip's opaque fill hid the hover and press layer. The chip style now
    /// darkens the accent fill itself; its white title keeps 4.5:1 in every state.
    func testSelectedChipFeedbackChangesTheFillAndKeepsTitleContrast() {
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let chip = ChipFill.resolve(selected: true)
        let accent = NSColor(chip.base).usingColorSpace(.sRGB)!, tint = NSColor(chip.feedbackTint).usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(tint.redComponent + tint.greenComponent + tint.blueComponent), 0, accuracy: 0.001, "The selected feedback darkens the fill")
        var idle = 0.0
        for increased in [false, true] {
            for (hovered, pressed) in [(false, false), (true, false), (false, true)] {
                let appearance = InteractionAppearance.resolve(hovered: hovered, pressed: pressed, enabled: true, focused: false, increasedContrast: increased)
                let a = appearance.fillOpacity * chip.feedbackScale
                let fill = (Double(accent.redComponent) * (1 - a), Double(accent.greenComponent) * (1 - a), Double(accent.blueComponent) * (1 - a))
                let ratio = 1.05 / (luminance(fill) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "white title, hovered \(hovered) pressed \(pressed) increased \(increased)")
                if !hovered && !pressed { idle = luminance(fill); XCTAssertEqual(a, 0) }
                else { XCTAssertLessThan(luminance(fill), idle * 0.9, "hover and press visibly change the selected fill") }
            }
        }
        let unselected = ChipFill.resolve(selected: false)
        XCTAssertEqual(unselected.feedbackScale, 1)
    }
}
