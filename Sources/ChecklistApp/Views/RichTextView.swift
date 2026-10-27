import SwiftUI
import AppKit
import Charts
import ChecklistCore

/// The one shared renderer for declared text fields (CL-127): ticket and Triage notes,
/// ticket briefs, Triage purposes, review explanations and request explanations.
/// It shows the exact source on request, copies it unchanged and never adds a
/// workflow action. Unsupported content falls back to the readable string.
struct RichTextView: View {
    let text: String
    var content: Any? = nil
    let capability: RichFieldCapability
    var task: Record? = nil
    var role: TextRole = .callout
    var contentDigest: String = ""
    @State private var prepared: RichContentPresentation?
    @State private var showSource = false
    @State private var copyStatus = ""

    /// Small, envelope-free text is prepared in place so rows keep a stable first layout.
    static let synchronousBytes = 16_384
    var synchronous: Bool { content == nil && text.utf8.count <= Self.synchronousBytes }
    var key: String { RichTextView.preparationKey(text: text, content: content, capability: capability) }
    var presentation: RichContentPresentation? {
        if synchronous { return RichPresentationCache.shared.presentation(text: text, capability: capability) }
        return prepared?.source == text ? prepared : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if showSource {
                RichSourceView(text: text, content: content, digest: contentDigest.isEmpty ? (presentation?.contentDigest ?? "") : contentDigest, role: role)
            } else if let presentation {
                RichBlocksView(presentation: presentation, task: task, role: role)
            } else {
                // Stable interim layout: the bounded leading source, then the rendered view.
                Text(verbatim: String(text.prefix(2_000))).checklistFont(role).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                ProgressView("Preparing rich view…").controlSize(.small).checklistFont(.micro)
            }
            if let notice = presentation?.notice { Text(notice).checklistFont(.micro).foregroundStyle(.orange).textSelection(.enabled) }
            if showSource || presentation?.rich == true || presentation?.notice != nil {
                AccessibleHStack(spacing: Spacing.small) {
                    Button(showSource ? "Show rendered" : "Show source") { showSource.toggle() }
                        .accessibilityHint(showSource ? "Shows the formatted view." : "Shows the exact stored text.")
                    Button("Copy source") { copy(text, status: "Copied the original source text.") }
                    if content != nil { Button("Copy source and content (JSON)") { copy(RichTextView.exportJSON(text: text, content: content), status: "Copied the original text and stored content envelope as JSON.") } }
                    if !copyStatus.isEmpty { Text(copyStatus).foregroundStyle(Color.checklistSecondaryText) }
                }.buttonStyle(.link).checklistFont(.micro)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: key) { await prepare() }
    }

    func copy(_ value: String, status: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copyStatus = status
    }

    func prepare() async {
        guard !synchronous else { return }
        let source = text, capability = capability, box = RichContentBox(value: content)
        let work = Task.detached(priority: .userInitiated) { () -> RichContentPresentation in
            RichContentPresentation.prepare(text: source, content: box.value, capability: capability, isCanceled: { Task.isCancelled })
        }
        let value = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        if !Task.isCancelled { prepared = value }
    }

