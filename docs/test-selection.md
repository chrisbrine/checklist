# Selecting checks for a build round

Before installing a combined round, run the tests for the changed targets and their dependents, the affected Python script tests, and `validate-plan.py` on the exact composed source. Use `script/affected_tests.py` to plan those checks:

```sh
python3 script/affected_tests.py --base <round-base> --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths Sources/ChecklistApp/Support/Canceled.swift --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths-file changed-paths.txt --scratch-path <build-slot>/.build --json
```

Script tests in both round checks and the background full suite use **uv-managed CPython 3.12**, selected explicitly with `uv run --no-project --python 3.12 --with jsonschema --with pyyaml python <script>`. The selector emits this same interpreter and dependency prefix for every Python test and `validate-plan.py`, including in `--full` mode. Use the emitted commands for both runs; an unpinned `uv run` or a bare `python3` test command can select a different interpreter. The `python3` commands above only launch the planner.

The script prints check commands and never executes test methods. It restores or regenerates its local cache from retained coverage or compiler-index evidence; stale compiler inputs can trigger one incremental native index build through a configured shared build-cap wrapper, using the assigned warm scratch path. JSON contains argv arrays in `commands`, plus `test_targets`, `affected_targets`, `python_tests`, `skip` and `fallback_paths`. `--paths-file -` reads newline-delimited paths from stdin. Paths are relative to the repository root. `--base` includes committed changes since the base, staged and unstaged changes, deletions, both rename endpoints and untracked files. Supply the union of all tickets' changed paths when planning a combined round.

## Target selection

The selector reads `swift package describe --type json` and caches the result under `<scratch-path>/affected-tests/<manifest fingerprint>.json`. Root or nested package manifest/lockfile changes invalidate the cache. The cached graph includes `Packages/ChecklistShared` targets and resolves its product dependencies into root target edges. For fallback it uses target paths from that graph, including custom paths and nested fixture targets, and follows reverse `target_dependencies` transitively. Graph closure for a changed test target selects itself, without selecting tests of its dependencies; explicit file readers can add other consumers. The named runtime-consumer map also selects Core tests for `StorageCrashProbe` (including its nested released fixture) and MCPServer tests for `ChecklistCLIInputProbe`. The tests launch or copy these executables at runtime without a SwiftPM dependency. The shipping CLI is imported by CLI tests; the MCP shim tests launch the input probe instead. Source-inspection dependencies also select App tests when Service, CLI, Bridges or Core test sources change (the glossary checks enumerate those trees). App source selects `ChecklistAppTests`, its extracted App test targets and bundle-identity consumers. Core source selects its transitive App, Bridges, CLI, IPC, MCPServer, Service and Providers test consumers. Use `test_targets` from the actual graph for the complete list.

Shared-package source edits select that module's shared test consumers plus its root consumers. Shared tests run in a separate `swift test --package-path <root>/Packages/ChecklistShared --scratch-path <scratch>/packages/ChecklistShared` command, with the same dependency cache and keychain skip as root tests. Keep both scratch directories warm; running shared tests never switches the root scratch to another package. A shared test-file edit selects its own target (and an independent XCTest class when safe), without selecting root tests. Manifest/lockfile changes in the shared package still select the full conservative plan, with `nested package manifest or lockfile` in `fallback_reasons`; unknown inputs keep their named full fallback.

