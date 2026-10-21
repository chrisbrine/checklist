import SwiftUI
import AppKit

enum Spacing {
    static let none: CGFloat = 0
    static let hairline: CGFloat = 2
    static let tight: CGFloat = 4
    static let compact: CGFloat = 6
    static let small: CGFloat = 8
    static let row: CGFloat = 10
    static let control: CGFloat = 12
    static let group: CGFloat = 16
    static let section: CGFloat = 20
    static let page: CGFloat = 24
    static let spacious: CGFloat = 28
    static let empty: CGFloat = 36
}

enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 14
}

enum TextRole {
    case pageTitle, title, sheetTitle, sheetHeading, sectionTitle, subheading, subheadingEmphasis
    case body, bodyEmphasis, bodyStrong, callout, calloutEmphasis, calloutStrong
    case caption, captionEmphasis, captionStrong, micro, microEmphasis, microStrong
    case code, codeCaption, codeCallout

    var size: CGFloat {
        switch self {
        case .pageTitle: return 26
        case .title: return 22
        case .sheetTitle, .sheetHeading: return 17
        case .sectionTitle: return 16
        case .subheading, .subheadingEmphasis: return 15
        case .body, .bodyEmphasis, .bodyStrong: return 13
        case .callout, .calloutEmphasis, .calloutStrong, .codeCallout: return 12
        case .caption, .captionEmphasis, .captionStrong, .codeCaption: return 11
        case .micro, .microEmphasis, .microStrong, .code: return 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .pageTitle, .title, .sheetTitle: return .bold
        case .sheetHeading, .sectionTitle, .subheadingEmphasis, .bodyStrong, .calloutStrong, .captionStrong, .microStrong: return .semibold
        case .bodyEmphasis, .calloutEmphasis, .captionEmphasis, .microEmphasis: return .medium
        default: return .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .code, .codeCaption, .codeCallout: return .monospaced
        default: return .default
        }
    }
}

extension EnvironmentValues {
    @Entry var checklistTextScale: CGFloat = 1.0
}

private struct ChecklistFont: ViewModifier {
    @Environment(\.checklistTextScale) private var scale
    let role: TextRole
    func body(content: Content) -> some View {
        content.font(.system(size: role.size * scale, weight: role.weight, design: role.design))
    }
}

enum Card {
    static let background = Color.primary.opacity(0.035)
    static let radius = Radius.medium
    static let padding = Spacing.control
}

private struct ChecklistCard: ViewModifier {
    let padding: CGFloat
    func body(content: Content) -> some View {
        content.padding(padding).background(Card.background, in: RoundedRectangle(cornerRadius: Card.radius))
    }
}

extension View {
    func checklistFont(_ role: TextRole) -> some View { modifier(ChecklistFont(role: role)) }
    func checklistCard(padding: CGFloat = Spacing.none) -> some View { modifier(ChecklistCard(padding: padding)) }
}

enum HitTarget {
    // The macOS small control height; an icon-only button is never smaller than this square.
    static let icon: CGFloat = 22
}

/// The visual feedback of one clickable control. A pure value so that tests can check every state.
/// Feedback draws only a fill, a border and a focus ring in the control's own bounds; it never changes layout.
struct InteractionAppearance: Equatable {
    /// A chip's focus ring sits this far outside its fill, with a one-point gap (CL-51).
    static func focusRingOutset(chip: Bool, ringWidth: CGFloat) -> CGFloat { chip ? ringWidth + 1 : 0 }
    var fillOpacity: Double
    var borderOpacity: Double
    var borderWidth: CGFloat
    var focusRingWidth: CGFloat
    var contentOpacity: Double

