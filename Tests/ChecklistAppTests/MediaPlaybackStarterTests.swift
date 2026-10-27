import XCTest
@testable import ChecklistApp
@testable import ChecklistCore

/// CL-117: the native video and audio starters are valid portable comparison schemas.
@MainActor final class MediaPlaybackStarterTests: XCTestCase {
    func testVideoAndAudioStartersParseAsPortableComparisonSchemas() throws {
        for kind in ["video","audio"] {
            let raw=MediaTypeSettings.schema(title:"Takes",starter:kind)
            let parsed=try ChecklistCore.MediaReviewSchema.parse(raw)
            XCTAssertEqual(parsed.slots.map(\.id.rawValue),["take","reference"])
            XCTAssertEqual(parsed.slots.map(\.kind.rawValue),[kind,kind])
            XCTAssertEqual(parsed.layout.kind.rawValue,kind+"_compare")
            XCTAssertEqual(parsed.layout.primarySlotID?.rawValue,"take")
            XCTAssertEqual(parsed.layout.referenceSlotID?.rawValue,"reference")
            XCTAssertTrue(parsed.fields.isEmpty)
            var keys=Set<String>()
            func collect(_ value:Any) {
                if let object=value as? [String:Any] {for (key,child) in object {keys.insert(key);collect(child)}}
                if let array=value as? [Any] {array.forEach(collect)}
            }
            collect(raw)
            XCTAssertTrue(keys.isSubset(of:["schema_version","id","name","slots","label","kind","material","layout","primary_slot_id","reference_slot_id"]),
                          "The starter holds portable IDs, kinds and labels only: \(keys.sorted())")
        }
        for starter in ["generic","text","animation"] {XCTAssertNoThrow(try ChecklistCore.MediaReviewSchema.parse(MediaTypeSettings.schema(title:"Existing",starter:starter)))}
    }
}
