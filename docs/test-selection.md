# Selecting checks for a build round

Before installing a combined round, run the tests for the changed targets and their dependents, the affected Python script tests, and `validate-plan.py` on the exact composed source. Use `script/affected_tests.py` to plan those checks:

```sh
python3 script/affected_tests.py --base <round-base> --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths Sources/ChecklistApp/Support/Canceled.swift --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths-file changed-paths.txt --scratch-path <build-slot>/.build --json
```

Script tests in both round checks and the background full suite use **uv-managed CPython 3.12**, selected explicitly with `uv run --no-project --python 3.12 --with jsonschema --with pyyaml python <script>`. The selector emits this same interpreter and dependency prefix for every Python test and `validate-plan.py`, including in `--full` mode. Use the emitted commands for both runs; an unpinned `uv run` or a bare `python3` test command can select a different interpreter. The `python3` commands above only launch the planner.

The script prints commands; it does not execute them. JSON contains argv arrays in `commands`, plus `test_targets`, `affected_targets`, `python_tests`, `skip` and `fallback_paths`. `--paths-file -` reads newline-delimited paths from stdin. Paths are relative to the repository root. `--base` includes committed changes since the base, staged and unstaged changes, deletions, both rename endpoints and untracked files. Supply the union of all tickets' changed paths when planning a combined round.

## Target selection

The selector reads `swift package describe --type json` and caches the result under `<scratch-path>/affected-tests/<Package.swift SHA-256>.json`. Root or nested package manifest/lockfile changes invalidate the cache. For fallback it uses target paths from that graph, including custom paths and nested fixture targets, and follows reverse `target_dependencies` transitively. Graph closure for a changed test target selects itself, without selecting tests of its dependencies; explicit file readers can add other consumers. The named runtime-consumer map also selects Core tests for `StorageCrashProbe` (including its nested released fixture) and MCPServer tests for `ChecklistCLIInputProbe`. The tests launch or copy these executables at runtime without a SwiftPM dependency. The shipping CLI is imported by CLI tests; the MCP shim tests launch the input probe instead. Source-inspection dependencies also select App tests when Service, CLI, Bridges or Core test sources change (the glossary checks enumerate those trees). App source selects `ChecklistAppTests`, its extracted App test targets and bundle-identity consumers. Core source selects its transitive App, Bridges, CLI, IPC, MCPServer, Service and Providers test consumers. Use `test_targets` from the actual graph for the complete list.

Each selected test target gets an anchored `--filter` in the generated `swift test` command; SwiftPM combines these filters. Python sources select their corresponding `scripts/test_<stem>.py` (hyphens become underscores), Python test files select themselves, and named shared Python helpers have explicit test owners. The validator selects its own shape/reference checks. `FILE_TEST_CONSUMERS` and `FILE_PYTHON_TEST_CONSUMERS` map repository inputs to every Swift test target and Python test script that reads them at runtime, before applying validation-only rules. Shared inputs select the union of both maps and any SwiftPM resource consumers; one known reader never excludes another:

| Input | Test consumers |
| --- | --- |
| `docs/integrations.md` | `ChecklistCoreTests` (`NativeCommunicationRoutesTests`) |
| `examples/human-request.json`, `contracts/human-request.schema.json` | `ChecklistCoreTests` (`HumanRequestTests`) |
| `contracts/ticket-bulk-edit.schema.json` | `ChecklistCoreTests` (`TicketBulkEditTests`) |
| `examples/media-intake.json` | `ChecklistCoreTests` (`MediaIntakeMappingTests`) |
| `Tests/Fixtures/path-overlap-vectors.json` | `ChecklistIPCTests` (`ChecklistInstanceTests`) and `scripts/test_test_instances.py` (`LiveRootTests.test_shared_path_overlap_vectors`) |

Ordinary documentation, planning, contracts and examples select validation only through the explicit `VALIDATION_ONLY_FILES` and `VALIDATION_ONLY_GLOBS` lists: root README/AGENTS, Markdown in docs/skills/templates/plugins, the icon README, planning/plans, contract schemas/README, example JSON and design prompts. Other non-code inputs (including arbitrary Markdown outside those families or a new binary fixture under docs) have unknown impact and select the full suite. SwiftPM resources under a target's path, including custom target paths, select that target and its consumers.