Root execution coverage can narrow a shared source when it has measured consumers. An empty shared coverage entry is insufficient: the root coverage build may not instrument the dependency. A current portable compiler-index export can instead select consuming root classes through a complete declaration-reference walk. Pass `--shared-index <export.json>`, or place the export at `<scratch>/affected-tests/shared-index.json`. Generate it with `script/index_store.py` from the existing index build for the same source tree (including its additional Clang store when present); this only reads the store. The planner verifies indexed source hashes and current root test declarations before using it. Requested changed sources may differ from the indexed bytes; other source drift, missing class declarations or unavailable index inputs retain the module's consuming targets and name the reason in `fallback_reasons`. This never converts a known shared source into an unknown-input full fallback. `shared_index_selections` records the static root classes, and `shared_package_commands` records the separate runnable package checks. A runner without current measurements/index evidence may receive a broad module plan; it must refresh the evidence before claiming a narrower measured selection.

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
qualification runs (`--qualification` or the final-round coverage refresh). Ordinary
default and affected plans, including changes to a timing fixture itself, skip them
and report `timing_deferred: true`, because wall-clock budgets are
performance checks that belong with the opt-in qualification level (CL-266 item 2); `scripts/test_affected_tests.py` fails when such a
test is in neither `TIMING_TESTS` nor the gated `QUALIFICATION_TESTS` (CL-275).
The guard follows same-file helpers, local timing helpers that return scalars or
tuples, tuple destructuring, comma-separated scalar/tuple bindings and their
alias chains, and clock-derived sample arrays/aggregates (including
`max` and `reduce`), plus `XCTAssertTrue` upper bounds. Commas inside calls,
strings, collections, tuple values or generic types do not create extra bindings;
independent counts in the same declaration retain their non-timing behavior. It has no size floor: 5-second termination,
8-second Git timeout and 300 ms cached-return assertions are isolated too.
The scaled cleanup-backup lookup also remains environment-gated qualification; its
local tuple timer and maximum warm sample are covered by the guard.
All Core timing methods are now environment-gated qualification (CL-358), including `MediaListScaleTests` methods
`testThousandItemPublishedRoundListIsFast` and
`testFiveThousandItemPublishedRoundListIsFast`, plus
`MediaPreparationScaleTests/testLargeProjectPreparationReadsTouchedRecordsAndHoldsAtomicityReplayAndFencing`.
The owned-copy preview/screen measurements also stay opt-in and keep their
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
This includes the four `MediaWorkflowQualificationTests` methods
`test300ItemRoundGroupingFilterUpdateAndListBudgets`,
`test1000ItemRoundGroupingFilterUpdateAndListBudgets`,
`test1200ItemRoundAboveTheFormerCeilingKeepsListBudgets` and
`testBulkPartialSuccessLostReplyReversalsReworkAndExamplesAboveOneThousandItems`.
Their original fixtures and assertions stay in place; the shared
`QualificationSuite.requireEnabled()` makes a direct `swift test` skip those gated
cases unless `CHECKLIST_QUALIFICATION=1`. The real-size manifest fixture is ungated;
use the planner to keep it out of a fast default run. The planner's single
`--qualification` switch adds a separate single-worker qualification invocation
with this variable enabled. Scale/soak probes therefore do not compete with the
default unit workers. The historical `default_swift_commands`/`swift_commands` fields contain the
ordered native XCTest commands as well as SwiftPM argv arrays.
JSON `qualification_commands` identifies explicitly requested qualification argv arrays;
they are also included in `swift_commands`/`commands`. The aggregate `skip` list
names cases omitted across the whole plan, including qualification commands.
The sustained-writer soak defaults to 360 seconds when qualification is enabled;
`CL193_SOAK_SECONDS` may set a longer measurement (minimum 180 seconds).
Ordinary affected plans report only candidate cases for the changed paths; they
execute no qualification or timing commands. `qualification_deferred` is true,
`qualification_tests` and `qualification_reasons` retain the candidate inventory,
and `qualification_execution_tests` is empty. Run the opt-in qualification group
once per pass with `--qualification` or the final-round coverage refresh
`--last-round`; changes to test fixtures cannot opt themselves in (CL-358).
Small correctness cases in the same classes still run by default. Owned-copy
qualifiers additionally require their existing explicitly selected private-copy
inputs; the switch never selects a live store or fabricates those inputs.

