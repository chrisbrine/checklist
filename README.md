# Checklist

A native macOS checklist app for independent game and app production, with coordinated agent work and a bundled MCP server.

**Status: local development implementation.** The app, SQLite service and official-SDK MCP executable are implemented. The [implementation status](docs/implementation-status.md) separates available features, observed verification and remaining release work from the full design target. No existing project boards have been migrated. Repository instructions do not authorize installation, external messages or automatic builds for another user.

Build and install with `./script/build_and_run.sh --verify` (or `CHECKLIST_BUILD_CONFIGURATION=debug` for a development build). This captures and verifies immutable inputs, signs the bundle and installs `/Applications/Checklist.app`. Existing or newly opened Codex/Claude conversations connect through the bundled CLI/MCP bootstrap using their actual host/session/workspace. Worker status/current-prior attempts and recovery stay on each ticket. No assistant connection/settings UI is active. The exact supported bootstrap/host capabilities are recorded in the implementation status. The Codex app Run action uses the same helper.

For isolated verification before installation, use `./script/build_and_run.sh --stage`, then `./script/test_instances.py create --slot 1 --latest-stage` and `start --slot 1`. Creation requires the actual native session ID; if none is exported, use `CHECKLIST_SESSION_ID` or `create --session-id <actual session ID>`. Up to four test slots can run headless or with a clearly marked GUI. [Test instances](docs/test-instances.md) covers snapshot seeds, checks, promotion gates and cleanup.

Triages coordinate one **Implementation** or **Review** pass through an actual Codex or Claude conversation. Already in-progress tickets can join an implementation pass; Active attention also includes members of an actively orchestrated Triage. Submission moves a ticket into a separate review pass. Passing tickets complete independently, and only failed or remaining tickets return for more work, unless an explicit project policy overrides the shared completion default. Ticket claims and exact review gates remain per ticket.

Projects keep separate tickets, statuses, tags, rules and history. Epics are stable subprojects by task type; temporary Triages can handle tickets across those Epics. Real work attempts name their actual sessions; reviews bind to the exact work examined. Human notes and agent communication retain their source and honest delivery receipts. The local owner means the human controlling this installation; v1 is a single-user Mac app, not a hosted team system.

Personal-assistant integration, including Dot access, named contact and notifications, was **cancelled by the owner on 22 October 2026**. CL-3 "Revisit local personal-assistant access" and CL-22 "Revisit direct assistant identity and ticket notifications" are Canceled after the investigation did not qualify a supported, terms-compliant direct route under the required local-only constraints. Generic contracts, preparatory source and prior component evidence remain as historical reference, not planned work or release requirements. The app exposes no assistant settings/sidebar/grant controls; the development installation's assistant grants remain disabled and its plugin uninstalled. See the [cancellation record](docs/assistant-plugin.md#cancellation-decision).

Current work providers are Codex and Claude, using actual sessions attached to tickets. **Use in Codex** prepares a native composer; the user presses Send. A separate explicit native Codex thread-creation test also returned a real thread that automatically connected to its ticket; that association alone assigns no work and acquires no claim. Claude automatic creation remains unqualified. Other clients such as Muse require their own supported, qualified adapters; names and personalities confer no access.

The versioned [bundled provider-plugin boundary](docs/provider-plugins.md) separates Codex/Claude metadata and supported native behavior from ticket/review policy. Optional [project orchestrators](docs/project-orchestrators.md) and [conversation content](docs/conversation-content.md) are defined as planned contracts; there is no Orchestrators tab or rich-message command in the current build.

## Start here

1. [Product brief](docs/brief.md)
2. [Interface and synthetic concepts](docs/interface.md)
3. [Architecture](docs/architecture.md) and [database/storage](docs/database-storage.md)
4. [Domain](docs/domain.md) and [MCP contract](docs/mcp-contract.md)
5. [Personal assistants and future adapters](docs/agent-profiles.md)
6. [Cancelled assistant integration](docs/assistant-plugin.md) and [retained package](plugins/checklist/README.md)
7. [Build sequence](docs/build-plan.md) and [acceptance scenarios](docs/acceptance.md)
8. [Public-reuse overhaul and critique](docs/reviews/2026-10-16-public-overhaul.md)

## Setup and operation

Root development commands, package ownership and the current acyclic target graph are documented in [the monorepo workspace](docs/monorepo-workspace.md).

- [Project setup](docs/project-setup.md), [customization](docs/project-customization.md), [workflow rules](docs/policies.md)
- [Task operations](docs/operations.md), [statuses/tags/live updates](docs/statuses-tags-live.md), [attachments](docs/attachments.md)
- [Later migration](docs/migration.md), [optional self-development](docs/self-hosting.md), [integration evidence and limits](docs/integrations.md)
- [Worker skill](skills/checklist/SKILL.md), [cancelled assistant skill reference](plugins/checklist/skills/checklist-assistant/SKILL.md), [prepared contracts](contracts/README.md)
- [Validation status](docs/preparation-review.md), [public source and release boundaries](docs/public-source.md)

The build starts with one complete production task: capture, claim, note/image, human answer, immutable review/fix, completion and archive. Native packaging and each advertised communication route need actual installed-client evidence; static concepts and simulated adapters are not runtime qualification.

Private source-project audits, native conversation receipts, old project-specific concepts and local authorization records are retained locally and excluded from the public source set. Public examples and screenshots use fictional projects.

## Project checks

Run these from the repository root with the installed macOS Swift/Xcode toolchain:

| Check | Command |
| --- | --- |
| Shipping executables (compile only) | `swift build --cache-path "$HOME/Library/Caches/ChecklistSwiftPM" --enable-dependency-cache --target ChecklistProducts` |
| All Swift tests | `CHECKLIST_STORAGE_PROBE="$(swift build --cache-path "$HOME/Library/Caches/ChecklistSwiftPM" --enable-dependency-cache --show-bin-path)/StorageCrashProbe" swift test --cache-path "$HOME/Library/Caches/ChecklistSwiftPM" --enable-dependency-cache` |
| Python script tests | `uv run --no-project --with jsonschema --with pyyaml python -m unittest discover -s scripts -p 'test_*.py'` |
| Plan, schemas and examples | `uv run --no-project --with jsonschema --with pyyaml python scripts/validate-plan.py` |
| Whitespace errors | `git diff --check` |

`swift test` discovers all thirteen test targets, including `ChecklistServiceTests`,
`DesktopAlertsTests`, `RequestAnswerCompletionTests`, `RequestRowPresentationTests`,
`TestResultEvidenceProjectionTests` and `TestResultParserTests`. To select one target,
append `--filter '^ChecklistServiceTests\.'` (replace the target name as needed).
The three older standalone check scripts remain usable; their checks also run under
SwiftPM. Shared build-slot users must use their assigned warm `--scratch-path` and
build-slot wrapper for every Swift build/test. The all-tests command supplies the
required storage crash-probe path. For an
assigned scratch layout, pass that same `--scratch-path` to both commands, or set
`CHECKLIST_STORAGE_PROBE` to its built `StorageCrashProbe` executable explicitly.

These checks support independent agent review. Installed app, signed owner-channel
and native provider observations remain separate checks described in
[acceptance](docs/acceptance.md) and [integration qualification](docs/integrations.md).

## License

Checklist is pre-alpha software and is early in construction. Features, the store format and the MCP contract can change between versions.

The source is available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, change and fork it for any noncommercial purpose. Commercial use needs a separate written agreement with the copyright holder, chrisbrine; contact chrisbrine on GitHub. Dependencies keep their own MIT or Apache-2.0 licenses.