    static func preparationKey(text: String, content: Any?, capability: RichFieldCapability) -> String {
        var hasher = Hasher(); hasher.combine(text); hasher.combine(capability.field)
        if let content, JSONSerialization.isValidJSONObject(content), let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) { hasher.combine(data) }
        return String(hasher.finalize())
    }

    /// Export states its contents: the exact plain string plus the stored envelope, unchanged.
    static func exportJSON(text: String, content: Any?) -> String {
        var value: [String: Any] = ["text": text, "export": "original_source"]
        if let content, JSONSerialization.isValidJSONObject(["content": content]) { value["content"] = content }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

struct RichContentBox: @unchecked Sendable { let value: Any? }

/// Bounded cache of prepared small fields so row redraws do not reparse.
@MainActor final class RichPresentationCache {
    static let shared = RichPresentationCache()
    private let cache = NSCache<NSString, Entry>()
    final class Entry { let value: RichContentPresentation; init(_ value: RichContentPresentation) { self.value = value } }
    init() { cache.countLimit = 512 }
    func presentation(text: String, capability: RichFieldCapability) -> RichContentPresentation {
        let key = (capability.field + "\u{1F}" + text) as NSString
        if let entry = cache.object(forKey: key) { return entry.value }
        let value = RichContentPresentation.prepare(text: text, capability: capability)
        cache.setObject(Entry(value), forKey: key)
        return value
    }
}

struct RichSourceView: View {
    let text: String
    let content: Any?
    let digest: String
    let role: TextRole
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Source text").checklistFont(.microStrong).foregroundStyle(Color.checklistSecondaryText)
            ScrollView(.horizontal) { Text(verbatim: text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if content != nil {
                Text("Stored content envelope").checklistFont(.microStrong).foregroundStyle(Color.checklistSecondaryText)
                ScrollView(.horizontal) { Text(verbatim: RichTextView.exportJSON(text: text, content: content)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 240)
            }
            if !digest.isEmpty { Text("Content fingerprint (SHA-256) " + digest).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText).textSelection(.enabled) }
        }.accessibilityElement(children: .contain).accessibilityLabel("Source view")
    }
}

struct RichBlocksView: View {
    let presentation: RichContentPresentation
    let task: Record?
    let role: TextRole
    @State private var linkProblem = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .plain(let value): Text(verbatim: value).checklistFont(role).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                case .markdown(let document): RichMarkdownBlocks(document: document, role: role)
                case .table(let columns, let rows, let caption): RichTableBlock(headers: columns.map(\.label), rows: rows, caption: caption)
                case .chart(let kind, let x, let y, let xUnit, let yUnit, let series, let caption, _):
                    RichChartBlock(kind: kind, xLabel: x, yLabel: y, xUnit: xUnit, yUnit: yUnit, series: series, caption: caption)
                case .html(let document, let fallback): RichHTMLBlock(blocks: document.layoutBlocks(), fallback: fallback)
                case .media(let ref, let caption, let fallback): RichMediaBlock(ref: ref, caption: caption, fallback: fallback, task: task)
                }
            }
            if !linkProblem.isEmpty { Text(linkProblem).checklistFont(.micro).foregroundStyle(.orange) }
        }.environment(\.openURL, OpenURLAction { url in
            // External navigation only after an explicit click, through macOS, for https.
            if case .externalLink(let link) = MarkdownResource.resolve(url.absoluteString, image: false, attachments: [:]), link.scheme?.lowercased() == "https" {
                if !NSWorkspace.shared.open(link) { linkProblem = "macOS could not open this link." }
            } else { linkProblem = "Only https links open from formatted text." }
            return .handled
        })
    }
}

enum RichInline {
    /// Bounded inline Markdown; HTML-looking text stays literal.
    static func markdown(_ text: String) -> Text {
        guard text.utf8.count < 32_768, !text.contains("<") else { return Text(verbatim: text) }
        let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return value.map(Text.init) ?? Text(verbatim: text)
    }
    static func runs(_ runs: [SafeInlineRun]) -> Text {
        var value = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            // Presentation intents keep the container's font, size and Dynamic Type.
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if run.code { intent.insert(.code) }
            if !intent.isEmpty { part.inlinePresentationIntent = intent }
            if run.underline || run.link != nil { part.underlineStyle = .single }
            if run.strike { part.strikethroughStyle = .single }
            if let link = run.link { part.link = link }
            value += part
        }
        return Text(value)
    }
}

