# Checklist develops itself

Checklist can optionally track, build and verify its own improvements. This is a per-installation development workflow, not a permission granted by downloading this repository. Ordinary users do not need a development project or automatic installation enabled.

The app has a local development build. Safe automatic self-build/install completion gates remain distinct from the manual development build helper and must be proven before automatic installation is enabled. Existing local build/install authorization belongs in the private `.local/planning/authorizations.md` record. An applicable grant remains valid within its stated scope and must not be requested again for each normal update. That local record is neither required for public installation nor shipped as a reusable grant.

## Project and workflow

After the app is usable, choose the Checklist source folder through the normal project setup flow. Use its own project UUID/key prefix and a synthetic proof task before real enhancement work. Add its design/build/verification tasks, link these specifications and give it explicit development policies. No machine-specific source path is a product default.

For a new public installation, the human chooses **Enable build and install** once, reviews the fixed helper, allowed source/destination, signing profile and automatic trigger, and grants that bounded workflow through the trusted app. An already recorded applicable local grant satisfies this step. Other projects and imported settings never inherit it. An owner can pause/revoke future build jobs; already running jobs reconcile their safe stop/receipt before replacement.

Trigger the **Build and install Checklist** workflow on implementation submission containing relevant app/service/contract code changes, or the explicit Build & Install action. Coalesce by captured source/dependency/toolchain/build-profile fingerprint; identical inputs build once. A failed job is not silently retried: an explicit Retry creates a linked retry receipt with the failure/reason recorded, while duplicate trigger delivery returns the original outcome. Status, notes, tags and build-result events alone must never trigger another build. No recurring model polling or mandatory file watcher is needed.

The project's completion preset adds a required **`installed_build_verified` gate** for affected enhancement tasks. Bind it to that task's submitted manifest, immutable captured-input fingerprint and produced build ID. Present one simple progress sequence, **Built → Installed → Verified**, next to the ordinary Review work action. Technical review passing while install/critique is queued, failed or stale cannot complete the task or satisfy a triage's review-accepted exit. Documentation-only changes can omit this gate under the explicit project preset; missing/failed installs are never bypassed by calling compilation verification.

Use a fixed reviewed repository build helper with typed arguments and a known root, not shell commands supplied in ticket text. It runs native build/test/package tools and never launches a model. The project's configured worker/agent may invoke the helper after submission; the service can run the same explicitly authorized build job as coordination infrastructure. Keep this narrow exception separate from human command requests, which the app does not execute implicitly.

## Safe install pipeline

1. Reserve a brief source-snapshot read barrier and the Checklist build lane. Cooperating writers checkpoint during capture. Copy an immutable input tree including required dirty/untracked source, resources, package lockfiles and build settings into an ordinary staging directory, **not a branch/worktree**. Hash every captured input and compare the source inventory/hashes before/after capture; reject/retry capture if uncontrolled edits or missing inputs are observed. Record base revision and exact captured-content fingerprint; release the source barrier after capture so main can keep evolving.
2. Build only from that immutable input snapshot, with output/generated intermediates outside its source tree and pinned dependency/toolchain identities in the receipt. Never compile the mutable main checkout while labeling the result with an earlier fingerprint. Compile a development `.app` into a staging directory outside `/Applications`. Run the required domain/MCP checks and a smoke launch against an isolated test store, not production data. `script/test_instances.py create/start/check` supplies up to four reusable slots from that verified stage, optionally headless; [test instances](test-instances.md) describes seeds and the backup-seeded promotion gate. A snapshot holding external absolute paths is refused at create: a store-relocation contract is required before it can qualify the build. Sign with the approved local/development identity; qualify IPC identity across upgrades. Production distribution signing/notarization is a separate release profile.
3. Verify bundle ID, entitlements, service/MCP executable versions, readiness, captured-input fingerprint and expected contents. Bind build/install receipts, relevant review request and later critique to that exact built snapshot, even if main has since changed. Deduplicate simultaneous triggers on the complete source/dependency/toolchain/build-profile fingerprint. A build failure leaves `/Applications/Checklist.app` untouched and attaches redacted logs to the task.
4. Pause new coordination mutations briefly, persist drafts and event cursors, checkpoint active service transactions and prepare a consistent store backup. External model processes are not killed. Preserve durable attempt identity, claims and pending deliveries through the service restart; missing continuity requires visible recovery, not fabricated completion.
5. Replace `/Applications/Checklist.app` through a staged, same-volume install/rename protocol with a last-known-good bundle retained. Use only owner-authorized writable paths; if Applications permissions block it, report the actual blocker rather than requesting hidden elevation or installing elsewhere silently. A dedicated updater/build helper owns only its exact processes and files.
6. Relaunch the installed app/service through supported APIs, restore the selected view/overlay/sidebar/drafts, reconnect MCP shims with version negotiation, and resume subscriptions from saved cursors. Verify the running bundle/build ID, not just the staged artifact. Preserve dispatch pause choices.
7. Verify a synthetic MCP round trip plus live update, note delivery, overlay/sidebar behavior, attachment and human response flow as appropriate to the change. Capture the running `/Applications/Checklist.app` build ID/fingerprint and match it to the required gate's target; record actual checks and limitations in its target-specific review. A stale installed version, missing real delivery receipt where delivery was changed, or a failed relevant behavior leaves the gate blocked/rejected. Record critique and independent review in the Checklist task. The implementation task is not done solely because compilation succeeded.

