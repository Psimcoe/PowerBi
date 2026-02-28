"""Metadata extractor for PBIX / PBIT artifacts.

Extracts:
- Power Query M scripts (from the nested DataMashup ZIP)
- Data model schema (tables, columns, measures) – PBIT only
- Connection / data-source information
"""

from __future__ import annotations

import io
import json
import logging
import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional

from .reader import PBIReader

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data classes (pure data, JSON-serialisable via asdict())
# ---------------------------------------------------------------------------


@dataclass
class QueryInfo:
    """A single Power Query (M) query."""

    name: str
    script: str


@dataclass
class ColumnInfo:
    name: str
    data_type: str


@dataclass
class MeasureInfo:
    name: str
    expression: str


@dataclass
class TableInfo:
    name: str
    columns: List[ColumnInfo] = field(default_factory=list)
    measures: List[MeasureInfo] = field(default_factory=list)


@dataclass
class ConnectionInfo:
    protocol: Optional[str]
    address: Optional[str]
    raw: str


@dataclass
class PBIMetadata:
    """Full metadata bag returned for a single PBIX/PBIT file."""

    file_path: str
    file_type: str  # "pbix" or "pbit"
    queries: List[QueryInfo] = field(default_factory=list)
    tables: List[TableInfo] = field(default_factory=list)
    connections: List[ConnectionInfo] = field(default_factory=list)
    archive_members: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------------------
# Extractor
# ---------------------------------------------------------------------------


