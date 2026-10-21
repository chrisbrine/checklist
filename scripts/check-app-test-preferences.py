#!/usr/bin/env python3
"""Run app tests and fail if they leave any new Checklist test preference plist.

Usage: python3 scripts/check-app-test-preferences.py [-- command ...]
This check only reads Preferences. Existing files belong to the separately
reviewed Trash cleanup; real Checklist.Workspace.* preferences are excluded.
"""
from pathlib import Path
import subprocess
import sys
import time


def test_plists(preferences: Path) -> set[str]:
    directories = [preferences, preferences / "ByHost"]
    return {
        str(path.relative_to(preferences))
        for directory in directories if directory.is_dir()
        for path in directory.glob("Checklist.*.plist")
        if not path.name.startswith("Checklist.Workspace.")
    }


def main() -> int:
    command = sys.argv[1:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        command = ["swift", "test", "--disable-sandbox", "--filter", "ChecklistAppTests"]
    return check(command, Path.home() / "Library" / "Preferences")


def check(command: list[str], preferences: Path) -> int:
    before = test_plists(preferences)
    print(f"Checklist test plists before: {len(before)}", flush=True)
    result = subprocess.run(command, check=False)
    # Process exit can flush an empty domain after per-test unlinking. Give
    # cfprefsd two separate settling intervals and retain leaks from either count.
    added: set[str] = set()
    for sample in range(1, 3):
        time.sleep(3)
        after = test_plists(preferences)
        added.update(after - before)
        print(f"Checklist test plists after {sample * 3}s: {len(after)}; new: {len(after - before)}; removed: {len(before - after)}", flush=True)
    for path in sorted(added):
        print("LEAK: " + path, file=sys.stderr)
    return result.returncode or (1 if added else 0)


if __name__ == "__main__":
    raise SystemExit(main())
