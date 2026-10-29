import Foundation
import CoreFoundation

/// Portable descriptors only. No file access, media decoder, renderer or approval authority.
struct MediaReviewID: Hashable, Comparable {
    let rawValue: String
    let bytes: Data

    init(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MediaSchemaError.invalid("id", "expected nonblank, control-free ID of at most256 UTF-8 bytes")
        }
        rawValue = value
        bytes = Data(value.utf8)
    }

    // Swift String equality folds canonically equivalent Unicode. Opaque IDs do not.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

enum MediaSchemaError: Error, Equatable, CustomStringConvertible {
    case invalid(String, String)
    var description: String {
        switch self { case let .invalid(path, reason): return "\(path): \(reason)" }
    }
}

enum MediaMetadataKind: String { case shortText = "short_text", longText = "long_text", number, boolean, choice }
enum MediaSlotKind: String { case image, video, audio, text }
enum MediaLayoutKind: String {
    case generic, imageCompare = "image_compare", videoCompare = "video_compare"
    case audioCompare = "audio_compare", textCompare = "text_compare"
    var slotKind: MediaSlotKind? {
        switch self {
        case .generic: return nil
        case .imageCompare: return .image
        case .videoCompare: return .video
        case .audioCompare: return .audio
        case .textCompare: return .text
        }
    }
}

struct MediaMetadataField {
    let id: MediaReviewID
    let label: String
    let kind: MediaMetadataKind
    let required: Bool
    let material: Bool
    let choices: [MediaReviewID]
    fileprivate init(id: MediaReviewID, label: String, kind: MediaMetadataKind,
                     required: Bool, material: Bool, choices: [MediaReviewID]) {
        self.id = id; self.label = label; self.kind = kind
        self.required = required; self.material = material; self.choices = choices
    }
}

struct MediaReviewSlot {
    let id: MediaReviewID
    let label: String
    let kind: MediaSlotKind
    let required: Bool
    let material: Bool
    fileprivate init(id: MediaReviewID, label: String, kind: MediaSlotKind, required: Bool, material: Bool) {
        self.id = id; self.label = label; self.kind = kind; self.required = required; self.material = material
    }
}

struct MediaReviewLayout {
    let kind: MediaLayoutKind
    let primarySlotID: MediaReviewID?
    let referenceSlotID: MediaReviewID?
    let referenceSlotIDs: [MediaReviewID]
    let loop: Bool
    let frameRate: Double?
    fileprivate init(kind: MediaLayoutKind, primary: MediaReviewID?, reference: MediaReviewID?, references: [MediaReviewID] = [], loop: Bool = false, frameRate: Double? = nil) {
        self.kind = kind; primarySlotID = primary; referenceSlotID = reference
        referenceSlotIDs = reference.map { [$0] } ?? references
        self.loop = loop; self.frameRate = frameRate
    }
}

enum MediaMetadataValue: Equatable {
    case text(String), number(Double), boolean(Bool), choice(MediaReviewID)
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.text(a), .text(b)): return Data(a.utf8) == Data(b.utf8)
        case let (.number(a), .number(b)): return a == b
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.choice(a), .choice(b)): return a == b
        default: return false
        }
    }
}

struct MediaReviewSchema {
    let id: MediaReviewID
    let name: String
    let fields: [MediaMetadataField]
    let slots: [MediaReviewSlot]
    let layout: MediaReviewLayout
    let maxCandidates: Int

