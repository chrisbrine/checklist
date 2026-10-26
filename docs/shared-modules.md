# Shared module extraction (CL-98)

`Packages/ChecklistShared` is the first real portable package. Its targets use
Swift 6 language mode (complete concurrency checking). The macOS root enables
complete checking and converts bounded targets to Swift 6; remaining adapter
and fixture boundaries are recorded in [the concurrency audit](swift-concurrency.md).
Product identities are unchanged. The shared package
has no external dependencies or platform minimum, and does not depend on the
root package. This source boundary is not a claim of qualified non-macOS products.

| Target | Initial authoritative contents | Real consumers |
|---|---|---|
| ChecklistDomain | TicketKind, TicketStatusCategory, AttemptPhase, WorkflowRole, CallerRole, stable wire values and phase-to-policy-role relationship | Core and App; Application/Contracts may depend on Domain |
| ChecklistContracts | Core, service and owner-media read-method metadata | Core dispatch/catalog and IPC reply classification; CLI/App use IPC |
| ChecklistApplication | Typed ticket-capture input, observed state, result plan, title/key validation and Draft/queued defaults | Core task_create adapter |

The package has no GRDB, AppKit, SwiftUI, Security, XPC, credential, process or
filesystem effects. Native code supplies authenticated scope and transactional
state. Metadata classifies request/receipt behavior; it never authorizes a call.
`coreReads` excludes the service-only `connection_list` and `task_handoff_prepare`.
`mediaInternalReads` classifies the internal media dispatcher; it intentionally
differs from the owner-channel media reads. Both sets live in `CommandMethods`.
Owner media lease reads retain their existing writer fallback in Core.

## Capture transaction

`TicketCaptureInput`, `TicketCaptureState` and `TicketCaptureResult` are immutable,
Sendable values. `TicketCapture.plan` performs no I/O. Its result is a plan, not a
receipt or evidence of a committed command. Core's `TicketCaptureAdapter` remains
the JSON/GRDB compatibility facade called by the existing dispatcher.

`CommandRouter.execute` still owns the single validated transaction. It validates
scope and command identity, reconciles a principal-scoped receipt, calls the
capture adapter, creates the opaque cursor and stores the semantic receipt before
commit. Within that same transaction the adapter reads the project counter and
queued status, validates title/kind/key, validates the primary Epic, tags and
assignment/policy, saves the counter and Draft ticket, synchronizes Epic membership
and appends `task_created`. Any failure rolls these writes back. Retry with the
same principal, command ID and payload returns the original result; a changed
payload conflicts. No schema, startup, migration, backup or storage format changes
are part of this extraction.

Legacy optional JSON fields (including owner-channel null behavior), assignment
and starter-field validation stay in Core. `Models.swift` JSON helpers and all
canonical UTF-8/SHA-256 producers are unchanged. Immutable legacy vectors were
executed before any codec extraction; no codec was moved in this slice. Shared
Codable enum decoding rejects unknown values, while existing open JSON record
codecs retain unknown fields. Do not silently substitute Codable for those codecs.

## Build and tests

From the root, resolve the existing pinned lock and build `ChecklistProducts` as
before. The root declares the local shared package and explicit product edges;
no second runtime or store is composed. Root App/Core/IPC tests cover the facade.
The portable tests also run independently of UI packaging:

```sh
swift test --package-path Packages/ChecklistShared
```

Use the caller's required build-slot wrapper, shared dependency cache and warm
scratch arguments where the current work session requires them. Do not run two
commands against one scratch path concurrently. Standalone shared tests need no
root dependencies, signed app, store, native host, Keychain or live installation.
The import-boundary test rejects nonportable production imports; enum/capture and
read-metadata tests freeze wire spellings and exact classification.

`LegacyContractParityTests` freezes missing/null, NSNumber/Boolean conversions,
unknown fields/enums, exact canonical UTF-8 and SHA-256. `TicketCaptureExtractionTests`
uses synthetic template stores, including a failing event trigger after ticket,
counter and Epic writes, to verify rollback and original-command retry/replay.
Existing claim, review, project-isolation and retry tests remain authoritative.
Native installed checks and independent completion gates still bind the exact
combined target; unit tests do not establish native UI/transport qualification.

## Migration and ownership

1. CL-98 alone establishes these definitions, the first package edges and capture
   planning. Core re-exports Domain for compatibility; `ReviewRequirementKind` is
   an alias of `TicketKind`, and old read-method properties are aliases of the
   shared metadata. They hold no independent lists or rule implementations.
2. CL-88 consumes these same definitions for remaining typed stored records,
   codec adoption, malformed-record errors and cleanup. Keep legacy fixtures fixed
   and preserve their permissive behavior unless a separate contract change is
   authorized. Do not create a competing enum, read list or evidence hash codec.
3. CL-99 extracts real native/storage adapters while retaining SwiftUI/AppKit,
   signed XPC, owner-channel authority, Keychain/native bootstrap and process fences.
   Shared modules must not acquire those dependencies or widen capabilities.
4. Future command families move incrementally behind the Core facade. Keep scope,
   state, membership, events and principal-scoped receipt in one transaction. A
   rollback restores the previous code/manifest together; it never resets data.

## Checked record consumers (CL-88)

Core's `StoredRecord` is a field-on-demand compatibility view of open JSON.
Mandatory string, object and object-array access throws `CANONICAL_RECORD_INVALID`
for a missing, null or wrongly typed field. Presence-only access retains every
present dynamic value, including null. Optional fields keep the existing helper
defaults and Foundation Boolean/number bridging. `StoredTaskRecord` and
`StoredAttemptRecord` expose checked identities and the shared Domain enum views;
an unknown enum spelling remains in the raw record and is not silently rewritten.

These consumer views do not replace the canonical storage envelope, revise the
schema, authorize work or close extensible records with synthesized Codable.
The existing JSON serializer and hash producers retain their legacy bytes.
Core command, read, review, group, media and managed-file consumers use the checked
views at mandatory field access. App command replies validate required identity
before applying navigation or clearing capture text; display-only optional fields
retain their established fallbacks. CLI continues through typed MCP values and
IPC's authoritative read-method classification.

The root's former blanket `Packages/` ignore is removed now that the first authored
package exists. Package-local `.build`/`.swiftpm` remain ignored. CL-97's complete
local-package inventory includes manifests, sources, tests and resources in
immutable captures, including nonignored untracked package inputs. Do not ship
package code that is absent from that capture. Staging/helper/signing paths and
all executable identifiers stay unchanged.

The implemented native/storage seams and retained authority owners are documented
in [platform adapters](platform-adapters.md). Their interfaces stay in native root
targets; ChecklistShared gains no OS, SQL, process or credential dependency.
