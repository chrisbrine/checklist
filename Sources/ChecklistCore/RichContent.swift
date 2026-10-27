import Foundation
import CryptoKit

/// Optional rich content (CL-127, contract docs/conversation-content.md). The plain
/// string stays the record of meaning; a v1 envelope is a validated presentation
/// companion. Nothing here executes, fetches, reads files or records authority.
public enum RichContentLimits {
    public static let schemaVersion = 1
    public static let blocks = 32
    public static let blockIDBytes = 64
    public static let fallbackBytes = 65_536
    public static let messageBytes = 262_144
    public static let columns = 20
    public static let tableRows = 200
    public static let cellBytes = 2_000
    public static let labelBytes = 2_000
    public static let unitBytes = 200
    public static let captionBytes = 4_000
    public static let series = 20
    public static let points = 1_000
    public static let htmlBytes = 65_536
    public static let cssBytes = 16_384
    public static let htmlNodes = 2_000
    public static let htmlDepth = 32
    public static let cssRules = 128
    /// Text above this size renders as bounded plain text; Copy source keeps all bytes.
    public static let renderedTextBytes = 262_144
}

public enum RichContentBlockType: String, CaseIterable, Sendable { case markdown, table, chart, html, media }

/// Explicit per-field capability metadata. A field renders only what it declares;
/// IDs, keys, enum values and other scalar data use `.plain` and stay verbatim.
public struct RichFieldCapability: Equatable, Sendable {
    public let field: String
    /// The advertised companion parameter, when the field's command accepts one.
    public let companion: String?
    public let markdown: Bool
    public let blockTypes: Set<RichContentBlockType>
    public init(field: String, companion: String?, markdown: Bool, blockTypes: Set<RichContentBlockType>) {
        self.field = field; self.companion = companion; self.markdown = markdown; self.blockTypes = blockTypes
    }
    public static let plain = Self(field: "scalar", companion: nil, markdown: false, blockTypes: [])
    /// Ticket and Triage notes (message_send `body` + `content`).
    public static let note = Self(field: "message.body", companion: "content", markdown: true, blockTypes: Set(RichContentBlockType.allCases))
    public static let ticketBrief = Self(field: "task.brief", companion: nil, markdown: true, blockTypes: [])
    public static let triagePurpose = Self(field: "triage.purpose", companion: nil, markdown: true, blockTypes: [])
    public static let reviewExplanation = Self(field: "review.reason", companion: nil, markdown: true, blockTypes: [])
    public static let requestExplanation = Self(field: "human_request.explanation", companion: nil, markdown: true, blockTypes: [])
    public static let all: [Self] = [.plain, .note, .ticketBrief, .triagePurpose, .reviewExplanation, .requestExplanation]
}

public struct RichContentColumn: Equatable, Sendable { public let id: String; public let label: String }
public struct RichChartPoint: Equatable, Sendable { public let x: String; public let xValue: Double?; public let y: Double }
public struct RichChartSeries: Equatable, Sendable { public let label: String; public let points: [RichChartPoint] }
public struct RichMediaReference: Equatable, Sendable {
    public let attachmentID: String; public let sha256: String; public let representation: String; public let mediaKind: String
    public init(attachmentID: String, sha256: String, representation: String, mediaKind: String) {
        self.attachmentID = attachmentID; self.sha256 = sha256; self.representation = representation; self.mediaKind = mediaKind
    }
}

public enum RichContentPayload: Equatable, Sendable {
    case markdown
    case table(columns: [RichContentColumn], rows: [[String]], caption: String)
    case chart(kind: String, xLabel: String, yLabel: String, xUnit: String, yUnit: String, series: [RichChartSeries], caption: String)
    case html(SafeHTMLDocument)
    case media(RichMediaReference, caption: String)
}

public struct RichContentBlock: Equatable, Sendable {
    public let id: String
    public let type: RichContentBlockType
    public let fallback: String
    public let payload: RichContentPayload
}

/// A validated v1 envelope. `source` keeps the accepted JSON object for lossless storage/export.
public struct RichContentEnvelope: @unchecked Sendable {
    public let blocks: [RichContentBlock]
    public let source: [String: Any]

    static func failure(_ path: String, _ reason: String) -> CoreError {
        CoreError("INVALID_CONTENT", "\(path): \(reason)", details: ["path": path, "reason": reason])
    }

