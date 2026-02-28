"""Lightweight FastAPI local service exposing pbi-tools as a REST API.

Endpoints
---------
GET  /files                          List files in the workspace.
GET  /files/{encoded_path}/members   List ZIP members of a specific file.
GET  /files/{encoded_path}/metadata  Extract and return full metadata.
GET  /files/{encoded_path}/validate  Run structural validations.

Run with::

    uvicorn pbi_tools.server:app --reload

or via the CLI helper::

    pbi-tools serve
"""

from __future__ import annotations

import json
import logging
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from .extractor import PBIExtractor
from .reader import PBIReader
from .workspace import WorkspaceConfig

logger = logging.getLogger(__name__)

app = FastAPI(
    title="pbi-tools local API",
    description="Read-only local Power BI artifact metadata API.",
    version="0.1.0",
)

# Workspace config is loaded once at import time.  Override by setting the
# PBI_TOOLS_CONFIG environment variable before starting the server.
import os as _os

_config_path: Optional[str] = _os.environ.get("PBI_TOOLS_CONFIG")
_ws = WorkspaceConfig.from_file(_config_path)


def _resolve_and_check(encoded_path: str) -> Path:
    """Decode *encoded_path*, resolve it, and check workspace access."""
    raw = urllib.parse.unquote(encoded_path)
    path = Path(raw).resolve()
    if not _ws.is_path_allowed(path):
        raise HTTPException(
            status_code=403,
            detail=f"Access denied: {path} is not within an allowed workspace folder.",
        )
    return path


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/files", response_model=List[str], summary="List workspace files")
def list_files() -> List[str]:
    """Return all .pbix/.pbit files found in the configured workspace folders."""
    return [str(p) for p in _ws.list_files()]


@app.get(
    "/files/{encoded_path:path}/members",
    response_model=List[str],
    summary="List ZIP members",
)
def list_members(encoded_path: str) -> List[str]:
    """Return the names of all ZIP members inside the given artifact."""
    path = _resolve_and_check(encoded_path)
    with PBIReader(path) as reader:
        return reader.list_members()


@app.get(
    "/files/{encoded_path:path}/metadata",
    summary="Extract metadata",
)
def extract_metadata(encoded_path: str) -> JSONResponse:
    """Extract Power Query scripts, model schema, and connection metadata."""
    path = _resolve_and_check(encoded_path)
    extractor = PBIExtractor(path)
    metadata = extractor.extract()
    return JSONResponse(content=metadata.to_dict())


@app.get(
    "/files/{encoded_path:path}/validate",
    summary="Validate artifact",
)
def validate(encoded_path: str) -> Dict[str, Any]:
    """Run basic structural validations and return a result dict."""
    from .reader import MEMBER_CONTENT_TYPES, MEMBER_DATA_MASHUP, MEMBER_DATA_MODEL_SCHEMA

    path = _resolve_and_check(encoded_path)
    issues: List[str] = []
    warnings: List[str] = []

    with PBIReader(path) as reader:
        members = reader.list_members()
        if MEMBER_CONTENT_TYPES not in members:
            issues.append(f"Missing required member: {MEMBER_CONTENT_TYPES}")
        if MEMBER_DATA_MASHUP not in members:
            warnings.append("DataMashup not found – Power Query queries will not be available.")
        if path.suffix.lower() == ".pbit" and MEMBER_DATA_MODEL_SCHEMA not in members:
            warnings.append("DataModelSchema not found in .pbit file.")

    return {
        "file": str(path),
        "passed": len(issues) == 0,
        "issues": issues,
        "warnings": warnings,
    }
