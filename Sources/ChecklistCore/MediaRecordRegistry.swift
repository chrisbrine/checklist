import Foundation
import CoreFoundation
import GRDB

/// First-persistence capture contract, shared by canonical envelopes, project export,
/// diagnostics and backup. These names enable no command, grant or media writer.
enum MediaRecordRegistry {
    static let families: Set<String> = [
        "media_review_type", "media_review_type_revision", "media_round", "media_round_manifest",
        "media_review_context", "media_context_attention", "media_context_reconciliation",
        "media_item", "media_item_target", "media_candidate", "media_owner_decision",
        "media_suggestion", "media_rework_link", "media_intake", "media_intake_plan",
        "media_intake_row", "media_intake_chunk", "media_bulk_operation", "media_bulk_chunk"
    ]

    static let immutableFamilies: Set<String> = [
        "media_review_type_revision", "media_round_manifest", "media_review_context",
        "media_context_reconciliation", "media_item_target", "media_candidate", "media_owner_decision", "media_suggestion",
        "media_intake_plan", "media_intake_chunk", "media_bulk_operation", "media_bulk_chunk"
    ]

    /// An explicit dependency list accompanies every media envelope, including an empty
    /// list for roots. Immutable versions have their own IDs; a moving head cannot stand
    /// in for a historical revision. Resolve against the SAME SQL boundary as the payload.
    static func validate(_ envelopes: [DecodedEnvelope]) throws {
        let byID = Dictionary(uniqueKeysWithValues: envelopes.map { (Data($0.id.utf8), $0) })
        func dependency(_ id: String, type: String, project: String?, revision: Int64? = nil) throws -> DecodedEnvelope {
            guard let target = byID[Data(id.utf8)], EnvelopeStorageIdentity.equal(target.type,type),
                  EnvelopeStorageIdentity.equal(target.projectID,project), revision == nil || target.revision == revision else {
                throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "A required same-project media record or exact revision is unavailable.")
            }
            return target
        }
        for envelope in envelopes {
            let value = envelope.object
            if families.contains(envelope.type) {
                guard let references = value["record_references"] as? [JSON] else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "Media history must declare its exact record dependencies.")
                }
                for reference in references {
                    guard Set(reference.keys).isSubset(of:["id","type","revision"]),
                          let id = reference["id"] as? String,!id.isEmpty,
                          let type = reference["type"] as? String,EnvelopeFamily.catalog[type] != nil else {
                        throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "A required media dependency is unregistered or malformed.")
                    }
                    var exact: Int64?
                    if let raw = reference["revision"] {
                        guard let number = raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                              let revision = try? EnvelopeInteger.positiveExact(number.stringValue) else {
                            throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "A media dependency revision is malformed.")
                        }
                        exact = revision
                    }
                    guard !immutableFamilies.contains(type) || exact != nil else {
                        throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "An immutable media dependency requires its exact revision.")
                    }
                    _ = try dependency(id,type:type,project:envelope.projectID,revision:exact)
                }
            }
            if envelope.type == "storage_job" {
                guard let kind = value["kind"] as? String,
                      ["attachment_import","archive_cleanup_delete","archive_cleanup_cursor","ticket_object_delete","media_attachment_owner"].contains(kind) else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "The required storage job kind is unregistered.")
                }
                if kind == "attachment_import",let ownerID = value["attachment_owner_id"] as? String {
                    let owner = try dependency(ownerID,type:"storage_job",project:envelope.projectID).object
                    guard owner["kind"] as? String == "media_attachment_owner",
                          owner["owner_kind"] as? String == value["attachment_owner_kind"] as? String else {
                        throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "The intake capture owner is unavailable.")
                    }
                }
            }
            if envelope.type == "storage_job", value["kind"] as? String == "media_attachment_owner" {
                guard let kind = value["owner_kind"] as? String, MediaAttachmentOwnerKind(rawValue:kind) != nil,
                      ["active","draft","published","released"].contains(value["state"] as? String ?? "") else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "The media ownership kind or state is unregistered.")
                }
            }
            if envelope.type == "storage_hold", value["kind"] as? String == "media_reference" {
                guard let ownerID = value["owner_id"] as? String, let attachmentID = value["attachment_id"] as? String,
                      ["active","released"].contains(value["state"] as? String ?? "") else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "The media ownership reference is incomplete.")
                }
                let owner = try dependency(ownerID,type:"storage_job",project:envelope.projectID).object
                let attachment = try dependency(attachmentID,type:"attachment",project:envelope.projectID).object
                guard owner["kind"] as? String == "media_attachment_owner", owner["owner_kind"] as? String == value["owner_kind"] as? String,
                      attachment["mode"] as? String == "managed", attachment["sha256"] as? String == value["sha256"] as? String,
                      let size = attachment["size"] as? NSNumber, size == value["size"] as? NSNumber else {
                    throw CoreError("MEDIA_CAPTURE_INCOMPLETE", "Media ownership no longer identifies the exact original.")
                }
            }
        }
    }

    static func envelopes(_ db: Database, project: String? = nil, limit: Int = 100_000, check: () throws -> Void = {}) throws -> [DecodedEnvelope] {
        let condition = project == nil ? "" : " WHERE project_id = CAST(? AS TEXT)"
        let arguments = project.map { StatementArguments([Data($0.utf8)]) } ?? StatementArguments()
        let rows = try Row.fetchCursor(db,sql:"SELECT " + CommandRouter.canonicalRecordColumns + " FROM records" + condition + " ORDER BY id COLLATE BINARY",arguments:arguments)
        var result: [DecodedEnvelope] = []
        while let row = try rows.next() {
            try check()
            guard result.count < limit else { throw StorageSnapshotFailure.limit }
            result.append(try GRDBRecordEnvelopeAdapter.decode(row))
        }
        return result
    }
}
