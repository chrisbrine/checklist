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

The footprint of the installed service through a complete post-install backup, with 281 s of backup in both cases:

| Build | Peak footprint | Footprint after the backup |
| --- | ---: | ---: |
| 265 | 13,167 MiB | 1,449 MiB (13 s after the backup), about 2,000 MiB later |
| 266 | 1,574 MiB | 700 MiB (5 min after start) |

Build 265 was sampled from 5 minutes after start, so its peak is the kernel's lifetime value. Build 266 has the sampled timeline. The change between the builds is that automatic retention streams each retained manifest's hash.

The live peak fell by 11,592.8 MiB. Owned-copy measures with ten older backups give the change only part of that fall, and they overlap, so they do not add:

| Owned measure | Build 265 peak | Build 266 peak | Difference |
| --- | ---: | ---: | ---: |
| One backup with automatic retention | 2,674 MiB | 1,456 MiB | 1,218.5 MiB |
| Two backups, byte turns and reads (the build 266 run stopped at its own time limit during backup 2) | 2,894.9 MiB | 1,565.0 MiB | 1,329.9 MiB |
| One real retention move with replay | 2,471.1 MiB | 230.4 MiB | 2,240.7 MiB |

So the measured share is 11% to 19%. The other 9,352 to 10,374 MiB (81% to 89%) has no measured cause, and none of these measures approaches 13 GB. CL-409 holds that remainder and the conditions that a measure did not reproduce. The fall on the live service can come from a condition that this one install did not repeat, so a later service backup can differ. Read the peak with `footprint -p PID -f bytes`.


## Round memory guard (CL-408)

The owned-copy measures above run only with explicit paths, and a shared test
process makes a process-wide limit unreliable. So every round runs
`python3 script/memory_guard.py --scratch-path <slot>/.build` on the built copy.
It uses no real store copy, no app, no service call and no Keychain.

The script runs two separate `swift test` processes:

1. `StorageMemoryGuardTests.testBuildSyntheticStore` builds a synthetic store
   with 6,000 tickets of 8,000-byte briefs (`checklist.sqlite` about 53 MB):
   20 through `task_create` and the rest as canonical SQL clones with their own
   IDs, titles and briefs; three older backups and owner-confirmed retention
   that keeps all of them. `task_create` keeps the `brief` field; it ignores a
   `description` field, which gave a 4.9 MB store in an earlier calibration.
2. `StorageMemoryGuardTests.testStartupAndBackupStayBounded` opens that store
   (startup) and makes one backup with automatic retention. That process runs
   nothing else, so earlier tests cannot change its kernel lifetime peak
   footprint (`ledger_phys_footprint_peak`).

The guard fails on each of these conditions:

- A structural seam reports a whole-store record array:
  `MediaRecordRegistry.envelopes` without a project, or the whole-table
  `TicketPurge` inventory.
- A structural seam reports a whole `manifest.json` read of a folder other than
  the new backup's own folder. Retention must stream the hash of each retained
  manifest.
- The peak footprint of the measure process passes the stated limit
  (`DEFAULT_LIMIT_MIB` in the script, overridable with `--limit-mib`).
- The backup or its automatic retention does not complete.

`StorageMemoryGuardSeam.observe` is test-only; production installs no observer.
Without the script's environment both tests skip, so a default or shared run
never measures process-wide memory. `--self-test` runs two deliberate
regressions and passes only when the guard catches each one:
`whole_store_json` keeps every decoded record JSON through the backup with no
seam report, so only the footprint limit can catch it; `whole_manifest` reads an
older backup's manifest whole. The Swift test removes its own fixture folder;
the script moves any folder left by a stopped process to the Trash.

Measured limit (3 November 2026, Apple silicon, load average 9 to 14): with the
defaults, `checklist.sqlite` was 53.4 MB. Three normal runs had a peak
footprint of 72.8 to 72.9 MiB, startup 0.19 to 0.22 s and backup 4.7 s. The
`whole_store_json` regression held 6,010 decoded records and peaked at
128.3 MiB. The stated limit is 96 MiB: 23 MiB (32 %) over the normal peak and
32 MiB under that regression. A normal run takes about 45 to 55 s (fixture 33
to 44 s, measure 11 s); `--self-test` takes about 90 s.

The normal peak grows with the database: 19.1 MiB at a 4.9 MB store and
72.9 MiB at a 53.4 MB store, while the footprint after the backup is 11 MiB.
So startup or the backup holds memory of about the database size for a short
time; the cause is not identified (a candidate is the SQLite online backup
copy in `StorageDatabaseCapture`). Change the limit when the default store size
changes.

Limits of the guard: the synthetic manifests are small, so the footprint limit
alone does not catch a whole manifest read; the seam does. The seams cover the
known whole-store loaders; a new whole-store loader is caught only by the
footprint limit, and only when its size passes the limit at this store size.
This guard does not replace the installed measure above or owned-copy
qualification of the actual store.
