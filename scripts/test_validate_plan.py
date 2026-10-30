#!/usr/bin/env python3
"""Regression cases for the planning validator's synthetic cleanup guidance lint."""
import importlib.util
from pathlib import Path
import tempfile
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



class SkillReferenceConsistencyTests(unittest.TestCase):
    def write_tree(self, root, *, table=None, contract_extra=''):
        references = root / 'skills/checklist/references'
        references.mkdir(parents=True)
        (root / 'docs').mkdir()
        rows = table if table is not None else ('| `attachment_read` | input | note |\n'
                                                 '| `policy_preview` | always | note |\n')
        rules = {rel: '\n'.join(found) for rel, found in plan.SKILL_RULE_TEXT.items()}
        for rel, body in rules.items():
            if rel.endswith('driven-sessions.md'):
                body = body.replace('## Reads that run as operations',
                                    '## Reads that run as operations\n\n' + rows + '\n## Next\n') + '\n'
            (root / rel).write_text(body)
        (root / 'skills/checklist/SKILL.md').write_text(
            ' '.join(f'references/{Path(rel).name}' for rel in rules))
        (root / 'docs/mcp-contract.md').write_text(
            'The service always uses this route for `backup_create`, `policy_preview`. `project_edit` and others.\n'
            'Read operations run exactly as their synchronous reads: These are `attachment_read`, `policy_preview`'
            + contract_extra + '. A backup capture does not wait.\n')

    def errors(self, **kwargs):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.write_tree(root, **kwargs)
            return plan.skill_reference_errors(root)

    def test_consistent_tree_has_no_errors(self):
        self.assertEqual(self.errors(), [])

    def test_contract_read_missing_from_table_is_reported(self):
        errors = self.errors(contract_extra=', `task_get`')
        self.assertEqual(len(errors), 1)
        self.assertIn('task_get', errors[0])

    def test_table_method_not_in_contract_is_reported(self):
        errors = self.errors(table='| `attachment_read` | input | n |\n| `policy_preview` | always | n |\n'
                                   '| `review_context` | input | n |\n')
        self.assertEqual(len(errors), 1)
        self.assertIn('review_context', errors[0])

    def test_wrong_route_is_reported(self):
        errors = self.errors(table='| `attachment_read` | always | n |\n| `policy_preview` | always | n |\n')
        self.assertEqual(len(errors), 1)
        self.assertIn('attachment_read', errors[0])

    def test_removed_rule_and_unlinked_reference_are_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.write_tree(root)
            review = root / 'skills/checklist/references/review.md'
            review.write_text('no rule here')
            (root / 'skills/checklist/references/new.md').write_text('# New')
            errors = plan.skill_reference_errors(root)
        self.assertEqual(len(errors), 2)
        self.assertIn('review.md: missing process rule', errors[0] + errors[1])
        self.assertIn('references/new.md', errors[0] + errors[1])


if __name__ == '__main__':
    unittest.main()
