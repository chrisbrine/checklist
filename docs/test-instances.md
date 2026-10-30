# Test instances

A test slot is a disposable copy of one verified staged build, with its own service, store, credentials and app identity. Slots 1–4 can run side by side with the live Checklist. The slot comes from the executable's containing bundle, never an environment variable. Unbundled development binaries, `.xctest` hosts and app bundles with a readable valid `Info.plist` but no `ChecklistInstanceSlot` retain the live defaults. Any present value other than an integer from 1 through 4 refuses startup. A missing, unreadable or malformed `Info.plist` in any containing `.app`, including a dangling link, refuses startup with exit 78. A damaged test helper can never fall back to live identity.

## Stage and create

Establish the caller's actual identity before creating a slot. Native Codex/Claude sessions export it automatically. Otherwise set `CHECKLIST_SESSION_ID` to your actual session ID or add `--session-id <actual session ID>` to each `create` command. Missing or invalid identity refuses before slot locks, replacement, seeding or app copying. Never supply a made-up ID. The preflight order is identity first, then live-root/overlap admission for every source and destination, then lock acquisition and slot changes. If both identity and a root are invalid, identity is the first error; a valid identity never bypasses root admission.

Build once with the ordinary immutable capture helper:

```sh
# Both commands refuse without ticket keys (--ticket KEY or CHECKLIST_TICKETS; CL-359).
CHECKLIST_BUILD_SCOPE=test CHECKLIST_BUILD_CONFIGURATION=debug ./script/build_and_run.sh --stage --ticket CL-N
./script/test_instances.py create --slot 1 --latest-stage --ticket CL-N
# Or select the exact .local/build/<fingerprint> capture directory:
./script/test_instances.py create --slot 2 --stage .local/build/<fingerprint> --seed latest-backup --ticket CL-N
```

