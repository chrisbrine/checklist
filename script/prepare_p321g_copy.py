#!/usr/bin/env python3
"""Prepare an owned CL-321 maintenance fixture; never open a live store."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--finish-existing", action="store_true", help="Finish metadata after a successful copy interrupted before marker publication")
    args = parser.parse_args()
    source, runtime = args.snapshot.resolve(), args.runtime.resolve()
    if not str(source).startswith("/private/tmp/") or runtime.parent != source:
        parser.error("Use the independently copied snapshot and its immediate runtime child in /private/tmp.")
    if runtime.exists() and not args.finish_existing:
        parser.error("Runtime already exists; preserve it and select a fresh runtime child.")
    if args.finish_existing and (not runtime.is_dir() or (runtime / ".p321g-owned-copy.json").exists()):
        parser.error("Resume only an incomplete marked-copy preparation.")
    for name in ("database.sqlite", "manifest.json", "managed"):
        if not (source / name).exists():
            parser.error(f"Copied snapshot lacks {name}")
    started = time.monotonic()
    if not args.finish_existing:
        runtime.mkdir(mode=0o700)
        subprocess.run(["/bin/cp", "-c", str(source / "database.sqlite"), str(runtime / "checklist.sqlite")], check=True)
        subprocess.run(["/bin/cp", "-cR", str(source / "managed") + "/.", str(runtime)], check=True)
    manifest = json.loads((source / "manifest.json").read_bytes())
    with open(runtime / "checklist.sqlite", "rb") as database:
        if hashlib.file_digest(database, "sha256").hexdigest() != manifest["databaseSHA256"]:
            raise RuntimeError("Runtime database does not match the immutable snapshot")
    # Read the immutable copied snapshot only. No SQLite write or restore occurs.
    with sqlite3.connect(f"file:{source / 'database.sqlite'}?mode=ro&immutable=1", uri=True) as connection:
        connection.create_collation("checklist_storage_v2", lambda a, b: (a.encode() > b.encode()) - (a.encode() < b.encode()))
        raw = connection.execute("SELECT value FROM metadata WHERE key COLLATE BINARY='store_identity'").fetchone()[0]
    identity = json.loads(raw)
    if identity.get("state") != "ready":
        raise RuntimeError("Copied snapshot identity is not ready")
    (runtime / "checklist-store.identity.json").write_text(json.dumps(identity, sort_keys=True))
    manifest_sha = hashlib.sha256((source / "manifest.json").read_bytes()).hexdigest()
    marker = {"purpose": "P321g-real-maintenance-owned-copy", "snapshot": str(source),
              "manifest_sha256": manifest_sha, "database_source": str(source / "database.sqlite"),
              "copy_method": "cp -c database; cp -cR managed/.", "database_mutated": False,
              "seconds": time.monotonic() - started,
              "load": subprocess.check_output(["/usr/sbin/sysctl", "-n", "vm.loadavg"], text=True).strip()}
    (runtime / ".p321g-owned-copy.json").write_text(json.dumps(marker, indent=2, sort_keys=True))
    print(json.dumps(marker, sort_keys=True))


if __name__ == "__main__":
    main()
