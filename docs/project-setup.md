# Project setup and automatic connections

The app, shared service and bundled MCP executable exist as a local development build. This guide defines the primary connection flow; [implementation status](implementation-status.md) records observed support and remaining native-host qualification. No existing checklist is imported automatically.

## First app setup

1. Open Checklist. Show the data location, service/background-item status and backup destination. Create or reopen the local store. macOS may require approval of the bundled background item for UI-closed cold starts.
2. Register the bundled Checklist CLI/MCP integration in the selected supported provider once, previewing owned configuration/skill entries and preserving unrelated settings. Use the app's absolute executable path; a relocated app needs registration repair. This integration setup is separate from manual per-thread pairing, which is not the primary workflow.
3. Use an existing or newly opened Codex/Claude conversation in the intended project. When it invokes the bundled integration, bootstrap resolves its actual host/session/workspace and connects it to allowed project context automatically. Credentials remain in Keychain; names or CLI flags alone cannot authenticate another session. Observed native process provenance and host-exported thread context are reported honestly, without claiming cryptographic thread attestation.
4. On the handling ticket, show the actual worker/current-prior attempt, accessible project, checkpoint and capability result: MCP pickup, verified push, unavailable or setup required. Automatic connection does not prove native push or that a model has seen a queued note. An unsupported/missing host identity returns a specific limitation rather than inventing one.

