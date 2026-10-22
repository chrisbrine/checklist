# Selecting checks for a build round

Before installing a combined round, run the tests for the changed targets and their dependents, the affected Python script tests, and `validate-plan.py` on the exact composed source. Use `script/affected_tests.py` to plan those checks:

```sh
python3 script/affected_tests.py --base <round-base> --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths Sources/ChecklistApp/Support/Canceled.swift --scratch-path <build-slot>/.build
python3 script/affected_tests.py --paths-file changed-paths.txt --scratch-path <build-slot>/.build --json
```

The script prints commands; it does not execute them. JSON contains argv arrays in `commands`, plus `test_targets`, `affected_targets`, `python_tests`, `skip` and `fallback_paths`. `--paths-file -` reads newline-delimited paths from stdin. Paths are relative to the repository root. `--base` includes committed changes since the base, staged and unstaged changes, deletions, both rename endpoints and untracked files. Supply the union of all tickets' changed paths when planning a combined round.

## Target selection

The selector reads `swift package describe --type json` and caches the result under `<scratch-path>/affected-tests/<Package.swift SHA-256>.json`. A manifest change invalidates the cache. It uses target paths from that graph, including custom paths and nested fixture targets, and follows reverse `target_dependencies` transitively. A changed test target selects itself, without selecting tests of its dependencies. The named runtime-consumer map also selects Core tests for `StorageCrashProbe` (including its nested released fixture), because Core tests launch that executable through the environment rather than a SwiftPM dependency. App source selects `ChecklistAppTests`; Core source currently selects App, Bridges, CLI, Core, IPC and MCPServer tests. Providers tests are selected when Providers or one of their dependencies changes.

Each selected test target gets an anchored `--filter` in the generated `swift test` command; SwiftPM combines these filters. Python sources select their corresponding `scripts/test_<stem>.py` (hyphens become underscores), Python test files select themselves, and named shared Python helpers have explicit test owners. The validator selects its own shape/reference checks. Documentation, planning, contracts and examples select validation only. `Package.swift`, `Package.resolved`, build scripts and unknown paths conservatively select all Swift test targets and Python test scripts. An empty diff still selects validation. Inspect `fallback_paths` if a round unexpectedly selects everything.

SwiftPM's `--filter` controls test execution. It can still build other test modules and the shared test runner when their build inputs changed. Keep the scratch directory warm; the selector does not promise that SwiftPM compiles only the selected test modules. Production compilation uses the existing target graph, for example `swift build --target ChecklistProducts --scratch-path <build-slot>/.build`; incremental compilation reuses unchanged modules. Follow the orchestrator's concurrency wrapper for every Swift build/test command.

When Core is selected, the generated command includes `env CHECKLIST_STORAGE_PROBE=<build-slot>/.build/out/Products/Debug/StorageCrashProbe`, the current toolchain's probe location, so the crash tests run too. If using a toolchain with another binary layout, adjust that value to its `StorageCrashProbe` executable. Keep baseline comparisons by failing test name; a previous unrelated failure is not a pass for the current ticket.

## Heavy cases and the background full suite

`HEAVY_TESTS` in the selector names the 30,000-object `StorageSnapshotCapacityTests` method, `MediaFrozenIntakeTests` and `MediaDecisionTests`. Round commands skip these cases by default. `HEAVY_SOURCE_PREFIXES` is the single list of source triggers: Core `Storage*`, `Snapshot*`, `PolicySnapshots*` and `Media*`, and App `Media/`, plus the named Store/schema, managed-path, file-durability and record-envelope storage infrastructure files. Those source changes remove the skips. Small snapshot-capacity cases still run. Changes to heavy test files alone retain the round skips; run the relevant case explicitly during implementation when changing that test. Extend the trigger list when moving or adding storage/media implementations.

```sh
python3 script/affected_tests.py --full --scratch-path <build-slot>/.build
```

`--full` emits a Swift suite command with no filters or skips and all Python test commands. After the affected checks and validation pass, install once using the qualified composed source and the existing installation/storage gates. Start the full suite on that same immutable source in the background after install. It does not block the install or ticket submissions. Keep its PID/job receipt, source fingerprint and logs; report failures to the orchestrator and map each failing case to the affected tickets. Only those tickets are blocked; passing unrelated tickets continue. A background run must not be lost when its launching session ends. This is one bounded suite job, not a monitoring loop.

## Persistent build slots and installed checks

Implementers, integrators and reviewers use assigned persistent build-slot workspaces at fixed paths outside `~/Documents`, with `src/` and a sibling `.build/`. Reuse that slot between tasks; never delete `.build/`, make a fresh temporary build directory for each ticket, or copy a different slot's compiler cache. The orchestrator syncs the appropriate checkout or immutable source capture before work:

```sh
rsync -a --delete --checksum --exclude .build --exclude .local <source>/ <build-slot>/src/
cd <build-slot>/src
swift build --target ChecklistProducts --scratch-path <build-slot>/.build
```

Only `src/` is synchronized. Keep the scratch path fixed so source identity and incremental outputs are reused. For a Git checkout, verify the expected base and clean tree before editing; for an immutable capture without Git, verify its source fingerprint and files instead. A new slot may need its initial cold build once; subsequent tasks must reuse it. Keep measurement edits out of hand-ins and restore their exact original bytes afterward.

Installed check runners normally use empty or small synthetic seeds. Use a verified real-store backup only for an acceptance item or installation storage gate that needs that store, and record why; preserve the required same-build live-backup promotion qualification. Keep test-slot folders outside `~/Documents` (the harness uses `~/Library/Application Support/Checklist Test Instances`). Follow [test instances](test-instances.md) for seed safety, slot identity, startup, qualification and cleanup. Build workspaces and installed instance slots are separate resources. See the [combined build round rule](../skills/checklist/references/coordinate.md#combined-build-rounds) and [session briefs](../skills/checklist/references/driven-sessions.md#reviewer-brief-template).
