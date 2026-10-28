"""Shared-source static selection uses portable synthetic index records only."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'script'))
from index_store import DEFINITION, REFERENCE, CALL, CHILDOF, CALLEDBY, CONTAINEDBY, EXTENDEDBY
from shared_test_impact import shared_source_classes


class SharedSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.shared = 'Packages/ChecklistShared/Sources/ChecklistShared/Commands.swift'
        self.core = 'Sources/ChecklistCore/Core.swift'
        self.first = 'Tests/ChecklistCoreTests/First.swift'
        self.second = 'Tests/ChecklistCoreTests/Second.swift'
        self.write(self.shared, 'public func command() {}')
        self.write(self.core, 'func core() {}')
        self.write(self.first, 'final class First: XCTestCase {}')
        self.write(self.second, 'final class Second: XCTestCase {}')
        self.rows = [self.row(self.shared, 'shared'), self.row(self.core, 'core'),
                     self.row(self.first, 'first', 'First', kind=7),
                     self.row(self.second, 'second', 'Second', kind=7)]

    def write(self, path, text):
        source = self.root / path
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(text)

    def row(self, path, usr, name=None, roles=DEFINITION, kind=12, relations=()):
        return dict(file=path, usr=usr, name=name or usr, roles=roles, kind=kind, relations=list(relations))

    def relation(self, usr, roles=CALLEDBY):
        return dict(usr=usr, roles=roles)

    def export(self):
        return dict(schema_version=1, occurrences=self.rows,
                    source_hashes={p.relative_to(self.root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in self.root.rglob('*.swift')})

    def select(self, export=None, paths=None):
        return shared_source_classes(self.root, export or self.export(), paths or [self.shared])

    def test_direct_reference_selects_only_its_test_class(self):
        self.rows.append(self.row(self.first, 'shared', roles=REFERENCE))
        self.assertEqual(self.select(), {self.shared: ['ChecklistCoreTests.First']})

    def test_transitive_callers_reach_test_file_and_terminate_cycles(self):
        self.rows += [self.row(self.core, 'shared', roles=REFERENCE | CALL, relations=[self.relation('core')]),
                      self.row(self.core, 'core', roles=REFERENCE | CALL, relations=[self.relation('shared')]),
                      self.row(self.first, 'core', roles=REFERENCE | CALL)]
        self.assertEqual(self.select(), {self.shared: ['ChecklistCoreTests.First']})

    def test_callable_local_declarations_are_reachable(self):
        self.rows += [self.row(self.shared, 'local', relations=[self.relation('core', CHILDOF)]),
                      self.row(self.first, 'core', roles=REFERENCE)]
        self.assertEqual(self.select(), {self.shared: ['ChecklistCoreTests.First']})

    def test_type_members_do_not_expand_from_type_reference(self):
        self.rows += [self.row(self.core, 'type', kind=6),
                      self.row(self.shared, 'member', relations=[self.relation('type', CHILDOF)]),
                      self.row(self.first, 'type', roles=REFERENCE, kind=6)]
        self.assertEqual(self.select(), {self.shared: []})

    def test_contained_reference_and_test_extension_are_conservative(self):
        extension = 'Tests/ChecklistCoreTests/FirstExtension.swift'
        self.write(extension, 'extension First {}')
        self.rows += [self.row(extension, 'first', 'First', roles=EXTENDEDBY, kind=7),
                      self.row(extension, 'core', roles=REFERENCE),
                      self.row(self.core, 'shared', roles=REFERENCE, relations=[self.relation('core', CONTAINEDBY)])]
        self.assertEqual(self.select(), {self.shared: ['ChecklistCoreTests.First']})

    def test_multiple_classes_in_same_file_are_conservative_seeds(self):
        self.write(self.first, 'final class First: XCTestCase {}\nfinal class Third: XCTestCase {}')
        self.rows += [self.row(self.first, 'third', 'Third', kind=7), self.row(self.first, 'shared', roles=REFERENCE)]
        self.assertEqual(self.select(), {self.shared: ['ChecklistCoreTests.First', 'ChecklistCoreTests.Third']})

    def test_multiple_sources_keep_results_separate_and_sorted(self):
        other = 'Packages/ChecklistShared/Sources/ChecklistShared/Other.swift'
        self.write(other, 'func other() {}')
        self.rows += [self.row(other, 'other'), self.row(self.second, 'other', roles=REFERENCE),
                      self.row(self.first, 'shared', roles=REFERENCE)]
        self.assertEqual(self.select(paths=[other, self.shared]),
                         {self.shared: ['ChecklistCoreTests.First'], other: ['ChecklistCoreTests.Second']})

    def test_requested_source_may_differ_but_other_source_must_match(self):
        export = self.export()
        self.write(self.shared, 'public func command() { changed() }')
        self.assertEqual(self.select(export), {self.shared: []})
        self.write(self.core, 'func different() {}')
        with self.assertRaisesRegex(ValueError, 'source inputs differ'):
            self.select(export)

    def test_unknown_or_unindexed_requested_source_is_rejected(self):
        for path in ['../escape.swift', 'Packages/ChecklistShared/Sources/ChecklistShared/Missing.swift']:
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'unknown shared source'):
                self.select(paths=[path])
        self.rows = [row for row in self.rows if row['file'] != self.shared]
        with self.assertRaisesRegex(ValueError, 'no indexed declarations'):
            self.select()

    def test_missing_hashes_and_occurrence_hash_are_rejected(self):
        export = self.export()
        del export['source_hashes']
        with self.assertRaisesRegex(ValueError, 'needs source hashes'):
            self.select(export)
        export = self.export()
        del export['source_hashes'][self.shared]
        with self.assertRaisesRegex(ValueError, 'no source hash'):
            self.select(export)

    def test_invalid_occurrences_and_relations_are_rejected(self):
        for row in [dict(file=self.shared), self.row(self.shared, 'bad', relations=[dict(usr='x')])]:
            with self.subTest(row=row):
                export = self.export()
                export['occurrences'].append(row)
                with self.assertRaisesRegex(ValueError, 'invalid index'):
                    self.select(export)

    def test_current_test_class_inventory_must_be_complete(self):
        self.rows = [row for row in self.rows if row['usr'] != 'second']
        with self.assertRaisesRegex(ValueError, 'root test class missing.*Second'):
            self.select()

    def test_class_declaration_must_be_in_the_current_source_file(self):
        self.rows = [self.row(self.first, 'second', 'Second', kind=7) if row['usr'] == 'second' else row
                     for row in self.rows]
        with self.assertRaisesRegex(ValueError, 'root test class missing.*Second'):
            self.select()

    def test_comments_and_swift_string_fixtures_do_not_invent_classes(self):
        self.write(self.first, '''final class First: XCTestCase {}
// class Comment: XCTestCase {}
/* class Block: XCTestCase {} */
let a = "class Quoted: XCTestCase {}"
let b = #"""
class Raw: XCTestCase {}
"""#
let c = """
class Multiline: XCTestCase {}
"""
''')
        self.assertEqual(self.select(), {self.shared: []})

    def test_missing_or_malformed_hash_input_fails_closed(self):
        for change in ['missing', 'invalid']:
            with self.subTest(change=change):
                export = self.export()
                if change == 'missing':
                    (self.root / self.second).unlink()
                else:
                    export['source_hashes'][self.core] = 'not-a-sha256'
                with self.assertRaisesRegex(ValueError, 'invalid index source hash'):
                    self.select(export)
                self.write(self.second, 'final class Second: XCTestCase {}')

    def test_new_unindexed_production_source_fails_closed(self):
        export = self.export()
        self.write('Sources/ChecklistCore/New.swift', 'func new() {}')
        with self.assertRaisesRegex(ValueError, 'missing current Swift source'):
            self.select(export)

    def test_new_unindexed_test_helper_fails_closed(self):
        export = self.export()
        self.write('Tests/ChecklistCoreTests/Helper.swift', 'func helper() {}')
        with self.assertRaisesRegex(ValueError, 'missing current Swift test input'):
            self.select(export)

    def test_new_unindexed_shared_source_fails_closed(self):
        export = self.export()
        self.write('Packages/ChecklistShared/Sources/ChecklistShared/New.swift', 'func new() {}')
        with self.assertRaisesRegex(ValueError, 'missing current Swift source'):
            self.select(export)

    def test_shared_package_own_tests_are_separately_planned(self):
        export = self.export()
        self.write('Packages/ChecklistShared/Tests/ChecklistSharedTests/Own.swift',
                   'final class Own: XCTestCase {}')
        self.assertEqual(self.select(export), {self.shared: []})

    def test_reverse_graph_matches_forward_index_reference_semantics(self):
        from test_impact_map import index_references
        self.rows += [self.row(self.core, 'shared', roles=REFERENCE | CALL,
                               relations=[self.relation('core')]),
                      self.row(self.first, 'core', roles=REFERENCE | CALL)]
        export = self.export()
        expected = [group for group in ['ChecklistCoreTests.First', 'ChecklistCoreTests.Second']
                    if self.shared in index_references(self.root, group, export)]
        self.assertEqual(self.select(export), {self.shared: expected})


if __name__ == '__main__':
    unittest.main()
