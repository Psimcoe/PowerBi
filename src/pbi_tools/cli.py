"""Click-based CLI for pbi-tools.

Commands
--------
list-files          List all allowed PBI files in the workspace.
read-file           Show the ZIP member list for a specific file.
extract-metadata    Extract and print metadata (queries, tables, connections).
validate            Run basic structural validations on a file.
"""

from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from typing import Optional

import click

from .extractor import PBIExtractor
from .logger import setup_logging
from .reader import (
    MEMBER_CONNECTIONS,
    MEMBER_CONTENT_TYPES,
    MEMBER_DATA_MASHUP,
    MEMBER_DATA_MODEL_SCHEMA,
    PBIReader,
)
from .workspace import WorkspaceConfig

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# CLI group
# ---------------------------------------------------------------------------


@click.group()
@click.option(
    "--config",
    default=None,
    metavar="PATH",
    help="Path to workspace YAML config (default: config/workspace.yaml).",
)
@click.option(
    "--log-level",
    default="INFO",
    type=click.Choice(["DEBUG", "INFO", "WARNING", "ERROR"], case_sensitive=False),
    show_default=True,
    help="Logging verbosity.",
)
@click.pass_context
def main(ctx: click.Context, config: Optional[str], log_level: str) -> None:
    """pbi-tools – local Power BI artifact reader and metadata extractor."""
    ctx.ensure_object(dict)
    ws = WorkspaceConfig.from_file(config)
    effective_level = log_level or ws.log_level
    setup_logging(effective_level)
    ctx.obj["ws"] = ws


# ---------------------------------------------------------------------------
# list-files
# ---------------------------------------------------------------------------


@main.command("list-files")
@click.pass_context
def list_files(ctx: click.Context) -> None:
    """List all .pbix/.pbit files found in the configured workspace folders."""
    ws: WorkspaceConfig = ctx.obj["ws"]
    files = ws.list_files()
    if not files:
        click.echo("No files found. Check your workspace_folders in the config.")
        return
    for f in files:
        click.echo(str(f))


# ---------------------------------------------------------------------------
# read-file
# ---------------------------------------------------------------------------


@main.command("read-file")
@click.argument("file_path")
@click.option("--member", default=None, help="Print raw content of a specific ZIP member.")
@click.pass_context
def read_file(ctx: click.Context, file_path: str, member: Optional[str]) -> None:
    """Show ZIP members (or the raw content of one member) for FILE_PATH."""
    ws: WorkspaceConfig = ctx.obj["ws"]
    path = Path(file_path).resolve()

    if not ws.is_path_allowed(path):
        click.echo(
            f"Access denied: {path} is not within an allowed workspace folder.",
            err=True,
        )
        sys.exit(1)

    with PBIReader(path) as reader:
        if member:
            try:
                data = reader.read_member(member)
                sys.stdout.buffer.write(data)
            except KeyError as exc:
                click.echo(str(exc), err=True)
                sys.exit(1)
        else:
            members = reader.list_members()
            click.echo(f"Archive: {path.name}  ({len(members)} members)")
            for m in members:
                click.echo(f"  {m}")


# ---------------------------------------------------------------------------
# extract-metadata
# ---------------------------------------------------------------------------


@main.command("extract-metadata")
@click.argument("file_path")
@click.option("--output", "-o", default=None, help="Write JSON output to this file.")
@click.pass_context
def extract_metadata(ctx: click.Context, file_path: str, output: Optional[str]) -> None:
    """Extract Power Query scripts, model schema, and connections from FILE_PATH."""
    ws: WorkspaceConfig = ctx.obj["ws"]
    path = Path(file_path).resolve()

    if not ws.is_path_allowed(path):
        click.echo(
            f"Access denied: {path} is not within an allowed workspace folder.",
            err=True,
        )
        sys.exit(1)

    extractor = PBIExtractor(path)
    metadata = extractor.extract()
    result = json.dumps(metadata.to_dict(), indent=2, ensure_ascii=False)

    if output:
        Path(output).write_text(result, encoding="utf-8")
        click.echo(f"Metadata written to {output}")
    else:
        click.echo(result)


# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------


@main.command("validate")
@click.argument("file_path")
@click.pass_context
def validate(ctx: click.Context, file_path: str) -> None:
    """Run basic structural validations on FILE_PATH and report results."""
    ws: WorkspaceConfig = ctx.obj["ws"]
    path = Path(file_path).resolve()

    if not ws.is_path_allowed(path):
        click.echo(
            f"Access denied: {path} is not within an allowed workspace folder.",
            err=True,
        )
        sys.exit(1)

    issues: list[str] = []
    warnings: list[str] = []

    with PBIReader(path) as reader:
        members = reader.list_members()

        if MEMBER_CONTENT_TYPES not in members:
            issues.append(f"Missing required member: {MEMBER_CONTENT_TYPES}")

        if MEMBER_DATA_MASHUP not in members and path.suffix.lower() == ".pbit":
            warnings.append("DataMashup not found – Power Query queries will not be available.")

        if path.suffix.lower() == ".pbit" and MEMBER_DATA_MODEL_SCHEMA not in members:
            warnings.append("DataModelSchema not found in .pbit file.")

    if issues:
        click.echo("ERRORS:")
        for i in issues:
            click.echo(f"  ✗ {i}")
    if warnings:
        click.echo("WARNINGS:")
        for w in warnings:
            click.echo(f"  ⚠ {w}")

    if not issues and not warnings:
        click.echo(f"✓ {path.name} passed all validations.")
    elif not issues:
        click.echo(f"\n✓ {path.name} passed (with warnings).")
    else:
        sys.exit(2)
