from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from codex_token_counter.project_names import load_project_labels


class ProjectNamesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.codex_home = Path(self.temporary.name)
        self.database = self.codex_home / "state_5.sqlite"
        self.state_file = self.codex_home / ".codex-global-state.json"

    def make_database(self, rows=()) -> None:
        with sqlite3.connect(self.database) as connection:
            connection.executescript(
                "CREATE TABLE projects(id TEXT PRIMARY KEY, name);"
                "CREATE TABLE project_roots(project_id TEXT, path);"
            )
            for index, (name, path) in enumerate(rows):
                identity = str(index)
                connection.execute("INSERT INTO projects VALUES(?, ?)", (identity, name))
                connection.execute("INSERT INTO project_roots VALUES(?, ?)", (identity, path))

    def write_state(self, state) -> None:
        self.state_file.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")

    def test_sqlite_is_authoritative_over_both_legacy_formats(self) -> None:
        self.make_database([("Current name", "/work/project")])
        self.write_state({
            "electron-workspace-root-labels": {"/work/project": "Old label", "/work/stale": "Stale"},
            "local-projects": {"p": {"name": "Older project", "rootPaths": ["/work/project"]}},
        })
        self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "Current name"})

    def test_successful_empty_database_does_not_restore_stale_names(self) -> None:
        self.make_database()
        self.write_state({"electron-workspace-root-labels": {"/work/deleted": "Deleted"}})
        self.assertEqual(load_project_labels(self.codex_home), {})

    def test_legacy_local_projects_override_labels_and_support_multiple_roots(self) -> None:
        self.write_state({
            "electron-workspace-root-labels": {"/work/project": "Old", "/work/other": "Other"},
            "local-projects": {"p": {"name": "New", "rootPaths": ["/work/project", "/work/second"]}},
        })
        self.assertEqual(load_project_labels(self.codex_home), {
            "/work/project": "New", "/work/second": "New", "/work/other": "Other"
        })

    def test_corrupt_database_and_missing_schema_fall_back(self) -> None:
        self.write_state({"electron-workspace-root-labels": {"/work/project": "Fallback"}})
        self.database.write_bytes(b"not a sqlite database")
        self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "Fallback"})
        self.database.unlink()
        with sqlite3.connect(self.database) as connection:
            connection.execute("CREATE TABLE unrelated(id TEXT)")
        self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "Fallback"})

    def test_missing_files_and_missing_home_are_not_created(self) -> None:
        self.assertEqual(load_project_labels(self.codex_home), {})
        self.assertEqual(list(self.codex_home.iterdir()), [])
        absent = self.codex_home / "absent"
        self.assertEqual(load_project_labels(absent), {})
        self.assertFalse(absent.exists())

    def test_malformed_state_and_wrong_top_level_type_are_ignored(self) -> None:
        for contents in ['{"local-projects":', "[]", "null", '"not an object"']:
            with self.subTest(contents=contents):
                self.state_file.write_text(contents, encoding="utf-8")
                self.assertEqual(load_project_labels(self.codex_home), {})
        self.state_file.write_bytes(b"\xff\xfe")
        self.assertEqual(load_project_labels(self.codex_home), {})

    def test_sqlite_ignores_nonstring_empty_and_relative_fields(self) -> None:
        self.make_database([
            ("  Valid  ", "/work/valid"), ("", "/work/empty"),
            ("  ", "/work/whitespace"), (None, "/work/null"), (42, "/work/number"),
            ("Missing path", None), ("Number path", 42), ("Empty path", ""),
            ("Relative path", "work/relative"), ("Space path", "   "),
        ])
        self.assertEqual(load_project_labels(self.codex_home), {"/work/valid": "Valid"})

    def test_legacy_ignores_invalid_fields(self) -> None:
        self.write_state({
            "electron-workspace-root-labels": {
                "/work/valid": " Good ", "/work/number": 42, "/work/empty": " ", "relative": "Wrong"
            },
            "local-projects": {
                "string": "wrong", "null": None,
                "roots-string": {"name": "Wrong", "rootPaths": "/work/wrong"},
                "name-number": {"name": 42, "rootPaths": ["/work/wrong"]},
                "valid": {"name": "Root", "rootPaths": [None, 42, "", "relative", "/work/root"]},
            },
        })
        self.assertEqual(load_project_labels(self.codex_home), {"/work/valid": "Good", "/work/root": "Root"})

    def test_normalizes_paths_without_resolving_symlinks_or_adding_descendants(self) -> None:
        target = self.codex_home / "real"
        target.mkdir()
        link = self.codex_home / "linked"
        link.symlink_to(target, target_is_directory=True)
        self.make_database([
            ("Normalized", "/work/part/../project/"),
            ("Linked", str(link)), ("Home", "~/project-name-test"),
        ])
        result = load_project_labels(self.codex_home)
        self.assertEqual(result["/work/project"], "Normalized")
        self.assertEqual(result[str(link)], "Linked")
        self.assertNotIn(str(target), result)
        self.assertNotIn("/work/project/child", result)
        self.assertEqual(result[str(Path.home() / "project-name-test")], "Home")

    def test_conflicting_names_for_same_path_are_omitted_without_legacy_fallback(self) -> None:
        self.make_database([
            ("One", "/work/conflict"), ("Two", "/work/conflict/"),
            ("Same", "/work/unambiguous"), ("Same", "/work/unambiguous"),
        ])
        self.write_state({"electron-workspace-root-labels": {"/work/conflict": "Stale"}})
        self.assertEqual(load_project_labels(self.codex_home), {"/work/unambiguous": "Same"})

    def test_same_display_name_for_different_paths_is_preserved(self) -> None:
        self.make_database([("Same", "/work/a"), ("Same", "/work/b")])
        self.assertEqual(load_project_labels(self.codex_home), {"/work/a": "Same", "/work/b": "Same"})

    def test_legacy_local_conflicts_do_not_choose_an_arbitrary_name(self) -> None:
        self.write_state({
            "electron-workspace-root-labels": {"/work/project": "Old"},
            "local-projects": {
                "a": {"name": "One", "rootPaths": ["/work/project"]},
                "b": {"name": "Two", "rootPaths": ["/work/project"]},
            },
        })
        self.assertEqual(load_project_labels(self.codex_home), {})

    def test_rename_is_reloaded_on_each_call(self) -> None:
        self.make_database([("Before", "/work/project")])
        self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "Before"})
        with sqlite3.connect(self.database) as connection:
            connection.execute("UPDATE projects SET name = 'After'")
        self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "After"})

    def test_sqlite_is_opened_read_only_and_files_stay_unchanged(self) -> None:
        self.make_database([("Read only", "/work/project")])
        before = self.database.read_bytes()
        before_mtime = self.database.stat().st_mtime_ns
        connect = sqlite3.connect
        calls = []

        def checked_connect(*args, **kwargs):
            calls.append((args, kwargs))
            connection = connect(*args, **kwargs)
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("UPDATE projects SET name = 'Unexpected write'")
            return connection

        with patch("codex_token_counter.project_names.sqlite3.connect", side_effect=checked_connect):
            self.assertEqual(load_project_labels(self.codex_home), {"/work/project": "Read only"})
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][0][0].endswith("?mode=ro"))
        self.assertTrue(calls[0][1]["uri"])
        self.assertLessEqual(calls[0][1]["timeout"], 0.2)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(self.database.stat().st_mtime_ns, before_mtime)
        self.assertEqual({path.name for path in self.codex_home.iterdir()}, {"state_5.sqlite"})


if __name__ == "__main__":
    unittest.main()