`RepositoryDependencyTests` checks the maps against the actual package graph and scans quoted repository paths and directory enumerations in **both** `Tests/**` and `Sources/**`. It also scans Python file reads (`read_text`, `read_bytes`, and `open`) in `scripts/test_*.py`, including literal paths split with `/`, and verifies that every reading script is selected. It checks source-inspection consumers, package resources, probe references and the crash-probe environment route. Adding/moving/removing a literal input read fails the map audit until its owner is updated; generated workspace/store fixtures and installed-bundle build metadata are not repository inputs. When adding split or dynamically constructed repository paths, update the explicit map and audit alongside the reader: the scans are not Swift or Python interpreters. If consumers cannot be determined, retain full-suite fallback; do not classify that input as validation-only. Missing mapped targets or Python scripts also trigger full-suite fallback.

`Package.swift`, `Package.resolved`, build scripts and unknown paths conservatively select all Swift test targets and Python test scripts. An empty diff still selects validation. Inspect `fallback_paths` if a round unexpectedly selects everything.

SwiftPM's `--filter` controls test execution. It can still build other test modules and the shared test runner when their build inputs changed. Keep the scratch directory warm; the selector does not promise that SwiftPM compiles only the selected test modules. Production compilation uses the existing target graph, for example `swift build --target ChecklistProducts --scratch-path <build-slot>/.build`; incremental compilation reuses unchanged modules. Follow the orchestrator's concurrency wrapper for every Swift build/test command.

When Core is selected, the generated command includes `env CHECKLIST_STORAGE_PROBE=<build-slot>/.build/out/Products/Debug/StorageCrashProbe`, the current toolchain's probe location, so the crash tests run too. If using a toolchain with another binary layout, adjust that value to its `StorageCrashProbe` executable. Keep baseline comparisons by failing test name; a previous unrelated failure is not a pass for the current ticket.

## Fast default and opt-in qualification

The full **default** Swift suite runs with `--parallel`. Its budget on this Mac is
180 seconds wall time with an incremental build; an affected App or typical Core
run has a 60-second budget. Record the load average at execution start and end, and the command with each timing.
For CL-266 margin checks, aim for 120 seconds default and 40 seconds affected App
under the recorded load; the acceptance limits remain 180 and 60 seconds.
All 13 targets share 10 process-isolated SwiftPM test workers (`--num-workers 10`).
SwiftPM launches a test host for each selected XCTest method; these are not
10 workers per target. The count overlaps repeated host startup; splitting a
test class does not reduce the number of host launches. The worker count does not change the build-slot cap.
T266d measured two warm parallel passes per count on this 10-core Mac:
64 workers took 126.6/130.4 s, 32 took 126.3/126.7 s, 16 took
124.5/120.0 s and 10 took 110.6/110.3 s. These measurements preceded
the real-size fixture move and exclude the separate native tail. More workers
therefore did not buy a faster default suite on this host.
Long App recovery and MCP archive-reason matrices expose their variants as
separate XCTest methods, retaining all original combinations and assertions so
one method does not leave a worker running the whole matrix at the end. The native
`SourceGitConfinementTests` class runs separately in one serial XCTest host:
`xcrun xctest -XCTest ChecklistCoreTests.SourceGitConfinementTests <scratch>/debug/ChecklistCoreTests.xctest`.
The parallel pass builds that exact bundle first. This avoids SwiftPM's separate
whole-package rediscovery (and unused App-host loading) for this isolated class:
its positive controls repeatedly received SIGKILL alongside concurrent Git probes
on this Mac. Its 12 methods remain serial and isolated from other test work;
the direct class selector avoids both 12 separate single-worker hosts and
`--no-parallel` launching unrelated empty bundles. `DelegateChildBindingTests` also runs in its own serial host against
`<scratch>/debug/ChecklistMCPServerTests.xctest`, keeping suspended-child signing
and exec observation off the concurrent unit queue. Its four cases and their
assertions remain in every applicable default plan. Neither isolated host runs
alongside the parallel pass. `TIMING_TESTS` lists the ungated default-suite methods
that assert a wall-clock budget of any size: the
parallel pass skips them, and one separate `--num-workers 1` SwiftPM invocation
(JSON `timing_commands` and `timing_tests`) runs them with unchanged assertions in
qualification runs (`--qualification` or the final-round coverage refresh) and whenever a
changed path is the test file of one of those classes. Ordinary default and affected
plans skip them and report `timing_deferred: true`, because wall-clock budgets are
performance checks that belong with the opt-in qualification level (CL-266 item 2); `scripts/test_affected_tests.py` fails when such a
test is in neither `TIMING_TESTS` nor the gated `QUALIFICATION_TESTS` (CL-275).
The guard follows same-file helpers and local clock-derived values/sample arrays,
including `XCTAssertTrue` upper bounds. It has no size floor: 5-second termination,
8-second Git timeout and 300 ms cached-return assertions are isolated too.
The owned-copy preview/screen measurements also stay isolated and keep their
explicit private-input gates. Two cleanup-deadline checks are conservatively
isolated because they compare a deadline with the real current time; injected
clock/configuration assertions stay in the default suite. Core and MCPServer retain parallel workers for
their other methods, as do all other test targets. The selector supplies the
shared SwiftPM dependency cache flags. Keep the build-slot concurrency wrapper. Run independent Python checks concurrently
with the Swift pipeline (up to three Python processes), keeping Swift invocations
on one scratch path sequential. Record slot-wait time separately from execution;
shared build-slot queueing can exceed the test budget without executing a test.