Affected plans read `.local/build/test-impact-map.json`, generated by
`script/test_impact_map.py`. Its source entries contain the XCTest classes and
individual real-size cases that executed that file, across all dependent test
modules. `qualification_reasons` names each selected case and the changed paths
that selected it. A mapped file selects only its measured covering classes and
qualification cases. A mapped zero-hit file selects no measured tests. Classes
that cannot be measured are recorded in `coverage_unmeasurable_classes` with
their native skip or owner-rule reason and `source: "index-store"`. The compiler
index identifies each class file (and indexed extensions), resolves its referenced
declarations by USR to their defining source files, and follows recorded
called-by/contained-by edges until the visited-set frontier is empty, with no
depth, node-count or time cutoff. Callable-local declarations are followed; a type
reference does not expand to every member or extension. This conservatively includes
reachable router branches; it does not specialize dispatch by method-name strings
or establish that a branch executed. Lexical symbol matching is not used.
They are selected only when one of those indexed source files changes;
`coverage_unmeasurable_classes` reports the selecting paths and `test_group_sources`
names `index-store` for each selected class. No module closure adds unmeasured
classes or qualification cases for a measured mapped file. Skipped coverage is never
presented as measured coverage. The owner-forbidden keychain class uses the same
index path without executing it. Missing index dependencies keep generation
incomplete. Each class records a `walk` with `complete`, visited USR `nodes`,
traversed distinct `edges` (including cycle edges) and elapsed `seconds` for graph
construction and traversal. The loader requires a complete walk and refuses
legacy lexical or depth-cut exceptions. An interrupted refresh cannot publish
a complete map.
A new/unmapped source falls back to the package module closure, including its
qualification cases, and appears in `group_fallback_paths`.

The map records its Git commit, UTC generation timestamp, elapsed generation
seconds, test inventories, input hashes and per-file source hashes. It is ignored
local build output, never a checked-in declaration. The planner accepts a complete
map for 24 hours by default (`--map-max-age-hours` overrides this), only from an
ancestor commit with unchanged build inputs, unnamed runtime fixtures/resources and nested-package tests. Changed test-tree code and runtime inputs with named readers do not invalidate the map; the planner selects them directly (see below) and `impact_map_status.changed_test_inputs` lists them. Other dirty fixture data without a captured fingerprint conservatively falls back until refreshed after commit. Missing or stale maps first try the automatic recovery below. Incomplete,
malformed or incompatible maps retain module fallback when no compatible evidence
can regenerate them, with the reason in `impact_map_status`. Changed source files already in a valid map keep measured
selection; `git diff` finds new files and untracked additions for fallback.

### Automatic cache recovery (CL-358)

A missing or stale map now triggers recovery before planning. A compatible copy
at `<scratch>/affected-tests/test-impact-map.json` restores a missing checkout
cache. Otherwise the planner derives a new map from a saved same-build semantic
index: pass `--impact-index <index-export.json>`, or retain it at
`<scratch>/affected-tests/index-export.json` or
`.local/build/test-impact-index.json`. Existing generator profile directories are
also searched. When no compatible evidence exists, the planner automatically runs
`swift build --build-tests --build-system native --enable-index-store`, with
`--skip-update`, the assigned scratch path and the shared dependency cache flags.
No runner environment variable is required; an explicit `--runner-wrapper` or
`CHECKLIST_SWIFT_RUNNER` wraps that command when a shared build cap applies. A warm
native or Swift Build cache must already exist. A native cache refreshes in place;
a Swift Build cache retains a separate native index lane at
`<scratch>/affected-tests/native-index`, because Swift Build may ignore the compiler
index flags. Its first index build is cold; later refreshes reuse that lane, and
the assigned warm test outputs and backend stay intact. The planner then exports
the current compiler index and regenerates the map. No test
methods execute. `affected-tests/index-refresh.log` and its status receipt retain
the command, timing and failure; identical failed inputs are not retried silently.
Generator fingerprints are captured before work and checked before index/map
publication. Tooling edits during a run refuse publication and require a fresh
process, so imported old logic cannot be relabeled with new on-disk fingerprints.
`impact_map_status.regeneration` records restoration, regeneration, or the exact
reason and refresh instruction when module fallback remains necessary.