struct RichMarkdownBlocks: View {
    let document: MarkdownDocument
    let role: TextRole
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(document.blocks.prefix(4096).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value): RichInline.markdown(value).font(level <= 2 ? .headline : .subheadline.bold()).accessibilityAddTraits(.isHeader)
                case .paragraph(let value): RichInline.markdown(value).checklistFont(role).textSelection(.enabled)
                case .quote(let value): HStack { Rectangle().fill(.secondary).frame(width: 3); RichInline.markdown(value).italic().checklistFont(role).textSelection(.enabled) }
                case .list(let marker, let value): HStack(alignment: .firstTextBaseline) { Text(verbatim: marker).frame(minWidth: 18, alignment: .trailing); RichInline.markdown(value).checklistFont(role).textSelection(.enabled) }
                case .code(let language, let value):
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        if !language.isEmpty { Text(verbatim: language).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
                        ScrollView(.horizontal) { Text(verbatim: value).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                    }.padding(8).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows): RichTableBlock(headers: rows.first ?? [], rows: Array(rows.dropFirst()), caption: "", inlineMarkdown: true)
                case .image(let label, _):
                    // Note images are not fetched; attached media use media blocks and previews.
                    Label(label.isEmpty ? "Image (not loaded in notes)" : label + " (image not loaded in notes)", systemImage: "photo").checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText)
                case .rule: Divider()
                }
            }
            ForEach(document.warnings, id: \.self) { Text($0).checklistFont(.micro).foregroundStyle(.orange) }
        }
    }
}

struct RichTableBlock: View {
    let headers: [String]
    let rows: [[String]]
    let caption: String
    var inlineMarkdown = false
    func cell(_ value: String) -> Text { inlineMarkdown ? RichInline.markdown(value) : Text(verbatim: value) }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if !caption.isEmpty { Text(verbatim: caption).checklistFont(.captionStrong) }
            // Wide tables scroll inside their block; the composer and controls stay reachable.
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(Array(headers.enumerated()), id: \.offset) { _, header in cell(header).fontWeight(.semibold).accessibilityAddTraits(.isHeader) } }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            cell(value).textSelection(.enabled).accessibilityLabel(index < headers.count ? headers[index] + ": " + value : value)
                        } }
                    }
                }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
        }.checklistFont(.callout).accessibilityElement(children: .contain).accessibilityLabel(caption.isEmpty ? "Table" : "Table: " + caption)
    }
}

struct RichChartBlock: View {
    let kind: String
    let xLabel: String
    let yLabel: String
    let xUnit: String
    let yUnit: String
    let series: [RichChartSeries]
    let caption: String
    struct Mark: Identifiable { let id: Int; let series: String; let x: String; let xValue: Double?; let y: Double }
    var marks: [Mark] {
        var result: [Mark] = []
        for entry in series { for point in entry.points { result.append(Mark(id: result.count, series: entry.label, x: point.x, xValue: point.xValue, y: point.y)) } }
        return result
    }
    func axis(_ label: String, _ unit: String) -> String { unit.isEmpty ? label : "\(label) (\(unit))" }
    var summary: String { "\(kind.capitalized) chart of \(axis(yLabel, yUnit)) by \(axis(xLabel, xUnit)), \(series.count) series, \(marks.count) points" }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if !caption.isEmpty { Text(verbatim: caption).checklistFont(.captionStrong) }
            // Typed data only: the bundled renderer draws declared marks, no supplied expressions.
            Chart(marks) { mark in
                switch kind {
                case "bar": BarMark(x: .value(xLabel, mark.x), y: .value(yLabel, mark.y)).foregroundStyle(by: .value("Series", mark.series))
                case "line": LineMark(x: .value(xLabel, mark.xValue ?? 0), y: .value(yLabel, mark.y)).foregroundStyle(by: .value("Series", mark.series)).symbol(by: .value("Series", mark.series))
                default: PointMark(x: .value(xLabel, mark.xValue ?? 0), y: .value(yLabel, mark.y)).foregroundStyle(by: .value("Series", mark.series)).symbol(by: .value("Series", mark.series))
                }
            }
            .chartXAxisLabel(axis(xLabel, xUnit)).chartYAxisLabel(axis(yLabel, yUnit))
            .frame(minHeight: 160, maxHeight: 220)
            .accessibilityLabel(summary)
            DisclosureGroup("Chart data") {
                RichTableBlock(headers: ["Series", axis(xLabel, xUnit), axis(yLabel, yUnit)], rows: marks.map { [$0.series, $0.x, RichChartBlock.number($0.y)] }, caption: "")
            }.checklistFont(.micro)
        }
    }
    static func number(_ value: Double) -> String { value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value) }
}

