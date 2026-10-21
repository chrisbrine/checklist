# Test instances

A test slot is a disposable copy of one verified staged build, with its own service, store, credentials and app identity. Slots 1–4 can run side by side with the live Checklist. The slot comes from the executable's containing bundle, never an environment variable. Unbundled development binaries, `.xctest` hosts and app bundles with a readable valid `Info.plist` but no `ChecklistInstanceSlot` retain the live defaults. Any present value other than an integer from 1 through 4 refuses startup. A missing, unreadable or malformed `Info.plist` in any containing `.app`, including a dangling link, refuses startup with exit 78. A damaged test helper can never fall back to live identity.

## Stage and create

Build once with the ordinary immutable capture helper:

```sh
CHECKLIST_BUILD_CONFIGURATION=debug ./script/build_and_run.sh --stage
./script/test_instances.py create --slot 1 --latest-stage
# Or select the exact .local/build/<fingerprint> capture directory:
./script/test_instances.py create --slot 2 --stage .local/build/<fingerprint> --seed latest-backup
```

`create` never builds. It verifies the captured inputs, fingerprint, completed build receipt, bundled manifests and signatures. It copies the stage, renames the app identity, removes bundled LaunchAgents and signs with the stage's signing selection (`CHECKLIST_SIGN_IDENTITY`, otherwise the owned private `.local/build/signing-identity` file, otherwise ad-hoc). App and helpers must have one signing team. With no source option, `create` selects the latest complete stage; `--latest-stage` makes that choice explicit. Both print the selected build ID. `--replace` requires a stopped slot and moves its prior folder to the Trash.

Each folder is `~/Library/Application Support/Checklist Test Instances/slot-N/`; its store is `data/`, app is `Checklist Test N.app`, and `slot.json` records the original stage/build, seed, mode and check results. Each slot has its own short-lived sibling lock directory. A busy slot is refused; locks are never removed by another command.

## Seeds

- `empty` is the default: the service initializes an empty store. Test startup does not create the development project automatically.
- `latest-backup` selects the newest published snapshot under the live store's `backups/`. `backup:PATH` selects a completed snapshot explicitly. Every listed file/link is checked against manifest hashes and sizes, publication intent and exact membership before use. The database is copied as `checklist.sqlite`; `managed/<relativePath>` becomes `<relativePath>`. Schemas 0–3 are supported. For initialized schemas the external identity receipt is reconstructed from the copied database. Snapshot age, manifest hash, pre-start schema/integrity/counts and path-inspection counts are recorded. The original database bytes are unchanged. No live database, WAL or `connections.json` is read or copied.
- `slot:M` copies a stopped slot, including any retained WAL, but excludes runtime connection credentials. Both slots are locked. The copied database and any retained WAL receive the same path inspection before publication. It does not count as live-backup qualification.

The harness resolves the live root from nonempty `CHECKLIST_DATA_ROOT`, otherwise `~/Library/Application Support/Checklist`, for backup lookup, read restrictions and provenance. Test roots remain fixed. Every slot command refuses if that effective live root canonically equals, contains or lies inside the slot folder or data root; all involved slots are admitted before any action, including replacement, slot-copy seeds and promotion evidence. Comparisons resolve symlinks and use whole path components, so sibling names remain distinct. The runtime also refuses test startup when its data root overlaps the effective live root, and refuses a live `CHECKLIST_DATA_ROOT` that equals, contains or lies inside the reserved test tree. Default live values remain unchanged. Only verified snapshots in that live root’s published `backups/` directory count toward promotion.

The shared Python helpers are `paths_overlap(a, b) -> bool` and `checklist_root_overlap(path, exclude=()) -> str | None`. Root lookup checks `live`, each `slot-N` data root and folder in numerical order, then `test-base`, returning the first non-excluded label. Slot admission excludes its own label and `test-base`; a live or another-slot overlap refuses. Swift uses the same path rule: existing equal/ancestor paths are identified by `(st_dev, st_ino)`; remaining comparisons use the deepest existing ancestor's canonical on-disk spelling (`F_GETPATH` on macOS), with symlinks resolved even for missing tails. Components are NFD-normalized and case-folded, treating every volume as case-insensitive to fail closed. Comparisons never use string prefixes. The shared vectors in `Tests/Fixtures/path-overlap-vectors.json` cover filesystem aliases and missing paths in both languages.

Snapshot seeding is a qualification copy, not a production restore or authority reactivation. Nonempty seeds require a verified stage with the schema-3 managed-path migration. The harness checks the immutable captured implementation before publication and again before startup, so an older staged binary cannot use these relaxed inspection rules.

Before publication, the harness inspects all database values read-only. It accepts validated root-relative managed descriptors and legacy absolute descriptors under the verified snapshot `sourceRoot` or stopped source slot root. Core resolves them only inside the new root. Schema 0, 1 and 2 enter the normal protected migration: the complete pre-upgrade snapshot finishes before one atomic path rewrite. An outside descriptor without local proof stays unavailable. The harness never rewrites database records. A descriptor into a different Checklist data root still refuses the seed; the verified origin exception applies only to canonical managed fields with the right family layout. Managed descriptors through a symlink in the corresponding copy also refuse. See [the storage contract](database-storage.md) for proof and rollback rules.

