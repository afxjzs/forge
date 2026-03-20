# forge

An agentic development pipeline that turns PRDs into deployed code. Planning conversations happen in Telegram, work gets tracked as GitHub Issues, and Claude Code workers build features autonomously.

## How it works

```
You (Telegram) → plan a feature → PRD created as GitHub Issue
                → PRD broken into task issues (labeled by complexity + priority)
                → Ralph Loop picks up tasks, spawns Claude Code workers
                → Workers create PRs → CI → auto-merge to staging
                → You test staging → report bugs → bugs become task issues → workers fix them
                → "ship it" → staging promoted to production
```

### Two interfaces

- **Telegram bot** — operational commands: `/status`, `/deploy`, `/ship`, `/kick`, `/testing`
- **OpenClaw agent** (optional) — conversational planning: PRDs, feature brainstorming, spec writing

### Key concepts

- **PRD → Issues**: A PRD (product requirements doc) is a GitHub Issue with the `prd` label. `forge-prd-to-issues.sh` uses Claude to break it into implementable task issues with complexity labels and dependency tracking.
- **Ralph Loop**: The orchestrator (`forge-run.sh`) that picks up task issues by priority, spawns workers on isolated git worktrees, and manages the merge queue.
- **Model tiers**: Tasks get routed to the right model based on complexity — `mechanical` (Haiku), `standard` (Sonnet), `architecture` (Opus).
- **Live testing**: `/testing <project>` starts a session where free-text bug reports become GitHub Issues with the `task` label, so workers pick them up automatically.
- **Circuit breaker**: 3 consecutive failures stops the loop and alerts you.

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│ Telegram Bot │────▶│   forge-api  │────▶│  forge scripts   │
│  (bot/)      │     │   (api/)     │     │  (scripts/)      │
│  port 8774   │     │  port 8773   │     │                  │
└─────────────┘     └──────────────┘     │ forge-run.sh     │
                                          │ forge-worker.sh  │
┌─────────────┐                           │ forge-plan.sh    │
│ OpenClaw    │──(dispatches to           │ forge-prd-to-    │
│ forge-pm    │   forge-pm agent)         │   issues.sh      │
└─────────────┘                           └────────┬────────┘
                                                   │
                                          ┌────────▼────────┐
                                          │  Claude Code     │
                                          │  (workers in     │
                                          │   git worktrees) │
                                          └─────────────────┘
```

### Components

| Component | Path | Purpose |
|-----------|------|---------|
| **forge-api** | `api/` | FastAPI service — project registry, orchestrator trigger, status |
| **forge-bot** | `bot/` | Telegram bot — commands, interviews, live testing sessions |
| **Scripts** | `scripts/` | Shell scripts — orchestrator, worker, planner, deploy, notifications |
| **Agent prompts** | `agents/` | Markdown instructions for Claude Code workers + orchestrator |

## Setup

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [uv](https://docs.astral.sh/uv/) for Python dependency management
- A Telegram bot token (from [@BotFather](https://t.me/botfather))

### Install

```bash
git clone https://github.com/afxjzs/forge.git
cd forge

# Configure secrets
cp .env.example .env
# Edit .env with your API keys

# Install dependencies
cd api && uv sync && cd ..
cd bot && uv sync && cd ..

# Start services
# Option 1: systemd (see systemd/ directory for unit files)
# Option 2: manual
cd api && uv run uvicorn api:app --host 127.0.0.1 --port 8773 &
cd bot && uv run python bot.py &
```

### GitHub repo setup

For each project you want forge to manage, create these labels:

| Label | Purpose |
|-------|---------|
| `task` | Implementable work item (required for worker pickup) |
| `prd` | Product requirements document |
| `bug` | Bug report |
| `P0`, `P1`, `P2` | Priority levels |
| `mechanical` | Haiku-tier complexity |
| `standard` | Sonnet-tier complexity |
| `architecture` | Opus-tier complexity |
| `in-progress` | Worker currently implementing |
| `needs-review` | Worker flagged for human review |

## Usage

### Adopt an existing project

```
/adopt ~/path/to/project
```

Forge asks interview questions to understand the project, then writes spec files.

### Plan a feature (via Telegram)

Message the bot or OpenClaw agent:
> "let's plan the next feature for myproject"

After the planning conversation, forge creates a PRD as a GitHub Issue, breaks it into task issues, and can kick off workers — all from the same conversation.

### Start workers

```
/kick myproject
```

The Ralph Loop picks up task issues by priority, spawns Claude Code workers in isolated git worktrees, creates PRs, and auto-merges to staging.

### Live testing

```
/testing myproject
```

Send free-text feedback. Forge classifies each note (bug/feature/ux) and creates GitHub Issues with the `task` label so workers pick them up automatically.

```
> "the onboarding shows raw JSON instead of buttons"
[myproject] #42 created (bug).

/done
```

### Deploy

```
/deploy myproject      # → staging
/ship myproject        # → production (requires staging tested first)
```

## Project structure (managed projects)

Forge expects this layout in each managed project:

```
project/
├── spec/
│   ├── MVP.md              # What "done" looks like
│   ├── BACKLOG.md          # Feature backlog
│   └── features/           # Individual feature specs
│       └── 001-auth.md
├── .agent/
│   ├── CONTEXT.md          # Current state (maintained by orchestrator)
│   ├── ERRORS.md           # Error catalog + prevention rules
│   ├── LOG.md              # Activity history (JSONL)
│   └── STEERING.md         # Human redirect mid-run
└── .github/
    ├── ISSUE_TEMPLATE/
    │   ├── task.md
    │   ├── prd.md
    │   └── bug.md
    └── workflows/
        └── forge-ci.yml
```

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | Yes | — | Anthropic API key for bot LLM features |
| `FORGE_BOT_TOKEN` | Yes | — | Telegram bot token |
| `FORGE_CHAT_ID` | Yes | — | Telegram chat ID for notifications |
| `DOCKER_OPS_TOKEN` | No | — | Token for docker-ops API (deploy features) |
| `FORGE_API_URL` | No | `http://127.0.0.1:8773` | forge-api URL |
| `ANTHROPIC_MODEL` | No | `claude-sonnet-4-6-20250514` | Model for bot LLM calls |

## License

MIT
