import Foundation

/// Portable presentation values. Detection, renderer selection and file authority are separate:
/// a descriptor never grants file access and no preview operation records a verdict.
public enum FilePreviewKind: String, Codable, Sendable, CaseIterable {
    case markdown, image, video, audio, pdf, text, unsupported

    public static func detect(name: String, contentType: String = "") -> Self {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        // Active vector/HTML content is source text, even if its MIME type says image.
        if ["svg", "html", "htm", "xml"].contains(ext) { return .text }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "avif"].contains(ext) { return .image }
        if ["mov", "mp4", "m4v", "mpeg", "mpg"].contains(ext) { return .video }
        if ["wav", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac", "ogg"].contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if ["txt", "log", "out", "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "swift", "rs", "go", "py", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh", "css", "sql", "ini", "plist"].contains(ext) { return .text }
        switch contentType.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "text/markdown": return .markdown
        case "application/pdf": return .pdf
        case "image/svg+xml", "text/html", "application/xml", "application/json": return .text
        case let mime where mime.hasPrefix("image/"): return .image
        case let mime where mime.hasPrefix("video/"): return .video
        case let mime where mime.hasPrefix("audio/"): return .audio
        case let mime where mime.hasPrefix("text/"): return .text
        default: return .unsupported
        }
    }
}

public struct FilePreviewPresentation: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable { case document, image, playback, pages, file }
    public enum Scale: String, Codable, Sendable { case fit, actualPixels = "actual_pixels" }
    public var layout: Layout
    public var scale: Scale
    public var nearestNeighbor: Bool
    public var showsSource: Bool
    public var accessibleLabel: String
    public init(kind: FilePreviewKind, scale: Scale = .fit, nearestNeighbor: Bool = false, accessibleLabel: String = "") {
        layout = switch kind { case .markdown, .text: .document; case .image: .image; case .video, .audio: .playback; case .pdf: .pages; case .unsupported: .file }
        self.scale = scale; self.nearestNeighbor = nearestNeighbor
        showsSource = kind == .markdown; self.accessibleLabel = accessibleLabel
    }
    /// A schema may choose display preferences, never a different decoder or file path.
    public static func resolved(kind: FilePreviewKind, metadata: [String: Any]) -> Self {
        var value = Self(kind: kind)
        if let scale = metadata["scale"] as? String { value.scale = Scale(rawValue: scale) ?? .fit }
        value.nearestNeighbor = metadata["nearest_neighbor"] as? Bool ?? false
        value.accessibleLabel = String((metadata["accessible_label"] as? String ?? "").prefix(512))
        return value
    }
}

extension MediaReviewSchema {
    /// Adapter from the existing portable review-slot contract. Public taskless
    /// media activation still belongs to its own capture/context composition.
    func filePreviewPresentation(slotID: MediaReviewID, filename: String = "", metadata: [String: Any] = [:]) -> FilePreviewPresentation? {
        guard let slot = slots.first(where: { $0.id == slotID }) else { return nil }
        let kind: FilePreviewKind
        switch slot.kind {
        case .image: kind = .image
        case .video: kind = .video
        case .audio: kind = .audio
        case .text: kind = FilePreviewKind.detect(name: filename) == .markdown ? .markdown : .text
        }
        var result = FilePreviewPresentation.resolved(kind: kind, metadata: metadata)
        if result.accessibleLabel.isEmpty { result.accessibleLabel = slot.label }
        return result
    }
}

public enum FilePreviewLimits {
    public static let fileBytes = 500 * 1024 * 1024
    public static let textBytes = 2 * 1024 * 1024
    public static let pdfBytes = 50 * 1024 * 1024
    public static let imagePixels = 80_000_000
    public static let imageFrames = 1_000
}

public struct FilePreviewCapability: Equatable, Sendable {
    public let builtIn: Bool
    public let reason: String?
    public let requiresDecoderProbe: Bool
    public static func assess(kind: FilePreviewKind, size: Int) -> Self {
        if size < 0 || size > FilePreviewLimits.fileBytes { return Self(builtIn: false, reason: "The file exceeds the 500 MiB preview limit or its size is unknown.", requiresDecoderProbe: false) }
        if [.markdown, .text].contains(kind), size > FilePreviewLimits.textBytes { return Self(builtIn: false, reason: "Text previews are limited to 2 MiB. Use Open in… for the complete file.", requiresDecoderProbe: false) }
        if kind == .pdf, size > FilePreviewLimits.pdfBytes { return Self(builtIn: false, reason: "PDF previews are limited to 50 MiB and 2,000 pages. Use Open in… for the complete file.", requiresDecoderProbe: false) }
        if kind == .unsupported { return Self(builtIn: false, reason: "This type has no built-in preview. Use Open in… to choose a compatible app.", requiresDecoderProbe: false) }
        return Self(builtIn: true, reason: nil, requiresDecoderProbe: [.image, .video, .audio, .pdf].contains(kind))
    }
}

