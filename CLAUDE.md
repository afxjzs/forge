# forge — Agentic Development Pipeline

Multi-agent dev pipeline for any software project. Telegram-driven. Stack-agnostic.

## Stack

- **forge-api**: FastAPI (port 8773) — project registry, orchestrator trigger, deploy
- **forge-bot**: Telegram bot (port 8774) — user-facing commands, interviews
- **Scripts**: Bash (`scripts/`) — CLI, Ralph Loop, worker spawn, deploys
- **Agents**: Claude Code subprocesses — orchestrator, workers, reviewers

## Commands

```bash
forge status [project]             # project status
forge board <project>              # kanban view (GitHub Issues)
forge init <name> <stack>          # new project
forge adopt <path> [--stack X]     # onboard existing project
forge run <project-path>           # start Ralph Loop
forge deploy <project> staging     # deploy staging
forge deploy <project> production  # ship: staging→main→deploy
```

## Task System: GitHub Issues

**GitHub Issues are the single source of truth for all tasks.** There are no local task files.

See **[TASK-SYSTEM.md](TASK-SYSTEM.md)** for the complete reference:
- How PRDs become task issues (`forge-prd-to-issues.sh`)
- Issue labels and state machine
- How the Ralph Loop picks and executes tasks
- Worker lifecycle (worktree → PR → CI → merge → issue closed)
- Branch naming (`issue/NNN`, PRs target `staging`)

## Key Documentation

| Doc | What it covers | Who reads it |
|-----|---------------|-------------|
| **[TASK-SYSTEM.md](TASK-SYSTEM.md)** | GitHub Issues workflow, labels, state machine | All agents, all humans |
| **[DESIGN.md](DESIGN.md)** | Architecture, roles, deployment flow, testing, security | Architects, PM |
| **[LEARNINGS.md](LEARNINGS.md)** | Production failure patterns and prevention rules | All agents (on failure) |
| **[agents/orchestrator/AGENT.md](agents/orchestrator/AGENT.md)** | Ralph Loop behavior, steering, model tiers | Orchestrator agent only |
| **[agents/worker/AGENT.md](agents/worker/AGENT.md)** | Worker startup, implementation, commit format | Worker agents only |
| **[agents/reviewer/AGENT.md](agents/reviewer/AGENT.md)** | PR review checklists, scoring rubric | Reviewer agents only |
| **[templates/stacks/](templates/stacks/)** | Stack-specific conventions + known issues | Workers on that stack |

## Per-Project File Structure

```
<project>/
├── CLAUDE.md                    # Project context (conventions, commands, stack)
├── docker-compose.yml           # Production container
├── docker-compose.staging.yml   # Staging container (x-forge.staging_url)
├── .github/workflows/
│   └── forge-ci.yml             # CI: build, lint, security, tests
├── scripts/
│   └── smoke-test.sh            # Post-deploy verification
├── spec/
│   ├── MVP.md                   # MVP spec
│   ├── BACKLOG.md               # Prioritized feature backlog
│   ├── features/NNN-*.md        # Feature specs
│   └── research/*.md            # Research findings
└── .agent/
    ├── STEERING.md              # Human redirect (read every iteration)
    ├── CONTEXT.md               # Current state (maintained by orchestrator)
    ├── LOG.md                   # JSONL activity log (append-only)
    ├── ERRORS.md                # Error catalog with prevention rules
    ├── DECISIONS.md             # ADR-style architecture decisions
    └── NOTES.md                 # Live testing observations
```

**Note:** `.agent/tasks/` and `.agent/scores/` are deprecated. Tasks live in GitHub Issues.

## Error Handling — Mandatory

- NEVER suppress errors silently
- Log all errors to `.agent/ERRORS.md`
- A loud failure that gets fixed is always better than a silent one that rots
- If using a fallback, log a WARNING that the primary path failed

## Conventions (FastAPI stack)

```bash
uv run uvicorn app.main:app --reload     # Development server
uv run pytest -v --no-header             # Run tests
uv run ruff check .                       # Lint
uv run ruff format .                      # Format
uv add <package>                          # Add dependency
uv sync                                   # Install dependencies
```

- `uv` for all Python tooling — never pip, never venv directly
- Pydantic models for all request/response schemas — never raw dicts
- Define all endpoints AFTER `app = FastAPI()` instantiation
- Use `datetime.now(UTC)` not `datetime.now()` — timezone-aware always
- Async endpoints by default; sync only for CPU-bound work
- Docker: use `--host 0.0.0.0` in uvicorn or container won't accept connections

## Known Footguns

- Defining routes before `app = FastAPI()` → routes silently don't register
- `datetime.now()` without timezone → comparison bugs with tz-aware DB timestamps
- Pydantic v2 uses `model_validate()` not `parse_obj()` — v1 methods silently break
- SQLAlchemy async sessions: must use `async_session()` context manager, not raw session
- Docker: `--host 0.0.0.0` required or container rejects connections
- CORS: must add middleware explicitly — FastAPI has no default CORS
