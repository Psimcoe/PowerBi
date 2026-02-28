# pbi-tools

A **local-only**, VS Code–friendly toolkit for inspecting Power BI Desktop artifacts (`.pbix` / `.pbit`).

> **No cloud credentials required.** All operations read local files only.

---

## Features

| Capability | Details |
|---|---|
| 🗂 Workspace allowlist | Only files inside explicitly configured folders are accessible |
| 🔍 Power Query extraction | Extracts M scripts from the embedded `DataMashup` archive |
| 📐 Model schema | Extracts tables, columns, and measures from `.pbit` files |
| 🔌 Connection info | Reads connection/data-source metadata |
| ✅ Validation | Basic structural checks on any artifact |
| 🖥 CLI | `pbi-tools` Click-based command-line interface |
| 🌐 Local API | FastAPI REST service for programmatic access |

---

## Quick Start

### 1. Prerequisites

- Python 3.9+
- (Optional) [VS Code](https://code.visualstudio.com/) with the recommended extensions

### 2. Install

```bash
# Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate

# Install the package and all dependencies
pip install -e ".[dev]"
```

### 3. Configure your workspace

Edit `config/workspace.yaml` to point at the folder(s) containing your `.pbix` / `.pbit` files:

```yaml
workspace_folders:
  - ~/PowerBI/projects      # absolute or ~ paths are both fine

allowed_extensions:
  - .pbix
  - .pbit

max_sample_rows: 100
log_level: INFO
```

Only files **inside** these folders will be accessible to the tool.

---

## CLI Usage

```bash
# List all .pbix/.pbit files in the configured workspace
pbi-tools list-files

# Show ZIP members of a specific artifact
pbi-tools read-file /path/to/report.pbit

# Extract metadata (queries, tables, connections) as JSON
pbi-tools extract-metadata /path/to/report.pbit

# Write metadata to a file
pbi-tools extract-metadata /path/to/report.pbit --output meta.json

# Run structural validations
pbi-tools validate /path/to/report.pbit

# Use a custom config file
pbi-tools --config my-workspace.yaml list-files
```

---

## Local API Server

Start the FastAPI development server:

```bash
uvicorn pbi_tools.server:app --reload
```

Open [http://localhost:8000/docs](http://localhost:8000/docs) for the interactive Swagger UI.

### Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/files` | List workspace files |
| `GET` | `/files/{path}/members` | List ZIP members |
| `GET` | `/files/{path}/metadata` | Extract full metadata |
| `GET` | `/files/{path}/validate` | Validate an artifact |

The `{path}` segment must be URL-encoded. Example (Python):

```python
import urllib.parse, requests

path = urllib.parse.quote("/home/user/projects/report.pbit", safe="")
r = requests.get(f"http://localhost:8000/files/{path}/metadata")
print(r.json())
```

---

## Running Tests

```bash
pytest
```

---

## VS Code

Install the recommended extensions (prompted automatically or via `.vscode/extensions.json`), then use the built-in **Run & Debug** panel to launch the CLI or server with pre-configured launch configurations.

---

## Project Structure

```
.
├── config/
│   └── workspace.yaml       # Workspace allowlist and settings
├── src/
│   └── pbi_tools/
│       ├── __init__.py
│       ├── cli.py           # Click CLI entry point
│       ├── extractor.py     # Metadata extraction logic
│       ├── logger.py        # Logging setup
│       ├── reader.py        # Low-level ZIP reader
│       ├── server.py        # FastAPI local service
│       └── workspace.py     # Allowlist config loader
├── tests/
│   ├── fixtures/
│   │   └── sample.pbit      # Minimal test fixture
│   ├── test_cli.py
│   ├── test_extractor.py
│   ├── test_reader.py
│   ├── test_server.py
│   └── test_workspace.py
├── .vscode/
│   ├── extensions.json
│   ├── launch.json
│   └── settings.json
└── pyproject.toml
```

---

## Security & Privacy

- **Allowlist only**: no file is readable unless its parent folder is listed in `workspace_folders`.
- **Read-only**: the tool never writes to, modifies, or deletes `.pbix`/`.pbit` files.
- **Local only**: no data is sent to any external service.
- **Metadata first**: by default only structural metadata (query names, column names, measure expressions) is returned. No row-level data is extracted.

---

## Clarifying Questions

The following points would affect future architecture decisions:

1. **PBIX binary model** – `.pbix` files contain a VertiPaq binary `DataModel`. Should row-level sampling be added (requires a Power BI Desktop process or a third-party Tabular library)?
2. **Authentication** – Should the local API server require an API key for multi-user environments?
3. **Output formats** – Is JSON sufficient, or are CSV / Excel exports required for metadata?
4. **Power BI Service integration** – Should optional read-only REST API calls to Power BI Service be added as an opt-in feature?
5. **Packaging** – Should a standalone executable (e.g., via PyInstaller) be produced for users without Python installed?