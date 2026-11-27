import Foundation
import GRDB

/// A rebuildable lookup on the store writer. Stage cleanup must still check
/// both stored spellings, preview references and every malformed attachment.
struct ManagedImportStageReferences {
    private let dataVersion: Int

    init(_ db: Database) throws {
        dataVersion = try Int.fetchOne(db,sql:"PRAGMA data_version") ?? -1
        try db.inSavepoint {
            try db.execute(sql:"""
                CREATE TEMP TABLE checklist_import_stage_refs(
                    record_rowid INTEGER PRIMARY KEY,source_id BLOB NOT NULL UNIQUE,
                    original TEXT COLLATE BINARY,preview TEXT COLLATE BINARY,malformed INTEGER NOT NULL
                );
                CREATE INDEX temp.checklist_import_stage_original ON checklist_import_stage_refs(original);
                CREATE INDEX temp.checklist_import_stage_preview ON checklist_import_stage_refs(preview);
                CREATE INDEX temp.checklist_import_stage_malformed ON checklist_import_stage_refs(malformed) WHERE malformed=1;
                INSERT INTO checklist_import_stage_refs
                SELECT \(Self.columns("")) FROM main.records INDEXED BY records_scope WHERE type='attachment';
                """)
            // REPLACE need not fire DELETE triggers. Remove prior rows by both
            // identity and rowid, including when a replacement changes family.
            for action in ["INSERT","UPDATE","DELETE"] {
                let entries = action == "INSERT" ? ["NEW"] : action == "DELETE" ? ["OLD"] : ["OLD","NEW"]
                let stale = entries.map {
                    "record_rowid=\($0).rowid OR source_id=CAST(\($0).id AS BLOB)"
                }.joined(separator:" OR ")
                let refresh = action == "DELETE" ? "" : """
                    INSERT INTO checklist_import_stage_refs SELECT \(Self.columns("NEW.")) WHERE NEW.type='attachment';
                    """
                try db.execute(sql:"""
                    CREATE TEMP TRIGGER checklist_import_stage_\(action.lowercased()) AFTER \(action) ON main.records
                    WHEN \(entries.map { "\($0).type='attachment'" }.joined(separator:" OR "))
                      OR EXISTS(SELECT 1 FROM checklist_import_stage_refs WHERE \(stale))
                    BEGIN
                        DELETE FROM checklist_import_stage_refs WHERE \(stale);
                        \(refresh)
                    END;
                    """)
            }
            return .commit
        }
    }

    private static func columns(_ prefix: String) -> String {
        """
        \(prefix)rowid,CAST(\(prefix)id AS BLOB),
        CASE WHEN json_valid(\(prefix)data) THEN json_extract(\(prefix)data,'$.path') END,
        CASE WHEN json_valid(\(prefix)data) THEN json_extract(\(prefix)data,'$.preview_path') END,
        NOT json_valid(\(prefix)data)
        """
    }

    /// A different writer does not update our TEMP triggers. Fall back to the
    /// complete canonical check if another connection has committed.
    func contains(_ db: Database,absolute: String,relative: String) throws -> Bool? {
        guard try Int.fetchOne(db,sql:"PRAGMA data_version") == dataVersion else {return nil}
        return try Bool.fetchOne(db,sql:"""
            SELECT EXISTS(
                SELECT 1 FROM temp.checklist_import_stage_refs WHERE malformed=1
                UNION ALL
                SELECT 1 FROM temp.checklist_import_stage_refs WHERE original IN (CAST(? AS TEXT),CAST(? AS TEXT))
                UNION ALL
                SELECT 1 FROM temp.checklist_import_stage_refs WHERE preview IN (CAST(? AS TEXT),CAST(? AS TEXT))
            )
            """,arguments:[Data(absolute.utf8),Data(relative.utf8),Data(absolute.utf8),Data(relative.utf8)])
    }

    static func scan(_ db: Database,absolute: String,relative: String) throws -> Bool {
        try Int.fetchOne(db,sql:"""
            SELECT COUNT(*) FROM records WHERE type='attachment' AND CASE WHEN json_valid(data) THEN
                json_extract(data,'$.path')=CAST(? AS TEXT) COLLATE BINARY OR
                json_extract(data,'$.preview_path')=CAST(? AS TEXT) COLLATE BINARY OR
                json_extract(data,'$.path')=CAST(? AS TEXT) COLLATE BINARY OR
                json_extract(data,'$.preview_path')=CAST(? AS TEXT) COLLATE BINARY ELSE 1 END
            """,arguments:[Data(absolute.utf8),Data(absolute.utf8),Data(relative.utf8),Data(relative.utf8)]) != 0
    }
}