    /// Closed v1 validation. `text` is the containing plain string; it must equal the
    /// fallbacks joined with two LF bytes. Unknown versions are refused for new writes.
    public static func validate(_ value: Any, text: String, capability: RichFieldCapability = .note, isCanceled: () -> Bool = { false }) throws -> Self {
        guard let object = value as? [String: Any], !object.isEmpty else { throw failure("content", "must be a non-empty object") }
        try closed(object, ["schema_version", "blocks"], path: "content")
        guard let version = object["schema_version"] as? NSNumber, !isBool(version), version.doubleValue == 1 else {
            throw CoreError("CONTENT_VERSION_UNSUPPORTED", "content.schema_version: only version 1 is accepted for new writes.", details: ["path": "content.schema_version"])
        }
        guard let rows = object["blocks"] as? [Any], (1...RichContentLimits.blocks).contains(rows.count) else { throw failure("content.blocks", "must contain 1–32 blocks") }
        var blocks: [RichContentBlock] = [], ids = Set<String>()
        var tableRows = 0, points = 0, nodes = 0, cssRules = 0
        for (index, row) in rows.enumerated() {
            if isCanceled() { throw CoreError("CONTENT_CANCELED", "Content validation was canceled.") }
            let path = "content.blocks[\(index)]"
            guard let block = row as? [String: Any] else { throw failure(path, "must be an object") }
            let id = try string(block, "block_id", path: path, max: RichContentLimits.blockIDBytes)
            guard !id.isEmpty, id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }),
                  id.unicodeScalars.first.map({ CharacterSet.alphanumerics.contains($0) }) == true else { throw failure(path + ".block_id", "must be an ASCII identifier") }
            guard ids.insert(id).inserted else { throw failure(path + ".block_id", "duplicates another block") }
            guard let typeName = block["type"] as? String, let type = RichContentBlockType(rawValue: typeName) else { throw failure(path + ".type", "unsupported block type") }
            guard capability.blockTypes.contains(type) else { throw failure(path + ".type", "\(typeName) blocks are not supported by \(capability.field)") }
            let fallback = try string(block, "fallback", path: path, max: RichContentLimits.fallbackBytes)
            let payload: RichContentPayload
            switch type {
            case .markdown:
                try closed(block, ["block_id", "type", "fallback"], path: path); payload = .markdown
            case .table:
                try closed(block, ["block_id", "type", "fallback", "columns", "rows", "caption"], path: path)
                guard let columnRows = block["columns"] as? [Any], (1...RichContentLimits.columns).contains(columnRows.count) else { throw failure(path + ".columns", "must contain 1–20 columns") }
                var columns: [RichContentColumn] = []
                for (number, column) in columnRows.enumerated() {
                    guard let column = column as? [String: Any] else { throw failure(path + ".columns[\(number)]", "must be an object") }
                    try closed(column, ["id", "label"], path: path + ".columns[\(number)]")
                    let value = RichContentColumn(id: try string(column, "id", path: path + ".columns[\(number)]", max: 200), label: try string(column, "label", path: path + ".columns[\(number)]", max: RichContentLimits.labelBytes))
                    guard !value.id.isEmpty, !columns.contains(where: { $0.id == value.id }) else { throw failure(path + ".columns[\(number)].id", "must be a distinct non-empty string") }
                    columns.append(value)
                }
                guard let cellRows = block["rows"] as? [Any] else { throw failure(path + ".rows", "must be an array") }
                tableRows += cellRows.count
                guard tableRows <= RichContentLimits.tableRows else { throw failure(path + ".rows", "the message exceeds 200 table rows") }
                var cells: [[String]] = []
                for (number, cellRow) in cellRows.enumerated() {
                    guard let values = cellRow as? [Any], values.count == columns.count else { throw failure(path + ".rows[\(number)]", "must have exactly one cell per column") }
                    cells.append(try values.enumerated().map { cell in
                        guard let text = cell.element as? String, text.utf8.count <= RichContentLimits.cellBytes else { throw failure(path + ".rows[\(number)][\(cell.offset)]", "must be text of at most 2,000 bytes") }
                        return text
                    })
                }
                payload = .table(columns: columns, rows: cells, caption: try optionalString(block, "caption", path: path, max: RichContentLimits.captionBytes))
            case .chart:
                try closed(block, ["block_id", "type", "fallback", "chart_kind", "x_label", "y_label", "series", "x_unit", "y_unit", "caption"], path: path)
                guard let kind = block["chart_kind"] as? String, ["bar", "line", "scatter"].contains(kind) else { throw failure(path + ".chart_kind", "must be bar, line or scatter") }
                guard let seriesRows = block["series"] as? [Any], (1...RichContentLimits.series).contains(seriesRows.count) else { throw failure(path + ".series", "must contain 1–20 series") }
                var series: [RichChartSeries] = []
                for (number, entry) in seriesRows.enumerated() {
                    let seriesPath = path + ".series[\(number)]"
                    guard let entry = entry as? [String: Any] else { throw failure(seriesPath, "must be an object") }
                    try closed(entry, ["label", "points"], path: seriesPath)
                    guard let pointRows = entry["points"] as? [Any] else { throw failure(seriesPath + ".points", "must be an array") }
                    points += pointRows.count
                    guard points <= RichContentLimits.points else { throw failure(seriesPath + ".points", "the message exceeds 1,000 chart points") }
                    var values: [RichChartPoint] = []
                    for (pointNumber, point) in pointRows.enumerated() {
                        let pointPath = seriesPath + ".points[\(pointNumber)]"
                        guard let point = point as? [String: Any] else { throw failure(pointPath, "must be an object") }
                        try closed(point, ["x", "y"], path: pointPath)
                        let y = try finite(point["y"], path: pointPath + ".y")
                        if kind == "bar" {
                            guard let x = point["x"] as? String, x.utf8.count <= RichContentLimits.labelBytes else { throw failure(pointPath + ".x", "bar x must be text") }
                            values.append(RichChartPoint(x: x, xValue: nil, y: y))
                        } else {
                            let x = try finite(point["x"], path: pointPath + ".x")
                            values.append(RichChartPoint(x: canonicalNumber(x), xValue: x, y: y))
                        }
                    }
                    series.append(RichChartSeries(label: try string(entry, "label", path: seriesPath, max: RichContentLimits.labelBytes), points: values))
                }
                payload = .chart(kind: kind, xLabel: try string(block, "x_label", path: path, max: RichContentLimits.labelBytes), yLabel: try string(block, "y_label", path: path, max: RichContentLimits.labelBytes),
                                 xUnit: try optionalString(block, "x_unit", path: path, max: RichContentLimits.unitBytes), yUnit: try optionalString(block, "y_unit", path: path, max: RichContentLimits.unitBytes),
                                 series: series, caption: try optionalString(block, "caption", path: path, max: RichContentLimits.captionBytes))
            case .html:
                try closed(block, ["block_id", "type", "fallback", "html", "css"], path: path)
                let html = try string(block, "html", path: path, max: RichContentLimits.htmlBytes)
                let css = try string(block, "css", path: path, max: RichContentLimits.cssBytes)
                let document: SafeHTMLDocument
                do { document = try SafeHTMLDocument.parse(html: html, css: css, isCanceled: isCanceled) }
                catch let error as SafeHTMLError { throw failure(path + "." + error.field, error.reason) }
                nodes += document.nodeCount; cssRules += document.rules.count
                guard nodes <= RichContentLimits.htmlNodes else { throw failure(path + ".html", "the message exceeds 2,000 parsed HTML nodes") }
                guard cssRules <= RichContentLimits.cssRules else { throw failure(path + ".css", "the message exceeds 128 CSS rules") }
                payload = .html(document)
            case .media:
                try closed(block, ["block_id", "type", "fallback", "attachment_ref", "media_kind", "caption"], path: path)
                guard let ref = block["attachment_ref"] as? [String: Any] else { throw failure(path + ".attachment_ref", "must be an object") }
                try closed(ref, ["attachment_id", "sha256", "representation"], path: path + ".attachment_ref")
                let attachment = try string(ref, "attachment_id", path: path + ".attachment_ref", max: 200)
                let sha = try string(ref, "sha256", path: path + ".attachment_ref", max: 64)
                guard !attachment.isEmpty, sha.count == 64, sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw failure(path + ".attachment_ref", "needs an attachment ID and a lowercase SHA-256") }
                guard let representation = ref["representation"] as? String, ["original", "preview"].contains(representation) else { throw failure(path + ".attachment_ref.representation", "must be original or preview") }
                guard let kind = block["media_kind"] as? String, ["image", "video", "audio", "pdf", "text", "file"].contains(kind) else { throw failure(path + ".media_kind", "unsupported media kind") }
                payload = .media(RichMediaReference(attachmentID: attachment, sha256: sha, representation: representation, mediaKind: kind), caption: try optionalString(block, "caption", path: path, max: RichContentLimits.captionBytes))
            }
            blocks.append(RichContentBlock(id: id, type: type, fallback: fallback, payload: payload))
        }
        let joined = blocks.map(\.fallback).joined(separator: "\n\n")
        guard Data(joined.utf8) == Data(text.utf8) else {
            throw CoreError("CONTENT_FALLBACK_MISMATCH", "The plain text must equal the block fallbacks joined with two line feeds, byte for byte.", details: ["path": "content.blocks"])
        }
        let envelope = Self(blocks: blocks, source: object)
        guard text.utf8.count + envelope.canonicalJSON().count <= RichContentLimits.messageBytes else { throw failure("content", "the text and content exceed 262,144 bytes") }
        return envelope
    }

    /// Deterministic serialization of the accepted object (sorted keys, no slash escapes).
    public func canonicalJSON() -> Data { Self.canonical(source) }
    static func canonical(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
    /// SHA-256 over the canonical pair of the plain string and the envelope.
    public static func digest(text: String, content: [String: Any]?) -> String {
        var pair: [String: Any] = ["text": text]
        if let content { pair["content"] = content }
        return SHA256.hash(data: canonical(pair)).map { String(format: "%02x", $0) }.joined()
    }

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    static func closed(_ object: [String: Any], _ keys: Set<String>, path: String) throws {
        if let extra = object.keys.sorted().first(where: { !keys.contains($0) }) { throw failure(path + "." + extra, "is not a v1 field") }
    }
    static func string(_ object: [String: Any], _ key: String, path: String, max: Int) throws -> String {
        guard let value = object[key] as? String else { throw failure(path + "." + key, "must be a string") }
        guard value.utf8.count <= max else { throw failure(path + "." + key, "exceeds \(max) bytes") }
        return value
    }
    static func optionalString(_ object: [String: Any], _ key: String, path: String, max: Int) throws -> String {
        object[key] == nil ? "" : try string(object, key, path: path, max: max)
    }
    static func finite(_ value: Any?, path: String) throws -> Double {
        guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite else { throw failure(path, "must be a finite number") }
        return number.doubleValue
    }
    static func canonicalNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

// MARK: - Static HTML/CSS (parsed allowlist model; the original markup is never executed)

public struct SafeHTMLError: Error, Equatable { public let field: String; public let reason: String }

public indirect enum SafeHTMLNode: Equatable, Sendable {
    case text(String)
    case element(tag: String, attributes: [String: String], children: [SafeHTMLNode])
}

public struct SafeCSSRule: Equatable, Sendable {
    /// Each selector is a descendant chain of steps; a step is `tag`, `.class` or `tag.class`.
    public let selectors: [[SafeCSSStep]]
    public let declarations: [String: String]
}
public struct SafeCSSStep: Equatable, Sendable { public let tag: String?; public let className: String? }

public struct SafeHTMLDocument: Equatable, Sendable {
    public let nodes: [SafeHTMLNode]
    public let rules: [SafeCSSRule]
    public let nodeCount: Int

    public static let elements: Set<String> = ["section", "div", "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "strong", "em", "b", "i", "u", "s", "br", "hr", "figure", "figcaption", "table", "caption", "thead", "tbody", "tfoot", "tr", "th", "td", "a"]
    static let voidElements: Set<String> = ["br", "hr"]
    public static let properties: Set<String> = ["color", "background-color", "font-weight", "font-style", "font-size", "line-height", "text-align", "text-decoration", "white-space", "overflow-wrap", "border", "border-color", "border-style", "border-width", "padding", "margin", "width", "max-width", "display", "gap", "flex-direction", "flex-wrap", "align-items", "justify-content", "grid-template-columns", "padding-top", "padding-right", "padding-bottom", "padding-left", "margin-top", "margin-right", "margin-bottom", "margin-left"]

    public static func parse(html: String, css: String, isCanceled: () -> Bool = { false }) throws -> Self {
        let rules = try parseCSS(css)
        return try withoutActuallyEscaping(isCanceled) { check in
            var parser = HTMLParser(source: Array(html.unicodeScalars), isCanceled: check)
            let nodes = try parser.parseDocument()
            return Self(nodes: nodes, rules: rules, nodeCount: parser.count)
        }
    }

    struct HTMLParser {
        let source: [Unicode.Scalar]
        let isCanceled: () -> Bool
        var index = 0
        var count = 0
        init(source: [Unicode.Scalar], isCanceled: @escaping () -> Bool) { self.source = source; self.isCanceled = isCanceled }

        func fail(_ reason: String) -> SafeHTMLError { SafeHTMLError(field: "html", reason: reason) }
        mutating func parseDocument() throws -> [SafeHTMLNode] {
            let (nodes, closing) = try parseChildren(depth: 0)
            guard closing == nil else { throw fail("unexpected closing tag </\(closing!)>") }
            return nodes
        }
        mutating func bump() throws {
            count += 1
            guard count <= RichContentLimits.htmlNodes else { throw fail("more than 2,000 parsed nodes") }
            if count % 64 == 0, isCanceled() { throw fail("parsing was canceled") }
        }
        /// Returns children and the closing tag name that ended them (nil at end of input).
        mutating func parseChildren(depth: Int) throws -> ([SafeHTMLNode], String?) {
            guard depth <= RichContentLimits.htmlDepth else { throw fail("nesting deeper than 32 levels") }
            var nodes: [SafeHTMLNode] = [], text = ""
            func flush(_ nodes: inout [SafeHTMLNode], _ text: inout String) throws {
                if !text.isEmpty { nodes.append(.text(text)); text = "" }
            }
            while index < source.count {
                let scalar = source[index]
                if scalar == "<" {
                    try flush(&nodes, &text)
                    let next = index + 1 < source.count ? source[index + 1] : " "
                    if next == "!" || next == "?" { throw fail("comments, declarations and processing instructions are not permitted") }
                    if next == "/" {
                        index += 2
                        let name = readName().lowercased()
                        skipSpace()
                        guard index < source.count, source[index] == ">" else { throw fail("malformed closing tag") }
                        index += 1
                        return (nodes, name)
                    }
                    index += 1
                    let tag = readName().lowercased()
                    guard !tag.isEmpty else { throw fail("a literal < must be written as &lt;") }
                    guard SafeHTMLDocument.elements.contains(tag) else { throw fail("<\(tag)> is not a permitted element") }
                    let (attributes, selfClosing) = try readAttributes(tag: tag)
                    try bump()
                    if SafeHTMLDocument.voidElements.contains(tag) || selfClosing {
                        guard SafeHTMLDocument.voidElements.contains(tag) else { throw fail("<\(tag)/> must have a closing tag") }
                        nodes.append(.element(tag: tag, attributes: attributes, children: []))
                        continue
                    }
                    let (children, closing) = try parseChildren(depth: depth + 1)
                    guard closing == tag else { throw fail(closing.map { "</\($0)> does not close <\(tag)>" } ?? "<\(tag)> is not closed") }
                    nodes.append(.element(tag: tag, attributes: attributes, children: children))
                } else if scalar == "&" {
                    text.unicodeScalars.append(contentsOf: try readEntity().unicodeScalars)
                } else {
                    if text.isEmpty { try bump() }
                    text.unicodeScalars.append(scalar); index += 1
                }
            }
            try flush(&nodes, &text)
            return (nodes, nil)
        }
        mutating func readName() -> String {
            var name = ""
            while index < source.count, CharacterSet.alphanumerics.contains(source[index]) || source[index] == "-" { name.unicodeScalars.append(source[index]); index += 1 }
            return name
        }
        mutating func skipSpace() { while index < source.count, CharacterSet.whitespacesAndNewlines.contains(source[index]) { index += 1 } }
        mutating func readAttributes(tag: String) throws -> ([String: String], Bool) {
            var attributes: [String: String] = [:]
            while true {
                skipSpace()
                guard index < source.count else { throw fail("unterminated <\(tag)> tag") }
                if source[index] == ">" { index += 1; return (attributes, false) }
                if source[index] == "/" {
                    index += 1; guard index < source.count, source[index] == ">" else { throw fail("malformed <\(tag)> tag") }
                    index += 1; return (attributes, true)
                }
                let name = readName().lowercased()
                guard !name.isEmpty else { throw fail("malformed attribute in <\(tag)>") }
                skipSpace()
                var value = ""
                if index < source.count, source[index] == "=" {
                    index += 1; skipSpace()
                    guard index < source.count, source[index] == "\"" || source[index] == "'" else { throw fail("attribute values must be quoted") }
                    let quote = source[index]; index += 1
                    while index < source.count, source[index] != quote {
                        if source[index] == "&" { value.unicodeScalars.append(contentsOf: try readEntity().unicodeScalars) }
                        else if source[index] == "<" { throw fail("< inside an attribute value") }
                        else { value.unicodeScalars.append(source[index]); index += 1 }
                    }
                    guard index < source.count else { throw fail("unterminated attribute value") }
                    index += 1
                }
                guard attributes[name] == nil else { throw fail("duplicate \(name) attribute") }
                try SafeHTMLDocument.checkAttribute(tag: tag, name: name, value: value)
                attributes[name] = value
            }
        }
        mutating func readEntity() throws -> String {
            var name = ""; index += 1
            while index < source.count, source[index] != ";", name.unicodeScalars.count < 12 { name.unicodeScalars.append(source[index]); index += 1 }
            guard index < source.count, source[index] == ";" else { throw fail("unterminated character reference") }
            index += 1
            switch name {
            case "amp": return "&"; case "lt": return "<"; case "gt": return ">"; case "quot": return "\""; case "apos", "#39": return "'"; case "nbsp": return "\u{00A0}"
            default:
                let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
                if name.hasPrefix("#"), let value = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value), value != 0 { return String(Character(scalar)) }
                throw fail("unsupported character reference &\(name);")
            }
        }
    }

    static func checkAttribute(tag: String, name: String, value: String) throws {
        func fail(_ reason: String) -> SafeHTMLError { SafeHTMLError(field: "html", reason: reason) }
        switch name {
        case "class":
            guard value.split(separator: " ").allSatisfy({ isIdentifier(String($0)) }) else { throw fail("class names must be simple identifiers") }
        case "lang", "dir", "aria-label":
            guard value.utf8.count <= 200 else { throw fail("\(name) is too long") }
            if name == "dir", !["ltr", "rtl", "auto"].contains(value) { throw fail("dir must be ltr, rtl or auto") }
        case "colspan", "rowspan":
            guard ["td", "th"].contains(tag), let number = Int(value), (1...20).contains(number) else { throw fail("\(name) must be 1–20 on a table cell") }
        case "href":
            guard tag == "a", let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false, value.utf8.count <= 4096 else {
                throw fail("links permit only explicit https: URLs")
            }
        default:
            throw fail("the \(name) attribute is not permitted")
        }
    }
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)) }
            && !(value.first?.isNumber ?? true)
    }

    static func parseCSS(_ css: String) throws -> [SafeCSSRule] {
        func fail(_ reason: String) -> SafeHTMLError { SafeHTMLError(field: "css", reason: reason) }
        var text = css
        // Comments are inert; remove them before checking the declarations.
        while let start = text.range(of: "/*") {
            guard let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) else { throw fail("unterminated comment") }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let lowered = text.lowercased()
        for banned in ["@", "url(", "\\", "<", "expression", "var(", "calc(", "!important"] where lowered.contains(banned) {
            throw fail("\(banned) is not permitted in CSS")
        }
        var rules: [SafeCSSRule] = []
        var rest = Substring(text)
        while !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") else { throw fail("malformed rule") }
            let selectorText = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = rest[rest.index(after: open)..<close]
            guard !body.contains("{") else { throw fail("nested blocks are not permitted") }
            rest = rest[rest.index(after: close)...]
            guard rules.count < RichContentLimits.cssRules else { throw fail("more than 128 CSS rules") }
            let selectors: [[SafeCSSStep]] = try selectorText.split(separator: ",").map { selector in
                let steps = selector.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
                guard (1...4).contains(steps.count) else { throw fail("selectors have 1–4 descendant steps") }
                return try steps.map { step in
                    let parts = step.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count <= 2 else { throw fail("selector step \(step) is not permitted") }
                    let tag = parts[0].isEmpty ? nil : parts[0].lowercased()
                    let className = parts.count == 2 ? parts[1] : nil
                    if let tag, !elements.contains(tag) { throw fail("selector \(step) names an element outside the allowlist") }
                    if let className, !isIdentifier(className) { throw fail("selector \(step) is not a local class") }
                    guard tag != nil || className != nil else { throw fail("empty selector step") }
                    return SafeCSSStep(tag: tag, className: className)
                }
            }
            guard !selectors.isEmpty else { throw fail("a rule needs a selector") }
            var declarations: [String: String] = [:]
            for declaration in body.split(separator: ";") {
                let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let colon = trimmed.firstIndex(of: ":") else { throw fail("malformed declaration \(trimmed)") }
                let property = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard properties.contains(property) else { throw fail("the \(property) property is not permitted") }
                try checkCSSValue(property: property, value: value)
                declarations[property] = value
            }
            rules.append(SafeCSSRule(selectors: selectors, declarations: declarations))
        }
        return rules
    }

    static func checkCSSValue(property: String, value: String) throws {
        func fail() -> SafeHTMLError { SafeHTMLError(field: "css", reason: "\(property): \(value) is outside the permitted values") }
        let words = value.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty, value.utf8.count <= 200 else { throw fail() }
        func color(_ word: String) -> Bool {
            if ["transparent", "currentcolor"].contains(word) { return true }
            guard word.hasPrefix("#") else { return false }
            let hex = word.dropFirst()
            return [3, 4, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
        }
        func length(_ word: String, allowFr: Bool = false) -> Bool {
            if word == "0" { return true }
            for unit in ["px", "rem", "%"] + (allowFr ? ["fr"] : []) where word.hasSuffix(unit) {
                guard let number = Double(word.dropLast(unit.count)), number.isFinite, number >= 0 else { return false }
                return unit == "px" ? number <= 4096 : unit == "%" ? number <= 100 : number <= 64
            }
            return false
        }
        let keywords: [String: Set<String>] = [
            "font-weight": ["normal", "bold", "bolder", "lighter", "100", "200", "300", "400", "500", "600", "700", "800", "900"],
            "font-style": ["normal", "italic"], "text-align": ["left", "right", "center", "start", "end", "justify"],
            "text-decoration": ["none", "underline", "line-through"], "white-space": ["normal", "nowrap", "pre", "pre-wrap", "pre-line"],
            "overflow-wrap": ["normal", "anywhere", "break-word"], "border-style": ["none", "solid", "dashed", "dotted", "double"],
            "display": ["block", "inline", "inline-block", "flex", "grid", "none"], "flex-direction": ["row", "column", "row-reverse", "column-reverse"],
            "flex-wrap": ["nowrap", "wrap"], "align-items": ["start", "end", "center", "stretch", "baseline", "flex-start", "flex-end"],
            "justify-content": ["start", "end", "center", "space-between", "space-around", "space-evenly", "flex-start", "flex-end"]
        ]
        let valid: Bool
        switch property {
        case "color", "background-color", "border-color": valid = words.count == 1 && color(words[0])
        case "line-height": valid = words.count == 1 && (Double(words[0]).map { $0.isFinite && $0 >= 0 && $0 <= 4 } ?? length(words[0]))
        case "font-size", "width", "max-width", "border-width", "gap": valid = words.count <= 2 && words.allSatisfy { length($0) }
        case "padding", "margin": valid = words.count <= 4 && words.allSatisfy { length($0) }
        case let side where side.hasPrefix("padding-") || side.hasPrefix("margin-"): valid = words.count == 1 && length(words[0])
        case "border": valid = words.count <= 3 && words.allSatisfy { length($0) || color($0) || keywords["border-style"]!.contains($0) }
        case "grid-template-columns":
            if words.count == 1, words[0].hasPrefix("repeat("), words[0].hasSuffix(",minmax(0,1fr))"),
               let count = Int(words[0].dropFirst(7).prefix { $0.isNumber }), (1...20).contains(count), words[0] == "repeat(\(count),minmax(0,1fr))" { valid = true }
            else { valid = (1...20).contains(words.count) && words.allSatisfy { length($0, allowFr: true) } }
        default: valid = words.count == 1 && (keywords[property]?.contains(words[0]) ?? false)
        }
        guard valid else { throw fail() }
    }
}