No self-update may strand the task that initiated it. The durable build/install job and its log survive UI/service replacement; a separately running helper records the install outcome and the next enrolled session can pick up verification. An interrupted/unknown install is reconciled using the original receipt before any retry. Avoid a self-update loop by acknowledging the exact source/dependency/toolchain/build-profile fingerprint/build ID.

## Failure and rollback

An interrupted install can recover the last known-good bundle through its receipt. Store migrations first run against a copy, and production migrations keep a consistent pre-upgrade backup. Rolling back binaries is allowed only when the old version can read the current schema; after new production writes, do not restore an old database and lose those writes to make a rollback appear successful. Use a recovery/repair-forward mode when schema compatibility prevents safe downgrade.

Each install runs `script/retire_old_bundles.py` to move older unused app copies to the Trash while keeping the immediate previous bundle, later concurrent installs, incoming bundles and bundles used by running processes. After the installed checks pass, run `python3 script/retire_old_bundles.py --retire-previous` to move the previous bundle to the Trash unless a running process still uses it.

Show the task's Built → Installed → Verified sequence and its next action first. Current/staged versions, last successful build, service compatibility, logs and rollback details are expandable. Attach large build logs/artifacts under its attachment policy; archiving completed development tasks can clean large managed copies while retaining result metadata. Keep originals still needed by pending installed-build verification or another active task.

## Gate before enabling automatic install

Prove a successful and a failed staged build, simultaneous complete-fingerprint deduplication, explicit retry after failure, UI-closed build, denied Applications write, interrupted replacement, service/schema mismatch, retained active claim, MCP reconnect, draft restoration and failed-running-version verification. Prove ordinary review cannot close an affected task or remove it from a review-exit triage before its installed-build gate passes. Exercise the flow with a disposable app/store first. Only then enable the already granted workflow for the actual `/Applications/Checklist.app`. A new installation needs its own bounded opt-in; an existing valid local grant does not require another routine approval. Importing the project or reading this guide can never enable automatic installation.

## Build versions

`VERSION` is the single repository source of the production series, initially `0.0.1`.
Ordinary development builds never edit it. `script/version.py` allocates the next
four-part version (`0.0.1.N`) from one allocator shared by every checkout on this
Mac, under `~/Library/Application Support/Checklist Build/`, outside checkouts and
the live store. `allocator.lock` uses an OS advisory exclusive lock held only for
reservation; process exit releases it. Keep this lock file in place: replacing or
removing it could split the lock authority. Compilation keeps its checkout-local
build lock and separate lanes.

`version-state.json` in that shared directory retains the global ordinal and the
highest fourth component for every production series. Under the shared lock,
allocation takes the maximum of shared history, the calling checkout's legacy
`.local/build/version-state.json` and `build-ordinal`, and the installed bundle.
Legacy files are read only, and each checkout contributes its history when it next
allocates. Reconcile any other pre-migration checkout histories before the first
production allocation with this helper; unobserved legacy reservations cannot be
inferred from the installed bundle. Do not delete, reset or restore an older shared
state, including after a failed build, an abandoned stage or uninstalling the app.
Preserve this build history separately from the app's store.

Both counters are written together to a temporary file, flushed with `fsync`, then
atomically replaced and the containing directory flushed before returning. Missing
directories and their parent entries are flushed when created. A crash can leave
unused numbers, but a completed reservation is never rolled back or reused. Invalid
history refuses allocation rather than resetting counters. No new checkout-local
allocation state is written.

The fourth component starts at `.1` for each new production series; historical
ordinals do not seed it. Returning to a previously built series continues its
retained counter. The separate global `build_number` never resets. Both version
and ordinal exceed the installed values; a source series older than the installed
series refuses allocation. Tests use `CHECKLIST_BUILD_ALLOCATOR_DIR` or the helper's
`allocator` parameter to select a temporary directory. All concurrently tested
checkouts must share that temporary directory. Production checkouts must use the
default shared location consistently; a checkout-local override loses the guarantee.

The capture and bundled `source-manifest.json` and `build-info.json` record `version`,
`production_version`, `build_number` and `build_id`. Apple plist fields retain the
three-part production version and integer ordinal; `ChecklistVersion` and
`ChecklistBuildID` carry the complete public identity. Settings → General, the CLI
`version` command, `service_info` and diagnostics expose that same identity.
Stage and installation verification reject inconsistent metadata or a stale service.

Only when the current open queue reaches zero, explicitly prepare the next production
series with `python3 script/version.py --release` in the clean main checkout. It reads
the actual workspace project through the installed CLI, prints its open ticket count,
refuses a nonzero count, raises the third component, commits only `VERSION`, and tags
that commit `vX.Y.Z`. `--release --dry-run` performs the same read-only preflight and
prints the proposed commit/tag without changing files or Git refs. This step neither
builds nor publishes; the following ordinary build starts the new development sequence.
Never run release preparation as a routine integration step while tickets remain open.
Integration round commit messages and install notes name the full four-part version,
for example `Integration round 23: 0.0.1.1 (build 119)`, alongside the build ID.