/// Only already-enrolled attachment names/IDs may resolve as document resources.
/// This deliberately does not turn the document's directory into a filesystem grant.
public enum MarkdownResource: Equatable, Sendable {
    case attachment(String), externalLink(URL), anchor(String), unavailable(String)
    public static func resolve(_ destination: String, image: Bool, attachments: [String: String]) -> Self {
        guard destination.utf8.count <= 4096, !destination.contains("\\"),
              !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .unavailable("Invalid resource") }
        if destination.hasPrefix("#"), !image { return .anchor(String(destination.dropFirst())) }
        if let url = URL(string: destination), let scheme = url.scheme {
            if ["https", "http"].contains(scheme.lowercased()), url.host != nil {
                return image ? .unavailable("Remote image blocked; no network request was made") : .externalLink(url)
            }
            return .unavailable("This URL scheme is not permitted")
        }
        guard let decoded = destination.removingPercentEncoding, !decoded.hasPrefix("/"),
              !decoded.contains("\\"), !decoded.contains(":"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else { return .unavailable("Resource is outside the authorized attachments") }
        let key = decoded.hasPrefix("./") ? String(decoded.dropFirst(2)) : decoded
        guard let entry = attachments.first(where: { Data($0.key.utf8) == Data(key.utf8) }) else { return .unavailable("Resource is not an explicitly attached file") }
        return .attachment(entry.value)
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(Int, String), paragraph(String), quote(String), list(String, String)
    case code(String, String), table([[String]]), image(String, String), rule
}

/// Bounded document parser. Inline emphasis/code/links are handled by the native
/// attributed-text renderer; HTML is always literal text, never a web document.
public struct MarkdownDocument: Sendable {
    public let blocks: [MarkdownBlock]
    public let warnings: [String]
    public static func parse(_ source: String, isCanceled: () -> Bool = { false }) -> Self {
        guard source.utf8.count <= FilePreviewLimits.textBytes else { return Self(blocks: [], warnings: ["This document exceeds the 2 MiB rendered-text limit. Use Open in… to inspect a working copy."]) }
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = [], warnings: [String] = [], i = 0
        let imageExpression = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^\s)]+)\)"#)
        func cells(_ line: String) -> [String] {
            var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }; if parts.last == "" { parts.removeLast() }
            return parts
        }
        while i < lines.count, blocks.count < 4096 {
            if isCanceled() { return Self(blocks: [], warnings: ["Preview canceled"]) }
            let line = lines[i], trim = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if trim.isEmpty { continue }
            if trim.hasPrefix("```") || trim.hasPrefix("~~~") {
                let fence = String(trim.prefix(3)), language = String(trim.dropFirst(3))
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 } else { warnings.append("Unclosed code fence is shown as code.") }
                blocks.append(.code(language, code.joined(separator: "\n"))); continue
            }
            let hashes = trim.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trim.dropFirst(hashes).first == " " { blocks.append(.heading(hashes, String(trim.dropFirst(hashes + 1)))); continue }
            if ["---", "***", "___"].contains(trim) { blocks.append(.rule); continue }
            if trim.hasPrefix(">") { blocks.append(.quote(String(trim.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            if i < lines.count, trim.contains("|"), cells(lines[i]).count > 1,
               cells(lines[i]).allSatisfy({ $0.contains("-") && $0.allSatisfy { "-: ".contains($0) } }) {
                var rows = [cells(trim)]; i += 1
                while i < lines.count, lines[i].contains("|"), rows.count < 200 { rows.append(cells(lines[i])); i += 1 }
                if rows.allSatisfy({ $0.count == rows[0].count }), rows[0].count <= 20 { blocks.append(.table(rows)) }
                else { blocks.append(.paragraph(rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))); warnings.append("Malformed or oversized table shown as text.") }
                continue
            }
            if trim.hasPrefix("- ") || trim.hasPrefix("* ") || trim.hasPrefix("+ ") { blocks.append(.list("•", String(trim.dropFirst(2)))); continue }
            if let dot = trim.firstIndex(of: "."), !trim[..<dot].isEmpty, trim[..<dot].allSatisfy(\.isNumber), trim[trim.index(after: dot)...].hasPrefix(" ") {
                blocks.append(.list(String(trim[...dot]), String(trim[trim.index(after: dot)...].dropFirst()))); continue
            }
            // Preserve line boundaries; unsupported constructs remain readable source text.
            if let expression = imageExpression {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let matches = expression.matches(in: line, range: range).prefix(max(0, min(128, (4095 - blocks.count) / 2)))
                if !matches.isEmpty {
                    var offset = line.startIndex
                    for match in matches {
                        guard let entire = Range(match.range, in: line), let alt = Range(match.range(at: 1), in: line), let destination = Range(match.range(at: 2), in: line) else { continue }
                        if offset < entire.lowerBound { blocks.append(.paragraph(String(line[offset..<entire.lowerBound]))) }
                        blocks.append(.image(String(line[alt]), String(line[destination]))); offset = entire.upperBound
                    }
                    if offset < line.endIndex { blocks.append(.paragraph(String(line[offset...]))) }
                    continue
                }
            }
            blocks.append(.paragraph(line))
        }
        if i < lines.count { warnings.append("Only the first 4,096 document blocks are rendered. Open the source for the remainder.") }
        return Self(blocks: blocks, warnings: warnings)
    }
}