// MARK: - Presentation (portable model fed to native adapters)

public enum RichPresentedBlock: Equatable, Sendable {
    case markdown(MarkdownDocument)
    case plain(String)
    case table(columns: [RichContentColumn], rows: [[String]], caption: String)
    case chart(kind: String, xLabel: String, yLabel: String, xUnit: String, yUnit: String, series: [RichChartSeries], caption: String, fallback: String)
    case html(SafeHTMLDocument, fallback: String)
    case media(RichMediaReference, caption: String, fallback: String)
}

extension MarkdownDocument: Equatable {
    public static func == (left: Self, right: Self) -> Bool { left.blocks == right.blocks && left.warnings == right.warnings }
}

/// Prepared view model. `source` is always the exact original string; `notice`
/// explains an honest fallback. No case carries an action, verdict or answer.
public struct RichContentPresentation: Equatable, Sendable {
    public let source: String
    public let blocks: [RichPresentedBlock]
    public let notice: String?
    public let rich: Bool
    public let contentDigest: String?
    public let canceled: Bool

    public static func canceled(_ source: String) -> Self {
        Self(source: source, blocks: [.plain(source)], notice: "Rendering was canceled. The source text is shown.", rich: false, contentDigest: nil, canceled: true)
    }

    /// Bounded, cancelable preparation. Unsupported or malformed content degrades to the
    /// readable plain/Markdown string with a reason; the string itself is never altered.
    public static func prepare(text: String, content: Any? = nil, capability: RichFieldCapability, isCanceled: () -> Bool = { false }) -> Self {
        if isCanceled() { return .canceled(text) }
        var notice: String?
        if let content, !(content is NSNull) {
            if capability.companion == nil || capability.blockTypes.isEmpty {
                notice = "Rich view unavailable: this field shows text only."
            } else if let object = content as? [String: Any], let version = object["schema_version"] as? NSNumber, version.doubleValue != 1 {
                notice = "Rich view unavailable: content version \(version) is not supported by this app. The text is shown."
            } else {
                do {
                    let envelope = try RichContentEnvelope.validate(content, text: text, capability: capability, isCanceled: isCanceled)
                    var blocks: [RichPresentedBlock] = []
                    for block in envelope.blocks {
                        if isCanceled() { return .canceled(text) }
                        switch block.payload {
                        case .markdown: blocks.append(.markdown(MarkdownDocument.parse(block.fallback, isCanceled: isCanceled)))
                        case .table(let columns, let rows, let caption): blocks.append(.table(columns: columns, rows: rows, caption: caption))
                        case .chart(let kind, let x, let y, let xUnit, let yUnit, let series, let caption):
                            blocks.append(.chart(kind: kind, xLabel: x, yLabel: y, xUnit: xUnit, yUnit: yUnit, series: series, caption: caption, fallback: block.fallback))
                        case .html(let document): blocks.append(.html(document, fallback: block.fallback))
                        case .media(let ref, let caption): blocks.append(.media(ref, caption: caption, fallback: block.fallback))
                        }
                    }
                    if isCanceled() { return .canceled(text) }
                    return Self(source: text, blocks: blocks, notice: nil, rich: true, contentDigest: RichContentEnvelope.digest(text: text, content: envelope.source), canceled: false)
                } catch let error as CoreError {
                    if error.code == "CONTENT_CANCELED" { return .canceled(text) }
                    notice = "Rich view unavailable: " + error.message + " The text is shown."
                } catch {
                    notice = "Rich view unavailable. The text is shown."
                }
            }
        }
        if text.utf8.count > RichContentLimits.renderedTextBytes {
            let prefix = String(decoding: Data(text.utf8.prefix(RichContentLimits.renderedTextBytes)), as: UTF8.self)
            return Self(source: text, blocks: [.plain(prefix)], notice: "Long text: the first 262,144 bytes are shown as plain text. Copy source copies all of it.", rich: false, contentDigest: nil, canceled: false)
        }
        guard capability.markdown, RichContentPresentation.hasMarkdownSyntax(text) else {
            return Self(source: text, blocks: [.plain(text)], notice: notice, rich: false, contentDigest: nil, canceled: false)
        }
        let document = MarkdownDocument.parse(text, isCanceled: isCanceled)
        if isCanceled() { return .canceled(text) }
        return Self(source: text, blocks: [.markdown(document)], notice: notice, rich: true, contentDigest: nil, canceled: false)
    }