Index-derived maps have schema 2 and `selection_source: "index-store"`; their
`measured_classes` and `measured_qualification_cases` are empty. Their source
entries contain conservative class reachability through the same CL-294 compiler
USR graph, plus source-inspection readers. A qualifying class conservatively
selects its registered qualification cases; this is static reachability, not
execution coverage. Schema 2 additionally follows override/protocol-witness, accessor and specialization
relations. Referencing a concrete type conservatively includes its witnesses,
because framework/generic calls may occur outside the repository index; unrelated
ordinary members are not expanded. Concrete XCTest-class overrides, including
synthesized XCTestCase/NSObject constructors, retain their receiver references
without selecting unrelated users of the external base implementation. Runtime
class/selector-name lookup readers start at the actual call's containing USR,
rather than every definition sharing that file. They conservatively accompany
mapped sources that can be loaded through their target dependencies or named
runtime-consumer links. Independent test bundles do not load one another; explicit
source-inspection readers are recorded separately. Same-target runtime fixtures
still retain these readers. When an opaque lookup has no indexed call, the file's
consumers remain conservative. Directly editing a production lookup implementation
keeps module fallback. Current XCTest declarations and the
root-target source inventory must be present in the index. Package manifests
remain separately fingerprinted build inputs; dependency-package Tests remain
snapshotted source inputs and run through their separate package commands, because
a root `--build-tests` indexes dependency Sources but does not build those test targets. Production source and manifest/lockfile hashes must match exactly. Only explicitly
selected test-tree edits may differ; an existing production file can add an
extension, conformance or override unseen by the old graph, so selected production
drift also keeps module fallback until a current export exists. Missing, malformed,
unrelated stale inputs or missing class declarations preserve module fallback.
Unindexed files without declarations also retain their normal fallback. Unselected
test/source drift invalidates a static map. A selected changed shared test helper
keeps its whole owning target when its indexed consumers are stale.

`script/index_store.py` exports manifest hashes and writes a sibling
`index-inputs.json` receipt for the explicitly selected completed build. If the
portable export is later missing, recovery can reread those raw stores only when
their signature still matches the receipt; it retains the original compiled
source hashes even if requested edits are now dirty. A raw store without that
receipt is insufficient: hashing sources when reading an old store cannot prove
what was compiled. As before, export only from the same completed index build.
`clean_builds.py` explicitly retains the canonical map, index export and input
receipt. Profile directories keep their existing cleanup policy; no broad profile
retention exemption is added. The independent scratch cache survives source-only
workspace synchronization.

`commands` wraps each default Swift/native invocation with
`script/check_test_timings.py run`, which retains a log, load/wall timing receipt
and SwiftPM per-case XML where applicable. It warns loudly above one second per
default method or the 180-second default Core budget; `--strict` makes either a
failure. `guarded_default_commands` names those executable wrappers; the existing
`swift_commands` and `default_swift_commands` remain raw argv for inspection.
Qualification and isolated timing commands retain their own intended budgets.
Some SwiftPM parallel XML omits skip metadata. In that case the guard reports
invocations with execution/skip counts unknown and labels durations as runner
process time; it never treats an empty XML case as proof that assertions ran.

### Changed test files and new sources (CL-299)

With a current map, a round that adds or changes test files keeps a narrow plan.
Every changed path that the planner selects directly is listed in
`direct_test_selections` with its `reason`, `classes`, `qualification_cases` and
`whole_targets`; every path in `fallback_paths` or `group_fallback_paths` has a
reason in `fallback_reasons`.

- A changed test file that is in the map selects its measured consumers (the
  classes and qualification cases that executed it), plus the XCTest classes it
  declares now and the qualification cases whose methods it declares. Measured
  consumers that no longer have a class declaration in their target are dropped.
