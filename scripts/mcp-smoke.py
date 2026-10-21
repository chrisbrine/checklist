#!/usr/bin/env python3
"""Exercise the installed SDK stdio server; never starts a model or imports boards.

Read checks are the default. --exercise-project explicitly permits a synthetic
Draft and an idempotent retry inside that already-enrolled project.
--expect-unregistered checks the limited start of a native conversation whose
folder is not a Checklist project: only service_info, with setup guidance.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid


class MCPProbe:
    def __init__(self, command: list[str]):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.sequence = 0
        self.notifications: list[dict] = []

    def send(self, message: dict):
        self.process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        self.process.stdin.flush()

    def request(self, method: str, params: dict | None = None, timeout: float = 15) -> dict:
        self.sequence += 1
        request_id = self.sequence
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                ready = self.selector.select(max(0, deadline - time.monotonic()))
                if not ready:
                    break
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("MCP stdout closed before a response; inspect redacted service diagnostics.")
                self.buffer += chunk
                if len(self.buffer) > 2 * 1024 * 1024:
                    raise RuntimeError("MCP output exceeds smoke-test bound.")
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            frame = json.loads(line)
            if frame.get("id") == request_id:
                return frame
            self.notifications.append(frame)
        raise TimeoutError(f"No MCP response to {method} within {timeout:g}s")

    def tool(self, name: str, arguments: dict | None = None) -> dict:
        response = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        assert "error" not in response, response
        result = response["result"]
        assert not result.get("isError", False), result
        assert isinstance(result.get("structuredContent"), dict), result
        return result["structuredContent"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)
        self.selector.close()
        self.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="/Applications/Checklist.app/Contents/MacOS/checklist")
    parser.add_argument("--service-only", action="store_true", help="Read-only unenrolled service probe; never bootstrap a native conversation")
    parser.add_argument("--workspace", default=str(Path.cwd()))
    parser.add_argument("--installation", help="Optional legacy/assistant binding; omit for automatic native connection")
    parser.add_argument("--session")
    mutation = parser.add_mutually_exclusive_group()
    mutation.add_argument("--exercise-project", help="Explicitly create one synthetic Draft in this permitted project ID")
    mutation.add_argument("--exercise-current-project", action="store_true", help="Resolve the native working directory and create one synthetic Draft without entering IDs")
    mutation.add_argument("--expect-unregistered", action="store_true", help="Expect the limited start of a native folder that is not a Checklist project; enrolls nothing")
    parser.add_argument("--output", help="Optional private receipt JSON path")
    arguments = parser.parse_args()
    command = [arguments.binary, "mcp", "--workspace", str(Path(arguments.workspace).resolve())]
    if arguments.service_only:
        assert not (arguments.installation or arguments.session or arguments.exercise_project or arguments.exercise_current_project or arguments.expect_unregistered)
        command += ["--installation", "test-instance-read-only-probe"]
    if arguments.installation:
        command += ["--installation", arguments.installation]
    if arguments.session:
        command += ["--session", arguments.session]
    probe = MCPProbe(command)
    report = {"schema_version": 1, "checks": [], "model_started": False, "source_boards_migrated": False}
    try:
        initialized = probe.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Checklist installed MCP smoke", "version": "1.0"}})
        assert "error" not in initialized, initialized
        assert initialized["result"]["serverInfo"]["name"] == "Checklist"
        capabilities = initialized["result"]["capabilities"]
        assert capabilities.get("tools") is not None
        assert "events" not in capabilities, "Unqualified MCP Events must not be advertised"
        report["protocol_version"] = initialized["result"]["protocolVersion"]
        report["checks"].append("official SDK initialize")
        limited = "PROJECT_SETUP_REQUIRED" in initialized["result"].get("instructions", "")
        assert limited == arguments.expect_unregistered, "Server limited-start state differs from the expected folder registration"
        probe.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert "error" not in probe.request("ping")
        report["checks"].append("ping")
        listed = probe.request("tools/list")
        assert "error" not in listed, listed
        tools = listed["result"]["tools"]
        names = {tool["name"] for tool in tools}
        assert "service_info" in names
        for tool in tools:
            assert tool["inputSchema"].get("type") == "object", tool["name"]
            assert tool["inputSchema"].get("additionalProperties") is False, tool["name"]
        assert not names.intersection({"human_request_answer", "connection_pair", "project_create"}), names
        # Checklist is AI-first: workers change project rules and settings (owner decision 2026-10-18).
        if arguments.service_only:
            assert names == {"service_info"}, names
        elif not arguments.expect_unregistered:
            assert {"policy_apply", "project_settings_save", "status_create", "task_archive", "work_takeover"} <= names, names
        report["tool_count"] = len(names)
        report["checks"].append("role-limited discovery and closed schemas")
        info = probe.tool("service_info")
        assert info.get("data", info).get("state") != "recovery_required", info
        report["checks"].append("structured service_info")
        if arguments.expect_unregistered:
            connection = info.get("data", info).get("connection", {})
            assert names == {"service_info"}, names
            assert connection.get("state") == "project_setup_required" and connection.get("connected") is False, info
            probe.stderr.seek(0)
            assert b"PROJECT_SETUP_REQUIRED" in probe.stderr.read(), "Setup guidance missing from stderr"
            report["checks"].append("unregistered folder: limited start with setup guidance, no enrollment")
        unknown = probe.request("tools/call", {"name": "connection_pair", "arguments": {}})
        assert "error" in unknown or unknown.get("result", {}).get("isError") is True
        report["checks"].append("owner tool denied")
        malformed = probe.request("tools/call", {"name": "service_info", "arguments": {"owner": True}})
        assert "error" in malformed or malformed.get("result", {}).get("isError") is True
        report["checks"].append("unknown argument rejected")
        resources = probe.request("resources/list")
        assert "error" not in resources, resources
        for resource in resources["result"]["resources"]:
            read = probe.request("resources/read", {"uri": resource["uri"]})
            assert "error" not in read, read
            assert read["result"]["contents"]
        report["checks"].append("scoped resources")
        project_id = arguments.exercise_project
        if arguments.exercise_current_project:
            resolved = probe.tool("project_resolve", {"workspace_path": str(Path(arguments.workspace).resolve())})
            resolved_data = resolved.get("data", resolved)
            projects = resolved_data.get("projects", [])
            assert resolved_data.get("state") == "registered" and len(projects) == 1, resolved_data
            project_id = projects[0]["id"]
            report["checks"].append("actual workspace resolved without user-entered IDs")
        if project_id:
            assert {"task_create", "task_get"} <= names, names
            nonce = uuid.uuid4().hex[:10]
            create = {"project_id": project_id, "command_id": str(uuid.uuid4()),
                      "title": "MCP verification " + nonce, "brief": "Synthetic installed-protocol verification. No source checklist migration.", "kind": "question"}
            first = probe.tool("task_create", create)
            retry = probe.tool("task_create", create)
            first_data = first.get("data", first)
            retry_data = retry.get("data", retry)
            first_task = first_data.get("task", first_data)
            retry_task = retry_data.get("task", retry_data)
            task_id = first_task.get("id") or first_task.get("task_id")
            assert task_id and task_id == (retry_task.get("id") or retry_task.get("task_id"))
            fetched = probe.tool("task_get", {"project_id": project_id, "task_id": task_id})
            assert nonce in json.dumps(fetched)
            report["synthetic_task_id"] = task_id
            report["checks"].append("synthetic Draft create/read and lost-reply idempotent retry")
        report["result"] = "passed"
    finally:
        probe.close()
    if arguments.output:
        output = Path(arguments.output)
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")
        output.chmod(0o600)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
