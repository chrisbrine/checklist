# Checklist local assistant plugin (deferred)

**Deferred at the owner's request.** This prepared package and generic [checklist-assistant skill](skills/checklist-assistant/SKILL.md) are retained for future development. They are not a current integration, release prerequisite or installation instruction. The current app has no assistant settings/sidebar/grant controls. The development installation disabled assistant relay grants and uninstalled its local plugin; do not install it or re-enable access as part of normal Checklist setup.

Before deferral, actual local assistant MCP component checks covered reads, requested notes/Drafts, denials and cached-grant changes. The actual Dot reported no direct Checklist tools and created a local Work thread; no completed plugin or Dot/helper result was verified. A manifest, CLI install or locally successful helper cannot establish cloud-Dot discovery, identity, return delivery or unattended notification support.

## Preserved package

The app resource marketplace is rooted at `Contents/Resources/plugins`, with catalog [`.agents/plugins/marketplace.json`](../.agents/plugins/marketplace.json). The manifest links the generic skill and local stdio mapping. That retained mapping invokes `/Applications/Checklist.app/Contents/MacOS/checklist mcp --assistant --project @enabled`; `@enabled` selects only owner-enabled project relay grants, never all projects. Every call remains subject to current scope/revision checks. This does not manufacture a verified Dot identity or human provenance.

The supported Codex marketplace command layout and local source paths were checked against the installed CLI and [official packaging documentation](https://developers.openai.com/plugins/build/plugins). The package remains source material rather than an active registration. Any later installation/reactivation requires a new explicit user request, reviewed host support and available trusted owner controls; editing a manifest/database or following the old removed UI flow cannot supply that authority.

## Future qualification

Prefer supported first-party access to this local Mac app with authorized project scopes, keeping the database/service on the Mac. Prove actual assistant discovery, a selected-project call and a returned result before advertising access. Requested Draft/note writes and denied worker/review/owner calls need real end-to-end evidence. Direct named host identity and ticket-update events need their own receipts; an on-demand helper is a separate path.

No public backend, automatic tunnel, model runtime or notification subscription is created by retaining this package. The assistant remains an observer/messenger and never receives work assignments. See the [deferred assistant design](../../docs/assistant-plugin.md), [identity boundary](../../docs/agent-profiles.md), [MCP contract](../../docs/mcp-contract.md) and [current implementation status](../../docs/implementation-status.md).