    static func resolve(hovered: Bool, pressed: Bool, enabled: Bool, focused: Bool, increasedContrast: Bool) -> InteractionAppearance {
        guard enabled else {
            return InteractionAppearance(fillOpacity: 0, borderOpacity: 0, borderWidth: 0, focusRingWidth: 0, contentOpacity: increasedContrast ? 0.6 : 0.45)
        }
        var appearance = InteractionAppearance(fillOpacity: 0, borderOpacity: 0, borderWidth: 0, focusRingWidth: 0, contentOpacity: 1)
        if pressed {
            appearance.fillOpacity = increasedContrast ? 0.2 : 0.12
            if increasedContrast { appearance.borderOpacity = 0.6; appearance.borderWidth = 1 }
        } else if hovered {
            appearance.fillOpacity = increasedContrast ? 0.12 : 0.06
            if increasedContrast { appearance.borderOpacity = 0.5; appearance.borderWidth = 1 }
        }
        if focused { appearance.focusRingWidth = increasedContrast ? 3 : 2 }
        return appearance
    }

    /// A short ease-out for state changes; no animation when Reduce Motion is on.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

private struct InteractionFeedback: ViewModifier {
    let pressed: Bool
    let radius: CGFloat
    /// An explicit focus value for a control that owns its focus state; nil reads the environment.
    let focusOverride: Bool?
    let dimsDisabledContent: Bool
    /// A chip owns its fill here, under the feedback layer; nil draws the feedback alone.
    var chip: ChipFill? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var environmentFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    func body(content: Content) -> some View {
        let appearance = InteractionAppearance.resolve(hovered: hovered, pressed: pressed, enabled: enabled, focused: focusOverride ?? environmentFocused, increasedContrast: contrast == .increased)
        let animation = InteractionAppearance.animation(reduceMotion: reduceMotion)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .opacity(dimsDisabledContent ? appearance.contentOpacity : 1)
            .background {
                ZStack {
                    if let chip { shape.fill(chip.base) }
                    shape.fill((chip?.feedbackTint ?? Color.primary).opacity(appearance.fillOpacity * (chip?.feedbackScale ?? 1)))
                }.animation(animation, value: appearance)
            }
            .overlay {
                ZStack {
                    shape.strokeBorder(Color.primary.opacity(appearance.borderOpacity), lineWidth: max(appearance.borderWidth, 1))
                    if chip != nil {
                        // A chip draws its ring just outside its fill: the accent ring on a selected (accent) fill would
                        // have too little contrast, while on the window background it keeps 3:1 (CL-51).
                        let width = max(appearance.focusRingWidth, 1), outset = InteractionAppearance.focusRingOutset(chip: true, ringWidth: width)
                        RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                            .strokeBorder(Color.checklistFocusRing.opacity(appearance.focusRingWidth > 0 ? 1 : 0), lineWidth: width).padding(-outset)
                    } else {
                        shape.strokeBorder(Color.checklistFocusRing.opacity(appearance.focusRingWidth > 0 ? 1 : 0), lineWidth: max(appearance.focusRingWidth, 1))
                    }
                }.animation(animation, value: appearance).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// Plain text or label buttons: hover and pressed fill, disabled dimming and a focus ring.
struct ChecklistPlainButtonStyle: ButtonStyle {
    var radius: CGFloat = Radius.small
    var focused: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(InteractionFeedback(pressed: configuration.isPressed, radius: radius, focusOverride: focused, dimsDisabledContent: true))
    }
}

/// Icon-only buttons: the plain feedback on a centered square hit area of at least `HitTarget.icon`.
struct ChecklistIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: HitTarget.icon, minHeight: HitTarget.icon)
            .modifier(InteractionFeedback(pressed: configuration.isPressed, radius: Radius.small, focusOverride: nil, dimsDisabledContent: true))
    }
}

/// Clickable rows and cards: the feedback covers the whole row with the card corner radius.
struct ChecklistRowButtonStyle: ButtonStyle {
    var focused: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(InteractionFeedback(pressed: configuration.isPressed, radius: Radius.medium, focusOverride: focused, dimsDisabledContent: true))
    }
}

/// The fill of a toggle chip and the color of its hover and pressed layer.
/// A selected chip darkens its accent fill, so its white title gains contrast in every state.
struct ChipFill {
    let base: Color
    let feedbackTint: Color
    let feedbackScale: Double
    static func resolve(selected: Bool) -> ChipFill {
        selected ? ChipFill(base: .checklistAccent, feedbackTint: .black, feedbackScale: 2)
                 : ChipFill(base: Color.primary.opacity(0.055), feedbackTint: .primary, feedbackScale: 1)
    }
}

