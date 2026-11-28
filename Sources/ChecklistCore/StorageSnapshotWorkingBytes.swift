import GRDB

/// Bounds retained inventory metadata and individual decoded inputs. Charges
/// include UTF-8 payload and room for collection entries. The exact manifest
/// length, filesystem bytes and process RSS are separate measurements.
struct StorageSnapshotWorkingBytes {
    let budget: StorageSnapshotBudget
    private var used = 0

    init(_ budget: StorageSnapshotBudget) { self.budget = budget }

    func requireInput(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= min(budget.maximumWorkingBytes, StorageSnapshotBudget.envelopeByteLimit) else {
            throw budget.capacityFailure("snapshot_working_capacity")
        }
    }

    mutating func retain(_ bytes: Int) throws {
        let next = used.addingReportingOverflow(bytes)
        guard bytes >= 0, !next.overflow, next.partialValue <= budget.maximumWorkingBytes else {
            throw budget.capacityFailure("snapshot_working_capacity")
        }
        used = next.partialValue
    }

    static let envelopeLength = "octet_length(data) AS snapshot_envelope_bytes"

    func requireEnvelope(_ row: Row) throws {
        let bytes: Int = row["snapshot_envelope_bytes"]
        try requireInput(bytes)
    }
}