```sh
python3 script/affected_tests.py --full --scratch-path <build-slot>/.build
python3 script/affected_tests.py --full --qualification --scratch-path <build-slot>/.build
```

The second command opts into the **Qualification suite**: real-size object/media
round trips, scale/query/cleanup measurements, writer contention, memory soaks
and deliberately elapsed-time observations. The latter include
`ChecklistIPCTests.LongCommandTests/testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient`
(the unchanged 16-second real XPC deadline check) and
`ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit`
(the unchanged post-exit persistence observation). The other IPC timeout/replay
and in-memory preferences correctness cases remain in the default suite.
`ChecklistCoreTests.TestStoreTests/testWarmStoreSetupReportsPairedMedians` keeps
its 25-pair setup measurement, and
`ChecklistCoreTests.MediaListQueryTests/testExamplesStayCollapsedUntilShowThenCapPageAndNeverGrantApproval`
keeps its 70-item accepted-history pagination fixture, in qualification too.
`ChecklistCoreTests.TicketCleanupReceiptReadTests/testLatestSummaryPagesRetainFirstReceiptAndAreBoundedWithLargeItems`
retains all 52 receipts, 250 items per receipt and its one-second read assertion
in that same single-worker group. Small receipt paging/cursor cases stay default.
`REAL_SIZE_TESTS` keeps the unchanged 200,000-object compact-manifest
encode/decode/descriptor round trip in the single-worker qualification invocation.
It took 66.9 s in a warm 64-worker pass and left a measured 28.3 s last-case
tail at 32 workers. Smaller compact Unicode/malformed-index and legacy-format
correctness cases remain default. Full qualification and any mapped affected change
emit its original assertions in `qualification_commands`. It stays out of
`timing_tests`: timing deferral never removes a selected real-size fixture.
`QUALIFICATION_CASES` combines `REAL_SIZE_TESTS` and `QUALIFICATION_TESTS`, so the
qualification selection, fast-pass skips and aggregate `skip` report agree.
`QUALIFICATION_TESTS` lists the gated XCTest identifiers across Core, App and IPC.
Their original fixtures and assertions stay in place; the shared
`QualificationSuite.requireEnabled()` makes a direct `swift test` skip those gated
cases unless `CHECKLIST_QUALIFICATION=1`. The real-size manifest fixture is ungated;
use the planner to keep it out of a fast default run. The planner's single
`--qualification` switch adds a separate single-worker qualification invocation
with this variable enabled. Scale/soak probes therefore do not compete with the
default unit workers. The historical `default_swift_commands`/`swift_commands` fields contain the
ordered native XCTest commands as well as SwiftPM argv arrays.
JSON `qualification_commands` identifies qualification argv arrays;
they are also included in `swift_commands`/`commands`. The aggregate `skip` list
names cases omitted across the whole plan, including qualification commands.
The sustained-writer soak defaults to 360 seconds when qualification is enabled;
`CL193_SOAK_SECONDS` may set a longer measurement (minimum 180 seconds).
Affected qualification commands include only registered cases in the selected test targets,
including App and IPC timing cases when their production dependencies change.
Small correctness cases in the same classes still run by default. Owned-copy
qualifiers additionally require their existing explicitly selected private-copy
inputs; the switch never selects a live store or fabricates those inputs.

