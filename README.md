# Checklist

A native macOS checklist app for independent game and app production, with coordinated agent work and a bundled MCP server.

**Status: local development implementation.** The app, SQLite service and official-SDK MCP executable are implemented. The [implementation status](docs/implementation-status.md) separates available features, observed verification and remaining release work from the full design target. No existing project boards have been migrated. Repository instructions do not authorize installation, external messages or automatic builds for another user.

Build and install with `./script/build_and_run.sh --verify` (or `CHECKLIST_BUILD_CONFIGURATION=debug` for a development build). This captures and verifies immutable inputs, signs the bundle and installs `/Applications/Checklist.app`. Existing or newly opened Codex/Claude conversations connect through the bundled CLI/MCP bootstrap using their actual host/session/workspace. Worker status/current-prior attempts and recovery stay on each ticket. No assistant connection/settings UI is active. The exact supported bootstrap/host capabilities are recorded in the implementation status. The Codex app Run action uses the same helper.

For isolated verification before installation, use `./script/build_and_run.sh --stage`, then `./script/test_instances.py create --slot 1 --latest-stage` and `start --slot 1`. Up to four test slots can run headless or with a clearly marked GUI. [Test instances](docs/test-instances.md) covers snapshot seeds, checks, promotion gates and cleanup.

Triages coordinate one **Implementation** or **Review** pass through an actual Codex or Claude conversation. Already in-progress tickets can join an implementation pass; Active attention also includes members of an actively orchestrated Triage. Submission moves a ticket into a separate review pass. Passing tickets complete independently, and only failed or remaining tickets return for more work, unless an explicit project policy overrides the shared completion default. Ticket claims and exact review gates remain per ticket.

Projects keep separate tickets, statuses, tags, rules and history. Epics are stable subprojects by task type; temporary Triages can handle tickets across those Epics. Real work attempts name their actual sessions; reviews bind to the exact work examined. Human notes and agent communication retain their source and honest delivery receipts. The local owner means the human controlling this installation; v1 is a single-user Mac app, not a hosted team system.

Personal-assistant integration, including Dot access and notifications, is **deferred at the owner's request**. Its generic contracts and prepared package remain for later work; the current app exposes no assistant settings/sidebar/grant controls. The development installation's assistant grants were disabled and its plugin uninstalled. A Dot reported no direct Checklist tools and opened a local Work thread instead; no completed plugin or Dot/helper result was verified. This is not a current release prerequisite.

Current work providers are Codex and Claude, using actual sessions attached to tickets. **Use in Codex** prepares a native composer; the user presses Send. A separate explicit native Codex thread-creation test also returned a real thread that automatically connected to its ticket; that association alone assigns no work and acquires no claim. Claude automatic creation remains unqualified. Future personal assistants and clients such as Muse require their own supported, qualified adapters; names and personalities confer no access.

## Start here

1. [Product brief](docs/brief.md)
2. [Interface and synthetic concepts](docs/interface.md)
3. [Architecture](docs/architecture.md) and [database/storage](docs/database-storage.md)
4. [Domain](docs/domain.md) and [MCP contract](docs/mcp-contract.md)
5. [Personal assistants and future adapters](docs/agent-profiles.md)
6. [Deferred assistant plugin](docs/assistant-plugin.md) and [prepared package](plugins/checklist/README.md)
7. [Build sequence](docs/build-plan.md) and [acceptance scenarios](docs/acceptance.md)
8. [Public-reuse overhaul and critique](docs/reviews/2026-10-16-public-overhaul.md)

## Setup and operation

Root development commands, package ownership and the current acyclic target graph are documented in [the monorepo workspace](docs/monorepo-workspace.md).

- [Project setup](docs/project-setup.md), [customization](docs/project-customization.md), [workflow rules](docs/policies.md)
- [Task operations](docs/operations.md), [statuses/tags/live updates](docs/statuses-tags-live.md), [attachments](docs/attachments.md)
- [Later migration](docs/migration.md), [optional self-development](docs/self-hosting.md), [integration evidence and limits](docs/integrations.md)
- [Worker skill](skills/checklist/SKILL.md), [deferred assistant skill](plugins/checklist/skills/checklist-assistant/SKILL.md), [prepared contracts](contracts/README.md)
- [Validation status](docs/preparation-review.md), [public source and release boundaries](docs/public-source.md)

The build starts with one complete production task: capture, claim, note/image, human answer, immutable review/fix, completion and archive. Native packaging and each advertised communication route need actual installed-client evidence; static concepts and simulated adapters are not runtime qualification.

Private source-project audits, native conversation receipts, old project-specific concepts and local authorization records are retained locally and excluded from the public source set. Public examples and screenshots use fictional projects.

## License

Checklist is pre-alpha software and is early in construction. Features, the store format and the MCP contract can change between versions.

The source is available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, change and fork it for any noncommercial purpose. Commercial use needs a separate written agreement with the copyright holder, chrisbrine; contact chrisbrine on GitHub. Dependencies keep their own MIT or Apache-2.0 licenses.
