# Public source preparation

Checklist is designed for independent game/app developers. Public product terms, fixtures and examples must work for any installation. Personal assistant names are user data, not package/skill/tool names. V1 remains a single-user local macOS app; publishing source does not add accounts, a hosted team backend or automatic provider support.

## Public and private material

Public source contains README/AGENTS, the LICENSE, active docs, contracts and synthetic examples, generic skills/plugin package, project instruction templates, the planning validator, and the selected `public-*.png` concepts with sanitized provenance. Only the current public-overhaul report is included from reviews. Public examples use fictional projects and agent names; stable example UUIDs are synthetic identities, never live grants.

The generated app icon, native `.icns` representations and [retained prompt/source notes](../Resources/AppIcon/README.md) are generic product assets. Inspect their artwork before publication; this does not make private runtime screenshots public.

The following stay local and are ignored: `.local/`, historical source-project audits in `docs/research/`, previous private review reports/evidence, native conversation/socket receipts and historical probe scripts, older screenshots with project-specific labels, credentials, store/config state and local build products. Their original files are preserved so history is not falsified. No user-specific path/session/conversation/test nonce or local authorization is a public product default.

`.gitignore` protects normal future additions; it does not remove already tracked files or make a forced add safe. Before an actual publication, inspect the exact staged/tracked source set and any earlier commits, validate an export built from that set, and inspect images for private labels. Do not publish a directory wholesale or treat an ignored local evidence link as public documentation. Publication, history rewrite, license selection or public-directory submission require their own instruction.

## Reproducible preparation check

From the repository root, run:

```sh
uv run --no-project --with jsonschema --with pyyaml python scripts/validate-plan.py
```

The validator selects an explicit generic public source set, checks schema/example pairs, positive/negative contract shapes and cross-references, both skill packages, plugin path wiring, public local links/anchors and PNG metadata/provenance. It reports prospective source files and fails on private-directory references, real home paths or concrete native inbox/session identifiers. Public screenshots also require human visual inspection; a string scan cannot prove their contents.

The script is read-only and does not execute bundled tools, historical probes, model CLIs, service startup or the bundled MCP command. JSON/manifest validation is not plugin host compatibility. Product tests and actual provider qualification remain separate.

## Distribution and authority

The owner chose the [PolyForm Noncommercial License 1.0.0](../LICENSE) on 21 October 2026. It permits use, changes and forks for noncommercial purposes; commercial use needs a separate written agreement with the licensor. A license change needs its own owner instruction. Before a binary release, document build/prerequisite versions, signing/package procedure, data/export paths, support status and known limitations. Source availability and public plugin-directory eligibility are distinct. A personal/local plugin setup can be tested without claiming public-directory approval. The retained assistant package points to the local development executable but is deferred, uninstalled locally and absent from current UI/setup. Real Dot discovery/bootstrap/result and event callbacks remain unqualified; do not reinstall or advertise them as current release support.

An installation registers its provider integration and bootstraps its actual host/session/workspace and opts into notifications/build installation explicitly. Imported data, repository Markdown, another user's host name/personality or a private authorization record cannot enroll a host, grant a role, start a model or enable an adapter. Existing local authorizations remain scoped to that installation; they are not copied into public releases.

Future clients such as Muse require reviewed adapter implementation, installation, real capability qualification and new supported connection bootstrap/identity verification. V1 includes no arbitrary downloaded adapter loader or provider marketplace. Named personal assistants already exist in their host. Checklist recognizes their verified identity, never creates named workers or a personality catalog. Codex/Claude workers remain actual sessions; host-exported thread references are observations. Review excludes actual recorded contributors while permitting a genuine separate non-contributor reviewer on the same authenticated host.
