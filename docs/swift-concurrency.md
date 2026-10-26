# Swift concurrency checking (CL-86)

The root manifest enables complete concurrency checking for every Swift target.
ChecklistProviders, ChecklistIPC, ChecklistBridges, ChecklistMCPServer,
ChecklistService, ChecklistCLI and the build-only ChecklistProducts use Swift 6 language mode. The independent
ChecklistShared manifest keeps ChecklistDomain, ChecklistContracts and
ChecklistApplication in Swift 6; no shared target is relaxed.

The remaining root adapters and fixtures temporarily use Swift 5 language mode
with complete checking. This is an explicit migration boundary, not a claim that
warnings are safe or that an unchecked Sendable conformance proves isolation.
Switching the remaining adapters to Swift 6 was checked and fails on legacy
shared state and isolation boundaries. The per-location audit below records the remaining findings and repair
boundaries. Do not add blanket unchecked conformances, preconcurrency imports or
diagnostic suppression to make this conversion appear complete.

## Fixed risks and ownership

The router's old mutable lifecycle callback is absent: the service coordinator
owns command hooks on its serial queue. CommandRouter still has an unchecked
conformance relying on GRDB writer serialization, per-read snapshots, preparation
locks and the serialized maintenance lane. Its lifecycle owner must drain work
before closeStore; closeStore itself does not establish that drain.

ChecklistClient registration state is contained in an OSAllocatedUnfairLock.
Detached unregister tasks own their SMAppService instance and return a copied
error string through a separate lock. XPC completion state is contained in one
lock; only the first reply/interruption/invalidation signals its waiter. Async
calls transfer JSON Data across dispatch, decoding a local graph on each side.
The public error's arbitrary Any details remain a separate unresolved boundary.

Bridge has a dedicated serial dispatch executor. Its synchronous IPC, bootstrap
and child-process waits run on that executor, preserving actor serialization
without blocking a Swift cooperative worker. This does not make IPC asynchronous
or permit another Bridge job to overtake a waiting job.

RecordOrdering's former static ISO8601DateFormatter instances already reside in
one locked bounded cache in the inherited source; its private fields cannot
escape. RequestRowPresentation now also contains both parsers in one lock and
returns only Date values. Its unchecked lock-state initializer is narrow: no
formatter reference leaves the critical section. Work-health defaults and cleanup
schema dictionaries are computed fresh instead of sharing non-Sendable Any graphs.

## Remaining boundaries

Core stays in Swift 5 while captured process-pipe results, database callbacks,
reference-index observers and native storage helper caches acquire explicit
Sendable ownership. Replacing Any-backed records and errors needs a value/codec
contract, coordinated with CL-88; storage callbacks/helpers overlap CL-99.
Do not move them into shared packages merely to avoid checking them.

IPC compiles in Swift 6, but ChecklistError.details still publicly accepts arbitrary
[String: Any]. Serializing it silently would reject, discard or trap on values
that its nonthrowing initializer currently preserves. Define and test the error
value contract before changing its stored representation.

Service also compiles in Swift 6, with warnings for dispatch callbacks capturing
the coordinator, peer/XPC reply closures, timing state and Any request/reply graphs. Queue-confined
ownership needs to be expressed and verified across the exact signed XPC path;
an annotation alone would not protect those objects.

App stays in Swift 5 because preview tasks return Any graphs or PDFDocument,
loader/file-inspection/termination callbacks cross isolation boundaries, and
AppKit accessibility/window/cache callbacks need explicit main-actor ownership.
SwiftUI environment defaults also retain non-Sendable closures. Converting these
requires updating their callers and native lifecycle tests together; this pass
does not change their UI behavior or claim those races are resolved.

Test/probe targets stay in Swift 5 with complete checking because legacy mutable
fixture counters, lock-protected captured variables, Any test records and native
fake callbacks need their own checked state containers/isolation. Preserve their
assertions; do not weaken tests or mark every fake unchecked to compile in Swift 6.
StorageReleasedCoreFixture is a frozen historical crash/recovery input and is
not rewritten as part of the current language migration.