    /// Input is an already-parsed object; raw JSON duplicate-key detection belongs at the transport boundary.
    /// Missing optional configuration gives a generic type. A missing project type list means no media feature.
    static func parse(_ input: [String: Any]) throws -> Self {
        try keys(input, allowed: ["schema_version", "id", "name", "fields", "slots", "layout", "max_candidates"], path: "type")
        guard try integer(input["schema_version"], min: 1, max: 1, path: "type.schema_version") == 1 else {
            throw MediaSchemaError.invalid("type.schema_version", "unsupported version")
        }
        let id = try identifier(input["id"], path: "type.id")
        let name = try text(input["name"], max: 256, path: "type.name")
        let fields = try array(input["fields"], max: 20, path: "type.fields").enumerated().map { index, raw -> MediaMetadataField in
            let path = "type.fields[\(index)]"
            let o = try object(raw, path: path)
            try keys(o, allowed: ["id", "label", "kind", "required", "material", "choices"], path: path)
            let id = try identifier(o["id"], path: path + ".id")
            guard let kind = MediaMetadataKind(rawValue: try text(o["kind"], max: 32, path: path + ".kind")) else {
                throw MediaSchemaError.invalid(path + ".kind", "unsupported metadata kind")
            }
            let choices = try array(o["choices"], max: 64, path: path + ".choices").map { try identifier($0, path: path + ".choices") }
            try unique(choices, path: path + ".choices")
            guard (kind == .choice ? !choices.isEmpty : o["choices"] == nil) else {
                throw MediaSchemaError.invalid(path + ".choices", "choices required only for choice fields")
            }
            return MediaMetadataField(id: id, label: try optionalLabel(o["label"], fallback: id.rawValue, path: path), kind: kind,
                required: try boolean(o["required"], fallback: false, path: path + ".required"),
                material: try boolean(o["material"], fallback: true, path: path + ".material"), choices: choices)
        }
        try unique(fields.map(\.id), path: "type.fields")
        let slots = try array(input["slots"], max: 8, path: "type.slots").enumerated().map { index, raw -> MediaReviewSlot in
            let path = "type.slots[\(index)]"
            let o = try object(raw, path: path)
            try keys(o, allowed: ["id", "label", "kind", "required", "material"], path: path)
            let id = try identifier(o["id"], path: path + ".id")
            guard let kind = MediaSlotKind(rawValue: try text(o["kind"], max: 16, path: path + ".kind")) else {
                throw MediaSchemaError.invalid(path + ".kind", "unsupported slot kind")
            }
            return MediaReviewSlot(id: id, label: try optionalLabel(o["label"], fallback: id.rawValue, path: path), kind: kind,
                required: try boolean(o["required"], fallback: false, path: path + ".required"),
                material: try boolean(o["material"], fallback: true, path: path + ".material"))
        }
        try unique(slots.map(\.id), path: "type.slots")
        let layout = try parseLayout(input["layout"], slots: slots)
        let maxCandidates = input["max_candidates"] == nil ? 8 : try integer(input["max_candidates"], min: 1, max: 8, path: "type.max_candidates")
        return Self(id: id, name: name, fields: fields, slots: slots, layout: layout, maxCandidates: maxCandidates)
    }

