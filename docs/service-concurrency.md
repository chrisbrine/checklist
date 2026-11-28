# Service concurrency

The command queue owns coordinator state. The writer serializes SQLite changes. The archive storage gate serializes managed-file authority. Ordinary reads use read-only SQLite connections while any of these resources are held. A read that issues a lease, repairs availability, or refreshes claim credentials has an explicit write continuation.

## Work inventory

| Work | Resource held | Concurrent work |
| --- | --- | --- |
| Request routing of writes, enrollment changes, connection revoke and repair | Command queue during coordinator work, writer and gate during committed registration | Independent reads and read-only bootstrap proceed. Conflicting registration and authority changes serialize. |
| Change subscriptions, storage wake calculation, native lifecycle and delivery scheduling, reply hooks | Command queue during coordinator callbacks. Deadline discovery and provider probes run on separate queues. | Independent reads proceed. Native delivery fences can acquire the writer and gate. |
| Ticket or Epic capture, ordinary domain mutations, notes and claims | Writer and gate during the domain transaction. Capture admission runs on separate lanes. | Preparation and reads run beside writes. SQLite commits serialize. |
| Asynchronous operation admission, running marker, terminal receipt and replay | Writer during durable journal changes. An owner/file publication record can require the gate. | Independent reads and unrelated preparation proceed. Same-project authority operations and media-round deletions preserve order. |
| Attachment imports and file-backed answers, media intake/publication, project icon, export and restore | Writer and gate during authority validation, intent and publication. File preparation runs before the gate where the operation supports it. | Reads and unrelated preparation proceed. Final file authority and publication serialize. |
| Attachment original leases, media read lifecycle, first cleanup preview, availability repair and claim-credential replay | Writer and, when required for managed-file authority, gate during the write continuation | Other reads proceed. Lease and availability mutations obey admission. |
| Ticket purge and media-round deletion | Reader for graph/impact selection, writer and gate for validation, graph pages, receipts and unlink settlements | Other reads and unrelated preparation proceed. A managed unlink shares the gate with leases and snapshot retention. |
| Routine pruning of cursors, command results, cleanup previews and legacy attachment-read receipts | Writer in individually labeled apply steps. Command protection and the durable age mark each have their own writer turn. | Candidate scans run on a reader. Foreground writer work takes precedence. |
| Archive cleanup and ticket cleanup | Readers for scheduling and preparation. Writer and gate during intent, revalidation and exact file settlement. | Independent reads proceed, and maintenance yields on contended admission. |
| Managed import reconciliation | Writer and gate during the recovery step | Independent reads proceed. New import work and exact stage cleanup share file authority. |
| Backup snapshot capture, publication and retention | Writer and gate during admission and authority fencing. A snapshot retains byte ownership during capture, copy and verification. | Independent reads proceed. Conflicting writes use the established backup queue. |
| Failed backup publication quarantine | Capture retention and the failed snapshot's exclusive manifest lease during manifest validation, marking and rename. | The intent and generation receipt use a separate SQLite reader. Foreground commands can use the writer and archive gate. Cleanup and retirement honor capture retention. |
| Backup retention, explicit prune and incomplete-generation retirement | Writer and gate during retirement intent, publication and settlement | Other reads proceed. Snapshot use, pin and retirement share the gate. |
| Work-health checks | Reader during candidate selection, writer during a targeted check and advisory receipt | Foreground commands take precedence. |
| Native close and resume, owner disconnect and allow, source recovery | Writer and gate during durable authority changes, outside provider observation | Reads proceed. Ticket claims, generation and delivery fences settle together. |
| Bootstrap, schema upgrade, recovery and startup fences | Gate and writer as needed before authority opens | An upgrade exposes its separate progress status. Authoritative reads begin once recovery permits them. |

## Hold evidence

The step deadline starts before SQLite acquires its write transaction. Maintenance tries the writer and gate without waiting behind foreground work. SQLite checks the monotonic deadline during execution, and the apply step checks it before commit. A filesystem syscall, commit flush or process descheduling can still run past a deadline. The watchdog measures the actual hold.

`service_info.data.busy_periods` reports current and recent holds over one second. The local busy-period file also records the over-limit active observation and completion. Test slots emit new measured maxima by resource and work label, with UTC start and observation times and load at observation. The command-result journal uses separate labels for the age mark, protection fence and apply.

The coordinator labels ordinary command turns `command.<method>` and the verified native closure continuation `native_closure_finish`. A claim's direction-receipt window seeks by message ID. When the ticket has no unresolved directions, the claim can skip the window and total-count queries. A claim with unresolved directions still computes the exact total across the eligible receipt history.

