import SwiftUI
import AppKit
import ChecklistCore

struct TextDocumentPreview: View {
    @EnvironmentObject var store: ChecklistStore
    let file: AuthorizedPreviewFile
    let markdown: Bool
    var resources: [Record] = []
    @State private var text = ""
    @State private var document: MarkdownDocument?
    @State private var problem = ""
    @State private var loading = true
    @State private var loadedResources: [Record] = []
    @State private var resourcesLoading = false
    @State private var resourceProblem = ""
    var body: some View {
        VStack {
        Group {
            if loading { ProgressView("Reading document…") }
            else if !problem.isEmpty { Text(problem).foregroundStyle(.orange).textSelection(.enabled) }
            else if markdown, let document { RenderedMarkdownPreview(document: document, resources: loadedResources, source: file.source) }
            else { ScrollView([.horizontal, .vertical]) { Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() } }
        }
        if resourcesLoading { ProgressView("Loading ticket attachment resources…").font(.caption) }
        if !resourceProblem.isEmpty { Text(resourceProblem).font(.caption).foregroundStyle(.orange) }
        }.task(id: file.url.path + String(markdown)) {
            loading = true; problem = ""; loadedResources = []; resourceProblem = ""; resourcesLoading = false
            let work = Task.detached(priority: .userInitiated) { () throws -> (String, MarkdownDocument?) in
                try Task.checkCancellation()
                guard file.source.integer("size", fallback: -1) <= FilePreviewLimits.textBytes else { throw FilePreviewFailure("Text previews are limited to 2 MiB. Use Open in… to inspect a working copy.") }
                let bytes = try Data(contentsOf: file.url)
                guard bytes.count <= FilePreviewLimits.textBytes, let value = String(data: bytes, encoding: .utf8), !value.contains("\0") else { throw FilePreviewFailure("The file is not bounded UTF-8 text. Use Open in… for another viewer.") }
                return (value, markdown ? MarkdownDocument.parse(value, isCanceled: { Task.isCancelled }) : nil)
            }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation(); text = value.0; document = value.1; loading = false
                if markdown {
                    resourcesLoading = true
                    do {
                        let files = try await MarkdownPreviewResources.load(source: file.source, seed: resources) { method, params in
                            try await store.request(method, params)
                        }
                        try Task.checkCancellation(); loadedResources = files
                    } catch { if !Task.isCancelled { resourceProblem = "Attached resources are unavailable: " + PlainError.text(error) } }
                    if !Task.isCancelled { resourcesLoading = false }
                }
            } catch { if !Task.isCancelled { problem = PlainError.text(error); loading = false } }
        }
    }
}

struct RenderedMarkdownPreview: View {
    let document: MarkdownDocument
    let resources: [Record]
    let source: Record
    @State private var linkedAttachment: Record?
    @State private var linkProblem = ""
    var permittedFiles: [Record] { resources.filter { $0.string("project_id") == source.string("project_id") && $0.string("task_id") == source.string("task_id") && !$0.bool("unlinked") } }
    var resourceMap: [String: String] {
        var result: [String: String] = [:]
        // Canonically equivalent spellings collide in a Swift Dictionary. Treat
        // that set as ambiguous too, rather than route one name to another file.
        let grouped = Dictionary(grouping: permittedFiles, by: { $0.string("name") })
        for values in grouped.values where values.count == 1 { result[values[0].string("name")] = values[0].id }
        return result
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                    render(block, index: index).id(anchor(for: block))
                }
                ForEach(document.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if !linkProblem.isEmpty { Text(linkProblem).font(.caption).foregroundStyle(.orange) }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }.environment(\.openURL, OpenURLAction { url in follow(url.absoluteString, scroll: { proxy.scrollTo($0, anchor: .top) }); return .handled })
            .sheet(item: $linkedAttachment) { FilePreviewSheet(attachment: $0, resources: permittedFiles) }
        }
    }
    @ViewBuilder func render(_ block: MarkdownBlock, index: Int) -> some View {
        switch block {
        case .heading(let level, let value): inline(value).font(level <= 2 ? .title2.bold() : .headline).accessibilityAddTraits(.isHeader)
        case .paragraph(let value): inline(value).textSelection(.enabled)
        case .quote(let value): HStack { Rectangle().fill(.secondary).frame(width: 3); inline(value).italic().textSelection(.enabled) }.padding(.leading, 8)
        case .list(let marker, let value): HStack(alignment: .firstTextBaseline) { Text(marker).frame(minWidth: 20, alignment: .trailing); inline(value).textSelection(.enabled) }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 4) {
                if !language.isEmpty { Text(verbatim: language).font(.caption).foregroundStyle(.secondary) }
                ScrollView(.horizontal) { Text(verbatim: value).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }.padding(10).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { number, cells in
                        GridRow { ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in inline(cell).fontWeight(number == 0 ? .semibold : .regular).textSelection(.enabled) } }
                        if number == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
        case .image(let label, let destination):
            if index < 100, case .attachment(let id) = MarkdownResource.resolve(destination, image: true, attachments: resourceMap),
               let file = permittedFiles.first(where: { $0.id == id }), FilePreviewKind.detect(name: file.string("name")) == .image {
                MarkdownAttachedImage(file: file, label: label)
            } else {
                Label(label.isEmpty ? "Image" : label, systemImage: "photo").font(.callout)
                Text(imageReason(destination, index: index)).font(.caption).foregroundStyle(.secondary)
                if case .attachment(let id) = MarkdownResource.resolve(destination, image: true, attachments: resourceMap), let file = permittedFiles.first(where: { $0.id == id }) {
                    Button("Open attached image…") { linkedAttachment = file }
                }
            }
        case .rule: Divider()
        }
    }
    func inline(_ text: String) -> Text {
        // Bound inline-parser work per block. Unsupported HTML remains visible text.
        guard text.utf8.count < 32_768, !text.contains("<") else { return Text(verbatim: text) }
        let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return value.map(Text.init) ?? Text(verbatim: text)
    }
    func anchor(for block: MarkdownBlock) -> String {
        guard case .heading(_, let text) = block else { return "block-" + String(describing: block) }
        return text.lowercased().replacingOccurrences(of: " ", with: "-")
    }
    func imageReason(_ destination: String, index: Int) -> String {
        if index >= 100 { return "Embedded-image budget reached. Open the attachment separately." }
        if case .unavailable(let reason) = MarkdownResource.resolve(destination, image: true, attachments: resourceMap) { return reason }
        return "This resource is not an available supported image attachment."
    }
    func follow(_ destination: String, scroll: (String) -> Void) {
        switch MarkdownResource.resolve(destination, image: false, attachments: resourceMap) {
        case .attachment(let id): linkedAttachment = permittedFiles.first { $0.id == id }
        case .externalLink(let url): if !NSWorkspace.shared.open(url) { linkProblem = "macOS could not open this link." }
        case .anchor(let id): scroll(id)
        case .unavailable(let reason): linkProblem = reason
        }
    }
}

