"""Discovery qualification checks; no installed process, enrollment or mutation."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("mcp_smoke", Path(__file__).with_name("mcp-smoke.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class DiscoveryTests(unittest.TestCase):
    def tools(self, *names):
        return [{"name": name, "inputSchema": {"type": "object", "additionalProperties": False}} for name in names]

    def test_verified_unregistered_discovery_requires_creation_and_no_project_tools(self):
        tools = self.tools("service_info", "project_create")
        self.assertEqual(smoke.validate_discovery(tools, service_only=False, expect_unregistered=True), {"service_info", "project_create"})
        for rejected in [self.tools("service_info"), tools + self.tools("task_list")]:
            with self.assertRaises(AssertionError):
                smoke.validate_discovery(rejected, service_only=False, expect_unregistered=True)

    def test_bound_worker_includes_creation_for_receipt_replay(self):
        tools = self.tools("service_info", "project_create", "policy_apply", "project_settings_save", "status_create", "task_archive", "work_takeover")
        self.assertIn("project_create", smoke.validate_discovery(tools, service_only=False, expect_unregistered=False))
        with self.assertRaises(AssertionError):
            smoke.validate_discovery([t for t in tools if t["name"] != "project_create"], service_only=False, expect_unregistered=False)

    def test_unenrolled_service_probe_stays_read_only(self):
        self.assertEqual(smoke.validate_discovery(self.tools("service_info"), service_only=True, expect_unregistered=False), {"service_info"})
        with self.assertRaises(AssertionError):
            smoke.validate_discovery(self.tools("service_info", "project_create"), service_only=True, expect_unregistered=False)

    def test_owner_tools_and_open_schemas_fail_discovery(self):
        tools = self.tools("service_info", "project_create")
        for owner_tool in ["connection_pair", "human_request_answer"]:
            with self.assertRaises(AssertionError):
                smoke.validate_discovery(tools + self.tools(owner_tool), service_only=False, expect_unregistered=True)
        for schema in [{"type": "object"}, {"type": "array", "additionalProperties": False}]:
            with self.assertRaises(AssertionError):
                smoke.validate_discovery([tools[0], {"name": "project_create", "inputSchema": schema}], service_only=False, expect_unregistered=True)


if __name__ == "__main__":
    unittest.main()