Affected plans read `.local/build/test-impact-map.json`, generated by
`script/test_impact_map.py`. Its source entries contain the XCTest classes and
individual real-size cases that executed that file, across all dependent test
modules. `qualification_reasons` names each selected case and the changed paths
that selected it. A covered file with no qualification execution selects none of the measured cases. Cases/classes skipped for absent private inputs keep explicit per-case/class module fallback (`qualification_fallback_cases`, `coverage_fallback_classes`), without discarding the measured map. Skipped coverage is never presented as a pass or an empty measured closure.
A new/unmapped source falls back to the package module closure, including its
qualification cases, and appears in `group_fallback_paths`.

The map records its Git commit, UTC generation timestamp, elapsed generation
seconds, test inventories, input hashes and per-file source hashes. It is ignored
local build output, never a checked-in declaration. The planner accepts a complete
map for 24 hours by default (`--map-max-age-hours` overrides this), only from an
ancestor commit with unchanged test/build inputs and runtime fixtures/resources. Dirty fixture data without a captured fingerprint conservatively falls back until refreshed after commit. Missing, incomplete, old,
malformed or incompatible maps use module fallback and report the reason in
`impact_map_status`. Changed source files already in a valid map keep measured
selection; `git diff` finds new files and untracked additions for fallback.

Generate or refresh it without a native app or test slot:

```sh
python3 script/test_impact_map.py --scratch-path <build-slot>/.build --runner-wrapper <shared-build-wrapper>
python3 script/affected_tests.py --base <round-base> --last-round --scratch-path <build-slot>/.build --runner-wrapper <shared-build-wrapper>
```

The generator builds with Swift code coverage in the assigned warm scratch path,
then runs each ordinary XCTest class in a separate native process and every
qualification case individually. Each execution gets its own LLVM raw profiles
(including child-process profiles), merged with `llvm-profdata` and exported with
`llvm-cov`. Unit source-inspection tests' literal repository paths/directories are
collected automatically and recorded separately as `inspection_references`;
coverage alone cannot observe a source file read as text. Qualification edges use the individual case’s executed-file coverage; unit source readers also include executed shared helper files. No manually maintained
source-to-class or source-to-qualification table exists. Dynamic source reads
remain subject to the repository-input audit and conservative fallback.

Run full qualification once per pass, on its last round (`--last-round`), or on
request (`--qualification`). The final-round plan emits
`coverage_refresh_commands` in `commands`; that refresh executes the classes and
full qualification while collecting the next map, instead of also executing a
second qualification command. Supply the actual shared build wrapper (or `CHECKLIST_SWIFT_RUNNER`) when the shared cap applies; standalone generation can run Swift directly. Read-only test listing is the one Swift subcommand that rejects `--skip`; no methods execute there, and the keychain class is excluded before any native execution. A requested
full qualification keeps the ordinary separate single-worker qualification
command. `--full` alone remains the fast default without scale/soak cases.
The planner prints the mode and never executes its commands itself. Checkpoint
logs and measured failures are retained by the generator; `--resume <logs>` continues a compatible run and `--resume <logs> --reexport` reuses completed native profiles after a generator-only change. Every selected method needs a terminal native result, and exports include instrumented child executable objects. An assertion failure is recorded and returns failure even when coverage collection completed; an interrupted or
incomplete refresh never authorizes closed-world selection.

The refresh restores the ordinary uninstrumented build before publishing its map, so later affected tests and production builds reuse that configuration. No tests execute during either build-only filter. Coverage collection and this configuration restoration cost a full refresh and are outside the 1–2 minute
affected-plan goal. A genuinely affected 360-second soak also cannot meet that
goal; retain its real fixture and report its measured cost. Test filters govern
execution, while SwiftPM may compile dependent modules incrementally.

## Private template stores and finer groups

`ChecklistTestSupport.TestStore` creates a pre-migrated empty template once per
linked test-bundle identity under the assigned scratch path. An OS file lock
protects atomic publication across parallel XCTest processes. Each process
retains the published template URL for its immutable loaded test image. Each fixture gets
an APFS copy-on-write clone (ordinary copy fallback), fresh logical-store and
incarnation IDs, and a fresh cursor seal key generated during private seed
preparation so reopening does not need another durable key write. Only disposable seed preparation
uses relaxed SQLite synchronization. The Router still opens through production
admission, pools and startup recovery. Disposable unit fixtures then select
SQLite `NORMAL` synchronization on their own writer, preserving WAL, foreign
keys, transaction visibility and reopen behavior without a disk durability
barrier per command. Qualification fixtures retain `FULL` (the helper's `durable`
option also selects it explicitly). Direct production/storage/migration/crash
constructors are unchanged. `TestStoreTests` checks this separation against a
fresh production Router. The setup benchmark measures the actual unit helper
with `durable: false` against fresh production setup. Reopening
an existing fixture preserves its data. Fresh storage, migration, crash and
failure qualifiers keep their original bootstrap path. `TestStoreTests` checks
isolation, concurrent copies, reopen preservation and paired setup medians.