    /// Plain text without Markdown constructs keeps its exact line layout as one block.
    public static func hasMarkdownSyntax(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(4096) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("#") || trim.hasPrefix("- ") || trim.hasPrefix("* ") || trim.hasPrefix("+ ") || trim.hasPrefix(">") || trim.hasPrefix("```") || trim.hasPrefix("~~~") || trim == "---" { return true }
            if let dot = trim.firstIndex(of: "."), !trim[..<dot].isEmpty, trim[..<dot].allSatisfy(\.isNumber), trim[trim.index(after: dot)...].hasPrefix(" ") { return true }
            if trim.contains("|") || trim.contains("*") || trim.contains("`") || trim.contains("](") || trim.contains("__") { return true }
        }
        return false
    }
}

// MARK: - Native HTML layout model

/// Inline run produced from the safe HTML tree. Links carry only verified https URLs.
public struct SafeInlineRun: Equatable, Sendable {
    public var text: String
    public var bold = false, italic = false, underline = false, strike = false, code = false
    public var link: URL?
    public init(text: String) { self.text = text }
}

public enum SafeHTMLBlock: Equatable, Sendable {
    case heading(Int, [SafeInlineRun], SafeHTMLStyle)
    case paragraph([SafeInlineRun], SafeHTMLStyle)
    case listItem(marker: String, depth: Int, [SafeInlineRun], SafeHTMLStyle)
    case quote([SafeInlineRun], SafeHTMLStyle)
    case code(String)
    case table(caption: String, rows: [[[SafeInlineRun]]], headerRows: Int)
    case rule
}

