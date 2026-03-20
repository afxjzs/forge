# Stack: Python CLI

Append to project CLAUDE.md when stack is a Python CLI tool.

## Commands

```bash
uv run python -m <package>       # Run the CLI
uv run pytest -v --no-header     # Run tests
uv run ruff check .              # Lint
uv run ruff format .             # Format
uv add <package>                 # Add dependency
uv sync                          # Install dependencies
```

## Conventions

- `uv` for all Python tooling
- `pyproject.toml` with `[project.scripts]` for CLI entrypoints
- `click` or `typer` for CLI framework — never raw `argparse` for non-trivial CLIs
- Rich for terminal output (progress bars, tables, colors)
- Structured logging: `structlog` or stdlib `logging` — never bare `print()` for operational output
- Config: environment variables + `.env` file (python-dotenv) — never hardcoded
- Exit codes: 0=success, 1=error, 2=usage error — match Unix conventions

## Known Issues

<!-- Populated by agents. Append-only. -->

- `uv run` must be used instead of `python` directly — venv not activated globally
- `click.echo()` over `print()` — handles encoding issues on Windows
- `typer` is sync by default — wrap async code in `asyncio.run()`
- File paths: use `pathlib.Path` always — never string concatenation for paths
- `sys.exit()` in library code prevents testing — raise exceptions, catch at CLI boundary