/// Native adapter for the parsed safe HTML model. No web view, script, resource load or bridge.
struct RichHTMLBlock: View {
    let blocks: [SafeHTMLBlock]
    let fallback: String
    func styled(_ text: Text, _ style: SafeHTMLStyle) -> some View {
        text.bold(style.bold).italic(style.italic)
            .foregroundStyle(style.color.flatMap(RichHTMLBlock.color) ?? Color.primary)
            .multilineTextAlignment(style.alignment == "center" ? .center : ["right", "end"].contains(style.alignment) ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: style.alignment == "center" ? .center : ["right", "end"].contains(style.alignment) ? .trailing : .leading)
            .textSelection(.enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let runs, let style): styled(RichInline.runs(runs).font(level <= 2 ? .headline : .subheadline.bold()), style).accessibilityAddTraits(.isHeader)
                case .paragraph(let runs, let style): styled(RichInline.runs(runs), style)
                case .listItem(let marker, let depth, let runs, let style): HStack(alignment: .firstTextBaseline) { Text(verbatim: marker).frame(minWidth: 18, alignment: .trailing); styled(RichInline.runs(runs), style) }.padding(.leading, CGFloat(min(depth, 6)) * 14)
                case .quote(let runs, let style): HStack { Rectangle().fill(.secondary).frame(width: 3); styled(RichInline.runs(runs).italic(), style) }
                case .code(let value): ScrollView(.horizontal) { Text(verbatim: value).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }.padding(8).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                case .table(let caption, let rows, let headerRows):
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        if !caption.isEmpty { Text(verbatim: caption).checklistFont(.captionStrong) }
                        ScrollView(.horizontal) {
                            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                                ForEach(Array(rows.enumerated()), id: \.offset) { number, row in
                                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in RichInline.runs(cell).fontWeight(number < headerRows ? .semibold : .regular).textSelection(.enabled) } }
                                    if number + 1 == headerRows { Divider().gridCellUnsizedAxes(.horizontal) }
                                }
                            }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.accessibilityElement(children: .contain).accessibilityLabel(caption.isEmpty ? "Table" : "Table: " + caption)
                case .rule: Divider()
                }
            }
        }.checklistFont(.callout).accessibilityElement(children: .contain).accessibilityHint(fallback.prefix(300).isEmpty ? "" : "Text equivalent: " + String(fallback.prefix(300)))
    }
    static func color(_ hex: String) -> Color? {
        var digits = String(hex.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? value >> 8 : value
        let alpha = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
        return Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }
}

/// Media blocks reuse the CL-121 attachment row: verified copy, type detection,
/// availability/hold state, Preview and explicit Open in…. Nothing loads implicitly.
struct RichMediaBlock: View {
    @EnvironmentObject var store: ChecklistStore
    let ref: RichMediaReference
    let caption: String
    let fallback: String
    let task: Record?
    var file: Record? { task.flatMap { RichMediaBlock.resolve(ref, in: store.detailRecords("attachments", task: $0), task: $0) } }
    static func resolve(_ ref: RichMediaReference, in files: [Record], task: Record) -> Record? {
        let matches = files.filter { Data($0.id.utf8) == Data(ref.attachmentID.utf8) }
        guard matches.count == 1, let file = matches.first, file.string("sha256") == ref.sha256,
              Data(file.string("task_id").utf8) == Data(task.id.utf8), !file.bool("unlinked") else { return nil }
        return file
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let file { AttachmentRow(file: file) }
            else {
                Label("Attachment unavailable for this ticket", systemImage: "paperclip.badge.ellipsis").checklistFont(.micro).foregroundStyle(.orange)
                Text(verbatim: fallback).checklistFont(.callout).textSelection(.enabled)
            }
            if !caption.isEmpty { Text(verbatim: caption).checklistFont(.micro).foregroundStyle(Color.checklistSecondaryText) }
        }
    }
}
