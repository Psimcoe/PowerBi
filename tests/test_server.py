"""Smoke tests for the FastAPI server."""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests import SAMPLE_PBIT


@pytest.fixture()
def workspace(tmp_path: Path, monkeypatch):
    """Set up a temporary workspace with the sample PBIT and patch server config."""
    dest = tmp_path / "sample.pbit"
    shutil.copy(SAMPLE_PBIT, dest)

    cfg = tmp_path / "ws.yaml"
    cfg.write_text(
        f"workspace_folders:\n  - {tmp_path}\n", encoding="utf-8"
    )

    # Patch the module-level WorkspaceConfig used by the server
    import pbi_tools.server as srv
    from pbi_tools.workspace import WorkspaceConfig

    monkeypatch.setattr(srv, "_ws", WorkspaceConfig.from_file(cfg))
    return tmp_path


@pytest.fixture()
def client(workspace):
    from pbi_tools.server import app
    return TestClient(app)


class TestFilesEndpoint:
    def test_get_files_returns_list(self, client, workspace) -> None:
        resp = client.get("/files")
        assert resp.status_code == 200
        files = resp.json()
        assert isinstance(files, list)
        assert any("sample.pbit" in f for f in files)


class TestMembersEndpoint:
    def test_get_members(self, client, workspace) -> None:
        import urllib.parse

        encoded = urllib.parse.quote(str(workspace / "sample.pbit"), safe="")
        resp = client.get(f"/files/{encoded}/members")
        assert resp.status_code == 200
        members = resp.json()
        assert "[Content_Types].xml" in members

    def test_access_denied_outside_workspace(self, client, workspace, tmp_path) -> None:
        import urllib.parse

        outside = tmp_path.parent / "outside.pbit"
        shutil.copy(SAMPLE_PBIT, outside)
        encoded = urllib.parse.quote(str(outside), safe="")
        resp = client.get(f"/files/{encoded}/members")
        assert resp.status_code == 403


class TestMetadataEndpoint:
    def test_get_metadata(self, client, workspace) -> None:
        import urllib.parse

        encoded = urllib.parse.quote(str(workspace / "sample.pbit"), safe="")
        resp = client.get(f"/files/{encoded}/metadata")
        assert resp.status_code == 200
        data = resp.json()
        assert data["file_type"] == "pbit"
        assert any(q["name"] == "SalesData" for q in data["queries"])


class TestValidateEndpoint:
    def test_validate_valid_pbit(self, client, workspace) -> None:
        import urllib.parse

        encoded = urllib.parse.quote(str(workspace / "sample.pbit"), safe="")
        resp = client.get(f"/files/{encoded}/validate")
        assert resp.status_code == 200
        result = resp.json()
        assert result["passed"] is True
        assert result["issues"] == []
