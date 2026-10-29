import Foundation

/// Closed worker request values only. Current grants, Draft state and owner
/// authority are checked by the service and cannot be granted by these schemas.
public enum MediaWorkerContract {
    public static let readMethods: Set<String> = [
        "media_type_list", "media_type_get", "media_round_get", "media_intake_get", "media_decision_list",
    ]
    public static let methods: Set<String> = readMethods.union([
        "media_round_create", "media_intake_preview", "media_intake_revise",
        "media_intake_confirm", "media_intake_capture", "media_suggest",
    ])

    public struct ValidationError: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static func inputSchema(_ method: String) -> [String: Any]? {
        guard methods.contains(method) else { return nil }
        var properties: [String: Any] = ["project_id": text(4_000)]
        var required = ["project_id"]
        if !readMethods.contains(method) {
            properties["command_id"] = ["type": "string", "format": "uuid", "minLength": 1, "maxLength": 100,
                "description": "Use a new random UUID for a distinct command; retry the identical input with its original UUID."]
            required.append("command_id")
        }
        switch method {
        case "media_type_list": break
        case "media_type_get":
            properties["type_id"] = text(4_000); required += ["type_id"]
        case "media_round_create":
            properties["type_id"] = text(4_000); properties["title"] = text(2_000)
            required += ["type_id", "title"]
        case "media_round_get", "media_decision_list":
            properties["round_id"] = text(4_000)
            properties["cursor"] = text(method == "media_round_get" ? 1_400_000 : 512)
            properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 100, "default": 100]
            required += ["round_id"]
        case "media_intake_preview":
            properties["round_id"] = text(4_000); required += ["round_id"]
            properties["sources"] = ["type": "array", "minItems": 1, "items": object([
                "path": text(4_096),
                "columns": ["type": "object", "maxProperties": 64, "additionalProperties": scalar],
            ], required: ["path"])]
            properties["text"] = text(1_048_576); properties["tsv"] = text(4_194_304)
            properties["mapping"] = mapping
        case "media_intake_get":
            properties["intake_id"] = text(4_000); required += ["intake_id"]
        case "media_intake_revise":
            properties["intake_id"] = text(4_000); properties["expected_revision"] = revision
            properties["mapping"] = mapping
            properties["resolutions"] = ["type": "array", "items": object([
                "row_id": text(4_000), "disposition": ["type": "string", "enum": ["include", "skip"]],
                "slot_id": text(256), "group_id": text(256), "title": text(2_000),
            ], required: ["row_id", "disposition"])]
            required += ["intake_id", "expected_revision"]
        case "media_intake_confirm", "media_intake_capture":
            properties["intake_id"] = text(4_000); properties["expected_revision"] = revision
            properties["plan_id"] = text(4_000)
            required += ["intake_id", "expected_revision", "plan_id"]
            if method == "media_intake_confirm" {
                properties["plan_digest"] = digest; required += ["plan_digest"]
            } else {
                properties["row_ids"] = ["type": "array", "minItems": 1, "maxItems": 200,
                    "uniqueItems": true, "items": text(4_000)]
                required += ["row_ids"]
            }
        case "media_suggest":
            properties["round_id"] = text(4_000); properties["expected_revision"] = revision
            properties["observed_context_token"] = text(65_536)
            properties["manifest_id"] = text(4_000); properties["manifest_digest"] = digest
            properties["disposition"] = ["type": "string", "enum": ["accepted", "needs_look", "changes_requested", "excluded"]]
            properties["winner_id"] = text(4_000); properties["none_fit"] = ["type": "boolean"]
            properties["note"] = text(4_000); properties["no_follow_up_reason"] = text(4_000)
            properties["items"] = ["type": "array", "minItems": 1, "maxItems": 200, "items": object([
                "item_id": text(4_000), "expected_revision": revision, "target_id": text(4_000),
                "review_basis_signature": digest, "winner_id": text(4_000), "none_fit": ["type": "boolean"],
            ], required: ["item_id", "expected_revision", "target_id", "review_basis_signature"])]
            required += ["round_id", "expected_revision", "observed_context_token", "manifest_id", "manifest_digest", "disposition", "items"]
        default: return nil
        }
        var schema = object(properties, required: required)
        if method == "media_intake_preview" {
            schema["oneOf"] = [["required": ["sources"]], ["required": ["text"]], ["required": ["tsv"]]]
        }
        return schema
    }

    /// Validates the same finite envelope advertised to workers. Type-defined
    /// metadata and exact target/manifest semantics remain domain checks.
    public static func validate(_ method: String, parameters: [String: Any]) throws {
        guard let schema = inputSchema(method) else { throw ValidationError("Unsupported worker media command.") }
        try validate(parameters, against: schema, path: method)
        if let selections = parameters["items"] as? [[String: Any]] {
            let ids = selections.compactMap { $0["item_id"] as? String }
            guard Set(ids).count == ids.count else { throw ValidationError("items must name distinct item IDs.") }
        }
        if let resolutions = parameters["resolutions"] as? [[String: Any]] {
            let ids = resolutions.compactMap { $0["row_id"] as? String }
            guard Set(ids).count == ids.count else { throw ValidationError("resolutions must name distinct row IDs.") }
        }
    }

    private static var revision: [String: Any] { ["type": "integer", "minimum": 1] }
    private static var digest: [String: Any] { ["type": "string", "pattern": "^[0-9a-f]{64}$", "minLength": 64, "maxLength": 64] }
    private static func text(_ maximum: Int) -> [String: Any] {
        ["type": "string", "minLength": 1, "maxLength": maximum, "pattern": "\\S"]
    }
    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static var scalar: [String: Any] {
        ["oneOf": [["type": "string", "maxLength": 65_536], ["type": "number"], ["type": "boolean"], ["type": "null"]]]
    }
    private static var mapping: [String: Any] {
        let source: [String: Any] = ["oneOf": [
            object(["kind": ["type": "string", "enum": ["column"]], "column_id": text(256)], required: ["kind", "column_id"]),
            object(["kind": ["type": "string", "enum": ["stem", "source_index"]]], required: ["kind"]),
            object(["kind": ["type": "string", "enum": ["stem_token"]], "delimiter": ["type": "string", "minLength": 1, "maxLength": 32],
                "index": ["type": "integer", "minimum": 0, "maximum": 63]], required: ["kind", "delimiter", "index"]),
        ]]
        return object([
            "input": ["type": "string", "enum": ["selected_files", "tsv", "explicit_metadata"]],
            "candidate_grouping": ["type": "string", "enum": ["explicit_preview_only"]],
            "assignments": ["type": "array", "maxItems": 20, "items": object([
                "field_id": text(256), "source": source,
            ], required: ["field_id", "source"])],
        ], required: ["input"])
    }

    /// Foundation's JSON representation preserves the Boolean/number distinction
    /// without depending on CoreFoundation or platform-specific NSNumber classes.
    /// Swift's `as? Bool` also accepts some numeric NSNumbers, so it is insufficient.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        guard number.doubleValue.isFinite,
              let encoded = try? JSONSerialization.data(withJSONObject: [number]) else { return false }
        return encoded == Data("[true]".utf8) || encoded == Data("[false]".utf8)
    }

    /// The schema vocabulary here is deliberately closed to these request values.
    private static func validate(_ value: Any, against schema: [String: Any], path: String) throws {
        if let choices = schema["oneOf"] as? [[String: Any]] {
            let matches = choices.filter { (try? validate(value, against: $0, path: path)) != nil }
            guard matches.count == 1 else { throw ValidationError("\(path) must match exactly one allowed input shape.") }
        }
        if let required = schema["required"] as? [String] {
            guard let values = value as? [String: Any], required.allSatisfy({ values[$0] != nil }) else {
                throw ValidationError("\(path) is missing a required field.")
            }
        }
        guard let type = schema["type"] as? String else { return }
        switch type {
        case "object":
            guard let values = value as? [String: Any] else { throw ValidationError("\(path) must be an object.") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            if schema["additionalProperties"] as? Bool == false, !Set(values.keys).isSubset(of: Set(properties.keys)) {
                throw ValidationError("\(path) contains an unsupported field.")
            }
            if let maximum = schema["maxProperties"] as? Int, values.count > maximum { throw ValidationError("\(path) contains too many fields.") }
            for (key, child) in values {
                if let spec = properties[key] as? [String: Any] ?? schema["additionalProperties"] as? [String: Any] {
                    try validate(child, against: spec, path: "\(path).\(key)")
                }
            }
        case "array":
            guard let values = value as? [Any] else { throw ValidationError("\(path) must be an array.") }
            if let minimum = schema["minItems"] as? Int, values.count < minimum { throw ValidationError("\(path) has too few entries.") }
            if let maximum = schema["maxItems"] as? Int, values.count > maximum { throw ValidationError("\(path) has too many entries.") }
            if schema["uniqueItems"] as? Bool == true, let ids = values as? [String], Set(ids).count != ids.count {
                throw ValidationError("\(path) must contain distinct IDs.")
            }
            if let item = schema["items"] as? [String: Any] {
                for (index, child) in values.enumerated() { try validate(child, against: item, path: "\(path)[\(index)]") }
            }
        case "string":
            guard let string = value as? String else { throw ValidationError("\(path) must be text.") }
            if let minimum = schema["minLength"] as? Int, string.utf8.count < minimum { throw ValidationError("\(path) is too short.") }
            if let maximum = schema["maxLength"] as? Int, string.utf8.count > maximum { throw ValidationError("\(path) exceeds its text limit.") }
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { throw ValidationError("\(path) has an invalid text value.") }
            if let choices = schema["enum"] as? [String], !choices.contains(string) { throw ValidationError("\(path) is not an allowed choice.") }
            if schema["format"] as? String == "uuid", UUID(uuidString: string) == nil { throw ValidationError("\(path) must be a UUID.") }
        case "integer", "number":
            guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite,
                  type != "integer" || number.doubleValue.rounded() == number.doubleValue else { throw ValidationError("\(path) must be a finite \(type).") }
            if let minimum = schema["minimum"] as? Int, number.doubleValue < Double(minimum) { throw ValidationError("\(path) is below its minimum.") }
            if let maximum = schema["maximum"] as? Int, number.doubleValue > Double(maximum) { throw ValidationError("\(path) exceeds its maximum.") }
        case "boolean":
            guard let number = value as? NSNumber, isBoolean(number) else { throw ValidationError("\(path) must be a Boolean.") }
        case "null":
            guard value is NSNull else { throw ValidationError("\(path) must be null.") }
        default: throw ValidationError("Unsupported worker media schema type.")
        }
    }
}
