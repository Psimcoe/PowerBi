"""Workspace configuration loader with allowlist-based access control."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import List

import yaml

logger = logging.getLogger(__name__)

DEFAULT_ALLOWED_EXTENSIONS = {".pbix", ".pbit"}
DEFAULT_CONFIG_PATH = Path(__file__).parent.parent.parent / "config" / "workspace.yaml"


class WorkspaceConfig:
    """Holds resolved workspace settings loaded from a YAML config file."""

    def __init__(
        self,
        folders: List[Path],
        allowed_extensions: set[str] | None = None,
        max_sample_rows: int = 100,
        log_level: str = "INFO",
    ) -> None:
        self.folders: List[Path] = folders
        self.allowed_extensions: set[str] = (
            allowed_extensions if allowed_extensions is not None else DEFAULT_ALLOWED_EXTENSIONS
        )
        self.max_sample_rows: int = max_sample_rows
        self.log_level: str = log_level

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------
    @classmethod
    def from_file(cls, config_path: str | Path | None = None) -> "WorkspaceConfig":
        """Load configuration from *config_path* (defaults to ``config/workspace.yaml``)."""
        path = Path(config_path) if config_path else DEFAULT_CONFIG_PATH
        if not path.exists():
            logger.warning("Config file not found at %s; using empty workspace.", path)
            return cls(folders=[])

        with open(path, "r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}

        raw_folders: list = raw.get("workspace_folders", [])
        folders: List[Path] = []
        for f in raw_folders:
            resolved = Path(os.path.expanduser(str(f))).resolve()
            if resolved.is_dir():
                folders.append(resolved)
            else:
                logger.warning("Workspace folder does not exist and will be skipped: %s", f)

        raw_ext: list | None = raw.get("allowed_extensions")
        allowed_ext: set[str] | None = (
            {str(e).lower() for e in raw_ext} if raw_ext is not None else None
        )

        return cls(
            folders=folders,
            allowed_extensions=allowed_ext,
            max_sample_rows=int(raw.get("max_sample_rows", 100)),
            log_level=str(raw.get("log_level", "INFO")).upper(),
        )

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------
    def is_path_allowed(self, path: str | Path) -> bool:
        """Return *True* only when *path* is inside one of the allowed workspace folders."""
        resolved = Path(os.path.expanduser(str(path))).resolve()
        # Extension check
        if resolved.suffix.lower() not in self.allowed_extensions:
            return False
        # Folder containment check (must be under at least one allowlisted folder)
        return any(
            _is_relative_to(resolved, folder) for folder in self.folders
        )

    def list_files(self) -> List[Path]:
        """Return all allowed files found recursively under the workspace folders."""
        results: List[Path] = []
        for folder in self.folders:
            for ext in self.allowed_extensions:
                results.extend(folder.rglob(f"*{ext}"))
        return sorted(results)


def _is_relative_to(child: Path, parent: Path) -> bool:
    """Portable backport of ``Path.is_relative_to`` (added in Python 3.9)."""
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False