    func validateValue(_ raw: Any, fieldID: MediaReviewID) throws -> MediaMetadataValue {
        guard let field = fields.first(where: { $0.id == fieldID }) else {
            throw MediaSchemaError.invalid("metadata.field_id", "unknown field")
        }
        switch field.kind {
        case .shortText, .longText:
            guard let value = raw as? String, value.utf8.count <= (field.kind == .shortText ? 1024 : 65_536),
                  !field.required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MediaSchemaError.invalid("metadata.value", "invalid or oversized text")
            }
            return .text(value)
        case .number:
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, abs(n.doubleValue) <= 1_000_000_000_000 else {
                throw MediaSchemaError.invalid("metadata.value", "expected bounded finite number")
            }
            return .number(n.doubleValue)
        case .boolean: return .boolean(try Self.boolean(raw, fallback: false, path: "metadata.value"))
        case .choice:
            let id = try Self.identifier(raw, path: "metadata.value")
            guard field.choices.contains(id) else { throw MediaSchemaError.invalid("metadata.value", "unknown choice") }
            return .choice(id)
        }
    }

    /// Canonical definition bytes for the declared material part of one item shape.
    /// Required constraints participate even in Draft shapes. Optional unused definitions and labels do not.
    /// The later target basis must ALSO bind actual bytes/values/candidate membership/references/context.
    /// This function validates IDs, but grants no completeness, media validity, publication or stale-decision verdict.
    func materialDefinition(usedFieldIDs: Set<MediaReviewID>, presentSlotIDs: Set<MediaReviewID>) throws -> Data {
        let fieldIDs = Set(fields.map(\.id)), slotIDs = Set(slots.map(\.id))
        guard usedFieldIDs.isSubset(of: fieldIDs), presentSlotIDs.isSubset(of: slotIDs) else {
            throw MediaSchemaError.invalid("item.shape", "unknown field or slot")
        }
        let selectedFields = fields.filter { $0.required || ($0.material && usedFieldIDs.contains($0.id)) }.sorted { $0.id < $1.id }
        let selectedSlots = slots.filter {
            $0.required || ($0.material && presentSlotIDs.contains($0.id)) || $0.id == layout.primarySlotID
        }.sorted { $0.id < $1.id }
        var output = Data()
        func append(_ bytes: Data) {
            output.append(contentsOf: String(bytes.count).utf8)
            output.append(58); output.append(bytes)
        }
        func atom(_ value: String) { append(Data(value.utf8)) }
        atom("checklist.media.material-definition.v1"); append(id.bytes)
        atom(String(selectedFields.count))
        for field in selectedFields {
            append(field.id.bytes); atom(field.kind.rawValue); atom(field.required ? "1" : "0"); atom(field.material ? "1" : "0")
            // Choice order is presentation; choice membership is a constraint.
            let choices = field.choices.sorted()
            atom(String(choices.count)); for choice in choices { append(choice.bytes) }
        }
        atom(String(selectedSlots.count))
        for slot in selectedSlots {
            append(slot.id.bytes); atom(slot.kind.rawValue); atom(slot.required ? "1" : "0"); atom(slot.material ? "1" : "0")
        }
        // Primary/reference roles affect review meaning; the native renderer kind itself is presentation.
        atom(layout.primarySlotID == nil ? "0" : "1")
        if let id = layout.primarySlotID { append(id.bytes) }
        let references = layout.referenceSlotIDs.filter { id in selectedSlots.contains { $0.id == id } }.sorted()
        let reference = references.first
        atom(reference == nil ? "0" : "1"); if let id = reference { append(id.bytes) }
        // Preserve existing v1 definitions exactly. Additional present reference roles and
        // declared playback speed affect review meaning; looping is display state only.
        if references.count > 1 {
            atom("additional-reference-slots.v1"); atom(String(references.count - 1))
            for id in references.dropFirst() { append(id.bytes) }
        }
        if let rate = layout.frameRate { atom("frame-rate.v1"); atom(String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), rate)) }
        return output
    }

    private static func parseLayout(_ raw: Any?, slots: [MediaReviewSlot]) throws -> MediaReviewLayout {
        guard let raw else { return MediaReviewLayout(kind: .generic, primary: nil, reference: nil) }
        let kindText: String
        var primary: MediaReviewID?, reference: MediaReviewID?
        var references: [MediaReviewID] = [], loop = false, frameRate: Double?
        if let value = raw as? String { kindText = value }
        else {
            let o = try object(raw, path: "type.layout")
            try keys(o, allowed: ["kind", "primary_slot_id", "reference_slot_id", "reference_slot_ids", "loop", "frame_rate"], path: "type.layout")
            kindText = try text(o["kind"], max: 32, path: "type.layout.kind")
            if let value = o["primary_slot_id"] { primary = try identifier(value, path: "type.layout.primary_slot_id") }
            if let value = o["reference_slot_id"] { reference = try identifier(value, path: "type.layout.reference_slot_id") }
            if o["reference_slot_ids"] != nil {
                guard reference == nil else { throw MediaSchemaError.invalid("type.layout", "choose reference_slot_id or reference_slot_ids") }
                references = try array(o["reference_slot_ids"], max: 7, path: "type.layout.reference_slot_ids").map { try identifier($0, path: "type.layout.reference_slot_ids") }
                try unique(references, path: "type.layout.reference_slot_ids")
            }
            loop = try boolean(o["loop"], fallback: false, path: "type.layout.loop")
            if let raw = o["frame_rate"] {
                guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      (1...240).contains(n.doubleValue) else { throw MediaSchemaError.invalid("type.layout.frame_rate", "expected frame rate from 1 to 240 fps") }
                frameRate = n.doubleValue
            }
        }
        guard let kind = MediaLayoutKind(rawValue: kindText) else { throw MediaSchemaError.invalid("type.layout", "unsupported native layout") }
        guard let expected = kind.slotKind else {
            guard primary == nil, reference == nil, references.isEmpty, !loop, frameRate == nil else { throw MediaSchemaError.invalid("type.layout", "generic layout has no comparison roles or playback settings") }
            return MediaReviewLayout(kind: kind, primary: nil, reference: nil)
        }
        if primary == nil {
            let candidates = slots.filter { $0.kind == expected }
            guard candidates.count == 1 else { throw MediaSchemaError.invalid("type.layout", "explicit primary slot required when zero or multiple compatible slots exist") }
            primary = candidates[0].id
        }
        guard let selected = slots.first(where: { $0.id == primary }), selected.kind == expected, selected.material else {
            throw MediaSchemaError.invalid("type.layout.primary_slot_id", "primary must reference a compatible material slot")
        }
        for id in reference.map({ [$0] }) ?? references {
            guard id != primary, slots.contains(where: { $0.id == id && ($0.kind == expected || (kind == .videoCompare && $0.kind == .image)) }) else {
                throw MediaSchemaError.invalid("type.layout.reference_slot_ids", "references must be distinct declared compatible slots; video comparisons also allow images")
            }
        }
        guard kind == .videoCompare || (!loop && frameRate == nil) else { throw MediaSchemaError.invalid("type.layout", "loop and frame_rate require video_compare") }
        return MediaReviewLayout(kind: kind, primary: primary, reference: reference, references: references, loop: loop, frameRate: frameRate)
    }

    private static func object(_ value: Any, path: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw MediaSchemaError.invalid(path, "expected object") }; return value
    }
    private static func keys(_ value: [String: Any], allowed: Set<String>, path: String) throws {
        guard Set(value.keys).isSubset(of: allowed) else { throw MediaSchemaError.invalid(path, "unknown field") }
    }
    private static func array(_ value: Any?, max: Int, path: String) throws -> [Any] {
        guard let value else { return [] }
        guard let value = value as? [Any], value.count <= max else { throw MediaSchemaError.invalid(path, "expected bounded array") }; return value
    }
    private static func text(_ value: Any?, max: Int, path: String) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= max else {
            throw MediaSchemaError.invalid(path, "expected bounded nonblank text")
        }; return value
    }
    private static func identifier(_ value: Any?, path: String) throws -> MediaReviewID {
        guard let value = value as? String else { throw MediaSchemaError.invalid(path, "expected ID") }
        do { return try MediaReviewID(value) } catch { throw MediaSchemaError.invalid(path, "invalid opaque ID") }
    }
    private static func optionalLabel(_ value: Any?, fallback: String, path: String) throws -> String {
        guard let value else { return fallback }
        return try text(value, max: 256, path: path + ".label")
    }
    private static func boolean(_ value: Any?, fallback: Bool, path: String) throws -> Bool {
        guard let value else { return fallback }
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw MediaSchemaError.invalid(path, "expected Boolean")
        }; return value.boolValue
    }
    private static func integer(_ value: Any?, min: Int, max: Int, path: String) throws -> Int {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= Double(min), value.doubleValue <= Double(max) else {
            throw MediaSchemaError.invalid(path, "expected bounded integer")
        }; return value.intValue
    }
    private static func unique(_ values: [MediaReviewID], path: String) throws {
        guard Set(values).count == values.count else { throw MediaSchemaError.invalid(path, "duplicate opaque ID") }
    }
}