An ordinary claim can select task-record row IDs on a separate reader before taking the gate. The writer observes a bounded set of changed row IDs while the reader selects. It pins its transaction snapshot, checks external SQLite changes and compares only touched rows that can change the selection. Each query repeats its authoritative row predicates. Unrelated foreground writes can continue. A stale selection retries once and then uses the original transaction. An already recorded command uses the normal receipt path.

The work-health writer rechecks current waits and delivery authorization. A tick that leaves a pending request unchanged skips rewriting its message. For apply transactions at or above the step limit, `work_health_apply_timing` records UTC, load, time through BEGIN, callback time and the time spent in validation and commit or rollback. The physical hold in the watchdog also covers the rest of the writer callback.

On SQLite 3.51.3 and later, the service can coalesce notifications at 1,000 WAL frames and checkpoint passively on a separate connection. The writer keeps FULL sync for each commit. A checkpoint may copy only through the oldest visible reader snapshot. A later commit can arrange another pass. Startup leaves the inline checkpoint in place if it cannot validate the separate connection. Older SQLite runtimes also keep the inline checkpoint. [SQLite WAL and runtime compatibility](https://www.sqlite.org/wal.html#the_wal_reset_bug)

### Live-size slot measurements

The first signed run used build 415 (`d678cf6cc5cb82f8`) on 27 November 2026. Its seeded copy had 77,602 command rows and 24,258 storage jobs. The window covered startup, scoped reads, 15 ticket captures, a cleanup preview request, and a backup through publication and receipt attempts. Times below are the UTC starts of each longest observed hold. Load is the one-, five-, and fifteen-minute averages sampled with the hold.

| Observed work | Resource | Longest hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Write routing and registration | Command queue | 257.136 ms | 22:41:29.811 | 133.03 / 182.87 / 218.12 |
| Scheduling callbacks | Command queue | 170.464 ms | 22:43:06.392 | 162.36 / 178.30 / 212.38 |
| Independent-read follow-up | Command queue | 2.597 ms | 22:43:48.212 | 254.70 / 198.20 / 217.99 |
| Project registration | Writer / gate | 218.791 / 219.393 ms | 22:41:29.839 / .838 | 133.03 / 182.87 / 218.12 |
| Ticket capture | Writer / gate | 423.025 / 428.939 ms | 22:44:16.394 / .393 | 328.08 / 220.94 / 225.52 |
| Operation acceptance for backup | Writer | 8.145 ms | 22:43:33.217 | 196.71 / 184.89 / 213.76 |
| Operation execution journal | Writer | 4.953 ms | 22:42:27.661 | 152.57 / 179.01 / 214.25 |
| Attachment import | Writer / gate | 5.539 / 5.565 ms | 22:42:27.904 | 152.57 / 179.01 / 214.25 |
| Prune age mark | Writer | 43.243 ms | 22:53:04.070 | 328.54 / 374.09 / 320.53 |
| Prune protection fence | Writer | 1.366 ms | 22:41:02.346 | 138.34 / 187.97 / 220.91 |
| Prune cursor apply | Writer | 1.057 ms | 22:59:10.832 | 147.45 / 252.61 / 283.63 |
| Prune command-result apply | Writer | 122.022 ms | 22:58:25.685 | 174.31 / 273.53 / 292.30 |
| Backup capture intent | Writer / gate | 3.569 / 3.589 ms | 22:43:33.234 | 196.71 / 184.89 / 213.76 |
| Backup SQLite snapshot pin | Writer | 3.889 ms | 22:43:33.401 | 196.71 / 184.89 / 213.76 |
| Backup receipt attempts | Writer / gate | 257.603 / 257.646 ms | 22:59:59.615 | 133.62 / 232.56 / 274.43 |
| Work-health fence setup | Writer | 1,502.698 ms | 22:42:04.086 | 140.42 / 179.46 / 215.47 |
| Work-health candidate apply | Writer | 693.543 ms | 22:44:52.317 | 390.51 / 248.50 / 235.39 |
| Work-health fence stop | Writer | 173.228 ms | 22:46:46.684 | 514.80 / 331.34 / 269.19 |
| Storage open | Writer | 11,142.732 ms | 22:40:42.093 | 141.74 / 190.27 / 222.10 |
| Storage open | Archive storage gate | 34,617.599 ms | 22:40:18.857 | 141.74 / 190.27 / 222.10 |
| Router startup | Writer / gate | 7,014.715 / 7,014.780 ms | 22:40:54.973 | 138.34 / 187.97 / 220.91 |

The command-result apply converted 250 aged results to tombstones. Its complete turn, including reader preparation, took 333.715 s. An earlier turn deferred after 716.543 s. The sampled backup receipt retries spent most of their writer time scanning for tickets waiting for Done evidence. That scan now uses a reader before the receipt, and each project wake has its own bounded writer step.

Build 422 (`9ae4162b2fae528d`) repeated the scoped workload with the reader-side Done-evidence scan. The forced backup completed in 563.682 s. The longest receipt writer and gate holds were 8.065 and 8.105 ms. The initial prune turn deferred after a command-result attempt held the writer for 811.990 ms. The aged tombstone count remained 19,802 at the end of that run.

| Observed work on build 422 | Resource | Longest hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Backup receipt | Writer / gate | 8.065 / 8.105 ms | 23:22:27.293 | 141.80 / 230.94 / 241.35 |
| Backup SQLite snapshot pin | Writer | 0.702 ms | 23:13:05.554 | 174.06 / 179.64 / 213.30 |
| Prune command-result attempt | Writer | 811.990 ms | 23:21:36.073 | 168.19 / 251.12 / 248.70 |
| Work-health fence setup | Writer | 3,836.929 ms | 23:15:02.382 | 354.28 / 239.94 / 232.27 |
| Work-health candidate apply | Writer | 1,853.212 ms | 23:22:16.397 | 146.68 / 234.89 / 242.84 |

Build 425 (`588181664594ccd1`) added 910 tombstones at a fixed age cutoff. Three successful turns converted 250, 500 and 160 command results. The first turn deferred three steps. The backup completed in 414.959 s. The separate archive preview returned `REFERENCE_GRAPH_LIMIT` after 752.792 s and retained the originals.

| Observed work on build 425 | Resource | Longest hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Write routing | Command queue | 126.980 ms | 23:42:29.430 | 197.53 / 217.04 / 208.01 |
| Prune command-result apply | Writer | 278.830 ms | 23:47:13.149 | 307.34 / 279.07 / 239.48 |
| Prune age mark | Writer | 107.823 ms | 23:40:21.691 | 233.00 / 231.75 / 210.77 |
| Work-health schema setup | Writer | 1,145.113 ms | 23:40:07.728 | 233.00 / 231.75 / 210.77 |
| Work-health fence setup | Writer | 3,812.975 ms | 23:43:50.458 | 281.86 / 240.23 / 217.82 |
| Work-health candidate apply | Writer | 1,411.789 ms | 23:48:02.879 | 256.57 / 270.75 / 238.73 |
| Ticket cleanup semantic commit | Writer / gate | 35.893 / 35.945 ms | 23:50:55.005 | 162.94 / 224.63 / 225.72 |
| Managed import recovery | Writer / gate | 201.356 / 201.592 ms | 23:53:14.266 | 178.24 / 208.30 / 218.92 |
| Backup receipt | Writer / gate | 8.892 / 8.942 ms | 23:49:01.302 / .301 | 225.14 / 261.26 / 237.30 |
| Storage open | Writer / gate | 11,625.839 / 35,354.763 ms | 23:39:45.701 / 23:39:22.464 | 242.91 / 233.60 / 211.16 |

Build 431 (`c9a8655ec7621682`) added 250 tombstones on a fresh copy of the latest backup. The first and third turns deferred. Its longest prune writer holds were 166.417 ms for cursors at 00:32:01.851 UTC on 28 November, load 300.02 / 293.28 / 251.39, and 126.320 ms for command results at 00:31:33.904 UTC, load 291.20 / 291.09 / 249.39. Work-health apply reached 869.787 ms at 00:30:13.760 UTC, load 301.72 / 290.23 / 244.90.

The observed prune and work-health maxima across these runs exceed the 250 ms maintenance limit. Archive unlink settlement, backup retirement, restore, native closure or resumption, first attachment-original lease, media deletion, and schema upgrade still need live-size hold samples.

### Build 432 on slot 4

The baseline stage reproduced build 432's shipping fingerprint
(`1da3b2cd99a62eb7`). The newest verified backup contained 78,937 commands
and 24,604 storage jobs. The census began at 04:56:15.891 UTC on 28 November
at load 145.36/245.04/220.45. The backup was already at the current schema.

| Work | Resource | Longest hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Storage open and preflight | Archive gate | 23,987.491 ms | 04:57:41.772 | 269.29 / 257.23 / 228.05 |
| Storage open verification | Writer connection | 9,031.399 ms | 04:57:56.639 | 261.22 / 255.46 / 227.26 |
| Router startup reconciliation | Writer / archive gate | 3,742.883 / 3,742.920 ms | 04:58:06.754 | 269.29 / 257.23 / 228.05 |
| Work-health journal preparation | Writer | 875.700 ms | 05:02:19.033 | 225.28 / 254.52 / 235.52 |
| Work-health apply | Writer | 885.103 ms | 04:58:58.135 | 304.40 / 268.67 / 233.95 |
| Ordinary claim | Writer / archive gate | 687.854 / 696.516 ms | 05:00:35.615 / .606 | 245.93 / 258.54 / 233.87 |
| Prune protection fence | Writer | 86.479 ms | 04:58:23.032 | 281.50 / 260.57 / 229.75 |
| Prune command results | Writer | 3.672 ms | 04:59:20.090 | 287.89 / 267.44 / 234.33 |

Eight first claims in the copied project took 400.280–685.450 ms from BEGIN
through commit. At the maximum, 679.729 ms was inside the transaction callback.
A service profile sampled `compactTaskContext` in SQLite record scans and
overflow-page reads. With zero outstanding directions, the legacy total-count
query alone visited the project's delivery history and took 236.329 ms wall
and 42.642 ms CPU at 04:56:16.297 UTC, load 145.36/245.04/220.45. The newer window
query used the message index in the same read-only comparison.

At cutoff 21,371, the one completing prune turn removed 40 unpruned results
while foreground fixture creation ran during the turn. The census retained
all 206 previously unpruned storage-job parents. The startup turn had deferred
before it reached result application. This copy had 290 aged, unpruned
results before startup, including protected results.

### Signed candidate inventory on 28 November 2026

The first candidate `5a392d41893763d3` used the same schema-6 snapshot with
78,937 commands and 24,604 storage jobs. This stage included the direction
receipt change and the health and quarantine changes.

| Observed work | Resource | Longest measured hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Ordinary claim | Writer / archive gate | 1,520.827 / 1,520.952 ms | 05:11:10.518 | 68.76 / 94.12 / 158.10 |
| Work-health apply | Writer | 703.494 ms | 05:26:57.922 | 128.42 / 98.93 / 109.94 |
| Work-health preparation | Writer | 300.627 ms | 05:19:36.553 | 76.10 / 65.49 / 111.95 |
| Incomplete backup retirement | Archive gate | 138.269 ms | 05:23:41.707 | 95.81 / 86.17 / 109.74 |
| Incomplete backup retirement | Writer / command queue | 4.992 / 4.843 ms | 05:23:41.839 / .801 | 95.81 / 86.17 / 109.74 |
| Whole-file attachment read operation admission | Writer | 9.082 ms | 05:22:34.264 | 112.39 / 86.06 / 111.75 |
| Media round deletion | Writer | 1,128.066 ms | 05:22:03.744 | 117.60 / 84.17 / 112.04 |
| Media round deletion | Archive gate | 109.788 ms | 05:25:10.756 | 106.72 / 91.72 / 109.61 |
| Media round deletion | Command queue | 3.959 ms | 05:22:02.854 | 117.60 / 84.17 / 112.04 |
| Backup capture intent | Writer / archive gate | 2.202 / 2.220 ms | 05:24:14.357 | 107.78 / 89.78 / 110.22 |
| Backup receipt commit | Writer / archive gate | 16.330 / 16.403 ms | 05:29:49.375 | 97.57 / 101.28 / 109.32 |
| Prune age mark | Writer | 13.292 ms | 05:10:43.119 | 48.92 / 93.46 / 160.17 |
| Prune command results | Writer | 4.757 ms | 05:11:34.209 | 59.00 / 90.25 / 155.23 |

The largest health apply spent 195.639 ms through BEGIN and 507.187 ms
in validation and finish. The callback took 0.650 ms. The media profile
sampled an inline SQLite passive checkpoint doing filesystem sync during
commit. The longest media writer hold was a separate interval. The synthetic
round had no original bytes. It accepted in 84.112 ms, reached its terminal
receipt after about 188 s, and kept the same operation on replay.

The worker retired one disposable pre-manifest backup folder after an exact
preview. A separate backup published and committed its receipt in 335.088 s.
Operation status then returned `COMMAND_RESULT_EXPIRED`. The worker's
6,304-byte original read succeeded and replayed under its accepted operation.
The first trusted native original lease still needs its own measurement.

At 05:23:16 UTC, load 99.05/85.92/110.36, a rolled-back WAL reservation
kept the edit's coordinator turn occupied for 4,198.958 ms and its writer
and gate occupied for 4,147.589 and 4,147.639 ms. Eighteen authenticated and
status probes replied while the three resources were occupied. Status took
151.048 ms. Authorization, catalog, project selection, project settings,
ticket detail, history, inbox, epics, cleanup jobs, operation status and
attachment metadata took 245–687 ms. Whole-file read admission took 581.730 ms.
Ticket context, ticket list and Triage list still took 2,472–2,662 ms.

Archive byte settlement, restore, native closure and resumption, the first
trusted original lease, and schema upgrade still need live-size measurements.
Failed-publication quarantine has a component hold check. It needs an exact
signed-slot failure after publication to measure the snapshot-local lease.

The `b48919e76537a7e0` stage's active checkpoint lane reached 145.269 ms
at 05:51:42.096 UTC, load 153.24/142.46/133.63. Its longest work-health apply
was 296.298 ms at 05:52:38.569 UTC, load 162.15/147.63/136.16. Its longest
health preparation was 212.461 ms at 05:52:12.638 UTC, load 172.21/148.00/135.94. The separate checkpoint
lane still shares filesystem I/O with writers and readers.

At fixed cutoff 21,626, the same stage removed 73 results in one completing
turn and retained all 225 protected parent rows. The result writer held
24.969 ms at 05:50:54.415 UTC, load 144.95/139.81/132.25. Foreground writes
started and completed during the turn's reader preparation.

The handler-tree SQL profile identified a full outer records scan in the initial
prepared query. The final prepared query drives the recursion with exact row IDs
and seeks final records by primary key. In a read-only control on the seeded
slot, the old project-scope query took 10.000 ms, the scan took 236.823 ms, and
the seek took 0.218 ms. All returned the same active tree. The three queries ran
at 05:54:57 UTC, load 121.12/139.74/134.90. The component differential covers
active descendants, inactive ancestors and unrelated tickets.

An archive executor component test processed 50,001 synthetic records and
removed the managed original. Its post-scan gate and writer phase was at most
15.007 ms. The control's one in-writer admission took 5.009 s. The test group
ran at 05:58:52–05:59:45 UTC, load 89.10/122.21/129.09 to 60.46/109.67/124.07.
The signed live-size event census observed no
original removals during its measured window.

### Final signed stage on 28 November 2026

The final `b5c3bc86f62ba6b7` stage used the same 78,937-command,
24,604-storage-job snapshot. All sixteen ordinary claims committed and
replayed under their original IDs. Eight ran with 150 competing foreground
captures. The competing BEGIN-through-commit maximum was 105.635 ms. The
physical writer and gate held 107.584 and 107.619 ms at 06:20:13.322 UTC,
load 45.39/65.53/84.21. The other eight took 73.632–97.617 ms through commit,
at 06:19:36–06:19:41 UTC. The command evidence records each load. The
selection stayed current during these unrelated writes. Sustained edits to the
same selection can still trigger retry and the original writer query.

| Observed work | Resource | Longest measured hold | Start (UTC) | Load |
| --- | --- | ---: | --- | --- |
| Result pruning | Writer | 12.569 ms | 06:19:19.914 | 55.72 / 70.81 / 87.19 |
| Health apply | Writer | 11.403 ms | 06:19:52.294 | 50.59 / 68.18 / 85.68 |
| Health preparation | Writer | 11.880 ms | 06:20:55.501 | 48.54 / 63.79 / 82.71 |
| Passive checkpoint | Checkpoint connection | 165.105 ms | 06:21:10.939 | 46.71 / 62.65 / 81.98 |
| Incomplete backup retirement | Gate / writer / coordinator | 105.708 / 5.503 / 0.972 ms | 06:21:02.789 / .889 / .871 | 47.47 / 63.07 / 82.23 |

The completing prune turn left 269 of 342 unpruned results at fixed cutoff
21,626. It preserved all 225 protected parents. Foreground captures and edits
started while the prune was preparing. A second held-resource test at
06:20:56 UTC, load 48.54/63.79/82.71, let all 18 valid probes finish during
the edit's multi-second hold. Status took 184.718 ms and Triage list took
1,281.818 ms. The earlier higher-load health overruns remain open under the
250 ms physical limit. The first successful status request started before
readiness and took 5.986 s. Later status replies during the initial prune
window reached at most 59.738 ms.
