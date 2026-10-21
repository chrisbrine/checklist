#!/usr/bin/env python3
"""Check CLI argument guards without connecting, enrolling or changing a store."""
from __future__ import annotations

import argparse
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/checklist")
    binary = parser.parse_args().binary
    # Every failure occurs in argument/command validation before IPC bootstrap.
    # Missing call METHOD tests that valid assistant UUID/name syntax is accepted
    # by the option parser while avoiding a connection or any service operation.
    cases = [
        (["help"], 0, "connect --assistant --project UUID_OR_EXACT_NAME"),
        (["tools", "--task", "CL-4"], 1, "supported only"),
        (["connect", "--task"], 1, "Missing value"),
        (["connect", "--task", "CL-4", "--task", "CL-5"], 1, "only once"),
        (["connect", "--task", "CL 4"], 1, "key or task UUID"),
        (["connect", "--task", "CL-4", "--installation", "legacy"], 1, "omit --installation"),
        (["connect", "--assistant"], 1, "requires --project"),
        (["connect", "--assistant", "--project"], 1, "Missing value"),
        (["connect", "--assistant", "--project", "   "], 1, "requires --project"),
        (["connect", "--assistant", "--project", "Game\nProject"], 1, "requires --project"),
        (["connect", "--project", "Project"], 1, "requires --assistant"),
        (["connect", "--assistant", "--assistant", "--project", "Project"], 1, "only once"),
        (["connect", "--assistant", "--project", "One", "--project", "Two"], 1, "only once"),
        (["connect", "--assistant", "--project", "Project", "--installation", "legacy"], 1, "omit --installation"),
        (["connect", "--assistant", "--project", "Project", "--task", "CL-4"], 1, "cannot use --task"),
        (["service", "status", "--assistant", "--project", "Project"], 1, "supported by connect"),
        (["call", "--assistant", "--project", "Exact Project Name"], 1, "Usage: checklist call"),
        (["call", "--assistant", "--project", "a85c9a24-fce8-49ba-a738-67594bb90a67"], 1, "Usage: checklist call"),
    ]
    for arguments, expected_exit, expected_text in cases:
        result = subprocess.run([binary, *arguments], text=True, capture_output=True, timeout=10)
        assert result.returncode == expected_exit, (arguments, result.returncode, result.stderr)
        assert expected_text in result.stdout + result.stderr, (arguments, result.stdout, result.stderr)
    print(f"{len(cases)} CLI argument checks passed; no service connection or mutation.")


if __name__ == "__main__":
    main()
