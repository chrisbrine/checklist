import XCTest
@testable import ChecklistCore

/// New pure-unit fixture source only. No service, filesystem evidence validation,
/// claim pinning, native behavior, historic verdict or executed-result claim.
final class ReviewRequirementsTests: XCTestCase {
    let policyDigest = String(repeating: "a", count: 64)
    func requirement(_ types: [String] = [], id: String = "check", text: String = "Inspect the specified result.") -> [String: Any] {
        ["checks": [["id": id, "text": text]], "reject_bar": "Reject an unmet requirement.", "required_evidence_types": types]
    }
    func policy(_ revision: Int = 7, project: String = "project") throws -> ReviewRequirementPolicyIdentity {
        try .init(projectID: project, revision: revision, digest: policyDigest)
    }
    func scope(task: String = "task", project: String = "project", manifest: String = "manifest", attempt: String = "attempt") throws -> ReviewRequirementEvidenceScope {
        try .init(projectID: ReviewRequirementID(project), taskID: ReviewRequirementID(task),
                  manifestID: ReviewRequirementID(manifest), reviewAttemptID: ReviewRequirementID(attempt))
    }
    func descriptor(_ types: Set<ReviewRequirementEvidenceType>, id: String = "evidence", namespace: ReviewRequirementEvidenceReference.Namespace = .artifact,
                    scope supplied: ReviewRequirementEvidenceScope? = nil, digest: String? = nil) throws -> ReviewRequirementEvidenceDescriptor {
        try .init(scope: supplied ?? scope(), reference: .init(namespace: namespace, id: ReviewRequirementID(id)),
                  digest: digest ?? policyDigest, types: types)
    }

    func testGenericFallbackHasNoExtraEvidenceAndPolicyAnchorIsExplicit() throws {
        let config = try ReviewRequirementConfiguration.parse(nil)
        for kind in ReviewRequirementKind.allCases {
            let value = config.resolve(policy: try policy(), kind: kind)
            XCTAssertEqual(value.requirement.checks.map(\.id.text), ["acceptance"])
            XCTAssertTrue(value.requirement.requiredEvidenceTypes.isEmpty)
            XCTAssertEqual(value.policy.revision, 7)
            XCTAssertEqual(value.policy.digest, policyDigest)
        }
        XCTAssertThrowsError(try policy(0))
        XCTAssertThrowsError(try ReviewRequirementPolicyIdentity(projectID: "project", revision: 7, digest: "unverified"))
        XCTAssertThrowsError(try ReviewRequirementPolicyIdentity(projectID: "project", revision: 7, digest: String(repeating: "A", count: 64)))
    }

    func testCompleteReplacementInheritanceAndResetPreserveOriginalValue() throws {
        let config = try ReviewRequirementConfiguration.parse([
            "default": requirement(["text_record"], id: "base"),
            "kind_overrides": [["kind": "asset", "requirement": requirement(["image"], id: "asset")]]])
        XCTAssertEqual(config.resolve(policy: try policy(), kind: .work).requirement.checks.first?.id.text, "base")
        let prior = config.resolve(policy: try policy(), kind: .asset)
        XCTAssertEqual(prior.requirement.requiredEvidenceTypes, [.image])
        let reset = config.resetting(.asset).resolve(policy: try policy(), kind: .asset)
        XCTAssertEqual(reset.requirement.checks.first?.id.text, "base")
        XCTAssertEqual(reset.requirement.requiredEvidenceTypes, [.textRecord])
        XCTAssertEqual(config.resolve(policy: try policy(), kind: .asset).digest, prior.digest)
        XCTAssertThrowsError(try ReviewRequirementConfiguration.parse(["kind_overrides": [["kind": "asset", "requirement": ["reject_bar": "Partial"]]]]))
    }

    func testClosedBoundedValidationRejectsUnknownAndDuplicateEntries() throws {
        XCTAssertThrowsError(try ReviewRequirementConfiguration.parse(["required_gates": []]))
        XCTAssertThrowsError(try ReviewRequirementConfiguration.parse(["default": NSNull()]))
        XCTAssertThrowsError(try ReviewRequirementConfiguration.parse(["kind_overrides": [["kind": "unknown", "requirement": requirement()]]]))
        XCTAssertThrowsError(try ReviewRequirementConfiguration.parse(["kind_overrides": [["kind": "bug", "requirement": requirement()], ["kind": "bug", "requirement": requirement()]]]))
        var raw = requirement(); raw["checks"] = [["id": "same", "text": "One"], ["id": "same", "text": "Two"]]
        XCTAssertThrowsError(try ReviewRequirement.parse(raw))
        raw["checks"] = (0..<21).map { ["id": "\($0)", "text": "Check"] }
        XCTAssertThrowsError(try ReviewRequirement.parse(raw))
        XCTAssertThrowsError(try ReviewRequirement.parse(requirement(id: String(repeating: "x", count: 257))))
        XCTAssertThrowsError(try ReviewRequirement.parse(requirement(text: " \n")))
        XCTAssertThrowsError(try ReviewRequirement.parse(requirement(text: String(repeating: "x", count: 2001))))
        XCTAssertThrowsError(try ReviewRequirement.parse(requirement(["execution_log"])))
        XCTAssertThrowsError(try ReviewRequirement.parse(requirement(["image", "image"])))
    }