The executable is `/Applications/Checklist.app/Contents/MacOS/checklist`; its `mcp` subcommand cold-starts the same coordination service while the UI is closed. In a conversation whose folder is not an active Checklist project, `mcp` still starts: it enrolls nothing, lists only `service_info` and says to add the folder as a project; restart the MCP connection after you add it ([MCP contract](mcp-contract.md#scope-authority-and-retry)). Use the integration's supported caller-context mechanism rather than treating the MCP process working directory or app-selected project as the caller's workspace. Advanced `service status`/`service start` diagnostics preserve the existing store and dispatch pause. After two identical start failures report repair guidance; never start a model or create a replacement empty store.

The current app exposes no assistant connection/settings UI. Actual Codex/Claude worker status, current/prior attempts, checkpoint/progress, recovery and supported actions stay on the ticket being handled; the internal worker registry is not a global user catalog. The user should not need a Pair connection form, socket address, session ID or invented profile before a normal provider thread can use a ticket. One-time integration registration or an actual host permission prompt may still be necessary; explain the real requirement instead of presenting manual pairing as the solution to every missing route.

## Reinstalling Checklist during a conversation

Reinstalling replaces the bundled CLI while an existing Codex or Claude conversation may keep its earlier MCP shim running. The service admits commands only from the installed build. Fixed shims safely delegate to the signed replacement at their original launch path and keep the MCP connection; this is the chosen recovery route rather than restarting the transport automatically.

If that route is unavailable or the replacement is also refused, `CLIENT_OUTDATED` says no command ran and carries `details.recovery_action: "restart_mcp_server"`. Use the Codex or Claude host's MCP controls to restart or reconnect this conversation's **checklist** MCP server, then retry the same request with its original `command_id`. Reinstalling or reopening the Checklist GUI alone does not restart a host's MCP process. A shim from before CL-171 cannot gain this behavior retroactively: reconnect it manually after installation. A genuine `OUTCOME_UNKNOWN` still requires reconciliation of the original command; it does not prove noncommit. See [install recovery](integrations.md#installs-and-running-mcp-shims).

## Add a project

Choose **Add Project → Choose Folder**, confirm name/key prefix and optional symbol/image/accent, then choose participating work providers and a simple preset: **Claude coordinates / Codex works**, **Shared work**, or **Codex-led**. Defaults provide statuses, review/storage behavior and an empty task list. Title/project capture is immediately usable; no routing graph or named-agent catalog is required. Manual/coordinator-directed pickup does not launch another model.

The owner authorizes bounded project/task communications among participating connections during project integration setup. This does not authorize unrelated email/Slack or a hidden runtime. Bootstrap verifies the actual local connection and scope; unknown workspaces, imported bindings, assistant names or the service directory do not grant access. Existing grants and revocations remain effective.

Canonicalize writable roots using filesystem identity, real paths, symlinks and actual volume case/normalization behavior. Reject overlapping writable roots in distinct projects, including aliases and parent/descendant folders. Show the conflicting project and offer its existing binding or a different root. Relink moved projects rather than duplicating them; shared read-only references grant no write reservation.

An optional `.checklist/project.json` binding contains stable project/store identity only, never tasks, policy, credentials or endpoint tokens. A cloned binding requires deliberate reconnect/import under the current store; it is not authority. Multiple roots need explicit project enrollment, but setup creates no branch/worktree. See the [binding example](../examples/project-binding.json).

An optional short project brief/pinned decisions section supplies production direction automatically in task context. Link existing game design/source documents rather than copying a wiki. Versioned human-direction changes reach relevant active handlers and require reconciliation. Offer the [AGENTS/CLAUDE snippets](../templates/project/AGENTS.checklist.md) as reviewable merges only when authorized; preserve project-specific rules.

## Use a ticket in a provider

Choose **Use in Codex** or **Use in Claude** on a ticket. The Codex flow opens a prepared native composer with the scoped prompt; press Send there, without copying instructions or entering a session ID. This prepares a draft, not a started turn or work claim. The actual resulting thread connects and attaches through bundled bootstrap. A separately requested native Codex `create_thread` test returned a real thread and automatically attached it with `connect --task CL-4`; that is context association, not assignment or claim. Claude uses an honest open/copy fallback until its native route is qualified. If a provider app is missing, a compose link is refused or the app fails to open, the sheet reports that outcome and keeps any prepared instruction available to copy. An opening failure can be retried without preparing another prompt; it never confirms a connection or claim.

The provider conversation connects automatically when it first uses Checklist's bundled CLI/MCP. It reads current context and obtains its own eligible claim before editing; a handoff is neither assignment nor a claim. If the provider is missing or a route cannot be verified, report that exact state and retain the copied brief. Do not silently create a CLI/API model runtime.

## Messages to Claude conversations

Checklist sends ticket notes from the owner and from other agents into the attached Claude conversation. It always identifies itself truthfully as a sender that asks before acting (`from-mode="prompting"`). Claude holds a message whose sender's permission class differs from the conversation's, for example in a conversation that skips permission prompts, and Claude Desktop may show no button to release it. The ticket then shows **Waiting for approval** with this explanation.

In **Settings → General → Message readiness**, select the project and choose **Refresh message readiness**. When the selected ticket has an observed current worker, the card names that handler. Otherwise it explicitly describes project context with no recipient. These are read-only local file observations, with paths and time, separate from transport, host hold/refusal and exact-recipient acknowledgment. Changing project/handler/store or observing a service change retires the observation. Refresh cannot display an earlier context's late result.

The owner app reads bounded candidate user, selected-project/local and standard managed JSON files; it neither exposes a worker settings command nor reads authentication files. The user candidate is `~/.claude/settings.json`, or the app's absolute `CLAUDE_CONFIG_DIR` candidate. A live recipient can use a different directory, settings-source selection, session flags, main-worktree local root or managed policy. MDM, server policy, `policyHelper`, embedding-host policy and live engine version are not exposed by a supported host read interface here. The card therefore says **Unknown: live policy not observable**, even if the observed user value is `accept`. It shows unavailable versions explicitly; a shell CLI version never stands in for a Desktop recipient's engine. Absent, unreadable, invalid and unsupported sources cannot establish Ready.

If the owner chooses to change Claude settings, use the cross-session inbound messages row in terminal Claude Code's `/config` when that version provides it, or edit the confirmed user-scope settings file. Claude Desktop does not open the terminal menu. The key belongs at the top level:

```json
{ "crossSessionInbound": "accept" }
```

Accept releases held messages from **all local senders**, not only Checklist. For this key, managed, session and user scopes choose the trusted value in that order; project/local settings can only tighten accept → hold → refuse. Unset uses sender/recipient permission-class parity. Invalid managed values refuse; invalid nonmanaged values hold. Check the named project/local path with its owner, or ask the administrator responsible for managed policy. Repair invalid JSON/values in the named source. Do not disable project settings to bypass a restriction. Claude's `/status` can show the actual session's setting sources. See [Claude settings](https://code.claude.com/docs/en/settings) and [crossSessionInbound](https://code.claude.com/docs/en/settings-reference#crosssessioninbound).

Reading, refreshing and opening guidance write no provider settings, change no permissions/grants and launch no model. **Automatic durable settings writes remain deferred** until a supported coordination/conditional-update mechanism or an explicitly accepted weaker conflict guarantee is separately qualified. Ordinary atomic replacement cannot prevent an uncooperative concurrent editor from losing an update.

Codex shows **Pickup only** for this build. Notes remain available at the conversation's next Checklist MCP check. CLI queue/resume, notify and hooks are unqualified wake candidates, not native delivery, automatic send or success receipts. An actual MCP acknowledgment retains its existing exact-recipient meaning. Automatic native Codex wake remains deferred.

## Deferred personal-assistant integration

Personal-assistant/Dot access is deferred at the owner's request and is not a current setup step or release prerequisite. The development installation disabled assistant relay grants and uninstalled the local plugin. The current UI has no assistant settings/sidebar/project-grant controls. Do not follow old enable/install instructions or create another helper as part of project setup.

The generic [assistant design](assistant-plugin.md), [identity contract](agent-profiles.md) and [prepared package](../plugins/checklist/README.md) remain for a later explicit reactivation. Prior local MCP component checks do not prove Dot access: the actual Dot reported no direct tools and opened a local Work thread, with no completed plugin/helper result verified. Ordinary Codex/Claude work uses the automatic actual-session flow above.

## Skills, changes and removal

The worker skill is [checklist](../skills/checklist/SKILL.md). The prepared [checklist-assistant](../plugins/checklist/skills/checklist-assistant/SKILL.md) remains deferred and must not be installed/enabled as part of ordinary setup. Install only the relevant supported integration, preserving customized versions with a diff/version receipt. A global worker skill resolves actual workspace bindings; project-local copies may use `.agents/skills/checklist/` or `.claude/skills/checklist/`. Discover the running server's actual tool schemas rather than assuming the complete design catalog is shipped.

Agents can propose policy changes; only the trusted owner flow applies them. Root changes use Finder relinking. Disconnect/revoke blocks future authority/delivery while retaining history and visibly recovering unresolved attempts; it does not stop an external writer by declaration. Uninstall removes only owned integration entries and preserves data/export by default. Destructive data removal is separate. See [customization](project-customization.md), [storage](database-storage.md) and [operations](operations.md).
