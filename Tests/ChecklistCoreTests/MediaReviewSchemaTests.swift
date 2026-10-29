import XCTest
@testable import ChecklistCore

final class MediaReviewSchemaTests: XCTestCase {
    private func base() -> [String: Any] { ["schema_version": 1, "id": "type", "name": "Review"] }
    private func field(_ id: String, kind: String = "short_text", required: Bool = false,
                       material: Bool = true) -> [String: Any] {
        ["id": id, "kind": kind, "required": required, "material": material]
    }
    private func slot(_ id: String, kind: String = "image", required: Bool = false,
                      material: Bool = true) -> [String: Any] {
        ["id": id, "kind": kind, "required": required, "material": material]
    }
    private func id(_ value: String) throws -> MediaReviewID { try MediaReviewID(value) }
    private func definition(_ raw: [String: Any], fields: [String] = [], slots: [String] = []) throws -> Data {
        try MediaReviewSchema.parse(raw).materialDefinition(
            usedFieldIDs: Set(try fields.map(id)), presentSlotIDs: Set(try slots.map(id)))
    }

    func testMinimalTypeUsesGenericOptionalDefaults() throws {
        let schema = try MediaReviewSchema.parse(base())
        XCTAssertEqual(schema.id, try id("type")); XCTAssertEqual(schema.name, "Review")
        XCTAssertTrue(schema.fields.isEmpty); XCTAssertTrue(schema.slots.isEmpty)
        XCTAssertEqual(schema.layout.kind, .generic)
        XCTAssertNil(schema.layout.primarySlotID); XCTAssertNil(schema.layout.referenceSlotID)
        XCTAssertEqual(schema.maxCandidates, 8)
        // Fixed portable length-prefixed golden; not JSON encoder/dictionary iteration output.
        XCTAssertEqual(try definition(base()), Data("38:checklist.media.material-definition.v14:type1:01:01:01:0".utf8))
    }

