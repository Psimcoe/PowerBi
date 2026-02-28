"""Smoke tests for PBIExtractor."""

from __future__ import annotations

from pbi_tools.extractor import PBIExtractor, PBIMetadata, QueryInfo, TableInfo
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