Project/workspace roots, file scopes, external attachment references and owner-selected project files are accepted outside every Checklist data root. Their occurrence count is recorded as `path_inspection.external_project_path_occurrences`. Source `additional_paths` remain relative to their recorded project root. Every binding uses the shared CL-169 overlap rule: it can neither lie inside nor contain the live/default roots or the whole test-instance base, including every slot. Comparisons use existing ancestor device/inode identities, resolve symlink spellings, and compare path components in Unicode NFD with case folding on every volume. This also covers normalized spellings and case-folded lock keys. Core source inventory separately refuses overlap with its current store before traversal and rejects selected entries that resolve into it. These folders are references; they are not copied or relocated. The slot's signed owner channel or an actually enrolled scoped session may read them later when an authorized attachment, source-capture or live-source check permits it. A copied path grants no new access and starts no work. Use synthetic projects when a check must avoid existing project files.

Captured file names, safe internal link targets and project-instruction references remain relative to their declared capture or project context. Captured Git paths are provenance; later Git work resolves a trusted executable afresh. Retained command results, event payloads and completed backup/migration receipts are history, not file authority. The capture-path lookup's old spelling is also metadata; its local target remains a validated root-relative descriptor. These inert values do not refuse a copy merely because they mention the origin. File URLs in any letter case or location, malformed/traversing paths, unsafe links and unknown external file references still refuse. A refused create publishes neither `data/` nor an executable app, and start refuses its recorded state. Refused staging material stays inside the slot folder until destruction moves it to Trash.

## Run and check

```sh
./script/test_instances.py start --slot 1          # headless by default
./script/test_instances.py start --slot 3 --gui
./script/test_instances.py status --json
./script/test_instances.py check --slot 1
./script/test_instances.py stop --slot 3
```

The harness bootstraps a nonpersistent launchd job directly from the slot folder. It never calls SMAppService or adds Login Items. Each label/Mach service is `org.checklist.testN.coordination`; each credential service is `org.checklist.testN.enrollments`. Test bundles derive their root from the slot and use `CHECKLIST_DATA_ROOT` only to reject live-root collisions. If the service is unavailable, the app gives the slot's exact start command.

The GUI window title identifies `Checklist Test N` and a persistent strip says **TEST INSTANCE N · synthetic/test data**. Headless operation covers the service, CLI and MCP. Human answers/approvals, `agent_rule_changes` and `backup_create` still require the actual signed GUI owner channel. A headless process gains no owner authority. Live owner drafts and the Finder data action keep their former fixed Library paths even under `CHECKLIST_DATA_ROOT`; test slots use their own derived root. Both ordinary and review handoff prompts retain the exact former live CLI literal for no slot, and use the test bundle’s shell-quoted CLI path for a test slot.

`check` runs the 18 CLI argument guards, service status and the official-SDK MCP smoke's `--service-only` mode using that slot's CLI. The MCP probe uses an explicit unenrolled binding, reads service information and checks the limited catalog, schema rejection and resources without bootstrapping a native conversation. The receipt also records a read-only observation of the running store’s schema, quick check and record counts, including committed WAL data. These are bounded smoke checks; acceptance cases for a particular change still need their own evidence.

## Promotion and cleanup

```sh
./script/test_instances.py promote --slot 1 --dry-run
# Only with installation authorization and all gates satisfied:
./script/test_instances.py promote --slot 1
./script/test_instances.py stop --all
./script/test_instances.py destroy --all
```

Every promotion requires a passing check for the selected build and a passing check of that same fingerprint in a slot seeded from a snapshot of the live store. This gate applies to every build, even when no storage change is intended. Stale, failed and other-build checks do not qualify. The original stage and slot payload/signature are verified again. Dry run prints every gate and the exact planned install command without changing slot state or installing anything. Without passing live-backup qualification, it names the missing same-build live-backup slot check; there is no bypass. Accepted legacy paths alone do not qualify startup, durable protected copying, migration time or native behavior.

Promotion installs the original live stage through `script/build_and_run.sh --install-stage CAPTURE_DIR`; it never installs the renamed test bundle or transfers test data. That mode re-verifies the original capture and signatures before entering the existing install path. Both `--install-stage` and `--verify` require the exact installed app process and a healthy service status. Shell mode dispatch makes verification mandatory even if its Python interpreter or helper cannot run. A zero-exit recovery, unavailable, malformed or error reply also fails verification. The previous bundle is retained and its rollback path reported on failure; promotion reports success only after verification passes. Normal compatibility and protected-backup rules still apply.

Stop signals only an app PID with the exact slot executable path and boots out only that slot label, then waits up to 10 seconds for launchd registration and all app/service/CLI processes to disappear. CLI processes are never signaled. A timeout preserves the slot metadata and reports remaining PIDs and launchd state. A separately running slot CLI/MCP must exit before replacement or destruction. Destroy calls stop first, verifies removal of only that slot's Keychain service and moves the whole slot folder to the Trash. It never stops the live app/service or deletes production data. The live application's ordinary rollback bundle cleanup remains unchanged.
