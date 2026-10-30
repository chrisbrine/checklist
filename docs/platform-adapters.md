# Native and storage adapters (CL-99)

Checklist retains its SwiftUI/AppKit macOS application. The portable
ChecklistShared package contains no platform effects or authority. These adapters
are narrow boundaries within the existing native targets, not a second runtime,
remote API, plugin loader or claim of other-platform support.

| Effect | Interface and production implementation | Authority retained by |
|---|---|---|
| Command transaction access | Core `TransactionStorage` / `GRDBTransactionAdapter` | StorageBootstrap, storage admission/archive gates, scoped command transaction |
| Local command transport | IPC `LocalCommandTransport` / `MacOSLocalCommandTransport` | Service signed-XPC peer authentication and grants |
| Local service preparation/registration/start | IPC `LocalServiceLifecycle` / `MacOSLocalServiceLifecycle` | Existing app identity, SMAppService registration and launchd singleton |
| Installation credential read | IPC `LocalCredentialReader` / `MacOSLocalCredentialReader` | `InstallationCredentialStore` private files, exact instance/root/installation binding, service code-signature and enrollment checks ([protection](database-storage.md#agent-installation-credentials-cl-374)) |
| Native socket send | Bridges `NativePeerTransportEffects` / `MacOSNativePeerTransportEffects` | Bundled provider qualification, private socket, kernel UID/PID and native process/registry verification |
| Confined source Git process | Core `SourceGitProcessAdapter` / `MacOSSourceGitProcessAdapter` | SourceGit executable/root/environment validation, protected-root confinement and existing error/stop handling |
| Verified local file read | Core `AuthorizedFileReading` / `MacOSAuthorizedFileReader` | Descriptor identity, allowed roots, regular-file/size checks and no-follow open |
| Owner draft file I/O | App `DraftFileStorage` / `MacOSDraftFileStorage` | Owner-local journal scope, atomic replacement, permissions, file/directory synchronization and readback |

Remaining Keychain use in product code (owner decision, 30 October 2026, CL-374):

| Use | File | Reason | Removal condition |
|---|---|---|---|
| One no-UI read of an old installation credential, when no file record exists, on the live instance only | `Sources/ChecklistIPC/LegacyKeychainCredentialMigration.swift` and its bridge `Sources/ChecklistLegacyKeychain/` (only the interaction flag calls) | Enrolled sessions of an existing installation keep working across the install with no prompt and no reconnect | Every live enrollment has a file record, and the owner keeps no bundle that reads Keychain for rollback |

`InstallationCredentialStoreTests.testSourceKeepsKeychainCallsInTheOneMigrationFile` keeps every other Keychain call out of `Sources/` and `Packages/`. `script/test_instances.py destroy` makes no Keychain call and runs no `security` command (CL-379). A test slot keeps its credentials in private files in the slot folder, so a slot created before CL-374 is removed the same way, and a leftover item of an older slot is ignored.

The transaction adapter wraps the queue already opened by StorageBootstrap. It
preserves synchronous GRDB read/write/writeWithoutTransaction/close semantics.
`writeWithoutTransaction` does not add a transaction: command dispatch still owns
the same atomic state, membership, event and principal-scoped receipt commit.
Read pools, schema, validation, migrations, consistent backup and managed-file
storage remain the existing native storage implementation; none enters shared
Domain/Application. This is an incremental extraction, not removal of all GRDB
from Core or a portable database protocol.

ChecklistClient composes the native transport, lifecycle and credential adapters
by default, keeping its existing API and anonymous-XPC-listener test seam. Request
serialization, original command IDs, retry rules and bootstrap budgets remain in
the client. XPC wait/error classification, native startup and app registration
live in the macOS adapters. A request's owner_channel flag remains untrusted: only
the service checks actual signed application identity. Injecting an adapter grants
no server role, workspace, credential or native identity.

Native peer send retains socket ownership/mode, no-follow identity, connected
kernel peer PID, inode recheck, exact registry/process expectations, bounded
write, and partial-write uncertainty. It does not interpret a write receipt as
acknowledgment. ClaudeLocalBridge retains its compatibility entrypoint. SourceGit
retains preflight before invoking its process adapter; no adapter failure triggers
a second executable, unconfined Git, different model/runtime or extra enrollment.
Job reservations and uncertain-process restart/stop fences remain in their
existing service/Core owners. Moving an effect never grants authority to release
a reservation or assert native conversation closure.

Other existing native services stay in their owning targets: NativeSessionContext
and ClaudeNativeHost handle native bootstrap/registry observations; service
ClientCodeIdentity/NativeCodeIdentity authenticate those observations; bounded
StorageFolderAccess and StorageObjectFiles/SafeFileRead own descriptor-based file
access; Finder panels and authorized preview copies remain in the AppKit shell.
DesktopAlertSink/SystemDesktopAlertSink already separates notification effects.
SafeFileRead is a compatibility facade over AuthorizedFileReading; its production
implementation preserves the same kernel descriptor/path revalidation.
Window/focus bridges, DockBadge, redacted diagnostics and signed immutable
packaging remain macOS-only. HumanClaims and pending-command recovery use the
macOS OwnerPrivateFileStore (CL-373), and the app makes no Keychain call. No UI
runtime, database schema or service credential format changes are introduced.

Unsupported capabilities fail explicitly: unavailable local IPC services report
PLATFORM_CAPABILITY_UNAVAILABLE with the exact capability; unsupported native peer
transport reports ADAPTER_UNAVAILABLE; unsupported confined Git returns the
existing SOURCE_GIT_CONFINEMENT_UNAVAILABLE; unavailable draft writes report
PLATFORM_CAPABILITY_UNAVAILABLE / owner_draft_storage. Unavailable verified file
reads report PLATFORM_CAPABILITY_UNAVAILABLE / authorized_file_read. IPC
supportedCapabilities describes implementation support, not current authorization
or successful slot/service registration. Unit tests exercise these
paths and verify that no fallback effect is invoked. These are unavailable
implementations for callers/tests, not newly advertised Windows/Linux products.

Verification includes in-memory/fake adapter tests and existing transaction,
XPC, Keychain, confinement, peer/lifecycle, draft and service regression targets.
Native qualification must use the exact signed stage and owned consistent actual
store copy through full protected startup/pre-upgrade backup, including retained
records/managed files. Settings, incomplete/Done navigation, durable drafts, real
review and supported host integration still require native observation. An
independent installed review remains separate from source tests/review.
