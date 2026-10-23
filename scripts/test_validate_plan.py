#!/usr/bin/env python3
"""Regression cases for the planning validator's synthetic cleanup guidance lint."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('validate_plan', Path(__file__).with_name('validate-plan.py'))
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class SyntheticProjectGuidanceTests(unittest.TestCase):
    def test_original_acceptance_cleanup_is_rejected(self):
        self.assertEqual(plan.synthetic_project_cleanup_errors(
            'A runner creates a synthetic project through MCP and archives it afterwards.'), [1])

    def test_wrapped_runner_brief_is_rejected_with_line_number(self):
        self.assertEqual(plan.synthetic_project_cleanup_errors(
            '# Brief\n\nCreate a synthetic test project.\nAfter the check, archive it afterwards.'), [3])

    def test_direct_and_passive_archive_instructions_are_rejected(self):
        for text in ('Archive the synthetic project after testing.',
                     'Synthetic projects should be archived after testing.',
                     'Synthetic test projects are archived after testing.'):
            with self.subTest(text=text):
                self.assertEqual(plan.synthetic_project_cleanup_errors(text), [1])

    def test_prohibitions_and_slot_destruction_are_allowed(self):
        for text in ('Never archive synthetic projects; destroy the owned slot.',
                     'Synthetic projects must not be archived. Destroy the slot.',
                     'Create synthetic projects through the slot CLI; do not archive them.',
                     'Never create synthetic projects in live or retain them by archiving.',
                     'Synthetic projects belong in slots. Archiving retains projects and is not cleanup.'):
            with self.subTest(text=text):
                self.assertEqual(plan.synthetic_project_cleanup_errors(text), [])

    def test_prohibition_does_not_hide_later_bad_instruction(self):
        self.assertEqual(plan.synthetic_project_cleanup_errors(
            'Do not archive synthetic projects. Create a synthetic project and archive it later.'), [1])

    def test_ticket_archive_checks_are_allowed(self):
        self.assertEqual(plan.synthetic_project_cleanup_errors(
            'Create a synthetic project in a slot. Archive the ticket and verify restore.'), [])

    def test_unrelated_paragraphs_are_not_joined(self):
        self.assertEqual(plan.synthetic_project_cleanup_errors(
            'Synthetic projects use test slots.\n\nRead a real ticket, then archive it.'), [])


if __name__ == '__main__':
    unittest.main()
