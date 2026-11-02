# Service memory qualification (CL-400)

Startup selects attachment-import job identities before it decodes their payloads.
It fetches and validates one canonical row at a time, with a separate autorelease
scope. It finishes each SELECT before a recovery transaction writes. Unrelated
cleanup receipts do not become a decoded startup array. Malformed JSON candidates
still refuse the sweep. Receipt, reference, grace-period, cancellation and revision
checks still apply.

Backup inventory validates each canonical record and its required media references
in the same read observation. References use exact stored IDs and retain the type,
project and immutable-revision checks. Inventory does not first build an array of
all decoded records. Removed-evidence matching retains deduplicated path, hash,
size and kind facts, rather than whole cleanup receipts and object dictionaries.
A file that reappears still enters the snapshot; a mismatched descriptor cannot
suppress it. Each streamed receipt and record has its own autorelease scope.
These changes need no schema migration and change no reply fields or deletion
permission.

The opt-in test
`TicketCleanupMaintenanceOwnedCopyTests.testP400MemoryPhasesOnExplicitOwnedSnapshot`
uses a runtime prepared by `script/prepare_p321g_copy.py`. Set
`CHECKLIST_P400_STORE` to that runtime and `CHECKLIST_P400_OUTPUT` to an evidence
prefix. It checks the owned marker and parent manifest hash before opening the
store. It records current resident bytes, physical footprint, maximum resident
bytes, uptime and load at startup checkpoints, after 30 seconds idle, around one
lifecycle and one byte turn, and through a full owned-router backup command and
its receipt/accounting/automatic-retention tail. Each checkpoint also saves
`footprint` output to distinguish dirty allocator memory from clean mapped pages
and reclaimable allocator pages. It selects both cleanup turns and bypasses only
their rest/retry schedule; decision events show which work was available. The
backup uses the production retention barrier, complete copy and verification.
Automatic retention has an owned Trash destination.

This harness uses no app, native transport or credential. It is a bounded owned
store measurement, not a full sweep, long-duration leak test, installed-service
qualification or a global process-memory guarantee. Retained snapshot inventories
and individual canonical rows still scale with admitted data. Before installation,
the composed exact staged build still needs complete startup and protected
pre-upgrade backup qualification on an owned copy of the actual installation.
