# Stack: FastAPI

Append to project CLAUDE.md when stack is FastAPI.

## Commands

```bash
uv run uvicorn app.main:app --reload     # Development server
uv run pytest -v --no-header             # Run tests
uv run ruff check .                       # Lint
uv run ruff format .                      # Format
uv add <package>                          # Add dependency
uv sync                                   # Install dependencies
```

## Conventions

- `uv` for all Python tooling — never pip, never venv directly
- `pyproject.toml` — no setup.py, no requirements.txt
- Pydantic models for all request/response schemas — never raw dicts
- Define all endpoints AFTER `app = FastAPI()` instantiation (not in separate modules imported before app exists)
- Use `datetime.now(UTC)` not `datetime.now()` — timezone-aware always
- Async endpoints by default; sync only for CPU-bound work
- Dependencies via `Depends()` — reusable auth, DB sessions, rate limits
- Background tasks via `BackgroundTasks` parameter, not threading

## Known Issues

<!-- Populated by agents. Append-only. -->

- Defining routes before `app = FastAPI()` → routes silently don't register
- `datetime.now()` without timezone → comparison bugs with DB timestamps that are tz-aware
- Pydantic v2 uses `model_validate()` not `parse_obj()` — v1 methods silently break
- SQLAlchemy async sessions: must use `async_session()` context manager, not raw session
- `response_model` strips extra fields — if you need them, use `response_model_exclude_unset`
- Docker: use `--host 0.0.0.0` in uvicorn or container won't accept connections
- CORS: must add middleware explicitly — FastAPI has no default CORS