Logic-only cancellation and offline recovery tests use protocol-shaped replies
through the existing page parser and request transport. Separate App/Core route
contract tests retain actual Router coverage.

`test_groups` in the plan names narrowed XCTest classes. Independent final test
classes with test methods only can select their own class; shared helpers,
extensions, other global declarations and deleted files retain whole-target
selection. Mixed paths union groups; any broad input for a target overrides its
narrow groups. Repository input consumers still supplement that selection.

Generated coverage groups include classes in dependent targets. Mixed paths
union those groups; an unmapped input broadens only the targets in that input's
module closure. `default_swift_commands` is the ordinary component and
`qualification_commands` is the affected scale/soak component, except during a
final-round coverage refresh as described above. Source/test moves and changes to
the observation environment require a refresh or conservative fallback.

## Persistent build slots and installed checks

Implementers, integrators and reviewers use assigned persistent build-slot workspaces at fixed paths outside `~/Documents`, with `src/` and a sibling `.build/`. Reuse that slot between tasks; never delete `.build/`, make a fresh temporary build directory for each ticket, or copy a different slot's compiler cache. The orchestrator syncs the appropriate checkout or immutable source capture before work:

```sh
rsync -a --delete --checksum --exclude .build --exclude .local <source>/ <build-slot>/src/
cd <build-slot>/src
swift build --target ChecklistProducts --scratch-path <build-slot>/.build
```

Only `src/` is synchronized. Keep the scratch path fixed so source identity and incremental outputs are reused. For a Git checkout, verify the expected base and clean tree before editing; for an immutable capture without Git, verify its source fingerprint and files instead. A new slot may need its initial cold build once; subsequent tasks must reuse it. Keep measurement edits out of hand-ins and restore their exact original bytes afterward.

Installed check runners normally use empty or small synthetic seeds. Use a verified real-store backup only for an acceptance item or installation storage gate that needs that store, and record why; preserve the required same-build live-backup promotion qualification. Keep test-slot folders outside `~/Documents` (the harness uses `~/Library/Application Support/Checklist Test Instances`). Follow [test instances](test-instances.md) for seed safety, slot identity, startup, qualification and cleanup. Build workspaces and installed instance slots are separate resources. See the [combined build round rule](../skills/checklist/references/coordinate.md#combined-build-rounds) and [session briefs](../skills/checklist/references/driven-sessions.md#reviewer-brief-template).

### Screen read query plans (CL-280)

`ScreenReadQueryPlanTests/testRealSizeScreenReadQueryPlans` is opt-in qualification,
never part of the default pass. Its disposable current-schema template contains
542 tickets, 227 Triages, 8,300 messages, 800 reviews and 8,300 events. It traces
production `executePureRead` SQL on cold and repeated reads, then prints each
unique SELECT/WITH statement, execution count, `EXPLAIN QUERY PLAN` details
(including each chosen index), and the records/events index inventory. Coverage
includes full/projected Triage and ticket lists, ticket UI/summary context, Epics,
project-switch tickets, and all twelve surfaces in
`ScreenReadPerformanceTests/testReadOnlyBackupScreenMeasurements`, including the
combined Overview and completed-since digest. Transaction/PRAGMA control statements
are excluded because they do not access the record corpus.

The guard rejects a records/events full scan when the statement constrains an
applicable leading primary/scope index key. Type-only and JSON-only corpus scans
remain visible in the plan notes: the schema has no type-leading/JSON index.
EXPLAIN bytecode cursor roots distinguish main corpus tables/indexes from
materialized CTE aliases; forward/reverse scans are checked. Virtual-table, CTE
and small metadata scans are not corpus scan failures.
The small scan-policy test stays in the default suite. These plans qualify the
synthetic fixture, not a live-store timing claim; CL-280 still requires an
independent runner's matched same-seed, exact-build screen/read measurements.