class PBIExtractor:
    """Extract metadata from a PBIX or PBIT file."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path).resolve()

    def extract(self) -> PBIMetadata:
        """Run all extractors and return a :class:`PBIMetadata` instance."""
        meta = PBIMetadata(
            file_path=str(self.path),
            file_type=self.path.suffix.lstrip(".").lower(),
        )
        with PBIReader(self.path) as reader:
            meta.archive_members = reader.list_members()
            meta.queries = self._extract_queries(reader)
            meta.tables = self._extract_tables(reader)
            meta.connections = self._extract_connections(reader)
        return meta

    # ------------------------------------------------------------------
    # Power Query M scripts
    # ------------------------------------------------------------------

    def _extract_queries(self, reader: PBIReader) -> List[QueryInfo]:
        raw = reader.read_data_mashup()
        if raw is None:
            return []
        return _parse_mashup(raw)

    # ------------------------------------------------------------------
    # Data model schema (PBIT only – JSON inside DataModelSchema member)
    # ------------------------------------------------------------------

    def _extract_tables(self, reader: PBIReader) -> List[TableInfo]:
        raw = reader.read_data_model_schema()
        if raw is None:
            return []
        return _parse_data_model_schema(raw)

    # ------------------------------------------------------------------
    # Connections
    # ------------------------------------------------------------------

    def _extract_connections(self, reader: PBIReader) -> List[ConnectionInfo]:
        raw = reader.read_connections()
        if raw is None:
            return []
        return _parse_connections(raw)


# ---------------------------------------------------------------------------
# Internal parsers
# ---------------------------------------------------------------------------


def _parse_mashup(raw_mashup: bytes) -> List[QueryInfo]:
    """Parse the ``DataMashup`` ZIP blob and return :class:`QueryInfo` list.

    The DataMashup entry is itself a ZIP archive containing M query sections.
    Layout (typical)::

        [Content_Types].xml
        Config/Package.xml
        Formulas/Section1.m
        ...

    If the inner ZIP layout is unexpected we fall back to a regex search for
    shared-document sections within any ``.m`` file.
    """
    queries: List[QueryInfo] = []
    try:
        inner_zf = zipfile.ZipFile(io.BytesIO(raw_mashup), "r")
    except zipfile.BadZipFile:
        logger.warning("DataMashup is not a valid ZIP; skipping query extraction.")
        return queries

    with inner_zf:
        m_members = [n for n in inner_zf.namelist() if n.lower().endswith(".m")]
        if not m_members:
            logger.debug("No .m files found inside DataMashup archive.")
            return queries

        for member in m_members:
            text = inner_zf.read(member).decode("utf-8-sig", errors="replace")
            queries.extend(_parse_m_section(text))

    return queries


# Regex to find "shared <QueryName> = ..." blocks in M source text.
_SECTION_RE = re.compile(
    r"shared\s+(?P<name>[^\s=]+)\s*=\s*(?P<body>.*?)(?=\s*shared\s+|\Z)",
    re.DOTALL,
)
_SECTION_HEADER_RE = re.compile(r"^section\s+\S+\s*;", re.MULTILINE)


def _parse_m_section(text: str) -> List[QueryInfo]:
    """Parse M section text and return one :class:`QueryInfo` per shared query."""
    queries: List[QueryInfo] = []
    # Strip leading section header line if present (e.g. "section Section1;")
    text = _SECTION_HEADER_RE.sub("", text).strip()
    for match in _SECTION_RE.finditer(text):
        name = match.group("name").strip('"').strip("'")
        body = match.group("body").strip().rstrip(";").strip()
        queries.append(QueryInfo(name=name, script=body))
    return queries


def _parse_data_model_schema(raw: bytes) -> List[TableInfo]:
    """Parse ``DataModelSchema`` (JSON) and return :class:`TableInfo` list.

    The schema is UTF-16-LE encoded JSON.  Only tables, columns, and measures
    are extracted; partitions and other internals are ignored.
    """
    tables: List[TableInfo] = []
    try:
        # DataModelSchema is encoded as UTF-16 LE with BOM
        text = raw.decode("utf-16-le", errors="replace")
        # Strip BOM if present
        text = text.lstrip("\ufeff")
        schema: Dict[str, Any] = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        logger.warning("Could not parse DataModelSchema: %s", exc)
        return tables

    model: Dict[str, Any] = schema.get("model", schema)
    for raw_table in model.get("tables", []):
        tname: str = raw_table.get("name", "<unnamed>")
        # Skip hidden system tables
        if raw_table.get("isHidden") or tname.startswith("$"):
            continue

        columns: List[ColumnInfo] = [
            ColumnInfo(
                name=c.get("name", ""),
                data_type=c.get("dataType", "unknown"),
            )
            for c in raw_table.get("columns", [])
            if not c.get("isHidden")
        ]
        measures: List[MeasureInfo] = [
            MeasureInfo(
                name=m.get("name", ""),
                expression=m.get("expression", ""),
            )
            for m in raw_table.get("measures", [])
        ]
        tables.append(TableInfo(name=tname, columns=columns, measures=measures))

    return tables


def _parse_connections(raw: bytes) -> List[ConnectionInfo]:
    """Parse the ``Connections`` member (JSON or XML) into a list of :class:`ConnectionInfo`."""
    conns: List[ConnectionInfo] = []
    text = raw.decode("utf-8", errors="replace").strip()

    # Try JSON first
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
            items = data if isinstance(data, list) else [data]
            for item in items:
                conns.append(
                    ConnectionInfo(
                        protocol=item.get("Protocol") or item.get("protocol"),
                        address=item.get("Address") or item.get("address"),
                        raw=json.dumps(item, indent=2),
                    )
                )
            return conns
        except json.JSONDecodeError:
            pass

    # Try XML
    try:
        root = ET.fromstring(text)
        ns = {"": root.tag.split("}")[0].lstrip("{") if "}" in root.tag else ""}
        for conn_el in root.iter():
            if conn_el.tag.lower().endswith("connection"):
                conns.append(
                    ConnectionInfo(
                        protocol=conn_el.get("Protocol") or conn_el.get("protocol"),
                        address=conn_el.get("Address") or conn_el.get("address"),
                        raw=ET.tostring(conn_el, encoding="unicode"),
                    )
                )
        if conns:
            return conns
    except ET.ParseError:
        pass

    # Fall back – return the raw text as a single opaque entry
    conns.append(ConnectionInfo(protocol=None, address=None, raw=text))
    return conns