    func testOpaqueUnicodeAliasesRemainDistinctWithoutNormalizingHumanText() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed) // Swift's ordinary human-text equality.
        XCTAssertNotEqual(try ReviewRequirementID(composed), try ReviewRequirementID(decomposed))
        var raw = requirement(); raw["checks"] = [["id": composed, "text": "One"], ["id": decomposed, "text": "Two"]]
        XCTAssertEqual(try ReviewRequirement.parse(raw).checks.count, 2)
        let a = try ReviewRequirementConfiguration.parse(["default": requirement(id: composed, text: decomposed)])
        let b = try ReviewRequirementConfiguration.parse(["default": requirement(id: decomposed, text: decomposed)])
        XCTAssertNotEqual(a.resolve(policy: try policy(), kind: .work).digest, b.resolve(policy: try policy(), kind: .work).digest)
        XCTAssertTrue(a.resolve(policy: try policy(), kind: .work).requirement.checks[0].text.utf8.elementsEqual(decomposed.utf8))
    }

    func testDigestIsDeterministicTypeOrderIndependentAndRevisionScoped() throws {
        let a = try ReviewRequirementConfiguration.parse(["default": requirement(["image", "reviewer_report"])])
        let b = try ReviewRequirementConfiguration.parse(["default": requirement(["reviewer_report", "image"])])
        let original = a.resolve(policy: try policy(), kind: .bug)
        XCTAssertEqual(original.digest, b.resolve(policy: try policy(), kind: .bug).digest)
        XCTAssertNotEqual(original.digest, a.resolve(policy: try policy(8), kind: .bug).digest)
        XCTAssertNotEqual(original.digest, a.resolve(policy: try policy(), kind: .work).digest)
        XCTAssertNotEqual(original.digest, a.resolve(policy: try policy(project: "other"), kind: .bug).digest)
    }

    func testMissingTypesUseOnlySelectedSameScopeDescriptors() throws {
        let rule = try ReviewRequirement.parse(requirement(["reviewer_report", "source_capture", "image", "text_record"]))
        let expected = try scope()
        let empty = ReviewRequirementEvidenceGaps.project(rule, scope: expected, selected: [])
        XCTAssertEqual(empty.missing, ReviewRequirementEvidenceType.allCases)
        let foreign = [try scope(task: "other"), try scope(project: "other"), try scope(manifest: "other"), try scope(attempt: "other")]
        let unselected = try descriptor([.image])
        _ = unselected // Existing but not selected evidence cannot fill a gap.
        let wrong = try foreign.map { try descriptor([.image], scope: $0) }
        let gaps = ReviewRequirementEvidenceGaps.project(rule, scope: expected, selected: wrong)
        XCTAssertEqual(gaps.missing, empty.missing); XCTAssertEqual(gaps.ignoredScopeCount, 4)
        let selected = [try descriptor([.reviewerReport, .textRecord]), try descriptor([.image], id: "image"),
                        try descriptor([.sourceCapture], id: "capture", namespace: .sourceCapture)]
        XCTAssertTrue(ReviewRequirementEvidenceGaps.project(rule, scope: expected, selected: selected).missing.isEmpty)
    }

    func testReferenceNamespacesAndUnicodeIDsDoNotCollapse() throws {
        let rule = try ReviewRequirement.parse(requirement(["image", "source_capture", "text_record"]))
        let first = try descriptor([.image], id: "caf\u{e9}")
        let second = try descriptor([.textRecord], id: "cafe\u{301}")
        let third = try descriptor([.sourceCapture], id: "caf\u{e9}", namespace: .sourceCapture)
        let result = ReviewRequirementEvidenceGaps.project(rule, scope: try scope(), selected: [first, second, third])
        XCTAssertTrue(result.missing.isEmpty); XCTAssertTrue(result.ambiguousReferences.isEmpty)
        let aliases = try scope(project: "caf\u{e9}")
        let other = try scope(project: "cafe\u{301}")
        XCTAssertNotEqual(aliases, other)
    }

    func testConflictingDuplicateCannotSupplyMultipleTypesOrChangedBytes() throws {
        let rule = try ReviewRequirement.parse(requirement(["image", "text_record"]))
        let image = try descriptor([.image]), text = try descriptor([.textRecord])
        let conflict = ReviewRequirementEvidenceGaps.project(rule, scope: try scope(), selected: [image, text, image])
        XCTAssertEqual(Set(conflict.missing), [.image, .textRecord])
        XCTAssertEqual(conflict.ambiguousReferences, [image.reference])
        let changed = try descriptor([.image], digest: String(repeating: "b", count: 64))
        XCTAssertEqual(ReviewRequirementEvidenceGaps.project(rule, scope: try scope(), selected: [image, changed]).ambiguousReferences, [image.reference])
        let duplicate = ReviewRequirementEvidenceGaps.project(rule, scope: try scope(), selected: [image, image])
        XCTAssertEqual(duplicate.missing, [.textRecord]); XCTAssertTrue(duplicate.ambiguousReferences.isEmpty)
    }

    func testDescriptorShapeIsNotNativeOrArtifactValidation() throws {
        XCTAssertThrowsError(try descriptor([]))
        XCTAssertThrowsError(try descriptor([.sourceCapture]))
        XCTAssertThrowsError(try descriptor([.image], namespace: .sourceCapture))
        XCTAssertThrowsError(try descriptor([.image], digest: "screenshot.png"))
        XCTAssertNil(ReviewRequirementEvidenceType(rawValue: "native_verified"))
        // Synthetic descriptors above are input fixtures only, not verified evidence.
        // No test in this file invokes a validator, native route, provider or service.
    }
}
