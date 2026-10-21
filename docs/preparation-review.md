# Preparation and validation status

**Design and development checks, 16 October 2026.** A local app, service, SQLite store and official-SDK MCP executable exist. [Implementation status](implementation-status.md) separates current source support, actual evidence and remaining native/release qualification. Prepared schemas, skills, manifests and concepts do not independently qualify host behavior.

The current [public-reuse overhaul](reviews/2026-10-16-public-overhaul.md) makes product language and the assistant plugin generic, defines existing host-owned assistants/future adapter boundaries and requested contact by name, and applies a fresh critique across domain/MCP/storage/UI/build/acceptance. Historical source-specific audits, native message receipts and older concepts remain private local material. They are excluded from the public source set and are not linked as public product documentation.

## Current checks

Run the reproducible [planning validator](../scripts/validate-plan.py) using the command in [public source](public-source.md). It validates prepared schema/example pairs and semantic references, skill/package structure, public Markdown targets, synthetic concept metadata and accidental local/native identifiers. Run it against the current tree and retain its exact counts/result; earlier review counts are historical and change as contracts/docs evolve. It does not install/load a plugin, call a model, open a production database or qualify a host route. The public-overhaul report records the result and independent review outcome.

Independent review identified scoped-cursor disclosure, in-flight revocation ambiguity, notification recursion/backlog, historical identity attribution, conflicting duplicate grants and future-adapter trust boundaries. Each fix is incorporated in the corresponding contract and an observable acceptance scenario. Named personal-assistant contact is deferred and not a current release prerequisite; if resumed, it needs real installed-client qualification; no message or subscription was created during this revision.

## Evidence boundaries

A limited local existing-Claude-session round trip was observed earlier after correcting missing sender permission metadata. Its sanitized result and limits are in [integrations](integrations.md). Private raw identifiers/probes are not public fixtures or a generic passing test. Future public release evidence must use deliberately enrolled synthetic sessions, redacted receipts and actual supported versions.

Database crashes/backup-versus-cleanup, packaged service startup, native routing, immutable review execution, live UI/focus/drafts, Finder grants, and optional self-install continuity still require the [acceptance scenarios](acceptance.md). Checklist does not create personas or named workers; existing assistant identity comes from a qualified host. Automatic provider-thread bootstrap, no manual Settings pairing, host execution-domain identity and truthful open-provider/copy-brief handoff are current integration requirements. A future provider entry is not a working adapter.