- A new test file selects only its own classes and its own qualification cases
  when it declares XCTest classes and only `private`/`fileprivate` top-level
  helpers, and no other file of its target names its classes. Otherwise it is a
  shared test helper whose consumers are not measured: its target stays whole,
  with all qualification cases of the target, and the path is in
  `group_fallback_paths`.
- A deleted test file in the map selects its remaining measured consumers. A
  deleted file that is not in the map keeps its whole target.
- A new Core test file is also read as text by the App source-inspection classes.
  The planner selects the classes whose recorded `inspection_references` read
  that directory; without them `ChecklistAppTests` stays whole.
- A named runtime input (`FILE_TEST_CONSUMERS`, outside the code suffixes)
  selects the classes and cases of the test files in each consumer target that
  name the file, through the rules above. If no file names it, the consumer
  target stays whole with all its qualification cases.
- Changed production sources in the map keep their measured edges, also when
  test files change in the same round.
- A new Swift source that is not in the map has no measured edges. Unchanged
  code compiled without its declarations, so only changed files can reach them.
  When every non-private name it declares is absent from the unchanged Swift
  files, and a chain of changed files that name it reaches a file with its own
  selection, the new source adds no classes of its own; those changed files carry
  the selection, and `new_source_reachability` lists them. Extensions of existing
  types may add new member names and the `Equatable`, `Hashable` or `Sendable`
  conformances with their `==`/`hash(into:)` requirements. Any other conformance,
  an initializer, operator or subscript on an existing type, `override`,
  `@objc`, `@main`, `@_cdecl`, `NSClassFromString`, a reused name or an
  unreached file keeps the module-closure fallback, with the reason.
- `Package.swift`, `Package.resolved`, build scripts, unknown paths, unnamed
  runtime inputs and nested-package test files keep the full or map fallback.

Measured on the round 41 diff (`6ba5c4c..r41-1`, 75 paths, 8 test files, 6 new
sources, 27 Swift sources): before, the map fell back and the plan selected all
13 unit targets and all 32 qualification cases; with this rule it selects 5
targets with 133 classes and 30 qualification cases (the changed `Router.swift`
and `Catalog.swift` execute in 30 of the 32 cases).

Generate or refresh it without a native app or test slot:

```sh
python3 script/test_impact_map.py --scratch-path <build-slot>/.build --runner-wrapper <shared-build-wrapper>
python3 script/affected_tests.py --base <round-base> --last-round --scratch-path <build-slot>/.build --runner-wrapper <shared-build-wrapper>
```

The generator first builds test targets once in a separate sibling scratch path
(default `<build-slot>/.build-idx`, configurable with `--index-scratch-path`),
using `swift build --build-tests --build-system native --enable-index-store` and
an explicit `-Xswiftc -index-store-path`. The explicit native backend is needed
because the Xcode SwiftPM backend can ignore these compiler flags. The index
build never alters the warm coverage scratch. `script/index_store.py` reads
current unit record dependencies through the toolchain's public
`libIndexStore.dylib` C API; orphan records, external dependencies and generated
build files are excluded. SwiftPM Clang-target records from the same build’s
standard `.build-idx/debug/index/store` are also read, retaining C definitions and
header declarations. No product dependency is added.
The generator then builds with Swift code coverage in the assigned warm scratch
path and runs each ordinary XCTest class in a separate native process and every
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
logs and measured failures are retained by the generator; `--resume <logs>` continues a compatible run and `--resume <logs> --reexport` reuses completed native profiles after a generator/index-reader-only change. Every selected method needs a terminal native result, and exports include instrumented child executable objects. An assertion failure is recorded and returns failure even when coverage collection completed; an interrupted or
incomplete refresh never authorizes closed-world selection. Every qualification case must have a non-skipped observation; a skipped case leaves the map incomplete. Every discovered class must be measured or have an explicit unmeasurable reason and nonempty index-store edges. The loader also refuses older maps whose inventories do not meet these requirements.

A bounded index-only refresh can replace skipped-class edges in an existing
complete coverage map without repeating native observations:

