from __future__ import annotations

import json
import errno
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
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

    def project_path(self, name: str) -> str:
        # Rooted POSIX strings such as /work/project are not absolute paths on
        # Windows. Use a real drive-qualified root there and native separators.
        return os.path.normpath(str(self.codex_home / "work" / name))

    def make_database(self, rows=()) -> None:
        with closing(sqlite3.connect(self.database)) as connection, connection:
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
        project = self.project_path("project")
        self.make_database([("Current name", project)])
        self.write_state({
            "electron-workspace-root-labels": {project: "Old label", self.project_path("stale"): "Stale"},
            "local-projects": {"p": {"name": "Older project", "rootPaths": [project]}},
        })
        self.assertEqual(load_project_labels(self.codex_home), {project: "Current name"})

    def test_successful_empty_database_does_not_restore_stale_names(self) -> None:
        self.make_database()
        self.write_state({"electron-workspace-root-labels": {self.project_path("deleted"): "Deleted"}})
        self.assertEqual(load_project_labels(self.codex_home), {})

    def test_legacy_local_projects_override_labels_and_support_multiple_roots(self) -> None:
        project, other, second = [self.project_path(name) for name in ("project", "other", "second")]
        self.write_state({
            "electron-workspace-root-labels": {project: "Old", other: "Other"},
            "local-projects": {"p": {"name": "New", "rootPaths": [project, second]}},
        })
        self.assertEqual(load_project_labels(self.codex_home), {
            project: "New", second: "New", other: "Other"
        })

    def test_corrupt_database_and_missing_schema_fall_back(self) -> None:
        project = self.project_path("project")
        self.write_state({"electron-workspace-root-labels": {project: "Fallback"}})
        self.database.write_bytes(b"not a sqlite database")
        self.assertEqual(load_project_labels(self.codex_home), {project: "Fallback"})
        self.database.unlink()
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("CREATE TABLE unrelated(id TEXT)")
        self.assertEqual(load_project_labels(self.codex_home), {project: "Fallback"})

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
            ("  Valid  ", self.project_path("valid")), ("", self.project_path("empty")),
            ("  ", self.project_path("whitespace")), (None, self.project_path("null")),
            (42, self.project_path("number")),
            ("Missing path", None), ("Number path", 42), ("Empty path", ""),
            ("Relative path", "work/relative"), ("Space path", "   "),
        ])
        self.assertEqual(load_project_labels(self.codex_home), {self.project_path("valid"): "Valid"})

    def test_legacy_ignores_invalid_fields(self) -> None:
        self.write_state({
            "electron-workspace-root-labels": {
                self.project_path("valid"): " Good ", self.project_path("number"): 42,
                self.project_path("empty"): " ", "relative": "Wrong"
            },
            "local-projects": {
                "string": "wrong", "null": None,
                "roots-string": {"name": "Wrong", "rootPaths": self.project_path("wrong")},
                "name-number": {"name": 42, "rootPaths": [self.project_path("wrong")]},
                "valid": {"name": "Root", "rootPaths": [None, 42, "", "relative", self.project_path("root")]},
            },
        })
        self.assertEqual(load_project_labels(self.codex_home), {
            self.project_path("valid"): "Good", self.project_path("root"): "Root"
        })

    def test_normalizes_paths_without_adding_descendants(self) -> None:
        raw_path = os.path.join(self.project_path(""), "part", "..", "project", "")
        self.make_database([("Normalized", raw_path), ("Home", "~/project-name-test")])
        result = load_project_labels(self.codex_home)
        self.assertEqual(result[self.project_path("project")], "Normalized")
        self.assertNotIn(self.project_path("project/child"), result)
        self.assertEqual(result[os.path.normpath(str(Path.home() / "project-name-test"))], "Home")

    def test_does_not_resolve_symlink_paths(self) -> None:
        target = self.codex_home / "real"
        target.mkdir()
        link = self.codex_home / "linked"
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError as error:
            if error.errno in {errno.EPERM, errno.EACCES, errno.ENOTSUP} or getattr(error, "winerror", None) == 1314:
                self.skipTest("Creating symlinks is not permitted on this host: " + str(error))
            raise
        except NotImplementedError as error:
            self.skipTest("This platform does not support creating symlinks: " + str(error))
        self.make_database([("Linked", str(link))])
        result = load_project_labels(self.codex_home)
        self.assertEqual(result[os.path.normpath(str(link))], "Linked")
        self.assertNotIn(os.path.normpath(str(target)), result)

    def test_conflicting_names_for_same_path_are_omitted_without_legacy_fallback(self) -> None:
        conflict, unambiguous = [self.project_path(name) for name in ("conflict", "unambiguous")]
        self.make_database([
            ("One", conflict), ("Two", conflict + os.sep),
            ("Same", unambiguous), ("Same", unambiguous),
        ])
        self.write_state({"electron-workspace-root-labels": {conflict: "Stale"}})
        self.assertEqual(load_project_labels(self.codex_home), {unambiguous: "Same"})

    def test_same_display_name_for_different_paths_is_preserved(self) -> None:
        first, second = self.project_path("a"), self.project_path("b")
        self.make_database([("Same", first), ("Same", second)])
        self.assertEqual(load_project_labels(self.codex_home), {first: "Same", second: "Same"})

    def test_legacy_local_conflicts_do_not_choose_an_arbitrary_name(self) -> None:
        project = self.project_path("project")
        self.write_state({
            "electron-workspace-root-labels": {project: "Old"},
            "local-projects": {
                "a": {"name": "One", "rootPaths": [project]},
                "b": {"name": "Two", "rootPaths": [project]},
            },
        })
        self.assertEqual(load_project_labels(self.codex_home), {})

    def test_rename_is_reloaded_on_each_call(self) -> None:
        project = self.project_path("project")
        self.make_database([("Before", project)])
        self.assertEqual(load_project_labels(self.codex_home), {project: "Before"})
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE projects SET name = 'After'")
        self.assertEqual(load_project_labels(self.codex_home), {project: "After"})

    def test_sqlite_is_opened_read_only_and_files_stay_unchanged(self) -> None:
        project = self.project_path("project")
        self.make_database([("Read only", project)])
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
            self.assertEqual(load_project_labels(self.codex_home), {project: "Read only"})
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][0][0].endswith("?mode=ro"))
        self.assertTrue(calls[0][1]["uri"])
        self.assertLessEqual(calls[0][1]["timeout"], 0.2)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(self.database.stat().st_mtime_ns, before_mtime)
        self.assertEqual({path.name for path in self.codex_home.iterdir()}, {"state_5.sqlite"})


if __name__ == "__main__":
    unittest.main()