    func testClosedObjectVersionsAndExecutableCapabilitiesRefuse() throws {
        for key in ["renderer", "script", "remote_url", "intake", "list", "approved_examples"] {
            var raw = base(); raw[key] = "unsupported"
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw), key)
        }
        for version in [true, 0, 2, "1", NSNull(), 1.5] as [Any] {
            var raw = base(); raw["schema_version"] = version
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        var raw = base(); raw.removeValue(forKey: "schema_version")
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        for kind in ["url", "javascript", "date", "file"] {
            raw = base(); raw["fields"] = [field("f", kind: kind)]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        raw = base(); raw["fields"] = [["id": "f", "kind": "short_text", "expression": "x"]]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw = base(); raw["slots"] = [["id": "s", "kind": "image", "url": "https://invalid"]]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
    }

    func testOpaqueIdentityUsesExactBytesIncludingCanonicalUnicodeAliases() throws {
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed) // Demonstrate why String-keyed identity is unsafe here.
        XCTAssertNotEqual(try id(composed), try id(decomposed))
        XCTAssertEqual(Set([try id(composed), try id(decomposed)]).count, 2)
        XCTAssertNotEqual(try id(" Case "), try id("Case"))
        var raw = base(); raw["fields"] = [field(composed), field(decomposed)]
        let schema = try MediaReviewSchema.parse(raw)
        XCTAssertEqual(schema.fields.count, 2)
        XCTAssertNotEqual(try definition(raw, fields: [composed]), try definition(raw, fields: [decomposed]))
        raw["fields"] = [field(composed), field(composed)]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw = base(); raw["slots"] = [slot("same"), slot("same")]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        for invalid in ["", " \n ", "nul\u{0}id", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try id(invalid))
        }
        XCTAssertEqual(try id(String(repeating: "x", count: 256)).bytes.count, 256)
    }

    func testDeclaredCollectionAndCandidateBoundsAreEnforced() throws {
        var raw = base(); raw["fields"] = (0..<20).map { field("f\($0)") }
        XCTAssertEqual(try MediaReviewSchema.parse(raw).fields.count, 20)
        raw["fields"] = (0..<21).map { field("f\($0)") }
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw = base(); raw["slots"] = (0..<9).map { slot("s\($0)") }
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        for invalid in [0, 9, true, "2", 2.5, NSNull()] as [Any] {
            raw = base(); raw["max_candidates"] = invalid
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        for invalid in ["true", 1, NSNull()] as [Any] {
            raw = base(); raw["fields"] = [["id": "f", "kind": "boolean", "required": invalid]]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        raw = base(); raw["fields"] = NSNull()
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
    }

    func testChoiceMembershipIsFiniteUniqueAndByteExact() throws {
        var choice = field("direction", kind: "choice")
        choice["choices"] = ["N", "NE", "\u{00e9}", "e\u{0301}"]
        var raw = base(); raw["fields"] = [choice]
        let schema = try MediaReviewSchema.parse(raw)
        XCTAssertEqual(try schema.validateValue("NE", fieldID: id("direction")), .choice(try id("NE")))
        XCTAssertThrowsError(try schema.validateValue("ne", fieldID: id("direction")))
        for choices in [[] as [String], ["N", "N"], Array(repeating: "N", count: 65), "N"] as [Any] {
            choice["choices"] = choices; raw["fields"] = [choice]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        raw["fields"] = [["id": "f", "kind": "short_text", "choices": []]]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
    }

    func testNativeLayoutResolvesOnlyDeclaredCompatibleMaterialPrimary() throws {
        for (kind, layout) in [("image", "image_compare"), ("video", "video_compare"),
                               ("audio", "audio_compare"), ("text", "text_compare")] {
            var raw = base(); raw["slots"] = [slot("current", kind: kind)]; raw["layout"] = layout
            XCTAssertEqual(try MediaReviewSchema.parse(raw).layout.primarySlotID, try id("current"))
        }
        var raw = base(); raw["layout"] = "image_compare"
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw["slots"] = [slot("a"), slot("b")]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw["layout"] = ["kind": "image_compare", "primary_slot_id": "b", "reference_slot_id": "a"]
        let schema = try MediaReviewSchema.parse(raw)
        XCTAssertEqual(schema.layout.primarySlotID, try id("b")); XCTAssertEqual(schema.layout.referenceSlotID, try id("a"))
        for layout in [
            ["kind": "image_compare", "primary_slot_id": "missing"],
            ["kind": "image_compare", "primary_slot_id": "a", "reference_slot_id": "a"],
            ["kind": "generic", "primary_slot_id": "a"],
            ["kind": "image_compare", "primary_slot_id": "a", "renderer": "plugin"], "web_view"
        ] as [Any] {
            raw["layout"] = layout; XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        raw["slots"] = [slot("a", material: false)]; raw["layout"] = "image_compare"
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        raw["slots"] = [slot("a", kind: "audio")]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
    }

    func testPrimitiveValuesUseStrictBooleansAndFiniteByteBounds() throws {
        var raw = base(); raw["fields"] = [field("text"), field("long", kind: "long_text"),
            field("n", kind: "number"), field("b", kind: "boolean"), field("required", required: true)]
        let schema = try MediaReviewSchema.parse(raw)
        XCTAssertEqual(try schema.validateValue(true, fieldID: id("b")), .boolean(true))
        XCTAssertThrowsError(try schema.validateValue(1, fieldID: id("b")))
        XCTAssertThrowsError(try schema.validateValue("true", fieldID: id("b")))
        XCTAssertEqual(try schema.validateValue(1.25, fieldID: id("n")), .number(1.25))
        for invalid in [true, "1", Double.nan, Double.infinity, 1_000_000_000_001.0] as [Any] {
            XCTAssertThrowsError(try schema.validateValue(invalid, fieldID: id("n")))
        }
        XCTAssertEqual(try schema.validateValue("", fieldID: id("text")), .text(""))
        XCTAssertNotEqual(try schema.validateValue("\u{00e9}", fieldID: id("text")),
                          try schema.validateValue("e\u{0301}", fieldID: id("text")))
        XCTAssertThrowsError(try schema.validateValue(" \n", fieldID: id("required")))
        XCTAssertThrowsError(try schema.validateValue(String(repeating: "é", count: 513), fieldID: id("text")))
        XCTAssertEqual(try schema.validateValue(String(repeating: "x", count: 65_536), fieldID: id("long")), .text(String(repeating: "x", count: 65_536)))
        XCTAssertThrowsError(try schema.validateValue(String(repeating: "x", count: 65_537), fieldID: id("long")))
        XCTAssertThrowsError(try schema.validateValue("x", fieldID: id("unknown")))
    }

    func testVideoComparisonAcceptsSeveralMixedReferencesAndRejectsAmbiguousRoles() throws {
        var raw = base()
        raw["slots"] = [slot("take", kind: "video"), slot("sheet"), slot("concept"), slot("earlier", kind: "video"), slot("sound", kind: "audio")]
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": ["sheet", "concept", "earlier"]]
        let schema = try MediaReviewSchema.parse(raw)
        XCTAssertEqual(schema.layout.referenceSlotIDs.map(\.rawValue), ["sheet", "concept", "earlier"])
        XCTAssertNil(schema.layout.referenceSlotID)
        XCTAssertEqual(schema.slots.map(\.kind), [.video, .image, .image, .video, .audio])
        for references in [["sheet", "sheet"], ["take"], ["absent"], ["sound"]] {
            raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": references]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw), references.description)
        }
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_id": "earlier", "reference_slot_ids": ["sheet"]]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        for invalid in [NSNull(), "sheet", Array(repeating: "sheet", count: 8)] as [Any] {
            raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": invalid]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
    }

    func testAdditionalReferenceRolesAreMaterialOnlyWhenPresentAndOrderIsCosmetic() throws {
        var raw = base(); raw["slots"] = [slot("take", kind: "video"), slot("sheet"), slot("earlier", kind: "video")]
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": ["sheet", "earlier"]]
        let empty = try definition(raw, slots: ["take"])
        let present = try definition(raw, slots: ["take", "sheet", "earlier"])
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": ["earlier", "sheet"]]
        XCTAssertEqual(present, try definition(raw, slots: ["take", "sheet", "earlier"]))
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take"]
        XCTAssertEqual(empty, try definition(raw, slots: ["take"]))
        XCTAssertNotEqual(present, try definition(raw, slots: ["take", "sheet", "earlier"]))
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_id": "earlier"]
        let legacy = try definition(raw, slots: ["take", "earlier"])
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "reference_slot_ids": ["earlier"]]
        XCTAssertEqual(legacy, try definition(raw, slots: ["take", "earlier"]), "Equivalent singular/array roles preserve applicable decisions")
    }

    func testVideoLoopAndFrameRateAreStrictPortableSettings() throws {
        var raw = base(); raw["slots"] = [slot("take", kind: "video")]
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take"]
        let original = try definition(raw, slots: ["take"])
        XCTAssertFalse(try MediaReviewSchema.parse(raw).layout.loop)
        XCTAssertNil(try MediaReviewSchema.parse(raw).layout.frameRate)
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "loop": true]
        XCTAssertTrue(try MediaReviewSchema.parse(raw).layout.loop)
        XCTAssertEqual(original, try definition(raw, slots: ["take"]), "Loop is presentation only")
        raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "loop": true, "frame_rate": 12]
        XCTAssertEqual(try MediaReviewSchema.parse(raw).layout.frameRate, 12)
        XCTAssertNotEqual(original, try definition(raw, slots: ["take"]), "Playback speed changes review meaning")
        for invalid in [true, 0, 241, Double.infinity, "12", NSNull()] as [Any] {
            raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "frame_rate": invalid]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        for invalid in [1, "true", NSNull()] as [Any] {
            raw["layout"] = ["kind": "video_compare", "primary_slot_id": "take", "loop": invalid]
            XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
        }
        raw["slots"] = [slot("take", kind: "image")]
        raw["layout"] = ["kind": "image_compare", "primary_slot_id": "take", "loop": true]
        XCTAssertThrowsError(try MediaReviewSchema.parse(raw))
    }

    func testCosmeticAndUnusedOptionalChangesDoNotChangeMaterialDefinition() throws {
        var raw = base(); raw["fields"] = [field("used"), field("unused")]
        raw["slots"] = [slot("current"), slot("unused")]; raw["layout"] = "generic"
        let original = try definition(raw, fields: ["used"], slots: ["current"])
        raw["name"] = "Renamed"
        var used = field("used"); used["label"] = "Display label"
        raw["fields"] = [field("unused", kind: "number"), field("new"), used]
        raw["slots"] = [slot("new"), slot("unused", kind: "video"), slot("current")]
        raw["max_candidates"] = 4
        XCTAssertEqual(original, try definition(raw, fields: ["used"], slots: ["current"]))
    }

    func testUsedAndRequiredDefinitionChangesAffectOnlyApplicableShapes() throws {
        var raw = base(); raw["fields"] = [field("used"), field("optional")]
        let empty = try definition(raw)
        let used = try definition(raw, fields: ["used"])
        raw["fields"] = [field("used", kind: "number"), field("optional")]
        XCTAssertEqual(empty, try definition(raw)); XCTAssertNotEqual(used, try definition(raw, fields: ["used"]))
        raw["fields"] = [field("used"), field("optional", required: true)]
        XCTAssertNotEqual(empty, try definition(raw))
        raw["fields"] = [field("used", material: false), field("optional")]
        XCTAssertEqual(empty, try definition(raw, fields: ["used"]))
        XCTAssertThrowsError(try definition(raw, fields: ["unknown"]))
        XCTAssertThrowsError(try definition(raw, slots: ["unknown"]))
    }

    func testChoiceOrderIsCosmeticWhileUsedMembershipIsMaterial() throws {
        var choice = field("direction", kind: "choice"); choice["choices"] = ["N", "NE", "E"]
        var raw = base(); raw["fields"] = [choice]
        let empty = try definition(raw), used = try definition(raw, fields: ["direction"])
        choice["choices"] = ["E", "N", "NE"]; raw["fields"] = [choice]
        XCTAssertEqual(used, try definition(raw, fields: ["direction"]))
        choice["choices"] = ["E", "N"]; raw["fields"] = [choice]
        XCTAssertNotEqual(used, try definition(raw, fields: ["direction"]))
        XCTAssertEqual(empty, try definition(raw))
    }

    func testRequiredSlotsPrimaryAndAdoptedReferenceParticipateSelectively() throws {
        var raw = base(); raw["slots"] = [slot("current"), slot("reference"), slot("unused")]
        raw["layout"] = ["kind": "image_compare", "primary_slot_id": "current", "reference_slot_id": "reference"]
        let withoutReference = try definition(raw, slots: ["current"])
        let withReference = try definition(raw, slots: ["current", "reference"])
        XCTAssertNotEqual(withoutReference, withReference)
        raw["slots"] = [slot("current"), slot("reference", kind: "image"), slot("unused", kind: "audio")]
        XCTAssertEqual(withoutReference, try definition(raw, slots: ["current"]))
        raw["slots"] = [slot("current"), slot("reference"), slot("unused", required: true)]
        XCTAssertNotEqual(withoutReference, try definition(raw, slots: ["current"]))
        raw["slots"] = [slot("current"), slot("reference"), slot("unused")]
        raw["layout"] = ["kind": "image_compare", "primary_slot_id": "reference", "reference_slot_id": "current"]
        XCTAssertNotEqual(withReference, try definition(raw, slots: ["current", "reference"]))
    }
}