```sh
python3 script/index_store.py --store <build-slot>/.build-idx/index-store --additional-store <build-slot>/.build-idx/debug/index/store --output <index-export.json>
python3 script/test_impact_map.py --scratch-path <build-slot>/.build --refresh-index-map <coverage-map.json> --index-export <index-export.json> --output <updated-map.json>
```

Build that index from the same source/test/manifest inputs first. The refresh
requires the original inputs to match, preserves coverage timestamps, commit,
failures and measured edges, and records the input map hash and index provenance.
It changes only index/generator implementation fingerprints and replaces legacy
depth metadata with fixed-point traversal receipts. `--index-store-path`
can read an already built store directly instead of a saved export; a full
refresh can consume either input too. Saved exports include indexed source
hashes, unit/record counts and generation time; both full generation and index-only
refresh reject stale saved-export hashes. A prebuilt raw store must come from the
same completed build inputs: read-time hashes do not establish compile-time
freshness. The export remains local evidence.

The refresh restores the ordinary uninstrumented build before publishing its map, so later affected tests and production builds reuse that configuration. No tests execute during either build-only filter. Coverage collection and this configuration restoration cost a full refresh and are outside the 1–2 minute
affected-plan goal. An explicitly requested 360-second soak also cannot meet that
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
constructors are unchanged. `TestStore.router` also selects `SourceGitFixtureMemo` for
that test (CL-363): the first Git request for an exact workspace state runs real,
confined Git, and a later byte-identical state reuses the output with the workspace path
rebound. Refusals, a workspace overlapping a protected root and a tree it cannot fully key
(symlink, `.git` file, unreadable or large entry) always run real Git. Direct-constructor
fixtures, `sourceGitMemo: false` and `CHECKLIST_QUALIFICATION=1` keep real Git. `TestStoreTests` checks this separation against a
fresh production Router. The setup benchmark measures the actual unit helper
with `durable: false` against fresh production setup. Reopening
an existing fixture preserves its data. Fresh storage, migration, crash and
failure qualifiers keep their original bootstrap path. `TestStoreTests` checks
isolation, concurrent copies, reopen preservation and paired setup medians.

Core batch/review, Evidence review/routing and media publication rollback tests
also publish populated class/phase templates. Their builders run the original
prerequisite commands once per linked image; every case or matrix branch gets
private database, managed-object and workspace bytes. Store and workspace roots
remain siblings. Canonical workspace authority is rebound to the private copy;
literal event/command history and source content stay unchanged. Tested commands
and assertions run on each copy. The first run pays phase publication; later
warm runs reuse it. `CHECKLIST_TEST_PROFILE=1` emits per-case
`CHECKLIST_FIXTURE_TIMING` JSON for `store.seed`, `store.open`, `git.key`,
`git.real` and cold `template.open/prepare/close` components. Set
`CHECKLIST_TEST_PROFILE_DIRECTORY` to retain per-process JSONL without mixing
with XCTest output. These nested components are already included in XCTest method times.
This profiling is test-support code and is off by default.

The two 1,000-operation `StorageFolderAccessTests` probes and the two lifecycle
maintenance boundary cases with over-4-MiB descriptor/inventory rows run in
qualification. Their input sizes and assertions remain unchanged; small native
folder-boundary and deletion-cohort/lifecycle correctness cases stay default.
The CL-318/349 250-item owner action and 201-item cross-chunk retry, the
CL-350 242-decision follow-up/closure measurement, and the four CL-362 real
file-descriptor exhaustion/retry observations also run in qualification. Their
large inputs, actual process limits, fixed retry conditions and assertions are
unchanged. Small bulk/filter/adoption, worker follow-up and error-text/errno
mapping correctness cases remain default.

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
`qualification_commands` is the opt-in scale/soak component, except during a
final-round coverage refresh as described above. Changes to the observation
environment other than the test files and named runtime inputs above require a
refresh or conservative fallback.

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
