"""Smoke tests for the CLI commands."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from pbi_tools.cli import main
from tests import FIXTURES_DIR, SAMPLE_PBIT


def _runner() -> CliRunner:
    return CliRunner()


class TestListFilesCommand:
    def test_no_files_when_empty_config(self, tmp_path: Path) -> None:
        cfg = tmp_path / "ws.yaml"
        cfg.write_text("workspace_folders: []\n", encoding="utf-8")
        result = _runner().invoke(main, ["--config", str(cfg), "list-files"])
        assert result.exit_code == 0
        assert "No files found" in result.output

    def test_lists_pbit_files(self, tmp_path: Path) -> None:
        import shutil

        shutil.copy(SAMPLE_PBIT, tmp_path / "sample.pbit")
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
        )
        result = _runner().invoke(main, ["--config", str(cfg), "list-files"])
        assert result.exit_code == 0
        assert "sample.pbit" in result.output


class TestReadFileCommand:
    def _cfg(self, tmp_path: Path, folder: Path) -> Path:
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {folder}\n", encoding="utf-8"
        )
        return cfg

    def test_lists_members(self, tmp_path: Path) -> None:
        import shutil

        shutil.copy(SAMPLE_PBIT, tmp_path / "sample.pbit")
        cfg = self._cfg(tmp_path, tmp_path)
        result = _runner().invoke(
            main,
            ["--config", str(cfg), "read-file", str(tmp_path / "sample.pbit")],
        )
        assert result.exit_code == 0
        assert "[Content_Types].xml" in result.output

    def test_access_denied_outside_workspace(self, tmp_path: Path) -> None:
        import shutil

        denied_dir = tmp_path / "denied"
        denied_dir.mkdir()
        shutil.copy(SAMPLE_PBIT, denied_dir / "sample.pbit")

        allowed_dir = tmp_path / "allowed"
        allowed_dir.mkdir()
        cfg = self._cfg(tmp_path, allowed_dir)

        result = _runner().invoke(
            main,
            ["--config", str(cfg), "read-file", str(denied_dir / "sample.pbit")],
        )
        assert result.exit_code == 1
        assert "Access denied" in (result.output + (result.stderr or ""))


class TestExtractMetadataCommand:
    def test_outputs_json(self, tmp_path: Path) -> None:
        import json, shutil

        shutil.copy(SAMPLE_PBIT, tmp_path / "sample.pbit")
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
        )
        result = _runner().invoke(
            main,
            ["--config", str(cfg), "extract-metadata", str(tmp_path / "sample.pbit")],
        )
        assert result.exit_code == 0
        data = json.loads(result.output)
        assert data["file_type"] == "pbit"
        assert any(q["name"] == "SalesData" for q in data["queries"])

    def test_writes_to_output_file(self, tmp_path: Path) -> None:
        import json, shutil

        shutil.copy(SAMPLE_PBIT, tmp_path / "sample.pbit")
        out_file = tmp_path / "meta.json"
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
        )
        result = _runner().invoke(
            main,
            [
                "--config", str(cfg),
                "extract-metadata",
                str(tmp_path / "sample.pbit"),
                "--output", str(out_file),
            ],
        )
        assert result.exit_code == 0
        assert out_file.exists()
        data = json.loads(out_file.read_text(encoding="utf-8"))
        assert "queries" in data


class TestValidateCommand:
    def test_valid_pbit_passes(self, tmp_path: Path) -> None:
        import shutil

        shutil.copy(SAMPLE_PBIT, tmp_path / "sample.pbit")
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
        )
        result = _runner().invoke(
            main,
            ["--config", str(cfg), "validate", str(tmp_path / "sample.pbit")],
        )
        assert result.exit_code == 0
        assert "passed" in result.output

    def test_corrupt_zip_handled(self, tmp_path: Path) -> None:
        bad = tmp_path / "corrupt.pbit"
        bad.write_bytes(b"not a zip file")
        cfg = tmp_path / "ws.yaml"
        cfg.write_text(
            f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
        )
        result = _runner().invoke(
            main,
            ["--config", str(cfg), "validate", str(bad)],
        )
        # Should fail gracefully (non-zero exit or error message)
        assert result.exit_code != 0 or result.exception is not None