The `test` scope does not consume a shared development version and cannot be promoted. For a round whose exact stage will later be installed, use `CHECKLIST_BUILD_SCOPE=install` instead, then qualify that capture. See [build versions](self-hosting.md#build-versions).

`create` never builds. It verifies the captured inputs, fingerprint, completed build receipt, bundled manifests and signatures. It copies the stage, renames the app identity, removes bundled LaunchAgents and signs with the stage's signing selection (`CHECKLIST_SIGN_IDENTITY`, otherwise the owned private `.local/build/signing-identity` file, otherwise ad-hoc). App and helpers must have one signing team. With no source option, `create` selects the latest complete stage; `--latest-stage` makes that choice explicit. Both print the selected build ID. `--replace` requires a stopped slot, runs the same name cleanup and prints the same receipt as `destroy` before copying the new stage, and moves its prior folder to the Trash.

Each folder is `~/Library/Application Support/Checklist Test Instances/slot-N/`; its store is `data/`, app is `Checklist Test N.app`, and `slot.json` records the original stage/build, seed, mode and check results. Each slot has its own short-lived sibling lock directory. A busy slot is refused; locks are never removed by another command.

`create` writes `.checklist-workspace.json` at the slot root immediately after creating the folder, before seeding or app copying. It records the actual owning session, purpose, captured `source_fingerprint` and `released:false`; failed seeds retain that protection. The session comes from `CODEX_THREAD_ID`/`CLAUDE_SESSION_ID`, then `CHECKLIST_SESSION_ID`, or `create --session-id <actual session ID>` when none is exported. An exported identity cannot be overridden. Missing, invalid or conflicting identity refuses before any slot locks or slot changes, including `--replace`; a new slot is always marked before seeding or copying. Slot cleanup continues through `destroy` or `clean_builds.py`. For a manually created qualification run or synthetic-project workspace under `~/Library/Caches/ChecklistQualification`, mark the enclosing run root with its exact fingerprint **before** copying stores or using the slot CLI's `project_create`; see the [qualification marker procedure](../skills/checklist/references/driven-sessions.md#scratch-cleanup-and-cache-settings). The harness does not create those external project workspaces.

Slot attachment drafts and Open in… working copies use the sibling `caches/` folder outside `data/`, so destroying the slot removes them without touching the live app's cache folders.

Secondary workspace windows keep slot preferences in the instance-specific suite `Checklist.Test<N>.Workspace.<window-uuid>`; live windows keep `Checklist.Workspace.<window-uuid>`. The standard preference domain follows the bundle ID (`org.checklist.app.testN`, live `org.checklist.app`); these files live separately in `~/Library/Preferences`. Human claims and pending commands use private files in the slot's `data/OwnerPrivate/` folder (live `~/Library/Application Support/Checklist/OwnerPrivate/`), and each window has its own pending-command file. A slot seed does not copy this folder. `destroy` removes the folder with the slot, the slot's own preference domains and Saved Application State. It makes no Keychain call.

The app makes no Keychain call for pending commands or claims, so it never prompts for the Keychain. A test slot also makes no Keychain call for agent installation credentials (CL-374). Pending-command recovery uses the key `pending-command-v2` / `pending-command-v2-window-<uuid>` in a mode 0600 file with no plain claim token. Each saved command records the connected store incarnation and the bundle-derived Mach service name. A recovery offer appears only after both match an accepted service read; **Check the last change** rechecks the incarnation before sending the original command UUID. A live command is refused by a test slot and a test command by live, even if a seed retained the same incarnation. An older incarnation, foreign service, malformed/unbound record or unreadable file is never sent and produces one plain-language in-app warning. Notice memory is local to the window key and survives relaunch; unreadable bytes share one warning interval until a readable/absent file or a new save is observed. No command is sent automatically. See [uncertain-command recovery](database-storage.md#uncertain-command-recovery-on-this-mac-cl-196).

Ignored files stay until a later save replaces them. Deleting one does not undo a command that may already have committed. Leftover Keychain items are ignored and can stay: the app never reads or deletes `pending-command`, `pending-command-v2` or claim items of the services `Checklist.HumanClaim` and `Checklist.Test<N>.HumanClaim`.

## Seeds

- `empty` is the default: the service initializes an empty store. Test startup does not create the development project automatically.
- `latest-backup` selects the newest published snapshot under the live store's `backups/`. `backup:PATH` selects a completed snapshot explicitly. Every listed file/link is checked against manifest hashes and sizes, publication intent and exact membership before use. The database is copied as `checklist.sqlite`; `managed/<relativePath>` becomes `<relativePath>`. Every schema from 0 to the staged build's current schema is supported (schema 4 since CL-125); the harness reads that number from the stage's verified `SchemaMigrations.currentSchema` (or, for a stage built before that constant, its highest migration target). A seed with a newer schema refuses with a message that names both schemas. `current_schema_no_migration` is true only when the seed schema equals the stage's current schema; an older seed migrates at first start. For initialized schemas the external identity receipt is reconstructed from the copied database. Snapshot age, manifest hash, pre-start schema/integrity/counts and path-inspection counts are recorded. The original database bytes are unchanged. No live database, WAL or `connections.json` is read or copied.
- `restored:PATH` copies a never-started candidate published by the trusted app under `restore/restored-<job>`. It requires a complete format-1 `restore-receipt.json` with quarantined dispatch, its exact fenced database SHA-256, matching embedded restore receipt/incarnation and a ready store identity whose schema revision equals the database schema. That schema must be 3 or later and no newer than the staged build's current schema; `current_schema_no_migration` records whether it equals the stage's current schema. Live/default data roots and their descendants are refused, including live `restore/` candidates. Unpublished stages, ordinary folders, missing/mismatched receipts, runtime credential/WAL files, unsafe links and special files refuse. Every copied file/link is hashed and checked against the source inventory, including executable modes; ordinary seed path inspection still applies. The harness preserves database/identity/receipt bytes, fences and quarantine without migration or authority reset. Slot metadata records kind `restored`, source `restore_job` (the restore command UUID), manifest/database/receipt hashes and a complete copied-inventory hash. This seed does not satisfy the live-backup promotion gate.
- `slot:M` copies a stopped slot, including any retained WAL, but excludes runtime connection credentials. Both slots are locked. The copied database and any retained WAL receive the same path inspection before publication. It does not count as live-backup qualification.

The harness resolves the live root from nonempty `CHECKLIST_DATA_ROOT`, otherwise `~/Library/Application Support/Checklist`, for backup lookup, read restrictions and provenance. Test roots remain fixed. Every slot command refuses if that effective live root canonically equals, contains or lies inside the slot folder or data root; all involved slots are admitted before any action, including replacement, slot-copy seeds and promotion evidence. Comparisons resolve symlinks and use whole path components, so sibling names remain distinct. The runtime also refuses test startup when its data root overlaps the effective live root, and refuses a live `CHECKLIST_DATA_ROOT` that equals, contains or lies inside the reserved test tree. Default live values remain unchanged. Only verified snapshots in that live root’s published `backups/` directory count toward promotion.

The shared Python helpers are `paths_overlap(a, b) -> bool` and `checklist_root_overlap(path, exclude=()) -> str | None`. Root lookup checks `live`, each `slot-N` data root and folder in numerical order, then `test-base`, returning the first non-excluded label. Slot admission excludes its own label and `test-base`; a live or another-slot overlap refuses. Swift uses the same path rule: existing equal/ancestor paths are identified by `(st_dev, st_ino)`; remaining comparisons use the deepest existing ancestor's canonical on-disk spelling (`F_GETPATH` on macOS), with symlinks resolved even for missing tails. Components are NFD-normalized and case-folded, treating every volume as case-insensitive to fail closed. Comparisons never use string prefixes. The shared vectors in `Tests/Fixtures/path-overlap-vectors.json` cover filesystem aliases and missing paths in both languages.

Snapshot seeding is a qualification copy, not a production restore or authority reactivation. Nonempty seeds require a verified stage with the schema-3 managed-path migration (schema 3 or later); the same verified captured file supplies the stage's current schema. The harness checks the immutable captured implementation before publication and again before startup, so an older staged binary cannot use these relaxed inspection rules.

Seed inspection and start preflight accept the managed families `objects`, `source-captures`, `staging`, `icons`, `source-executions` and `source-build-cache`. Cache cleanup descriptors use `source-build-cache/<cache-key>` for a retained directory or paths below it for files. They receive the same traversal, slot-containment and symlink checks as other managed descriptors.

Before publication, the harness inspects all database values read-only. It accepts validated root-relative managed descriptors and legacy absolute descriptors under the verified snapshot `sourceRoot` or stopped source slot root. Core resolves them only inside the new root. Schema 0, 1 and 2 enter the normal protected migration: the complete pre-upgrade snapshot finishes before one atomic path rewrite. An outside descriptor without local proof stays unavailable. The harness never rewrites database records. A descriptor into a different Checklist data root still refuses the seed; the verified origin exception applies only to canonical managed fields with the right family layout. Managed descriptors through a symlink in the corresponding copy also refuse. See [the storage contract](database-storage.md) for proof and rollback rules.

Project/workspace roots, file scopes, external attachment references and owner-selected project files are accepted outside every Checklist data root. Their occurrence count is recorded as `path_inspection.external_project_path_occurrences`. Source `additional_paths` remain relative to their recorded project root. Top-level manifest (submit) `evidence.additional_paths[]` and `evidence.checks[].path` are submitter-supplied project-relative names (for example `unity/Assets/Game/Runtime/UI/TitleScreen.cs` or `TestResults/run.xml`). They get the capture's spelling safety: an empty, `.`, `..`, empty-component, traversing or NUL value refuses as a relative, malformed or traversing stored file path, and a file URL refuses as a stored file URL. A safe relative value is inert: the harness neither resolves nor opens it and counts it in `path_inspection.relative_evidence_paths`. When that evidence also records a `source_root`, the joined path takes the project binding check instead. A leading-slash value must be a well-formed absolute path inside the destination slot data root. The same keys elsewhere keep their earlier rules. Every binding uses the shared CL-169 overlap rule: it can neither lie inside nor contain the live/default roots or the whole test-instance base, including every slot. Comparisons use existing ancestor device/inode identities, resolve symlink spellings, and compare path components in Unicode NFD with case folding on every volume. This also covers normalized spellings and case-folded lock keys. Core source inventory separately refuses overlap with its current store before traversal and rejects selected entries that resolve into it. These folders are references; they are not copied or relocated. The slot's signed owner channel or an actually enrolled scoped session may read them later when an authorized attachment, source-capture or live-source check permits it. A copied path grants no new access and starts no work. Use synthetic projects in a disposable slot when a check must avoid existing project files. Create them only with `project_create` through that slot’s CLI from its actual authorized workspace, after verifying the slot/build identity; never use the live CLI for synthetic project creation. After evidence capture, close the slot GUI and run `./script/test_instances.py destroy --slot N` for the owned slot. Archiving a project retains it and is not cleanup. Record the destroy receipt or incomplete cleanup; leave no synthetic project or enrollment in the live installation.

Seed inspection classifies file authority before ordinary record text. Known file fields (`PATH_FIELDS` and `PATH_LIST_FIELDS` in the harness), canonical managed descriptors, project bindings (including both `file_scopes[].path` and `file_scopes[].declared_path`) and captured paths retain their context-specific path checks. `ABSOLUTE_PATH_FIELDS` names `stored_path`, `capture_path`, `cache_path`, `declared_path`, `link_target` and `root`: outside inert history and unless a context-specific rule applies first, these fields accept relative spellings as written (including `../outside/file`), but a leading absolute path must be well-formed and contained in the destination slot data root, with traversal and symlink checks.

Other ordinary record scalar fields are text, including Bug starter `reproduction`, `expected` and `actual`, Playtest starter `build`, `platform` and `clip`, titles, descriptions, notes/messages, review text, manifest `evidence.checks[].evidence` descriptions, and retained attempt/source-execution `file_state_refs[]` and `stop_observation_refs[]`. A leading `/`, trailing slash, spaces or `..` in this prose does not make it file authority; leading-slash or file-URL mentions count in `inert_history_path_occurrences` without resolving the prose as a path, subject to the whole-value file-URL rule below. This text rule applies to scalar leaves, not whole objects: nested objects, lists and serialized JSON payloads are inspected recursively, so their path-bearing fields keep their own rules. Human-request `command.working_directory` is inert instruction text: Core validates and displays the command example without executing it. Its blanket file-URL refusal remains; source-execution working directories still use the managed-path rule.

The ordinary record-text fallback does not apply to unknown metadata, capture-binding metadata (`managed-capture-paths-v3`) or storage-summary metadata (`storage-last-verified-*`). They retain their explicit rules and conservative fallback: an otherwise unclassified leading absolute path must be well-formed and contained in the destination slot data root. The existing `body`, `brief`, `reason` and `summary` text rules still apply. Capture bindings validate the local `relative` descriptor and the `stored` lookup spelling under their distinct rules; storage summaries have the specific top-level exception below.

The top-level `path` and `source_root` fields of `storage-last-verified-*` metadata are display-only backup/restore observations. Both must be well-formed absolute paths inside the destination slot folder (including its own `data/` root); a verified live-backup seed (`backup:` from a live snapshot, or `restored:` whose verified source manifest is a live snapshot) additionally admits the verified source root itself and paths inside its `backups/` folder, records the exact metadata key/field/path in `seed.source_summary_paths`, and accepts only those retained source values at startup. Inspection compares spelling without opening, resolving or following those paths; relative, traversing, malformed, file-URL and other outside-slot values still refuse, including another slot's root, and later slot summaries must remain inside the slot folder. Nested paths and other fields retain their ordinary checks.

Captured file names, safe internal link targets and project-instruction references remain relative to their declared capture or project context. Captured Git paths are provenance; later Git work resolves a trusted executable afresh. Retained command results, event payloads and completed backup/migration receipts are history, not file authority. The capture-path lookup's old spelling is also metadata; its local target remains a validated root-relative descriptor. These inert values do not refuse a copy merely because they mention the origin. File URLs in any letter case still refuse in every field with a path rule, including retained history. An unknown or known text field whose entire trimmed value is a file URL must decode to an absolute path contained in the destination slot; it receives the same traversal and symlink checks as a bare absolute path. Embedded file URLs in longer free text, such as notes, titles and review text, are inert and count once per leaf value in `inert_history_path_occurrences` (or `inert_metadata_path_occurrences` for retained backup/migration metadata). Outside inert history, fields classified as `strict` require a well-formed absolute path contained in the destination slot data root, with traversal and symlink checks. Fields classified as `slot_absolute` (`ABSOLUTE_PATH_FIELDS` without an earlier context-specific rule) apply those checks only to leading-slash values; relative spellings such as `stored_path="../outside/file"` are accepted as written. Retained `commands.result`, `events.data` and completed backup/migration receipts skip path validation, accepting relative or malformed/traversing absolute spellings even under known path keys; the file-URL checks still apply before this history exception. Unsafe links in checked paths and outside-slot absolute paths in unclassified metadata still refuse; ordinary record prose mentioning external paths remains text. A refused create publishes neither `data/` nor an executable app, and start refuses its recorded state. Refused staging material stays inside the slot folder until destruction moves it to Trash.

## Run and check

```sh
./script/test_instances.py start --slot 1          # headless by default
./script/test_instances.py start --slot 3 --gui
./script/test_instances.py status --json
./script/test_instances.py check --slot 1
./script/test_instances.py stop --slot 3
```

For a forced appearance, quit the slot app first, then use `./script/test_instances.py start --slot N --gui --appearance dark` (or `light`). This passes `-ChecklistTestAppearance dark|light` through the launch argument domain; a directly launched slot executable also accepts `CHECKLIST_TEST_APPEARANCE=dark|light`, with the launch argument taking precedence. The app sets its appearance before showing windows, including Settings and panels. Invalid values log once and leave the system appearance in use. Without either input it follows the system; production apps without a bundle-derived slot ignore both inputs. No system preference is changed.

The harness bootstraps a nonpersistent launchd job directly from the slot folder. It never calls SMAppService or adds Login Items. Each label/Mach service is `org.checklist.testN.coordination`; each credential service is `org.checklist.testN.enrollments`. Test bundles derive their root from the slot and use `CHECKLIST_DATA_ROOT` only to reject live-root collisions. If the service is unavailable, the app gives the slot's exact start command.

The first start of a real-backup seed runs the protected pre-upgrade snapshot and migration and can take 20 minutes or more. `start` waits for health with status calls capped at 30 seconds and progress about once a minute. `CHECKLIST_START_DEADLINE_SECONDS` sets the total health-wait bound (default 2700 seconds; finite and at least 60). Per-call timeouts and unavailable/starting replies keep waiting; recovery, definite errors and malformed replies fail immediately. At the bound, the slot service keeps running its protected startup: run `start --slot N` again to keep waiting or `status --slot N` to inspect it. Destroying the slot during a protected snapshot discards that work. Starting an already running slot waits for health without bootstrapping another job. A direct `check` uses the same bounded wait for its status leg before the MCP probe; its other smoke-command bounds remain unchanged.

The GUI window title identifies `Checklist Test N` and a persistent strip says **TEST INSTANCE N · synthetic/test data**. Headless operation covers the service, CLI and MCP. Human answers/approvals and the per-project `agent_rule_changes` switch require the actual signed GUI owner channel. Enrolled workers can create constrained backups when that switch allows agent changes; owner-selected backup destinations and restore remain trusted GUI operations. A headless process gains no owner authority. Live owner drafts and the Finder data action keep their former fixed Library paths even under `CHECKLIST_DATA_ROOT`; test slots use their own derived root. Both ordinary and review handoff prompts retain the exact former live CLI literal for no slot, and use the test bundle’s shell-quoted CLI path for a test slot.

`check` runs the 18 CLI argument guards, service status and the official-SDK MCP smoke's `--service-only` mode using that slot's CLI. The MCP probe uses an explicit unenrolled binding, reads service information and checks the limited catalog, schema rejection and resources without bootstrapping a native conversation. The receipt also records a read-only observation of the running store’s schema, quick check and record counts, including committed WAL data. These are bounded smoke checks; acceptance cases for a particular change still need their own evidence.

## Orchestrator runner preparation

1. Resolve the actual native caller identity before `create`; if no native ID is exported, use `CHECKLIST_SESSION_ID` or `create --session-id <actual session ID>`. A runner assignment does not authorize impersonating the orchestrator. Keep an assigned persistent build workspace's existing orchestrator-owned marker.
2. Select the exact verified stage and create the assigned disposable slot with that identity. Verify the slot root's `.checklist-workspace.json` names its creator and the stage fingerprint before handing it to a runner. Preserve any failed seed and its marker for inspection.
3. Start headless with `./script/test_instances.py start --slot N --headless`; this command takes no `--session-id`. Identify the separate test app/data before a GUI start. The slot creator's marker is retained; starting a slot does not transfer ownership.
4. Give the runner the exact build, slot CLI, authorized synthetic workspace and external evidence path. Capture evidence before destroying the owned slot through `destroy --slot N`; report incomplete cleanup and restore the real Checklist window after closing its GUI.

## Overview load notices (CL-177)

Every app writes content-free unified-log notices with subsystem `org.checklist.app` and category `OverviewLoad`: `combined visit=V request=R start_uptime_ms=S outcome=O surfaces=N duration_ms=D` for each combined Overview read (`success`, `timeout` for the typed 30-second read deadline, `error:CODE`, `canceled` or `superseded`), `attempt visit=V surface=S attempt=A mode=fallback|single|independent outcome=O rows=R total=T duration_ms=D` for each single-surface read (`independent` marks the bounded per-group reads that apply complete live change coverage, CL-254; count only `mode=fallback` lines for the timeout fallback; outcomes `installed`, `timeout`, `error:CODE`, `rejected`, `canceled` or `superseded`; `none` when no page was installed), and `fallback_settled visit=V outcome=complete|partial|retired attempts=N installed=I failed=F duration_ms=D` when a fallback pass ends. The window-local visit number changes with each page, project or Overview visit change; attempt numbers count per surface within one visit. Start the stream before a `kill -STOP`/`kill -CONT` hold of the slot's `ChecklistService` PID (match its path first), filter by the slot app path because the live app logs the same category, and count per visit: one `combined … outcome=timeout`, no later `combined` line with that visit, one `attempt=1` line per due surface and one `fallback_settled`.

The `LiveUpdates` notice `watchdog path=defer_combined_overview surface=overview lag_ms=N` means the current combined loader still owns its request or sequential timeout fallback. The freshness watchdog leaves that loader intact through settlement; it does not restart the combined request or a held fallback surface. Other Overview watchdog recoveries use small independent group reads (sequential after a timeout), even without complete live coverage, and never introduce a combined request. Accepted sibling groups carry into recovery. Tickets and selected-detail watchdog replacement remain independent.

```sh
log stream --style compact --predicate 'subsystem == "org.checklist.app" AND category == "OverviewLoad" AND processImagePath CONTAINS "Checklist Test Instances/slot-4/"' | tee overview-load.log
grep -o 'combined visit=[0-9]* request=[0-9]* start_uptime_ms=[0-9]* outcome=[a-z:_A-Z]*' overview-load.log
grep -o 'attempt visit=[0-9]* surface=[a-z_]* attempt=[0-9]*' overview-load.log | sort | uniq -c
```

## Selected-record qualification faults (CL-205)

Only a GUI app with a valid `ChecklistInstanceSlot` reads `checklistQualificationFaults`, and it reads exactly its own preference domain (`org.checklist.app.testN`). Live apps never read this key. Global defaults, command-line defaults and secondary-window suites cannot arm it. This is an app-client fault; the service, SQLite store, CLI and MCP are unaffected.

The value is a dictionary with `selected_records` equal to `cursor_reset_twice` or `fresh_context_fail`, and `remaining` a positive integer. Each injected client read decrements `remaining` in that same slot domain; zero disables it. Invalid values are inactive. `cursor_reset_twice` injects `CURSOR_RESET` at `ui_records` / `ui_history` reads, including the bounded retry. `fresh_context_fail` injects `CURSOR_RESET` at those reads and `QUALIFICATION_FRESH_CONTEXT_FAILED` at the shared CL-174 fresh-context recovery read. Ordinary selected-ticket `ui` reads are unaffected. The budget is shared across windows and record/history reads, so use one window and one action for a deterministic observation.

For a selected synthetic ticket in slot 1, arm **two** read faults before loading current work/review records or opening a record-history page:

```sh
defaults write org.checklist.app.test1 checklistQualificationFaults -dict selected_records -string cursor_reset_twice remaining -int 2
# Alternatively, fail the fresh context after the first injected reset:
defaults write org.checklist.app.test1 checklistQualificationFaults -dict selected_records -string fresh_context_fail remaining -int 2
```

The slot strip shows **TEST FAULT · N remaining** while armed (external preference changes appear within about one second). Each observed arm writes one unified-log notice in category `QualificationFaults` with slot domain, fault kind and budget: a key already set at startup, an external arm while running, or a changed kind/budget on refresh (including re-arming after countdown). Unchanged timer polls and the app’s own countdown do not add arm notices. Each injected fault still writes its own notice with slot domain, read boundary, error code and remaining count. Live apps write neither kind of notice:

```sh
log show --last 5m --style compact --predicate 'category == "QualificationFaults"'
defaults read org.checklist.app.test1 checklistQualificationFaults
# Disarm explicitly if the check ends before the budget is used:
defaults delete org.checklist.app.test1 checklistQualificationFaults
```

With `cursor_reset_twice` and `remaining=2`, the first record read resets, the existing recovery fetches fresh context, and the one retry resets again. Observe the selected ticket's “context changed again” explanation and **Refresh selected ticket** action. With `fresh_context_fail` and `remaining=2`, observe the concrete “TEST FAULT: selected-ticket fresh context read failed” cause and the same refresh action. In both cases confirm the unsent draft is kept, the stored count is zero, the marker disappears and a subsequent refresh/read works. A budget of one injects only the initial reset; use two for the terminal-state check. These instructions prepare an observation; they do not establish an installed pass. The non-contributor runner must record the exact installed build and native result, then close the qualification slot app and restore the real Checklist window.

## Reuse an owned live-backup slot (CL-366)

A stopped slot may keep its existing owned `data/` while replacing only its app:

```sh
./script/test_instances.py restage --slot N --stage /absolute/verified-stage --seeded-commit <full-original-seeded-build-commit>
./script/test_instances.py start --slot N --headless
./script/test_instances.py check --slot N
./script/test_instances.py promote --slot N --dry-run
```

The actual active marker owner must run `restage` (native session identity or
`--session-id` follows `create`); stop app, service and CLI/MCP processes first.
Restage never starts/stops processes, changes Keychain/preferences or copies the
store. It verifies both original and incoming stages and signatures, prepares
and verifies the renamed test app before swapping it, preserves the seed/store,
updates the workspace fingerprint and clears prior checks. Run fresh `start`
and `check` for the exact replacement build before promotion.

Reuse requires the original seed to be the **newest complete published live
backup**, with the same manifest hash and source path. Both `snapshot-*` and
`qualification-*/snapshot-*` publications count, ordered by manifest mtime with
path as a tie-breaker. An unpaired manifest without publication intent is not
complete. Existing seed validation supplied full database/managed-file hash
verification; restage checks publication identity rather than rehashing every
backup's managed payload. A newly published backup, changed seed manifest,
foreign/slot/restored/empty seed or unverifiable publication refuses reuse.

The seeded build's commit must be known. Existing captures have no commit field:
supply its full SHA using `--seeded-commit`; a capture with `source_commit` can
supply it directly. The harness verifies **all** captured build-input membership,
bytes and executable modes against that commit in the repository. A guessed,
missing, unavailable or dirty/nonmatching seeded commit refuses; no override
bypasses this proof. Keep the original capture and Git commit available.

The cumulative `git diff --no-index --no-renames` between that verified seeded
capture and the replacement capture decides whether a fresh copy is required,
including added/deleted paths and captured uncommitted target edits. The single
conservative path policy is `FRESH_COPY_PATHS` in
`script/test_instance_restage.py`, covered by fake/temporary Git tests. It covers
storage validation, migrations, backups, startup and their listed dependencies;
add new implementation dependencies there when introducing them. A matching
path requires a **fresh real-size live-backup copy and complete exact-stage
startup/protected pre-upgrade backup qualification** under AGENTS.md. Reusing a
previously started store cannot qualify those changes. Conservative matches may
require a fresh copy even for an unrelated edit in a storage/startup file.

`slot.json.restage` records the original capture/build/fingerprint/commit,
replacement identity, backup manifest hash, changed paths and qualification
reason. Repeated restaging always compares with the **original seeded build**,
never just the prior replacement. Promotion re-verifies that cumulative proof
and newest-backup identity and prints the recorded reason; stale/failed or
other-build checks cannot qualify. Dry run changes no slot metadata. A failed
publication remains fenced as `restaging` with no passing checks, requiring
explicit reconciliation; it cannot start as a healthy slot.

Record separate create/restage, start and check wall times and
`sysctl -n vm.loadavg` for the real-size runner gate. Fake tests do not establish
the minutes target or replace native/installed qualification.

## Promotion and cleanup

```sh
./script/test_instances.py promote --slot 1 --dry-run
# Only with installation authorization and all gates satisfied:
./script/test_instances.py promote --slot 1
./script/test_instances.py stop --all
./script/test_instances.py destroy --all
```

Every promotion requires a passing check for the selected build and a passing check of that same fingerprint in a slot seeded from a snapshot of the live store. A restaged live-backup slot qualifies only under the reuse rule above, revalidated at promotion; storage/startup changes still require a fresh real-size copy. Stale, failed and other-build checks do not qualify. The original stage and slot payload/signature are verified again. Dry run prints every gate and the exact planned install command without changing slot state or installing anything. Without passing live-backup qualification, it names the missing same-build live-backup slot check; there is no bypass. Accepted legacy paths alone do not qualify startup, durable protected copying, migration time or native behavior.

Promotion installs the original live stage through `script/build_and_run.sh --install-stage CAPTURE_DIR`; it never installs the renamed test bundle or transfers test data. That mode re-verifies the original capture and signatures before entering the existing install path. Before stopping the old service, it invokes the incoming service's `--prepare-upgrade`: an older schema receives a verified protected snapshot and rehearsal while the old service still serves. Preparation failures abort before the stop. The installer prints the expected offline window before the swap and the measured stop-request-to-first-healthy-answer window afterward; promotion forwards both. If no healthy answer is observed, the installer reports elapsed time rather than claiming recovery. Startup accepts preparation only if the stopped database and required managed files still match; otherwise a fresh protected snapshot and rehearsal preserve the swap-time store, with a reported upgrading stage, estimate and reason.

Both `--install-stage` and `--verify` require the exact installed app process and a healthy service status. Shell mode dispatch makes verification mandatory even if its Python interpreter or helper cannot run. Verification polls status with calls bounded to 30 seconds for up to 45 minutes; `CHECKLIST_VERIFY_DEADLINE_SECONDS` overrides the total bound with a minimum of 60 seconds. Timeouts and unavailable/starting replies keep waiting, with progress about every minute. Structured `STORAGE_UPGRADING` replies also keep waiting and print the stage, remaining estimate and any fallback reason when they change; recovery, definite errors, malformed replies or a missing exact app process fail immediately. Slot `start` uses the same upgrading progress. On failure the installed bundle, store and previous bundle are kept. Check `checklist service status` and the service log. If the first start upgraded the store, rollback requires restoring its protected pre-upgrade generation, not the previous bundle; diagnostics name the newest completed `backups/snapshot-*` created since install began when one exists. Promotion distinguishes an install that ran but failed installed verification and reports success only after verification passes.

For a storage gate, seed an owned slot from a copied real pre-upgrade backup including all required managed files. Exercise preparation before service launch, first startup and its first healthy call; retain the protected generation and its verification receipt. Record both launch-to-answer and stop-to-answer timing plus host load. Change the copied store after preparation and verify the fallback produces a new matching protected generation and reports why. Run the exact staged code through these paths; inventory inspection or SQL-only migration rehearsal does not qualify the durable copy or its time budget.

Stop signals only an app PID with the exact slot executable path and boots out only that slot label, then waits up to 10 seconds for launchd registration and all app/service/CLI processes to disappear. CLI processes are never signaled. A timeout preserves the slot metadata and reports remaining PIDs and launchd state. A separately running slot CLI/MCP must exit before replacement or destruction. Destroy calls stop first, clears the slot's exact preference domains through `defaults delete`, removes any verified empty plists left behind and confirms the files are gone, then moves `~/Library/Saved Application State/org.checklist.app.testN.savedState` and the whole slot folder to the Trash. Its receipt lists removal counts and names; missing items are harmless, and live and other-slot names are excluded. Destroy runs no `security` command and reads no preference file outside the slot's own suites (CL-379), so a runner uses it with no guard. This includes a slot created before CL-374: the receipt states that a leftover Keychain item of an older slot is ignored. It never stops the live app/service or deletes production data. The live application's ordinary rollback bundle cleanup remains unchanged.

## Cleanup after bounded checks

For a check whose owned slot will not be promoted or inspected further, use:

```sh
./script/test_instances.py check --slot 1 --destroy-after-check > /private/tmp/checklist-slot-1-check.log 2>&1
```

This explicit bounded-check option prints the slot's check evidence, then stops
and destroys that slot even if the check fails. Retain the external log; the slot
and its evidence are moved to the Trash by the existing destroy path. Keep the
ordinary `check` command when the slot is still needed for promotion or further
inspection. After other bounded verification, capture evidence, close its marked
GUI, and use `destroy --slot N` for the owned slot. Restore the real Checklist
window after closing a separate native qualification app.

For leftover slots, `python3 script/clean_builds.py --preview --only slots`
reports each slot's size and retention reason. Inspect the report before the
matching `--apply --only slots`. `--keep PATH` retains assigned idle slots.
Cleanup never stops a running slot: a running app/service/CLI, registered launchd
job, open file/cwd/command reference or `.slot-N.lock` retains it. Apply takes the
same slot lock as create/start/check/promote and rechecks use before destruction;
`destroy(..., unused_only=True)` refuses use instead of signaling processes.
Slot identity, live-root overlap, links and ownership use the existing slot
safety checks. Unavailable inspection retains the slot and reports failure.

Hand-ins under `.local/evidence` are handled by the same cleanup command only
when every owning ticket is Done. See
[local build and hand-in cleanup](monorepo-workspace.md#local-build-and-hand-in-cleanup)
for ownership/status lists, process protection and the report format. Never run
apply against another pass's active slots or unsubmitted evidence.


### Agent-created backup seeds (CL-258)

An enrolled worker in a project with `agent_rule_changes=allowed` can create the same verified full-store snapshot without an owner click:

```json
{"project_id":"<enrolled project UUID>","command_id":"<new UUID>","qualification_name":"round29","reason":"Owned-copy qualification"}
```

Call `backup_create` through that installation's CLI/MCP and retain its returned path, operation ID and manifest digest. It publishes under that installation's `backups/qualification-round29/`; agents cannot choose an outside path. The orchestrator may then use `create --slot N --stage <verified stage> --seed backup:<returned path>` under its ordinary slot authorization. The harness verifies the new family/table counts, complete file hashes and identity and records `current_schema_no_migration=true` when the backup has the stage's current schema. It copies database bytes without rewriting schema, identity or historical authority; this remains qualification seeding, distinct from the owner-only fenced restore command. On startup, compare current-schema identity/schema and migration ledger before/after to prove no migration occurred. Use `--latest-stage` when appropriate to the existing documented create syntax; no seed operation launches a model.

The trusted app's Storage → Preview backup restore verifies a backup, shows its unavailable/external references and prepares a separate restored data root only after explicit owner confirmation. It keeps the existing installation intact. A separately authorized disposable qualification can now start that candidate with the verified stage:

```sh
./script/test_instances.py create --slot N --stage /absolute/verified-stage --seed 'restored:/absolute/test-data/restore/restored-<job>' --replace --ticket CL-N
./script/test_instances.py start --slot N --headless
```

Stop the destination slot first. Creation fully copies and verifies the candidate in a temporary sibling of the slot **before** replacing an existing slot; a source inside that same slot therefore works. Only the verified temporary copy is published as `data/`; the harness never rewrites or directly moves the candidate. Ordinary `--replace` retirement still moves the old slot folder, including any candidate it contains, to the Trash. A validation failure preserves the old slot. Stage identity/signing, caller identity and existing path checks remain required. No credentials are copied or synthesized; new work still needs actual native host bootstrap. The seed authorizes neither enrollment nor changing the live root. After startup and again after a stop/start, inspect recovery-required attempts and quarantined deliveries; startup alone is not evidence of reconciliation or message acknowledgment.

For retained origin paths, `restored:` finds the published format-1/2 manifest in the restoring installation's or configured/default live installation's `backups/` (including qualification folders), requires its hash/store/schema to match the restore receipt, and uses its `sourceRoot` for the existing managed-origin checks against the copy. When that manifest is a live snapshot (in the live installation's `backups/`, with the live data folder as its origin), it also records exact display-only source-summary fields for startup, as `backup:` does; a manifest with any other origin, such as another test slot, keeps the managed-origin checks but grants no summary exception; an absent or mismatched manifest grants no origin exception, unrelated roots still refuse, and candidate/database bytes remain unchanged.


Current format-1 backups may include optional checksummed `capturedAt` metadata. The current-schema seed validator accepts this additive field and preserves database bytes/version without migration; older snapshots remain readable with an unknown capture time. Native Storage status distinguishes restore-copy verification from later installed startup/reconnection qualification.
