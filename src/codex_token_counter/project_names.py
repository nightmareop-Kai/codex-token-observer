"""Read Codex project labels without changing project identity or Codex files."""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any, Dict, Iterable, Optional, Set, Tuple


def _path_key(value: Any) -> Optional[str]:
    if not isinstance(value, str) or not value.strip():
        return None
    path = os.path.normpath(os.path.expanduser(value))
    return path if os.path.isabs(path) else None


def _label(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    return value.strip() or None


def _candidates(rows: Iterable[Tuple[Any, Any]]) -> Dict[str, Set[str]]:
    result: Dict[str, Set[str]] = {}
    for raw_path, raw_label in rows:
        path = _path_key(raw_path)
        label = _label(raw_label)
        if path is not None and label is not None:
            result.setdefault(path, set()).add(label)
    return result


def _unambiguous(candidates: Dict[str, Set[str]]) -> Dict[str, str]:
    return {path: next(iter(labels)) for path, labels in candidates.items() if len(labels) == 1}


def _sqlite_labels(database: Path) -> Optional[Dict[str, str]]:
    """None means unavailable; an empty dictionary is an authoritative result."""
    try:
        if not database.is_file():
            return None
        connection = sqlite3.connect(
            database.absolute().as_uri() + "?mode=ro", uri=True, timeout=0.2
        )
        try:
            connection.execute("PRAGMA query_only = ON")
            rows = connection.execute(
                "SELECT p.name, r.path FROM projects p "
                "JOIN project_roots r ON r.project_id = p.id"
            ).fetchall()
        finally:
            connection.close()
        return _unambiguous(_candidates((path, label) for label, path in rows))
    except (OSError, sqlite3.Error, ValueError):
        return None


def _legacy_labels(state_file: Path) -> Dict[str, str]:
    try:
        with state_file.open("r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, UnicodeError, ValueError):
        return {}
    if not isinstance(state, dict):
        return {}

    legacy = state.get("electron-workspace-root-labels")
    labels = _unambiguous(_candidates(legacy.items())) if isinstance(legacy, dict) else {}

    local_projects = state.get("local-projects")
    if not isinstance(local_projects, dict):
        return labels
    local_rows = []
    for project in local_projects.values():
        if not isinstance(project, dict) or not isinstance(project.get("rootPaths"), list):
            continue
        local_rows.extend((path, project.get("name")) for path in project["rootPaths"])
    for path, names in _candidates(local_rows).items():
        if len(names) == 1:
            labels[path] = next(iter(names))
        else:
            # Multiple projects claim one root: let callers display the basename.
            labels.pop(path, None)
    return labels


def load_project_labels(codex_home: Path) -> Dict[str, str]:
    """Reload current labels; exact normalized paths only, never ancestor matching.

    A successful SQLite query is authoritative even when it returns no labels.
    Legacy preferences are used only if the database cannot be queried. Names
    are display metadata: callers must retain the original paths for accounting.
    """
    codex_home = codex_home.expanduser()
    labels = _sqlite_labels(codex_home / "state_5.sqlite")
    if labels is not None:
        return labels
    return _legacy_labels(codex_home / ".codex-global-state.json")
