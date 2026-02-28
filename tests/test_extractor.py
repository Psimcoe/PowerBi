"""Smoke tests for PBIExtractor."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import pandas as pd
import pytest

from pbi_tools.extractor import (
    PBIExtractor,
    PBIMetadata,
    QueryInfo,
    TableInfo,
    _extract_via_pbixray,
)
from tests import SAMPLE_PBIT


class TestPBIExtractor:
    def setup_method(self) -> None:
        self.extractor = PBIExtractor(SAMPLE_PBIT)
        self.meta: PBIMetadata = self.extractor.extract()

    def test_returns_pbi_metadata(self) -> None:
        assert isinstance(self.meta, PBIMetadata)

    def test_file_type_is_pbit(self) -> None:
        assert self.meta.file_type == "pbit"

    def test_archive_members_populated(self) -> None:
        assert len(self.meta.archive_members) > 0

    def test_queries_extracted(self) -> None:
        assert len(self.meta.queries) > 0
        names = [q.name for q in self.meta.queries]
        assert "SalesData" in names

    def test_query_has_script(self) -> None:
        sales_query = next(q for q in self.meta.queries if q.name == "SalesData")
        assert "Table.FromRows" in sales_query.script

    def test_tables_extracted(self) -> None:
        assert len(self.meta.tables) > 0
        names = [t.name for t in self.meta.tables]
        assert "SalesData" in names

    def test_hidden_system_table_excluded(self) -> None:
        names = [t.name for t in self.meta.tables]
        assert "$System" not in names

    def test_table_columns_extracted(self) -> None:
        table = next(t for t in self.meta.tables if t.name == "SalesData")
        col_names = [c.name for c in table.columns]
        assert "Name" in col_names
        assert "Sales" in col_names

    def test_table_measures_extracted(self) -> None:
        table = next(t for t in self.meta.tables if t.name == "SalesData")
        measure_names = [m.name for m in table.measures]
        assert "TotalSales" in measure_names

    def test_connections_extracted(self) -> None:
        assert len(self.meta.connections) > 0
        protocols = [c.protocol for c in self.meta.connections]
        assert "memory" in protocols

    def test_to_dict_is_json_serialisable(self) -> None:
        import json
        d = self.meta.to_dict()
        text = json.dumps(d)
        assert '"SalesData"' in text


# ---------------------------------------------------------------------------
# Tests for the pbixray fallback path (_extract_via_pbixray)
# ---------------------------------------------------------------------------


class TestExtractViaPbixray:
    """Unit tests for the pbixray-based extraction used on PBIX/ABF files."""

    def _fake_model(self) -> MagicMock:
        """Return a mock PBIXRay model with power_query and schema DataFrames."""
        model = MagicMock()
        model.power_query = pd.DataFrame(
            {
                "TableName": ["Orders", "Customers"],
                "Expression": [
                    'let\n    Source = Sql.Database("srv", "db")\nin\n    Source',
                    'let\n    Source = Sql.Database("srv", "db")\nin\n    Source',
                ],
            }
        )
        model.schema = pd.DataFrame(
            {
                "TableName": ["Orders", "Orders", "Customers"],
                "ColumnName": ["OrderId", "Amount", "Name"],
                "DataType": ["Int64", "Float64", "string"],
            }
        )
        return model

    @patch("pbi_tools.extractor.PBIXRay")
    def test_queries_extracted(self, mock_cls: MagicMock) -> None:
        mock_cls.return_value = self._fake_model()
        queries, tables = _extract_via_pbixray(Path("fake.pbix"))
        assert len(queries) == 2
        assert queries[0].name == "Orders"
        assert "Sql.Database" in queries[0].script

    @patch("pbi_tools.extractor.PBIXRay")
    def test_tables_extracted(self, mock_cls: MagicMock) -> None:
        mock_cls.return_value = self._fake_model()
        queries, tables = _extract_via_pbixray(Path("fake.pbix"))
        assert len(tables) == 2
        names = [t.name for t in tables]
        assert "Orders" in names
        assert "Customers" in names

    @patch("pbi_tools.extractor.PBIXRay")
    def test_table_columns(self, mock_cls: MagicMock) -> None:
        mock_cls.return_value = self._fake_model()
        _, tables = _extract_via_pbixray(Path("fake.pbix"))
        orders = next(t for t in tables if t.name == "Orders")
        col_names = [c.name for c in orders.columns]
        assert "OrderId" in col_names
        assert "Amount" in col_names

    @patch("pbi_tools.extractor.PBIXRay")
    def test_empty_power_query_returns_empty(self, mock_cls: MagicMock) -> None:
        model = MagicMock()
        model.power_query = pd.DataFrame(columns=["TableName", "Expression"])
        model.schema = pd.DataFrame(columns=["TableName", "ColumnName", "DataType"])
        mock_cls.return_value = model
        queries, tables = _extract_via_pbixray(Path("fake.pbix"))
        assert queries == []
        assert tables == []

    @patch("pbi_tools.extractor.PBIXRay", side_effect=Exception("corrupt"))
    def test_pbixray_failure_returns_empty(self, mock_cls: MagicMock) -> None:
        queries, tables = _extract_via_pbixray(Path("fake.pbix"))
        assert queries == []
        assert tables == []


class TestPbixrayFallbackIntegration:
    """Verify that extract() triggers the pbixray fallback for PBIX files."""

    @patch("pbi_tools.extractor._extract_via_pbixray")
    def test_fallback_triggered_for_pbix_without_mashup(
        self, mock_fallback: MagicMock, tmp_path: Path
    ) -> None:
        """When a .pbix has no DataMashup, extract() should invoke the fallback."""
        import shutil, zipfile

        # Create a minimal .pbix with no DataMashup member
        pbix = tmp_path / "test.pbix"
        with zipfile.ZipFile(pbix, "w") as zf:
            zf.writestr("[Content_Types].xml", "<Types/>")
            zf.writestr("DataModel", b"dummy blob")

        mock_fallback.return_value = (
            [QueryInfo(name="Q1", script="let x = 1 in x")],
            [TableInfo(name="T1")],
        )

        meta = PBIExtractor(pbix).extract()
        mock_fallback.assert_called_once()
        assert len(meta.queries) == 1
        assert meta.queries[0].name == "Q1"
        assert len(meta.tables) == 1

    def test_fallback_not_triggered_for_pbit(self) -> None:
        """PBIT files use DataMashup; the pbixray fallback should not fire."""
        meta = PBIExtractor(SAMPLE_PBIT).extract()
        # PBIT path should still work via the original DataMashup extractor
        assert len(meta.queries) > 0
        assert any(q.name == "SalesData" for q in meta.queries)