/// Filter and visibility chips. The style owns the chip fill: a fill inside the label would sit above
/// the feedback layer and hide hover and press on a selected chip.
struct ChecklistChipButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(selected ? Color.white : Color.primary)
            .modifier(InteractionFeedback(pressed: configuration.isPressed, radius: Radius.medium, focusOverride: nil, dimsDisabledContent: true, chip: .resolve(selected: selected)))
    }
}

extension ButtonStyle where Self == ChecklistPlainButtonStyle {
    static var checklistPlain: ChecklistPlainButtonStyle { ChecklistPlainButtonStyle() }
}

extension ButtonStyle where Self == ChecklistIconButtonStyle {
    static var checklistIcon: ChecklistIconButtonStyle { ChecklistIconButtonStyle() }
}

extension ButtonStyle where Self == ChecklistRowButtonStyle {
    static var checklistRow: ChecklistRowButtonStyle { ChecklistRowButtonStyle() }
}

extension View {
    /// Hover feedback for a control that has its own button style, such as a borderless menu.
    /// It keeps the control's focus ring and disabled look.
    func checklistHoverHighlight(radius: CGFloat = Radius.small) -> some View {
        modifier(InteractionFeedback(pressed: false, radius: radius, focusOverride: false, dimsDisabledContent: false))
    }
}

extension Color {
    /// The fill and tint accent (prominent buttons draw white titles on it).
    static let checklistAccent = Color(red: 0.03, green: 0.49, blue: 0.52)
    /// The accent for text, icons and thin marks, also the window tint for menu and pop-up titles.
    /// A darker teal in light appearances: the fill accent measures under 4.5:1 on light control fills.
    /// A lighter teal in dark ones, where the fill accent measures 2.96:1 against the window background.
    static let checklistAccentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.27, green: 0.70, blue: 0.73, alpha: 1)
            : NSColor(red: 0.02, green: 0.40, blue: 0.43, alpha: 1)
    })
    static let checklistFocusRing = checklistAccentText
    static func named(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "red": return .red
        case "green": return .green
        case "pink": return .pink
        case "gray", "grey": return .gray
        default: return .checklistAccentText
        }
    }
}

struct StatusPill: View {
    let name: String
    var category: String = "ready"
    var body: some View {
        HStack(spacing: Spacing.compact) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).checklistFont(.captionEmphasis)
        }
        .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
        .background(color.opacity(0.11), in: Capsule())
        .foregroundStyle(color)
    }
    var color: Color {
        switch Canceled.normalized(category) {
        case "active", "in_progress", "working": return .checklistAccent
        case "review", "in_review": return .purple
        case "done", "completed": return .green
        case "parked", "blocked": return .orange
        case "draft", "canceled": return .secondary
        default: return .blue
        }
    }
}

/// A label whose icon is decorative. A button-style menu otherwise exposes the symbol as its own
/// element with the symbol's default name (for example "All Mailboxes" for tray.2).
struct DecorativeIconLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: systemImage).accessibilityHidden(true) }
            .accessibilityElement(children: .ignore).accessibilityLabel(Text(title))
    }
}

struct SectionCaption: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: Spacing.small) {
            Text(title).checklistFont(.bodyStrong)
            if let count { Text("\(count)").checklistFont(.captionEmphasis).foregroundStyle(.secondary).padding(.horizontal, Spacing.compact).padding(.vertical, Spacing.hairline).background(.quaternary, in: Capsule()) }
            Spacer()
        }.padding(.top, Spacing.small).padding(.bottom, Spacing.tight)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: Spacing.control) {
            // Decorative empty-state artwork keeps its size independently of text scaling.
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).checklistFont(.subheadingEmphasis)
            Text(detail).checklistFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(Spacing.empty)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).checklistFont(.bodyStrong)
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func relativeTime(_ string: String) -> String {
    RelativeTimeFormatterCache.shared.string(from: string)
}