Legacy Keychain and native AX deprecation warnings remain visible. Credential
CRUD already uses SecItem. The remaining file-keychain interaction/ACL APIs and
AXEnhancedUserInterface fixture setup have no established supported equivalent
with the same behavior. Credential migration or changing that native harness
requires explicit scope and qualification, not suppression of these diagnostics.

## Qualification

Use a fresh scratch directory with swift build --build-tests for an exact warning
inventory, and the affected-test selector for changed targets. Keep the assigned
shared build-slot wrapper and dependency cache settings. Compiler checking and
anonymous XPC fixtures do not qualify installed signed credentials, service
registration, native bootstrap, UI accessibility, traffic latency or memory.
Those observations bind to the exact composed stage and remain runner work.

## Exact complete-check findings

The clean all-target check with the Swift 6.4 toolchain reports 318 distinct
concurrency diagnostics, plus 40 legacy API deprecations. Each line/column below
identifies a remaining compiler finding in this source; the reason and repair
apply to every listed location in that row. Multiple diagnostics at one location
share that ownership boundary. These are deferred implementation steps, not
requests for owner permission. No listed warning is certified harmless. Recheck
changed boundaries after CL-88/CL-99 composition, since source locations move.

### Production

| File and line:column | Unresolved boundary / smallest repair |
| --- | --- |
| `Sources/ChecklistApp/Media/MediaOwnerComparison.swift` — 241:126 | OperationQueue bridge captures arbitrary generic operation and result with no Sendable constraints. Repair: Require @Sendable operation and T: Sendable and fix actual inputs; keep mutable media/framework objects with one owner. |
| `Sources/ChecklistApp/Media/MediaReviewWorkspace.swift` — 102:84 | Binding setter method reference is converted to Sendable closure without explicit actor contract. Repair: Use an explicit MainActor setter closure and ensure model remains actor-owned; preserve chooseRound reset/refresh behavior. |
| `Sources/ChecklistApp/Models/RequestFileInspection.swift` — 72:26, 81:17 | Inspection worker and completion aliases lack Sendable/actor contracts across worker queue and main completion. Repair: Declare worker/progress/cancellation closures Sendable, completion MainActor, and make scope/result immutable Sendable; audit cancellation and stale-scope fences. |
| `Sources/ChecklistApp/Models/TicketBulkSelection.swift` — 44:73 | EnvironmentKey static default contains interaction closures without Sendable/actor contracts. Repair: Give row interaction callbacks explicit main-actor Sendable ownership or an immutable Sendable interaction model; preserve selection behavior. |
| `Sources/ChecklistApp/Previews/AuthorizedPreviewFile.swift` — 149:38, 151:15, 172:29 | Preview read task returns Any-valued service response across actor boundary and detached copy captures source/progress hooks with incomplete ownership contracts. Repair: Decode read authorization into immutable Sendable metadata on MainActor, send only file-copy inputs to detached work and explicitly isolate progress/test callbacks; keep hold release/cancellation fences. |
| `Sources/ChecklistApp/Previews/MarkdownPreview.swift` — 42:72 | Async resource loader receives store-request closure without shared actor/Sendable contract. Repair: Keep resource authorization loader and request callback on MainActor or send typed Sendable requests/responses across explicit worker boundary; preserve scope and seed validation. |
| `Sources/ChecklistApp/Previews/NativeFilePreview.swift` — 4:1, 193:17, 193:24, 193:29, 194:32, 194:37 | Detached task returns PDFDocument, a non-Sendable PDFKit object, to UI actor. Repair: Perform PDFDocument creation/ownership on MainActor or use a dedicated owner that sends immutable preview data; do not globally declare PDFKit objects Sendable. Check preview responsiveness after repair. |
| `Sources/ChecklistApp/Stores/ChecklistStore.swift` — 46:17, 482:38, 493:13, 496:56, 510:31, 510:45, 972:31, 1543:50, 1544:54 | Task results contain SelectedTicketDisplay backed by Any-valued records; task-group MainActor closure also reaches a region-checker unsupported pattern. Repair: Use an immutable Sendable selected-display snapshot at task boundaries or keep recovery entirely in actor-owned async state; restructure overview task scheduling with explicit actor-owned inputs rather than suppress checker diagnostics. |
| `Sources/ChecklistApp/Support/CaptureTermination.swift` — 26:27, 26:36 | Background queue captures plain check and completion closures with unspecified ownership. Repair: Require Sendable check/results and MainActor completion (or explicit completion executor), fix captures at construction and preserve termination timeout/completion behavior. |
| `Sources/ChecklistApp/Support/Design.swift` — 380:17, 381:11, 382:11, 383:11, 384:11, 385:18, 385:44 | Synchronous chooseFiles is nonisolated but constructs/configures/runs NSOpenPanel. Repair: Mark chooseFiles MainActor and propagate caller isolation; preserve synchronous modal result handling. |
| `Sources/ChecklistApp/Support/DetailOverlayInteraction.swift` — 1:1, 35:9, 36:9, 37:9 | Nonisolated deinit reads main-actor monitor/notification token storage and performs UI-related cleanup. Repair: Provide deterministic MainActor teardown at overlay lifecycle end and a safe token cleanup owner; preserve removal on every dismissal path. |
| `Sources/ChecklistApp/Support/DisplayCaches.swift` — 44:16 | Global image cache owns mutable image entries and AppKit images without a compiler-visible confinement boundary. Repair: Audit all cache reads/writes; isolate UI image cache to MainActor or protect state while keeping NSImage use on its supported lane. |
| `Sources/ChecklistApp/Support/LazyListAccessibilityGuard.swift` — 17:24, 45:79, 46:45, 47:35, 48:43, 48:63, 49:41, 50:22, 50:49, 51:24 | Swizzled AX entry and static installed flag are nonisolated while scrolling touches main-actor AppKit state. This is a real unproven boundary, not a harmless warning. Repair: Enforce and encode main-thread installation/action execution, isolate installed state and scrolling helper; bridge the Objective-C callback with checked actor preconditions, preserving synchronous handled/fallback action semantics. |
| `Sources/ChecklistApp/Support/QuickCapture.swift` — 139:107 | MainActor quick-capture model forwards Any-valued params to an async transport callback with no matching actor/Sendable contract. Swift 5 compatibility mode does not prove the callback stays on the actor. Repair: Give transport an explicit MainActor contract if UI-owned, or transfer immutable Sendable command/response data across the worker boundary; preserve idempotent command IDs and retry behavior. |
| `Sources/ChecklistApp/Support/SettingsModalPresentation.swift` — 1:1, 15:70, 53:9, 54:9, 55:9 | Environment action default lacks Sendable ownership and nonisolated deinit accesses main-actor event/observer tokens. Repair: Type settings action as main-actor Sendable; arrange explicit main-actor lifecycle teardown or a dedicated thread-safe token owner so deinit does not access isolated state. |
| `Sources/ChecklistApp/Support/TestInstanceIdentification.swift` — 46:27, 46:51 | Notification callback is Sendable and directly mutates NSWindow title despite main-actor AppKit ownership. Repair: Hop/check MainActor in notification delivery and keep title mutation actor-isolated; preserve slot-identification timing. |
| `Sources/ChecklistApp/Views/CaptureEpicCreator.swift` — 26:34 | UI retains pending Any-valued epic mutation parameters while handing them to a nonisolated async request callback. Suspension and retained aliases make the transfer unproven. Repair: Align request closure with MainActor UI ownership or pass a typed immutable Sendable epic request; keep the same pending command ID through ambiguous failures. |
| `Sources/ChecklistApp/Views/ProjectSettingsView.swift` — 142:73 | Binding setter applyPreset method reference has implicit actor ownership during Sendable conversion. Repair: Use explicit MainActor binding closure and maintain settings write ordering. |
| `Sources/ChecklistCore/AgentReviews.swift` — 108:66 | GRDB rollback callback captures a filesystem rollback owner whose mutable committed/lifecycle state is not Sendable. Repair: Make the rollback token immutable where possible and guard any lifecycle flag with lock-owned state; preserve exactly-once file cleanup and transaction rollback semantics. |
| `Sources/ChecklistCore/EpicReferenceIndex.swift` — 114:23 | Background index queue captures a mutable lifecycle owner weakly; weak capture alone proves neither isolation nor thread safety. Repair: Audit stop/start and index work state, encode queue/lock confinement in a state container or actor and pass only immutable work inputs across dispatch. |
| `Sources/ChecklistCore/SourceCapture.swift` — 136:44, 136:67 | Pipe readers mutate output/errors captured local variables; the adjacent NSLock does not give the captured storage a Swift ownership model. Repair: Put stdout/stderr data in a single lock-owned Sendable result state and read its snapshot after the reader group joins. |
| `Sources/ChecklistCore/StorageBootstrap.swift` — 53:70 | GRDB prepareDatabase callback is Sendable but receives a plain escaping closure from bootstrap API. Repair: Require a Sendable preparation closure and fix each capture at callers; keep database use scoped to GRDB callback and startup ordering unchanged. |
| `Sources/ChecklistCore/StorageFolderAccess.swift` — 65:16 | Shared reaper owns its dispatch queue and lifecycle state; compiler cannot prove its queue confinement. Repair: Audit every reaper state access, move mutable state into a lock-owned container or actor and retain asynchronous close/reap behavior before claiming Sendable. |
| `Sources/ChecklistCore/StorageObjectFiles.swift` — 171:20 | PinnedRoots singleton holds weak root records and lock-protected mutable entries; the class has no explicit concurrency contract. Repair: Encapsulate all entries inside a Sendable lock-state container; audit weak-root lifetimes and callers before any narrowly justified conformance. |
| `Sources/ChecklistIPC/Protocol.swift` — 25:16 | ChecklistError.details stores arbitrary Any while Error is Sendable; unchecked conformance would accept unknown mutable reference payloads. Repair: Introduce a validated Sendable JSON/error-detail value at the error boundary and convert to wire dictionaries locally; preserve existing diagnostics fields. |
| `Sources/ChecklistService/main.swift` — 118:42, 158:24, 159:34, 163:17, 169:56, 186:26, 188:35, 374:50, 376:34, 377:51, 379:37, 379:51, 434:41, 435:31, 450:109, 450:185, 458:21, 458:112, 545:29, 554:29, 564:27, 565:61, 565:79, 565:97, 565:105, 573:98, 586:21, 588:129, 589:21, 590:21, 590:74, 590:87, 590:143, 594:90 | Service coordinator/peer dispatch crosses serial coordinator, maintenance and XPC execution lanes with Any dictionaries, timing objects, reply closures and NSXPCConnection. Existing queues do not prove all object accesses isolated. Repair: Split coordinator-owned mutable state from immutable Sendable command/delivery snapshots; explicitly own XPC reply/connection lifetime on one lane; mark callbacks Sendable only after capture audit. Preserve writer admission, pooled reads, ordered replies and shutdown behavior. |