private struct MarkdownAttachedImage: View {
    @EnvironmentObject var store: ChecklistStore
    let file: Record
    let label: String
    @StateObject private var loader = FilePreviewLoader()
    @State private var showing = false
    var bounded: Bool { (0...(25 * 1024 * 1024)).contains(file.integer("size", fallback: -1)) }
    var body: some View {
        VStack(alignment: .leading) {
            if !bounded {
                Text("This image exceeds the 25 MiB embedded-preview limit.").font(.caption).foregroundStyle(.secondary)
                Button("Preview attached image…") { showing = true }
            } else if let verified = loader.file { NativeImagePreview(url: verified.url).frame(height: 280).accessibilityLabel(label.isEmpty ? file.string("name") : label) }
            else if loader.loading { ProgressView("Loading attached image…") }
            else { Text(loader.problem).font(.caption).foregroundStyle(.orange) }
            if loader.file != nil, !loader.problem.isEmpty { Text(loader.problem).font(.caption).foregroundStyle(.orange) }
            Text(label.isEmpty ? file.string("name") : label).font(.caption).foregroundStyle(.secondary)
        }.task(id: file.id) { if bounded { await loader.load(file, store: store) } }.onDisappear { loader.cancel() }
            .sheet(isPresented: $showing) { FilePreviewSheet(attachment: file) }
    }
}

/// Preview resources are ticket attachments, independent of a submission's refs.
enum MarkdownPreviewResources {
    static func load(source: Record, seed: [Record], request: (String, [String: Any]) async throws -> [String: Any]) async throws -> [Record] {
        guard !source.string("project_id").isEmpty, !source.string("task_id").isEmpty else {
            throw FilePreviewFailure("This document has no ticket attachment scope.")
        }
        // Current-action records contain only submitted refs. Ask for the ticket's
        // full metadata set so an omitted duplicate cannot silently authorize a name.
        let reply = try await request("attachment_list", ["project_id": source.string("project_id"), "task_id": source.string("task_id")])
        try Task.checkCancellation()
        guard let rows = reply["attachments"] as? [[String: Any]], rows.count <= 1000,
              reply["has_more"] as? Bool != true, reply["next_cursor"] as? String == nil else {
            throw FilePreviewFailure("A complete set of at most 1,000 ticket attachments is required to resolve document resources.")
        }
        return rows.map(Record.init).filter {
            Data($0.string("project_id").utf8) == Data(source.string("project_id").utf8) &&
            Data($0.string("task_id").utf8) == Data(source.string("task_id").utf8) && !$0.bool("unlinked")
        }.map { file in
            // Preserve supplied target attribution only for the same immutable file;
            // current service metadata remains authoritative for access and names.
            guard let known = seed.first(where: { Data($0.id.utf8) == Data(file.id.utf8) && $0.string("sha256") == file.string("sha256") }) else { return file }
            var values = file.values
            for key in ["target_manifest_id", "review_attempt_id"] { if let value = known.values[key] { values[key] = value } }
            return Record(values: values)
        }
    }
}
