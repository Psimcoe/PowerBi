"""Low-level PBIX / PBIT ZIP reader.

PBIX and PBIT files are ZIP archives.  This module provides safe,
read-only access to their internal members.
"""

from __future__ import annotations

import logging
import zipfile
from pathlib import Path
from typing import List

logger = logging.getLogger(__name__)

# Well-known member names inside a PBIX/PBIT archive
MEMBER_DATA_MASHUP = "DataMashup"
MEMBER_DATA_MODEL_SCHEMA = "DataModelSchema"  # present in PBIT only
MEMBER_CONNECTIONS = "Connections"
MEMBER_CONTENT_TYPES = "[Content_Types].xml"
MEMBER_REPORT_LAYOUT = "Report/Layout"
MEMBER_METADATA = "Metadata"
MEMBER_VERSION = "Version"

# The DataMashup entry is itself a ZIP; M queries live inside it.
MASHUP_QUERY_DIR = "Formulas/Section1.m"


class PBIReader:
    """Open a ``.pbix`` or ``.pbit`` file for safe, read-only inspection."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path).resolve()
        if not self.path.exists():
            raise FileNotFoundError(f"File not found: {self.path}")
        suffix = self.path.suffix.lower()
        if suffix not in {".pbix", ".pbit"}:
            raise ValueError(f"Unsupported file type: {suffix!r}. Expected .pbix or .pbit")
        self._zf: zipfile.ZipFile | None = None

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------
    def __enter__(self) -> "PBIReader":
        self._zf = zipfile.ZipFile(self.path, "r")
        return self

    def __exit__(self, *_: object) -> None:
        if self._zf:
            self._zf.close()
            self._zf = None

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _ensure_open(self) -> zipfile.ZipFile:
        if self._zf is None:
            raise RuntimeError("PBIReader must be used as a context manager.")
        return self._zf

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def list_members(self) -> List[str]:
        """Return the list of all ZIP member names inside the artifact."""
        zf = self._ensure_open()
        return [m.filename for m in zf.infolist()]

    def read_member(self, name: str) -> bytes:
        """Return the raw bytes of a ZIP member by *name*."""
        zf = self._ensure_open()
        try:
            return zf.read(name)
        except KeyError:
            raise KeyError(f"Member {name!r} not found in {self.path.name}")

    def has_member(self, name: str) -> bool:
        """Return *True* when the archive contains a member with the given *name*."""
        zf = self._ensure_open()
        return any(m.filename == name for m in zf.infolist())

    def read_data_mashup(self) -> bytes | None:
        """Return the raw bytes of the ``DataMashup`` member (or *None*)."""
        if not self.has_member(MEMBER_DATA_MASHUP):
            logger.debug("%s has no DataMashup entry.", self.path.name)
            return None
        return self.read_member(MEMBER_DATA_MASHUP)

    def read_data_model_schema(self) -> bytes | None:
        """Return the raw bytes of ``DataModelSchema`` (PBIT only, or *None*)."""
        if not self.has_member(MEMBER_DATA_MODEL_SCHEMA):
            logger.debug("%s has no DataModelSchema entry.", self.path.name)
            return None
        return self.read_member(MEMBER_DATA_MODEL_SCHEMA)

    def read_connections(self) -> bytes | None:
        """Return the raw bytes of the ``Connections`` member (or *None*)."""
        if not self.has_member(MEMBER_CONNECTIONS):
            return None
        return self.read_member(MEMBER_CONNECTIONS)
