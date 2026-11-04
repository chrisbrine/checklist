import Foundation

/// Test-only structural memory guard seam (CL-408). Production installs no
/// observer, so each report is one nil check. `script/memory_guard.py` runs
/// `StorageMemoryGuardTests` in its own process, installs an observer and fails
/// when startup or a backup builds a whole-store record array or reads a
/// manifest other than the new backup's own manifest whole.
enum StorageMemoryGuardSeam {
    /// (event, subject, count): `whole_store_records` reports a loader that keeps
    /// every canonical record at once (subject = loader, count = records);
    /// `whole_manifest_read` reports a complete manifest read into one Data value
    /// (subject = manifest path, count = bytes).
    nonisolated(unsafe) static var observe: ((String,String,Int) -> Void)?
}
