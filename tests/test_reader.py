"""Smoke tests for PBIReader."""

from __future__ import annotations

from pathlib import Path

import pytest

from pbi_tools.reader import PBIReader, MEMBER_CONTENT_TYPES, MEMBER_DATA_MASHUP
from tests import SAMPLE_PBIT


class TestPBIReaderContextManager:
    def test_must_use_as_context_manager(self) -> None:
        reader = PBIReader(SAMPLE_PBIT)
        with pytest.raises(RuntimeError):
            reader.list_members()

    def test_context_manager_opens_and_closes(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            members = reader.list_members()
        assert isinstance(members, list)
        assert len(members) > 0

    def test_file_not_found_raises(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError):
            PBIReader(tmp_path / "missing.pbit")

    def test_unsupported_extension_raises(self, tmp_path: Path) -> None:
        bad = tmp_path / "file.docx"
        bad.touch()
        with pytest.raises(ValueError):
            PBIReader(bad)


class TestPBIReaderAPI:
    def test_list_members_includes_content_types(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            members = reader.list_members()
        assert MEMBER_CONTENT_TYPES in members

    def test_has_member_true(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            assert reader.has_member(MEMBER_CONTENT_TYPES)

    def test_has_member_false(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            assert not reader.has_member("__nonexistent__")

    def test_read_member_returns_bytes(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            data = reader.read_member(MEMBER_CONTENT_TYPES)
        assert isinstance(data, bytes)
        assert len(data) > 0

    def test_read_member_missing_raises_key_error(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            with pytest.raises(KeyError):
                reader.read_member("__nonexistent__")

    def test_read_data_mashup_returns_bytes(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            data = reader.read_data_mashup()
        assert data is not None
        assert isinstance(data, bytes)

    def test_read_data_model_schema_returns_bytes(self) -> None:
        with PBIReader(SAMPLE_PBIT) as reader:
            data = reader.read_data_model_schema()
        assert data is not None
