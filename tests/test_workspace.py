"""Smoke tests for WorkspaceConfig."""

from __future__ import annotations

from pathlib import Path

import pytest

from pbi_tools.workspace import WorkspaceConfig, DEFAULT_ALLOWED_EXTENSIONS
from tests import FIXTURES_DIR, SAMPLE_PBIT


class TestWorkspaceConfigFromFile:
    def test_missing_config_returns_empty_workspace(self, tmp_path: Path) -> None:
        ws = WorkspaceConfig.from_file(tmp_path / "nonexistent.yaml")
        assert ws.folders == []

    def test_valid_config_loads_existing_folders(self, tmp_path: Path) -> None:
        folder = tmp_path / "pbi"
        folder.mkdir()
        cfg_file = tmp_path / "ws.yaml"
        cfg_file.write_text(
            f"workspace_folders:\n  - {folder}\nallowed_extensions:\n  - .pbix\n  - .pbit\n",
            encoding="utf-8",
        )
        ws = WorkspaceConfig.from_file(cfg_file)
        assert folder.resolve() in ws.folders
        assert ".pbix" in ws.allowed_extensions

    def test_nonexistent_folder_is_skipped(self, tmp_path: Path) -> None:
        cfg_file = tmp_path / "ws.yaml"
        cfg_file.write_text(
            "workspace_folders:\n  - /does/not/exist\n", encoding="utf-8"
        )
        ws = WorkspaceConfig.from_file(cfg_file)
        assert ws.folders == []


class TestIsPathAllowed:
    def _ws_with(self, folder: Path) -> WorkspaceConfig:
        return WorkspaceConfig(folders=[folder])

    def test_allowed_pbix_inside_folder(self, tmp_path: Path) -> None:
        ws = self._ws_with(tmp_path)
        target = tmp_path / "report.pbix"
        target.touch()
        assert ws.is_path_allowed(target)

    def test_allowed_pbit_inside_folder(self, tmp_path: Path) -> None:
        ws = self._ws_with(tmp_path)
        target = tmp_path / "model.pbit"
        target.touch()
        assert ws.is_path_allowed(target)

    def test_denied_path_outside_folder(self, tmp_path: Path) -> None:
        ws = self._ws_with(tmp_path / "allowed")
        outside = tmp_path / "secret.pbix"
        assert not ws.is_path_allowed(outside)

    def test_denied_extension_not_in_allowlist(self, tmp_path: Path) -> None:
        ws = self._ws_with(tmp_path)
        target = tmp_path / "data.csv"
        assert not ws.is_path_allowed(target)


class TestListFiles:
    def test_returns_matching_files(self, tmp_path: Path) -> None:
        (tmp_path / "a.pbix").touch()
        (tmp_path / "b.pbit").touch()
        (tmp_path / "c.txt").touch()
        ws = WorkspaceConfig(folders=[tmp_path])
        files = ws.list_files()
        names = {f.name for f in files}
        assert "a.pbix" in names
        assert "b.pbit" in names
        assert "c.txt" not in names

    def test_empty_workspace(self) -> None:
        ws = WorkspaceConfig(folders=[])
        assert ws.list_files() == []
