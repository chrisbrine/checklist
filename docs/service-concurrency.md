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
| Backup retention, explicit prune and incomplete-generation retirement | Writer and gate during retirement intent, publication and settlement | Other reads proceed. Snapshot use, pin and retirement share the gate. |
| Work-health checks | Reader during candidate selection, writer during a targeted check and advisory receipt | Foreground commands take precedence. |
| Native close and resume, owner disconnect and allow, source recovery | Writer and gate during durable authority changes, outside provider observation | Reads proceed. Ticket claims, generation and delivery fences settle together. |
| Bootstrap, schema upgrade, recovery and startup fences | Gate and writer as needed before authority opens | An upgrade exposes its separate progress status. Authoritative reads begin once recovery permits them. |

## Hold evidence

The step deadline starts before SQLite acquires its write transaction. Maintenance tries the writer and gate without waiting behind foreground work. SQLite checks the monotonic deadline during execution, and the apply step checks it before commit. A filesystem syscall, commit flush or process descheduling can still run past a deadline. The watchdog measures the actual hold.

`service_info.data.busy_periods` reports current and recent holds over one second. The local busy-period file also records the over-limit active observation and completion. Test slots emit new measured maxima by resource and work label, with UTC start and observation times and load at observation. The command-result journal uses separate labels for the age mark, protection fence and apply.

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

The observed prune and work-health maxima across all runs exceed the 250 ms maintenance limit. Archive unlink settlement, backup retirement, restore, native closure or resumption, first attachment-original lease, media deletion, and schema upgrade still need live-size hold samples.
