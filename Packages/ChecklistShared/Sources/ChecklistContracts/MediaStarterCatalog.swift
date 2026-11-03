import Foundation

/// CL-419: the fixed built-in media type starters. The owner's Media review screen
/// and the worker `media_type_adopt_starter` command build a definition from this one
/// catalog, so an agent-adopted starter stores the same schema as an owner-added one.
public enum MediaStarterCatalog {
    public struct Starter: Sendable, Equatable {
        public let id: String
        public let name: String
    }

    /// Stable order, as the owner's starter picker shows it.
    public static let starters: [Starter] = [
        .init(id: "generic", name: "Text and images"),
        .init(id: "text", name: "Story text"),
        .init(id: "animation", name: "Character animation images"),
        .init(id: "video", name: "Video takes"),
        .init(id: "animation_video", name: "Animation takes"),
        .init(id: "audio", name: "Audio takes"),
    ]

    /// Resolves an exact starter ID or an exact starter name. Nothing else matches.
    public static func starter(_ idOrName: String) -> Starter? {
        starters.first { $0.id == idOrName } ?? starters.first { $0.name == idOrName }
    }

    /// The type definition of one starter. The service replaces `id` with the
    /// server-owned type ID; `name` is the type title.
    public static func schema(title: String, starter: String) -> [String: Any] {
        var value: [String: Any] = ["schema_version": 1, "id": "server-owned", "name": title,
            "slots": [["id": "text", "kind": "text", "material": true], ["id": "image", "kind": "image", "material": true]],
            "layout": ["kind": "generic"]]
        if starter == "text" {
            value["slots"] = [["id": "text", "kind": "text", "required": true]]
            value["layout"] = ["kind": "text_compare", "primary_slot_id": "text"]
        }
        if starter == "animation" {
            value["fields"] = [["id": "character", "kind": "short_text", "material": true], ["id": "animation_label", "kind": "short_text", "material": true],
                ["id": "direction", "kind": "choice", "material": true, "choices": ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]]]
            value["layout"] = ["kind": "image_compare", "primary_slot_id": "image"]
        }
        if starter == "video" || starter == "audio" {
            // CL-117: a candidate take and a declared reference of the same kind; portable IDs and kinds only.
            value["slots"] = [["id": "take", "label": "Take", "kind": starter, "material": true], ["id": "reference", "label": "Reference", "kind": starter, "material": true]]
            value["layout"] = ["kind": starter + "_compare", "primary_slot_id": "take", "reference_slot_id": "reference"]
        }
        if starter == "animation_video" {
            value["fields"] = [["id": "character", "label": "Character", "kind": "short_text", "required": true, "material": true],
                ["id": "animation_label", "label": "Action", "kind": "short_text", "required": true, "material": true],
                ["id": "direction", "label": "Direction", "kind": "choice", "required": true, "material": true, "choices": ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]],
                ["id": "take", "label": "Take", "kind": "short_text", "material": true],
                ["id": "hint", "label": "Hint", "kind": "long_text", "material": false],
                ["id": "frame_rate", "label": "Frame rate (fps)", "kind": "number", "material": true]]
            value["slots"] = [["id": "take", "label": "Take", "kind": "video", "material": true],
                ["id": "model_sheet", "label": "Model sheet", "kind": "image", "material": true],
                ["id": "concept_art", "label": "Concept art", "kind": "image", "material": true],
                ["id": "reference", "label": "Earlier take", "kind": "video", "material": true]]
            value["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": ["model_sheet", "concept_art", "reference"],
                "loop": true, "frame_rate_field_id": "frame_rate"]
        }
        return value
    }
}
