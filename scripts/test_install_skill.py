"""Skill install checks use only temporary home, source and Trash folders (CL-423)."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'script/install_skill.py'
SKILL = '---\nname: checklist\ndescription: fixture\n---\n# Checklist\n'


def files_of(root):
    return {path.relative_to(root).as_posix(): path.read_text()
            for path in sorted(root.rglob('*')) if path.is_file()}


class InstallSkillTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        # Read-only fixtures must stay removable by the temporary-folder cleanup.
        self.addCleanup(lambda: [os.chmod(p, os.lstat(p).st_mode | stat.S_IWUSR)
                                 for p in [self.root, *self.root.rglob('*')] if not p.is_symlink()])
        self.home = self.root / 'home';self.home.mkdir()
        resources = self.root / 'Checklist.app/Contents/Resources'
        self.source = resources / 'skills/checklist'
        (self.source / 'references').mkdir(parents=True)
        (self.source / 'SKILL.md').write_text(SKILL + 'new rule\n')
        (self.source / 'references/work.md').write_text('new work\n')
        (resources / 'build-info.json').write_text(json.dumps({'version': '0.0.1.9', 'build_number': 999,
                                                               'build_id': 'fixture', 'source_fingerprint': 'f' * 64}))
        self.claude = self.home / '.claude/skills/checklist'
        self.codex = self.home / '.agents/skills/checklist'
        self.environment = {key: value for key, value in os.environ.items() if key != 'CHECKLIST_TRASH_DIR'}
        self.environment['HOME'] = str(self.home)

    def run_script(self, *arguments, source=None):
        result = subprocess.run([sys.executable, str(SCRIPT), *arguments, '--source', str(source or self.source)],
                                env=self.environment, capture_output=True, text=True, timeout=60)
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        return result, {row.get('host'): row for row in rows}

    def old_copy(self, target, skill=SKILL + 'old rule\n', read_only=False):
        (target / 'references').mkdir(parents=True)
        (target / 'SKILL.md').write_text(skill)
        (target / 'references/work.md').write_text('old work\n')
        if read_only:
            for path in [*target.rglob('*'), target]:
                os.chmod(path, os.stat(path).st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))

    def trash_entries(self):
        trash = self.home / '.Trash'
        return sorted(trash.iterdir()) if trash.exists() else []

    def test_preview_plans_installs_and_writes_nothing(self):
        result, rows = self.run_script('--preview')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({rows['claude']['action'], rows['codex']['action']}, {'install'})
        self.assertEqual(rows['claude']['path'], str(self.claude))
        self.assertEqual(rows['codex']['path'], str(self.codex))
        self.assertEqual(rows['claude']['source_build']['build_number'], 999)
        self.assertFalse(rows['claude']['applied'])
        self.assertFalse((self.home / '.claude').exists());self.assertFalse((self.home / '.agents').exists())

    def test_apply_installs_both_hosts_with_receipt_then_reports_current(self):
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        for host, target in [('claude', self.claude), ('codex', self.codex)]:
            self.assertEqual(rows[host]['action'], 'installed');self.assertTrue(rows[host]['applied'])
            copied = files_of(target);receipt = json.loads(copied.pop('.checklist-skill-receipt.json'))
            self.assertEqual(copied, files_of(self.source))
            self.assertEqual(receipt['source_build']['build_number'], 999)
            self.assertEqual(sorted(receipt['files']), ['SKILL.md', 'references/work.md'])
            self.assertEqual(receipt['tree_sha256'], rows[host]['source_tree_sha256'])
            self.assertEqual(rows[host]['target_tree_sha256'], rows[host]['source_tree_sha256'])
            self.assertEqual(list(target.parent.iterdir()), [target], 'no incoming folder remains')
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({rows['claude']['action'], rows['codex']['action']}, {'current'})
        self.assertEqual(self.trash_entries(), [])

    def test_stale_copy_with_matching_receipt_moves_to_trash_and_is_replaced(self):
        self.run_script('--apply')
        (self.source / 'SKILL.md').write_text(SKILL + 'newer rule\n')
        (self.source / 'references/orchestration.md').write_text('new file\n')
        result, rows = self.run_script('--preview')
        self.assertEqual(rows['claude']['action'], 'replace')
        self.assertEqual(rows['claude']['difference'], {'added': [], 'changed': ['SKILL.md'],
                                                        'missing': ['references/orchestration.md']})
        self.assertIn('newer', (self.source / 'SKILL.md').read_text())
        self.assertNotIn('newer', (self.claude / 'SKILL.md').read_text(), 'preview changed nothing')
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({rows['claude']['action'], rows['codex']['action']}, {'replaced'})
        self.assertIn('newer rule', (self.claude / 'SKILL.md').read_text())
        self.assertTrue((self.codex / 'references/orchestration.md').is_file())
        trashed = self.trash_entries()
        self.assertEqual(len(trashed), 2);self.assertEqual(len({path.name for path in trashed}), 2)
        self.assertEqual({rows['claude']['trashed_to'], rows['codex']['trashed_to']}, set(map(str, trashed)))
        for path in trashed:
            self.assertIn('new rule', (path / 'SKILL.md').read_text())

    def test_user_changed_copy_with_receipt_is_kept_and_reported(self):
        self.run_script('--apply')
        (self.source / 'SKILL.md').write_text(SKILL + 'newer rule\n')
        (self.claude / 'references/work.md').write_text('my local change\n')
        (self.claude / 'mine.md').write_text('added by the user\n')
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows['claude']['action'], 'skip');self.assertFalse(rows['claude']['applied'])
        self.assertIn('user change', rows['claude']['reason'])
        self.assertEqual(rows['claude']['difference'], {'added': ['mine.md'], 'changed': ['references/work.md'],
                                                        'missing': []})
        self.assertEqual((self.claude / 'references/work.md').read_text(), 'my local change\n')
        self.assertEqual(rows['codex']['action'], 'replaced')
        self.assertEqual(len(self.trash_entries()), 1)

    def test_read_only_copy_without_receipt_is_replaced_and_stays_read_only(self):
        self.old_copy(self.claude, read_only=True)
        self.old_copy(self.codex, skill='---\nname: "checklist"\n---\nold codex\n', read_only=True)
        result, rows = self.run_script('--preview')
        self.assertEqual({rows['claude']['action'], rows['codex']['action']}, {'replace'})
        self.assertTrue(rows['claude']['read_only'])
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        for host, target in [('claude', self.claude), ('codex', self.codex)]:
            self.assertEqual(rows[host]['action'], 'replaced')
            self.assertEqual((target / 'SKILL.md').read_text(), SKILL + 'new rule\n')
            for path in [target, *target.rglob('*')]:
                self.assertFalse(os.stat(path).st_mode & stat.S_IWUSR, str(path) + ' stays read-only')
            trashed = Path(rows[host]['trashed_to'])
            self.assertEqual(trashed.parent, self.home / '.Trash')
            self.assertEqual((trashed / 'references/work.md').read_text(), 'old work\n')
            self.assertTrue(os.stat(trashed).st_mode & stat.S_IWUSR, 'the Trash copy is user-writable')

    def test_foreign_copy_without_receipt_is_skipped(self):
        self.old_copy(self.claude, skill='---\nname: other-skill\n---\nnot ours\n')
        (self.codex.parent).mkdir(parents=True);(self.codex).symlink_to(self.claude)
        result, rows = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows['claude']['action'], 'skip');self.assertIn("'other-skill'", rows['claude']['reason'])
        self.assertEqual(rows['codex']['action'], 'skip');self.assertIn('link', rows['codex']['reason'])
        self.assertIn('not ours', (self.claude / 'SKILL.md').read_text())
        self.assertEqual(self.trash_entries(), [])

    def test_unreadable_receipt_is_skipped(self):
        self.old_copy(self.claude)
        (self.claude / '.checklist-skill-receipt.json').write_text('{broken')
        result, rows = self.run_script('--apply')
        self.assertEqual(rows['claude']['action'], 'skip');self.assertIn('receipt is unreadable', rows['claude']['reason'])
        self.assertEqual(rows['codex']['action'], 'installed')

    def test_source_that_is_not_the_checklist_skill_is_refused(self):
        other = self.root / 'other';other.mkdir()
        (other / 'SKILL.md').write_text('---\nname: other\n---\n')
        result = subprocess.run([sys.executable, str(SCRIPT), '--apply', '--source', str(other)],
                                env=self.environment, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['action'], 'refused')
        self.assertFalse((self.home / '.claude').exists())

    def test_install_script_calls_skill_install_after_installed_verification_and_never_fails(self):
        script = (REPO / 'script/build_and_run.sh').read_text()
        call = script.index('script/install_skill.py')
        self.assertLess(script.index('script/verify_install.py" "$DEST"'), call)
        self.assertLess(script.index('echo "Installed $DEST"'), call)
        self.assertGreater(call, script.index('case "$MODE" in --stage|--rebuild-stage|--clean-stage) echo "Staged'))
        line = script[script.rindex('\n', 0, call):script.index('\n', call)]
        self.assertIn('--apply', line);self.assertIn('skill-install.jsonl', line);self.assertIn('||', line)


if __name__ == '__main__':
    unittest.main()
