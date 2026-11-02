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


## Retained backup manifests (CL-406)

Retention previews hash every managed snapshot manifest. A fresh automatic prune
intent makes three previews so it can check the rule and recheck current protection
before moving files. Retention now hashes each complete manifest through the existing
64 KiB streaming digest reader, with the same 512 MiB byte admission. It never
builds a manifest-sized `Data` value for this check. The same reader applies when
a retry checks a snapshot already moved to Trash. The reader checks the opened
file's identity, size and modification metadata before and after the full read;
the lease still checks the current manifest name. Exact moved inode checks, pins,
upgrade protection and retention rules still apply. There is no new timeout or
cancellation rule. This changes no schema, command or reply field. The 64 KiB
buffer is a bound on read working space, not total process memory; decoded new
backup inventories, index rebuilding and allocator pages have separate costs.

`StorageBackupMemoryOwnedCopyTests.testP406BackupWithRetainedSnapshots` is an
opt-in check. Set `CHECKLIST_P406_STORE` to an owned runtime prepared by
`script/prepare_p321g_copy.py`, with ten older cloned snapshot folders in its
`backups/`, and `CHECKLIST_P406_OUTPUT` to the evidence prefix. The test verifies
the owned marker and seed manifest before opening the store. It logs physical
footprint and kernel lifetime peak, resident bytes, elapsed time and load at
startup, per index generation, per retained-manifest hash, around accounting and
the cleanup index, and through the full backup receipt and automatic retention.
Each point also saves a `footprint` report. There is no app, native transport,
credential access or live backup command.

The fixture rebinds existing physical receipt destinations to its owned clones.
An original receipt whose folder is already absent is preserved byte-for-byte
under a test-only metadata key and reported explicitly. It is not counted as a
physical backup. Source-root, store, operation and manifest bindings remain exact.
The fixture confirms its original retention counts through a test-only owner call
on the owned router and uses an owned Trash directory. It preserves pins and
upgrade protection. A directory-entry test seam re-spells each actually enumerated
child in its base URL, because Foundation enumeration and the anchored router use
different `/private/tmp` and `/tmp` spellings. Production installs no such seam;
the fixture still runs enumeration, lstat, managed-root admission, leases, hashes
and all retention decisions. It refuses duplicate or outside-root observations.

The installed check belongs to the orchestrator. Read the new service PID with
`ps -axo pid,etime,rss,comm` and select the actual `ChecklistService` process.
Capture `sysctl -n vm.loadavg` and `footprint -p PID -f bytes` before and after the
normal authorized install/backup path. Record both `phys_footprint` and
`phys_footprint_peak`, the build identity, PID and times. The peak belongs to that
process's entire lifetime and cannot be reset by a read. An older PID's peak is
not an after-change measure. A backup's complete receipt and retention result are
separate from a memory read. This procedure does not authorize starting a live
backup.

## Installed measure (CL-406, 2 November 2026)

The footprint of the installed service, sampled every few seconds from service start through a complete post-install backup, with 281 s of backup in both cases:

| Build | Peak footprint | Footprint after the backup |
| --- | ---: | ---: |
| 265 | 13,167 MiB | 1,449 MiB (13 s after the backup), about 2,000 MiB later |
| 266 | 1,574 MiB | 700 MiB (5 min after start) |

Build 265 was sampled from 5 minutes after start, so its peak is the kernel's lifetime value. Build 266 has the sampled timeline. The change between the builds is that automatic retention streams each retained manifest's hash. On an owned copy with ten older backups, that change alone took the peak from 2,674 to 1,456 MiB, so it does not explain every byte of the difference on the live service. The first run of build 265 also retired legacy command replies. The peak is a single install's result: a later service backup can differ. Read it with `footprint -p PID -f bytes`.