### Fixtures

| File and line:column | Unresolved boundary / smallest repair |
| --- | --- |
| `Tests/ChecklistAppTests/CachedProjectSwitchFrameTests.swift` — 48:53 | Continuation resumes with Any reply returned from async actor-owned transport. Repair: Give held reads typed Sendable payload or decode on same actor before continuation; preserve held-read destination-frame checks. |
| `Tests/ChecklistAppTests/CachedScreenReturnTests.swift` — 70:109, 71:114 | Screen cache harness keeps Any replies in pending tuples and sends them to asynchronous readers through continuations. Repair: Store immutable Sendable reply snapshots/wire Data and keep all pending-list mutation on harness actor; preserve cached-return/late-reply tests. |
| `Tests/ChecklistAppTests/ColorContrastTests.swift` — 71:52 | Synchronous XCTest method/autoclosure reads main-actor SwiftUI/AppKit presentation API without actor isolation. Repair: Mark affected test method MainActor and evaluate actor-owned properties into local values before XCTest autoclosures where required; preserve existing assertions. |
| `Tests/ChecklistAppTests/ConfirmationTests.swift` — 3:11, 39:38, 39:52, 47:34, 47:48 | Binding Sendable getter/setter close over mutable pending confirmation local and performed state. Repair: Use MainActor harness state object for pending/performed values and explicit actor-owned binding closures; preserve exactly-once confirmation checks. |
| `Tests/ChecklistAppTests/GlossaryTests.swift` — 12:75, 13:76, 44:42, 45:42, 47:42, 48:42 | Synchronous XCTest method/autoclosure reads main-actor SwiftUI/AppKit presentation API without actor isolation. Repair: Mark affected test method MainActor and evaluate actor-owned properties into local values before XCTest autoclosures where required; preserve existing assertions. |
| `Tests/ChecklistAppTests/HumanClaimsKeychainTests.swift` — 37:17, 38:32, 44:17 | Concurrent no-UI test mutates captured active counter behind an external lock. Repair: Use lock-owned active state with atomic increment/assert/decrement; keep the actual Keychain interaction-flag verification. |
| `Tests/ChecklistAppTests/IsolatedDefaults.swift` — 64:32, 64:38 | Sendable XCTest teardown captures a mutable suite owner. Repair: Transfer immutable suite identity/cleanup paths into teardown or make a narrowly owned cleanup token; preserve deterministic suite cleanup. |
| `Tests/ChecklistAppTests/LiveUpdateFreshnessTests.swift` — 93:144, 189:48, 193:49, 291:56, 295:49, 314:46, 318:49, 446:44 | Held service reply continuation transfers Any dictionary while fixture mutates version/status. Repair: Freeze typed Sendable reply at hold time and keep commit/release state actor-owned; retain revision/late-reply fences. |
| `Tests/ChecklistAppTests/NeedsYouRefreshTests.swift` — 55:63 | Needs You harness sends retained Any heldReply through a continuation while fixture retains state. Repair: Use Sendable held reply representation and clear ownership before resume; preserve completion-refresh ordering and notification assertions. |
| `Tests/ChecklistAppTests/OverviewReadRecoveryTests.swift` — 67:38 | Recovery harness continuation sends Any-valued reply computed from retained call state. Repair: Produce Sendable reply snapshots at hold/release boundary and retain per-call cancellation, failure and fallback ordering. |
| `Tests/ChecklistAppTests/OverviewTests.swift` — 75:25 | Async badge permission method receives UserDefaults preferences still reachable from test suite owner; actor transfer is unproven. Repair: Align permission function and test with explicit MainActor ownership or pass immutable permission preference values; retain no-unrequested-system-prompt behavior. |
| `Tests/ChecklistAppTests/OwnedStoreScreenCacheTests.swift` — 35:34, 35:39, 35:129 | Detached pure-read sends Any request/response across MainActor test transport boundary. Repair: Encode immutable typed request/response snapshots or serialize to Data across worker boundary; preserve real copied-store read and cache observations. |
| `Tests/ChecklistAppTests/PendingCommandRecoveryTests.swift` — 189:14 | Held identity continuation transfers Any reply from mutable fixture state. Repair: Use typed identity reply/Sendable wire payload and keep held continuation lifecycle on one actor; preserve recovery ordering. |
| `Tests/ChecklistAppTests/PlainLanguageTests.swift` — 86:24, 86:122, 87:23, 87:84 | Synchronous XCTest method/autoclosure reads main-actor SwiftUI/AppKit presentation API without actor isolation. Repair: Mark affected test method MainActor and evaluate actor-owned properties into local values before XCTest autoclosures where required; preserve existing assertions. |
| `Tests/ChecklistAppTests/PreviewCancellationTests.swift` — 108:22 | Canceled preview task receives mutable Any reply with a late read_hold_id; compiler cannot prove dictionary aliases stop at resume. Repair: Build independently owned typed Sendable read authorization metadata or wire Data before resume; keep late-hold release and canceled-preview assertions. |
| `Tests/ChecklistAppTests/PreviewReworkTests.swift` — 101:60, 118:57, 121:53, 123:56 | Resource-loader async transport closures capture actor-local calls and Any reply fixtures without matching ownership. Repair: Align loader transport to MainActor or typed Sendable transport, store call count on harness actor and retain every partial/foreign/stale-seed rejection. |
| `Tests/ChecklistAppTests/ReadCancellationTests.swift` — 54:71, 80:17, 80:24, 85:39, 85:44, 101:13, 101:20, 104:28, 104:33 | Task returns Any service response while current/held state is actor-owned by test. Repair: Use actor-owned async helper with typed Sendable response or decode accepted scalar before task return; keep superseded-reply and current-state cancellation assertions. |
| `Tests/ChecklistAppTests/RecordOrderingTests.swift` — 2:11, 26:43, 26:98 | Concurrent sorting captures Record arrays containing Any and writes local failure counter. Repair: Provide immutable Sendable record projection or per-worker records and use locked failure state; retain concurrent cache/parser exercise. |
| `Tests/ChecklistAppTests/ScopedWorkspaceReadTests.swift` — 82:57, 568:60 | Resource authorization loader captures MainActor store.request through nonisolated async callback. Repair: Use same actor-aware transport contract as production Markdown loader and preserve selected-ticket/scope fencing assertions. |
| `Tests/ChecklistAppTests/ScreenTimingTests.swift` — 28:117 | Timing harness sends Any receipt dictionaries retained alongside continuations across async boundary. Repair: Freeze receipts into typed Sendable snapshots/wire Data and keep held-array mutation actor-owned; preserve literal receipt and delayed-display checks. |
| `Tests/ChecklistAppTests/SelectedRecordRecoveryTests.swift` — 65:88 | Selected-record harness continuation sends retained Any heldReply while fixture owns held error/reply state. Repair: Transfer immutable Sendable response and clear retained ownership at release; keep obsolete context, failure and recovery ordering assertions. |
| `Tests/ChecklistAppTests/TaskHandoffTests.swift` — 164:31, 183:42, 199:31, 211:31, 226:30 | Held provider-preparation continuations receive Any-valued response fixtures from self while a prior preparation task is still outstanding. Repair: Return typed Sendable preparation reply or independently encoded immutable payload; retain stale ticket/provider preparation and dismissal ordering. |
| `Tests/ChecklistAppTests/TicketEpicReadTests.swift` — 72:109, 73:114 | Held epic read replies are Any dictionaries retained in actor-local pending tuples when sent through continuations. Repair: Store pending typed Sendable responses or immutable wire Data; keep per-read release order, cached choices and context freshness checks. |
| `Tests/ChecklistAppTests/TicketReadinessLabelTests.swift` — 64:26, 65:35, 66:35, 67:34 | Synchronous XCTest method/autoclosure reads main-actor SwiftUI/AppKit presentation API without actor isolation. Repair: Mark affected test method MainActor and evaluate actor-owned properties into local values before XCTest autoclosures where required; preserve existing assertions. |
| `Tests/ChecklistAppTests/TicketRetirementDialogTests.swift` — 36:18, 57:18, 87:18, 121:18 | Tests resume held async reads with Any-valued preview dictionaries still reachable through XCTest self. Repair: Construct independent Sendable preview snapshots for each held reply, or serialize at the continuation boundary; keep dismiss/scope-change/late-preview assertions. |
| `Tests/ChecklistAppTests/TicketStatusReasonTests.swift` — 14:36, 14:72, 16:24, 16:58, 21:25, 21:61, 22:25, 22:59, 23:22, 23:62, 24:22, 24:75 | Synchronous XCTest method/autoclosure reads main-actor SwiftUI/AppKit presentation API without actor isolation. Repair: Mark affected test method MainActor and evaluate actor-owned properties into local values before XCTest autoclosures where required; preserve existing assertions. |
| `Tests/ChecklistAppTests/TriageBatchHistoryTests.swift` — 95:18 | Old history load continuation receives Any reply built through XCTest self while a newer history load has completed. Repair: Freeze typed Sendable history reply before resume and retain stale-load rejection scenario. |
| `Tests/ChecklistCoreTests/AgentBackupRouteTests.swift` — 4:11, 168:163 | Concurrent backup captures mutable StorageSnapshotBudget with callback-bearing ownership. Repair: Freeze a per-operation Sendable budget snapshot and make budget callbacks Sendable with isolated result state. |
| `Tests/ChecklistCoreTests/AttachmentOwnershipTests.swift` — 255:94 | Maintenance worker captures whole StorageFixture while foreground holds storage gate. Repair: Capture lifecycle-stable router independently and prove join before optional router teardown; preserve exclusive gate/barrier test. |
| `Tests/ChecklistCoreTests/BatchRaceTests.swift` — 16:64 | Race workers capture Any-valued parameter dictionary despite existing result collector. Repair: Convert immutable validated command parameters to Sendable representation and materialize dictionary within each worker. |
| `Tests/ChecklistCoreTests/CoreTests.swift` — 140:26, 140:44, 140:65, 141:34 | Concurrent claim test captures XCTest self/Any input and mutates local success/failure counters. Repair: Extract router/caller/scalar claim IDs and use lock-owned counts; retain eight-way race and exact winner assertion. |
| `Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift` — 86:78, 86:84, 86:86, 86:155 | Concurrent claims capture XCTest self and Any records while mutating a local winner count. Repair: Build scalar claim inputs per iteration with explicit router/caller ownership; store winners in a lock-owned counter. |
| `Tests/ChecklistCoreTests/ImportStoreCopyQualificationTests.swift` — 28:14, 42:34, 48:37, 49:42 | Concurrent measurement captures plain sample function and mutates calls/failures arrays. Repair: Use Sendable typed sample values/function and a locked measurement collector; preserve measured lanes and no widening of timing acceptance. |
| `Tests/ChecklistCoreTests/MediaHistoryCaptureTests.swift` — 4:11, 258:25, 259:37, 259:56, 261:116, 261:136, 262:27 | Contender captures full mutable media fixture, Any reference/prepared attachment and writes local error. Repair: Extract immutable hold ID/path/caller before dispatch, use router ownership boundary and locked result; preserve archive gate acquisition and join before cleanup. |
| `Tests/ChecklistCoreTests/MediaRoundTests.swift` — 476:25, 476:63, 476:159 | Background edit captures mutable fixture and Any record and writes local commandError. Repair: Capture item ID/revision/caller and router separately, collect error in lock-owned result and join before teardown. |
| `Tests/ChecklistCoreTests/OverviewReadOptimizationTests.swift` — 146:110, 154:110 | Concurrent pinned snapshot closure captures the full mutable ReadPerformanceFixture for its caller. Repair: Capture immutable caller/project values and reader/router handles with documented ownership instead of the fixture; preserve pinned-transaction barrier. |
| `Tests/ChecklistCoreTests/ReadSnapshotCacheTests.swift` — 56:87 | Pinned read closure captures whole mutable fixture to access owner. Repair: Capture immutable owner independently and keep fixture teardown after reader join. |
| `Tests/ChecklistCoreTests/RecordPruningTests.swift` — 104:57, 105:17, 124:31, 124:100, 124:127, 125:13, 125:68 | Concurrent pruning/attachment read captures XCTest self, Any records and mutable timing/hold results. Repair: Capture router/caller/root and scalar IDs independently; collect timing/hold/error in lock-owned result storage and join before teardown. |
| `Tests/ChecklistCoreTests/ScreenReadQueryPlanTests.swift` — 57:69 | GRDB Sendable trace hook captures mutable QueryTrace reference. Repair: Make trace collector internally lock-owned with a Sendable interface; snapshot results after hook removal. |
| `Tests/ChecklistCoreTests/StorageBackupConcurrencyTests.swift` — 5:11, 27:122, 27:137, 137:71 | Backup workers capture mutable budget and full StorageFixture while retention worker also uses fixture root. Repair: Freeze budget/caller/root before dispatch; isolate fixture-owned store lifecycle and join every worker before teardown. |
| `Tests/ChecklistCoreTests/StorageDeadlineReadTests.swift` — 55:29, 57:29, 90:32 | Concurrent closures mutate holding/failure local storage even though NSLock surrounds some accesses. Repair: Move holding and failure into one lock-owned state container; retain barrier ordering and snapshot reads under that lock. |
| `Tests/ChecklistCoreTests/StorageFolderAccessTests.swift` — 25:26, 87:26 | Delayed waitpid check captures mutable children array. Repair: Freeze child pid array before scheduling and retain join before process/fixture cleanup. |
| `Tests/ChecklistCoreTests/TestStoreTests.swift` — 44:37, 45:39 | Concurrent store-creation workers mutate captured identity/error collections behind external lock. Repair: Move both collections into lock-owned state and preserve per-worker store close before join. |
| `Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift` — 134:177, 142:54, 316:52, 478:193, 480:166, 490:54, 496:140 | Traffic/sampler workers capture XCTest self for owner/RSS and Any-valued trafficEpic. Repair: Capture immutable caller/epic ID, extract Sendable RSS helper and keep traffic stop/join ownership explicit; preserve actual traffic rates and CPU/RSS assertions. |
| `Tests/ChecklistCoreTests/WriterLockTests.swift` — 18:26, 18:44, 18:47, 18:60, 19:26, 49:22, 49:42, 50:26 | Worker captures XCTest self, Any command inputs, plain operation closure and mutable errors/timing. Repair: Build Sendable command closure from scalar IDs and independently owned router/caller; collect elapsed/error in locked result, retain semaphores and assertions. |
| `Tests/ChecklistIPCTests/AsyncServiceCallTests.swift` — 25:94 | Delayed fake XPC reply closure has no Sendable ownership contract. Repair: Give delayed reply a one-shot executor-owned sender and transfer immutable response Data only. |
| `Tests/ChecklistIPCTests/LongCommandTests.swift` — 37:21, 41:21, 71:25, 72:21 | Delayed XPC service captures mutable service, reply and connection across global queues. Repair: Separate lock-owned fake service state from immutable request data and give reply/connection a single executor-owned wrapper; keep disconnect-after-commit timing. |
| `Tests/ChecklistMCPServerTests/DelegateChildBindingTests.swift` — 49:91, 74:91, 91:22 | Sendable validation hooks capture mutable filesystem Fixture owning replacement executable/slot state. Repair: Capture immutable paths and build a narrowly owned filesystem mutation hook; keep fixture teardown strictly after hook execution and retain adversarial replacement order. |
| `Tests/RequestAnswerCompletionTests/RequestAnswerCompletionChecks.swift` — 12:16 | Standalone check runner stores mutable global check count without an execution-actor contract. Repair: Place runner/check-count owner on MainActor or pass a local counter through synchronous checks; keep check totals and exit status. |
| `Tests/RequestRowPresentationTests/RequestRowPresentationChecks.swift` — 12:16 | Standalone check runner stores mutable global check count without an execution-actor contract. Repair: Place runner/check-count owner on MainActor or pass a local counter through synchronous checks; keep check totals and exit status. |
| `Tests/TestResultEvidenceProjectionTests/main.swift` — 3:11, 10:5, 32:5 | Standalone runner exposes non-Sendable closure tables and, for projection, Any-backed Record as globals. Repair: Move fixture values and check table into a single synchronous entry function or explicitly MainActor runner; keep per-check exception reporting. |
| `Tests/TestResultParserTests/main.swift` — 81:5 | Standalone runner exposes non-Sendable closure tables and, for projection, Any-backed Record as globals. Repair: Move fixture values and check table into a single synchronous entry function or explicitly MainActor runner; keep per-check exception reporting. |