func chooseFiles(directories: Bool = false, files: Bool = true, multiple: Bool = true) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directories
    panel.canChooseFiles = files
    panel.allowsMultipleSelection = multiple
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.urls : []
}

func clipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}


enum BuildIdentity {
    static let current: String = {
        if let url = Bundle.main.url(forResource: "build-info", withExtension: "json"), let data = try? Data(contentsOf: url), let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let buildID = info["build_id"] as? String { return buildID }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    }()
}

/// Reflows actions without replacing their view identities when text grows.
struct AccessibleHStack<Content: View>: View {
    @Environment(\.checklistTextScale) private var scale
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content
    var body: some View {
        let layout = scale > 1.3
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content }.fixedSize(horizontal: false, vertical: scale > 1.3)
    }
}

private struct ChecklistSheet: ViewModifier {
    @Environment(\.checklistTextScale) private var scale
    let width: CGFloat
    func body(content: Content) -> some View {
        ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            // A sheet does not take the window root's button style: without this, plain sheet buttons
            // keep the system text size and the window tint (2.85:1 in dark, installed build 821f489b).
            .buttonStyle(.checklistAutomatic)
            // Fits inside the smallest supported window; all form actions scroll into view.
            .frame(width: min(800, width * max(1, scale))).frame(idealHeight: 540, maxHeight: 540)
    }
}

extension View {
    func checklistSheet(width: CGFloat) -> some View { modifier(ChecklistSheet(width: width)) }
}

private struct ChecklistActionScroll: ViewModifier {
    @Environment(\.checklistTextScale) private var scale
    func body(content: Content) -> some View {
        if scale > 1.3 {
            ScrollView(.horizontal) { content.fixedSize(horizontal: true, vertical: false) }
        } else { content }
    }
}

extension View {
    func checklistActionScroll() -> some View { modifier(ChecklistActionScroll()) }
}

struct ChecklistTextScaleRoot: ViewModifier {
    @AppStorage(TextScale.key, store: .standard) private var storedScale = 1.0
    func body(content: Content) -> some View {
        content.checklistFont(.body).buttonStyle(.checklistAutomatic)
            .environment(\.checklistTextScale, CGFloat(TextScale.normalized(storedScale)))
            .background {
                Button("Bigger Text") { storedScale = TextScale.stepping(storedScale, by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                    .checklistDisabled([(TextScale.normalized(storedScale) == TextScale.steps.last, "Text is already at the largest size.")]).hidden()
            }
    }
}

extension View {
    func checklistTextScaleRoot() -> some View { modifier(ChecklistTextScaleRoot()) }
}


enum ControlTextRole {
    static func role(for size: ControlSize) -> TextRole {
        switch size {
        case .mini: return .caption
        case .small: return .callout
        default: return .body
        }
    }
}

/// The font belongs inside the label: native macOS buttons ignore an outer font.
struct ChecklistScaledButtonStyle: PrimitiveButtonStyle {
    enum Appearance { case automatic, bordered, prominent }
    var appearance: Appearance = .automatic
    @Environment(\.controlSize) private var controlSize

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch appearance {
        case .automatic: button(configuration).buttonStyle(.automatic).tint(labelTint(configuration))
        case .bordered: button(configuration).buttonStyle(.bordered).tint(labelTint(configuration))
        case .prominent: button(configuration).buttonStyle(.borderedProminent).tint(configuration.role == .destructive ? nil : .checklistAccent)
        }
    }
    /// AppKit draws this inner button's title in the window tint in an active window:
    /// 2.4-2.7:1 on the dark bordered fill, measured on builds 52 and 53. Use the primary text color instead;
    /// a destructive button keeps the system tint.
    private func labelTint(_ configuration: Configuration) -> Color? {
        configuration.role == .destructive ? nil : .primary
    }
    private func button(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.checklistFont(ControlTextRole.role(for: controlSize))
        }
    }
}

extension PrimitiveButtonStyle where Self == ChecklistScaledButtonStyle {
    static var checklistAutomatic: Self { Self() }
    static var checklistBordered: Self { Self(appearance: .bordered) }
    static var checklistProminent: Self { Self(appearance: .prominent) }
}