/// The CSS subset a native adapter applies. Other validated declarations are inert.
public struct SafeHTMLStyle: Equatable, Sendable {
    public var bold = false, italic = false
    public var alignment = "start"
    public var color: String?
    public init() {}
}

extension SafeHTMLDocument {
    /// Flatten the parsed tree into native layout blocks (bounded by the node limit).
    public func layoutBlocks() -> [SafeHTMLBlock] {
        var blocks: [SafeHTMLBlock] = []
        func style(for tag: String, classes: [String], ancestors: [(String, [String])], inherited: SafeHTMLStyle) -> SafeHTMLStyle {
            var value = inherited
            for rule in rules where rule.selectors.contains(where: { matches($0, tag: tag, classes: classes, ancestors: ancestors) }) {
                for (property, raw) in rule.declarations {
                    let word = raw.lowercased()
                    switch property {
                    case "font-weight": value.bold = ["bold", "bolder", "600", "700", "800", "900"].contains(word)
                    case "font-style": value.italic = word == "italic"
                    case "text-align": value.alignment = word
                    case "color": value.color = word.hasPrefix("#") ? word : nil
                    default: break
                    }
                }
            }
            return value
        }
        func inline(_ nodes: [SafeHTMLNode], base: SafeInlineRun, into runs: inout [SafeInlineRun]) {
            for node in nodes {
                switch node {
                case .text(let text):
                    // HTML whitespace collapses outside <pre>.
                    var run = base; run.text = text.split(whereSeparator: { $0.isWhitespace && $0 != "\u{00A0}" }).joined(separator: " ")
                    if text.first?.isWhitespace == true, text.first != "\u{00A0}" { run.text = " " + run.text }
                    if text.last?.isWhitespace == true, text.last != "\u{00A0}", !run.text.hasSuffix(" ") { run.text += " " }
                    runs.append(run)
                case .element(let tag, let attributes, let children):
                    var next = base
                    switch tag {
                    case "strong", "b": next.bold = true
                    case "em", "i": next.italic = true
                    case "u": next.underline = true
                    case "s": next.strike = true
                    case "code": next.code = true
                    case "a": next.link = attributes["href"].flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
                    case "br": var run = base; run.text = "\n"; runs.append(run); continue
                    default: break
                    }
                    inline(children, base: next, into: &runs)
                }
            }
        }
        func runs(_ nodes: [SafeHTMLNode], style: SafeHTMLStyle) -> [SafeInlineRun] {
            var base = SafeInlineRun(text: ""); base.bold = style.bold; base.italic = style.italic
            var result: [SafeInlineRun] = []; inline(nodes, base: base, into: &result)
            return result
        }
        let blockTags: Set<String> = ["section", "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "figure", "figcaption", "table", "hr"]
        func walk(_ nodes: [SafeHTMLNode], ancestors: [(String, [String])], inherited: SafeHTMLStyle, listDepth: Int) {
            var pending: [SafeHTMLNode] = []
            func flushInline() {
                let value = runs(pending, style: inherited); pending = []
                if !value.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { blocks.append(.paragraph(value, inherited)) }
            }
            for node in nodes {
                guard case .element(let tag, let attributes, let children) = node, blockTags.contains(tag) else { pending.append(node); continue }
                flushInline()
                let classes = (attributes["class"] ?? "").split(separator: " ").map(String.init)
                let current = style(for: tag, classes: classes, ancestors: ancestors, inherited: inherited)
                let chain = ancestors + [(tag, classes)]
                switch tag {
                case "h1", "h2", "h3", "h4", "h5", "h6": blocks.append(.heading(Int(String(tag.last!)) ?? 3, runs(children, style: current), current))
                case "p", "figcaption": blocks.append(.paragraph(runs(children, style: current), current))
                case "blockquote": blocks.append(.quote(runs(children, style: current), current))
                case "pre": var text = ""; collectText(children, into: &text); blocks.append(.code(text))
                case "hr": blocks.append(.rule)
                case "ul", "ol":
                    var number = 0
                    for child in children {
                        guard case .element("li", let itemAttributes, let itemChildren) = child else { continue }
                        number += 1
                        let itemClasses = (itemAttributes["class"] ?? "").split(separator: " ").map(String.init)
                        let itemStyle = style(for: "li", classes: itemClasses, ancestors: chain, inherited: current)
                        let nested = itemChildren.filter { if case .element(let t, _, _) = $0 { return t == "ul" || t == "ol" }; return false }
                        let own = itemChildren.filter { if case .element(let t, _, _) = $0 { return t != "ul" && t != "ol" }; return true }
                        blocks.append(.listItem(marker: tag == "ol" ? "\(number)." : "•", depth: listDepth, runs(own, style: itemStyle), itemStyle))
                        walk(nested, ancestors: chain + [("li", itemClasses)], inherited: itemStyle, listDepth: listDepth + 1)
                    }
                case "table":
                    var caption = "", rows: [[[SafeInlineRun]]] = [], headerRows = 0
                    func collectRows(_ nodes: [SafeHTMLNode], header: Bool) {
                        for node in nodes {
                            guard case .element(let rowTag, _, let rowChildren) = node else { continue }
                            switch rowTag {
                            case "caption": collectText(rowChildren, into: &caption)
                            case "thead": collectRows(rowChildren, header: true)
                            case "tbody", "tfoot": collectRows(rowChildren, header: false)
                            case "tr":
                                let cells: [[SafeInlineRun]] = rowChildren.compactMap { cell in
                                    guard case .element(let cellTag, _, let cellChildren) = cell, ["td", "th"].contains(cellTag) else { return nil }
                                    var cellStyle = current; if cellTag == "th" { cellStyle.bold = true }
                                    return runs(cellChildren, style: cellStyle)
                                }
                                if header || rowChildren.allSatisfy({ if case .element("th", _, _) = $0 { return true }; if case .text(let t) = $0 { return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return false }), rows.count == headerRows { headerRows += 1 }
                                rows.append(cells)
                            default: break
                            }
                        }
                    }
                    collectRows(children, header: false)
                    blocks.append(.table(caption: caption, rows: rows, headerRows: headerRows))
                default: walk(children, ancestors: chain, inherited: current, listDepth: listDepth)
                }
            }
            flushInline()
        }
        walk(nodes, ancestors: [], inherited: SafeHTMLStyle(), listDepth: 0)
        return blocks
    }

    func collectText(_ nodes: [SafeHTMLNode], into text: inout String) {
        for node in nodes {
            switch node {
            case .text(let value): text += value
            case .element(let tag, _, let children): if tag == "br" { text += "\n" } else { collectText(children, into: &text) }
            }
        }
    }

    func matches(_ selector: [SafeCSSStep], tag: String, classes: [String], ancestors: [(String, [String])]) -> Bool {
        func step(_ step: SafeCSSStep, _ tag: String, _ classes: [String]) -> Bool {
            (step.tag == nil || step.tag == tag) && (step.className == nil || classes.contains(step.className!))
        }
        guard let last = selector.last, step(last, tag, classes) else { return false }
        var remaining = selector.dropLast()
        for ancestor in ancestors.reversed() where !remaining.isEmpty {
            if step(remaining.last!, ancestor.0, ancestor.1) { remaining = remaining.dropLast() }
        }
        return remaining.isEmpty
    }
}
