# Recommended practices

These are recommendations, not requirements. They come from measured lessons in projects that run their work through Checklist. A project's own rules, its owner's decisions and the product invariants always come first. Use a practice when it fits the project; record in the project's own policy any practice that the project adopts as a rule.

Each practice gives the reason and a short example.

## Before you submit

**Match the evidence to the wording of each acceptance item.** Read each item and name the evidence kind it asks for: an observation on the exact installed build, both appearances, a before and an after measurement, a native display, or an automated test. Attach that kind, or state the limit in plain words. *Why:* a reviewer returns `evidence_missing` when the kind does not match, and each return costs a full round. *Example:* an item that says "light and dark" needs captures in both appearances; a light-only capture with a note is a limit, not a pass.

**Use a pre-submit check.** Run a small script on the packet before `work_submit`. It can refuse a runner report that marks an item FAIL or INCONCLUSIVE without a stated limit, an item that asks for an installed or native observation without a runner report, and a hand-in that has no base timing next to its final timing. *Why:* a refusal before submit costs minutes; a review return costs a round. *Example:* the script finds a `null` base wall time in a hand-in's timing file and blocks the submit until the base run is added.

**Search every document before a rule-text submit.** When a ticket changes a rule, search all tracked documents, skills and user-visible catalog text for the old wording, and fix every copy in the same change. *Why:* one stale copy in another file causes the same rejection again. *Example:* a routing rule changed in the contract still appeared in two skill references; a plain text search for the old phrase would have found both before the first submit.

## Helper sessions and runners

**Give each brief one meaning.** Name one base commit, one workspace and one evidence folder. When the shared rules forbid an action that the task needs, say explicitly in the task that this action is authorized and why. Start a session only after its brief file exists and is not empty. *Why:* a helper that reads two conflicting instructions stops or guesses, and the run is lost. *Example:* a brief whose shared rules said "do not replace a slot" and whose task said "create the slot with --replace" stopped two runners at setup.

**Give exact inputs.** Name the earlier reports to read, the evidence to carry with its original producer, and the cases to rerun. *Why:* a runner that must guess repeats finished work or skips a case. *Example:* "read the round's earlier report for this ticket, carry its passing items, and rerun only items 2 and 4."

## Measurements

**Do not measure timing beside heavy work.** Disk-heavy copies (backups, store seeds, migrations) and other builds change timing results. Run a latency or traffic check alone, and record the load average and disk activity at each check's start and end. Do not wait for a perfectly idle machine; record the conditions instead. *Why:* a timing taken beside a large copy can be several times slower and proves nothing about the change. *Example:* a note-latency median measured beside a multi-gigabyte backup was about three times the median measured alone.

**Prove a bound with a measure that can prove it.** Use a measure whose own cost is well below the limit. *Why:* if the probe takes longer than the target, it cannot show that the target was met. *Example:* a UI-automation probe on a large screen took longer than a 300 ms target, so the team added an in-app timing log and used the probes only as a cross-check.

**Compare base and final runs under the same conditions.** Alternate the base and the final run of each target, repeat them, compare medians, and record the time spent waiting for a shared resource apart from the run itself. *Why:* runs taken at different times or loads differ for reasons that are not the change. *Example:* a target that gained tests between base and final takes longer for a reason that is not a regression; count the tests on both sides.

## Diagnosis

**Read the evidence before you name a cause.** Compare the history times of the service with the times of the report, and read the client's and the operating system's own logs. *Why:* a cause named from memory is often wrong, and its fix does not hold. *Example:* for a screen that showed old data, the logs showed that the client kept requesting updates and that the screen changed only after the user's first click; that ruled out a stopped update loop.

**When a problem does not reproduce, fix the proven paths and add a guard.** Fix each code path that can produce the symptom, add a check that enforces the limit whatever the cause, and add a log that names the path if the symptom returns. *Why:* an unreproduced symptom can return, and a guard bounds its effect while the log finds its cause. *Example:* a client that could show old rows got a re-read whenever its display fell more than two seconds behind the applied changes, plus a log line for each such re-read.

## Stores and backups

**Watch the project's storage against its limits.** Check the project's storage status and backup results after each round, and act at about 80% of a limit. Keep captures and attachments to what reviews need. *Why:* a store that passes a backup limit can no longer be backed up, and every later check that needs a fresh backup stops. *Example:* exclude build output and vendored dependencies from source captures, so each submission adds only the project's own files.

## Tests

**Keep test levels apart.** Unit tests use fakes and prepared templates. Real-size, timing and soak cases run in a separate qualification group. End-to-end checks run at round commits or on purpose. Each change runs only the tests that its changed paths select. *Why:* mixing levels makes every build slow and makes timing cases fail under parallel load. *Example:* moving 22 real-size and soak cases out of the default suite cut it from about 18 minutes to under 3.

**Keep margin on suite time limits.** Aim well below the limit. *Why:* a suite that passes only on a quiet machine fails when reviewers build at the same time. *Example:* a suite measured at 140 s alone took 200 s under review load against a 180 s limit; after the margin work it took about 110 s even beside a second build.

## Reviews and rework

**Recheck only what failed.** Carry passing items with their original producer, target and hash. Rerun failed, inconclusive and materially affected cases only. *Why:* rerunning passing work costs time and adds no evidence. *Example:* after a fix to one acceptance item, rerun that item's cases and attach the earlier passes with their original reports.

**Batch rework.** Start each rework when its verdict arrives, and put it in the next combined round with the open work. *Why:* one combined build, test and review wave costs less than one per ticket. *Example:* three returned tickets and two new ones go into the same next round instead of three single-ticket rounds.

**Link for order, not for completion, when that is the need.** When a ticket needs only the implementation of another ticket, use an ordering-only link. *Why:* a required link makes the dependent ticket wait for the other ticket's whole review. *Example:* an import ticket that needs the backup code present links to the backup ticket as ordering-only and starts once that code is in the integration base.

## Measure the process

**Count round trips by cause each round.** Record each return (reject, `evidence_missing`, blocked) with its cause. Fix the most frequent cause first, in a check or a script, not only in a note. *Why:* the same cause returns until a check stops it. *Example:* after two returns for a missing base timing, the team added that check to the pre-submit script.
