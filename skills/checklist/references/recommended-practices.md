# Recommended practices

These are recommendations, not requirements. They come from measured lessons in projects that run their work through Checklist. A project's own rules, its owner's decisions and the product invariants always come first. Use a practice when it fits the project; record in the project's own policy any practice that the project adopts as a rule.

## Before you submit

**Match the evidence to the wording of each acceptance item.** Read each item and name the evidence kind it asks for: an observation on the exact installed build, both appearances, a before and an after measurement, a native display, or an automated test. Attach that kind, or state the limit in plain words. A reviewer returns `evidence_missing` when the kind does not match, and each return costs a full round. Example: an item that says "light and dark" needs captures in both appearances; a light-only capture with a note is a limit, not a pass.

**Use a pre-submit check.** A small script that reads the packet before `work_submit` can refuse: a runner report that marks an item FAIL or INCONCLUSIVE without a stated limit; an item that asks for an installed or native observation without a runner report; a hand-in that has no base timing next to its final timing. A refusal before submit costs minutes; a review return costs a round.

**Search every document before a rule-text submit.** When a ticket changes a rule, search all tracked documents, skills and user-visible catalog text for the old wording, and fix every copy in the same change. One stale copy in another file causes the same rejection again.

## Helper sessions and runners

**Give each brief one meaning.** Name one base commit, one workspace and one evidence folder. When the shared rules forbid an action that the task needs (for example, replacing a test slot), say explicitly in the task that this action is authorized and why. Start a session only after its brief file exists and is not empty.

**Give exact inputs.** Name the earlier reports to read, the evidence to carry with its original producer, and the cases to rerun. A runner that must guess repeats work or skips a case.

## Measurements

**Do not measure timing beside heavy work.** Disk-heavy copies (backups, store seeds, migrations) and other builds change timing results. Run a latency or traffic check alone, on one slot, and record the load average and disk activity at each check's start and end. Do not wait for a perfectly idle machine; record the conditions instead. A bound that holds under a higher load also holds under a lower load.

**Prove a bound with a measure that can prove it.** Accessibility probes on a large window can take longer than a 300 ms target. Use an app-side timing log or a measurement host for tight limits, and use the probes as a cross-check.

**Compare base and final runs under the same conditions.** Alternate the base and the final run of each target, repeat them, and compare medians. Count the tests on each side; a target that gains tests takes longer for a reason that is not a regression.

## Diagnosis

**Read the evidence before you name a cause.** Compare the service history times with the times of the report. For a display problem, the system log shows whether the app kept reading (its service connections), whether the window was frontmost (RunningBoard roles) and when the user clicked (AppKit actions). State "cause not proven" until a reproduction or a trace proves it.

**When a problem does not reproduce, fix the proven paths and add a guard.** Fix each code path that can produce the symptom, add a check that enforces the limit whatever the cause (for example, a re-read when the display lags the applied changes), and add a log that names the path if the symptom returns.

## Stores and backups

**Watch the store against its backup limits.** Check managed object count, manifest size, bytes and backup time against the limits after each round. Act at about 80% of a limit, before a backup fails. Store identical captured file content once instead of once per capture.

## Tests

**Keep test levels apart.** Unit tests use fakes and prepared templates. Real-size, timing and soak cases run in a separate qualification group. End-to-end checks run at round commits or on purpose. Each change runs only the tests that its changed paths select.

**Keep margin on suite time limits.** A suite that passes its limit only on a quiet machine fails under review load. Aim well below the limit.

## Reviews and rework

**Recheck only what failed.** Carry passing items with their original producer, target and hash. Rerun failed, inconclusive and materially affected cases only.

**Batch rework.** Start each rework when its verdict arrives, and put it in the next combined round with the open work.

**Link for order, not for completion, when that is the need.** When a ticket needs only the implementation of another ticket, use an ordering-only link, so it does not wait for that ticket's review.

## Measure the process

**Count round trips by cause each round.** Record each return (reject, `evidence_missing`, blocked) with its cause. Fix the most frequent cause first, in a check or a script, not only in a note.
