# forge — Agentic Development Pipeline

**Location:** `~/nexus/infra/dev-pipeline/`
**Purpose:** Reusable multi-agent dev pipeline for any software project. Telegram-driven. Stack-agnostic.
**Updated:** 2026-03-15

---

## Architecture

```
YOU (Telegram → main OpenClaw bot, forge skill)
  │
  ▼
Project PM Agent (OpenClaw, Sonnet)
  │  ← intake interviews, adoption interviews, status, feature requests,
  │     live notes, research, deploy commands. [project] tagging always.
  │
  ▼
forge-api (local HTTP, port 8773)
  │  ← project registry, orchestrator trigger, deploy (calls docker-ops),
  │     smart next_action guidance for PM
  │
  ▼
Orchestrator (Claude Code subprocess, Opus, Ralph Loop)
  │  reads: spec/features/*.md → builds .agent/tasks/
  │  reads: .agent/STEERING.md at every iteration start (mid-run redirect)
  │
  ├─→ Planner-Critic (Sonnet) — adversarial plan review, 2-3 rounds
  ├─→ UI Designer (Opus) — frontend projects only, writes spec/ui-spec.md
  │
  ├─→ Worker A (worktree: task/001) ─ model tier per task complexity
  ├─→ Worker B (worktree: task/002)
  └─→ Worker C (worktree: task/003)
       │  implements → tests → commits
       ▼
  Worker creates PR (targets staging branch, never main)
       │  → PR includes: summary, files by area, diff stats, what to test
       ▼
  GitHub Actions CI (build, lint, security scan, unit tests)
       │  → Worker waits up to 5 min for checks to pass
       ▼
  CI passes → Worker auto-merges PR to staging
       │  → PR stays on GitHub as audit trail
       ▼
  Security scan (bandit + semgrep + gitleaks + /security-review)
       │  → Results posted as PR comment
       ▼
  Staging auto-deploys → smoke tests → E2E Playwright tests run against live staging
       │  → Telegram notification with results + artifact links
       ▼
  YOU review on staging (always latest working code)
       ▼
  "ship <project>" → staging merges to main → production deploys via docker-ops → smoke tests verify
```

---

## Role Map

| Role | Runtime | Model | Responsibility |
|------|---------|-------|----------------|
| Project PM | OpenClaw (main bot, forge skill) | Sonnet | Human-facing: intake, adoption interviews, status, live notes, research, deploy |
| Orchestrator | Claude Code subprocess | Opus | Ralph Loop, task routing, merge queue |
| Planner-Critic | Claude Code subprocess | Sonnet | Adversarial plan review |
| UI Designer | Claude Code subprocess | Opus | UI spec, design tokens, UI PR review |
| Worker | Claude Code subprocess | Haiku/Sonnet/Opus | Task implementation in git worktrees |
| PR Reviewer | Claude Code subprocess | Sonnet | Code review, scoring, error pattern check |
| Security Scanner | Claude Code subprocess + tools | Sonnet | Two-layer: deterministic tools (bandit, semgrep, gitleaks) + /security-review |

**Worker model tiers** (set per task `complexity` field):
- `mechanical` → Haiku (migrations, refactors, boilerplate)
- `standard` → Sonnet (most features, bug fixes, 90% of tasks)
- `architecture` → Opus (core abstractions, system design, novel problems)

---

## Git Branch Strategy

| Branch | Purpose | Who merges to it | Deploys to |
|--------|---------|-------------------|------------|
| `main` | Production code | YOU (via "ship" command) | Production |
| `staging` | Integration + testing | Workers (auto-merge after CI passes) | Staging |
| `task/task-NNN` | Individual task work | Worker creates, auto-deleted after merge | Never deployed directly |

**Rules:**
- Workers ALWAYS PR against `staging`, never `main`
- PRs auto-merge to staging ONLY after GitHub Actions CI passes
- Staging → main promotion is human-triggered ("ship X" or "deploy X production")
- Main is always production-ready. Staging is always the latest working code.

---

## Deployment Flow

### Staging (automated)
```
Worker merges PR to staging
  → forge-api triggers staging deploy
  → docker compose rebuilds from staging branch
  → smoke tests run against live staging URL
  → Playwright E2E tests run (if tests/e2e/ exists)
  → Telegram notification with results + artifact links
  → results logged to .agent/LOG.md
```

### Production (human-triggered)
```
"ship omnilingo" or "deploy omnilingo production" (Telegram or CLI)
  → forge-api merges staging → main
  → pushes main to GitHub
  → calls docker-ops to rebuild production container
  → smoke tests run against production URL
  → results reported with commit hash
```

**Deploy commands:**
- Telegram: "ship omnilingo", "deploy omnilingo", "deploy omnilingo staging"
- CLI: `forge deploy omnilingo production`, `forge deploy omnilingo staging`

**Staging URLs:** configured per project in `docker-compose.staging.yml` under `x-forge.staging_url`

---

## Skills Architecture

Two separate runtimes, two separate skill systems:

| Runtime | Skills | Location |
|---------|--------|----------|
| OpenClaw (PM bot) | OpenClaw skills | `~/.openclaw/workspace/skills/forge/` |
| Claude Code (workers etc.) | Claude Code skills | `~/.claude/skills/forge-*/` |

The forge-api bridges them. OpenClaw skill → forge-api HTTP → bash scripts → Claude Code subprocess.

**forge-api is the brain.** It determines `next_action` for every project state (incomplete adoption → interview, no features → write specs, etc.). The PM skill relays API guidance — it doesn't make decisions itself.

---

## Ideas vs. Projects vs. Building

| Intent | Signal | Action |
|--------|--------|--------|
| Quick idea capture | "idea: X" | NOT forge. Goes to IDEAS.md via SOUL.md |
| Explore an idea | "explore idea about X", "new project" | Forge interview → inception stage |
| Commit to build | "approve", "kick off" | Promote inception → planning → active |
| Add to existing | "new feature for X" | Add to spec/BACKLOG.md |

NEVER auto-promote from inception. User explicitly approves.

---

## Project Lifecycle

```
inception  →  planning  →  active  →  shipped
                              ↕
                           paused
```

| Stage | Location | Meaning |
|-------|----------|---------|
| `inception` | `projects/inception/<name>/` | Interview done, spec drafted, not committed to build |
| `planning` | `projects/planning/<name>/` | Spec approved, task queue being generated |
| `active` | `projects/active/<name>/` → symlink to actual path | In active development |
| `paused` | `projects/paused/<name>/` | On hold |
| `shipped` | `projects/shipped/<name>/` | Done |

---

## Per-Project File Structure

```
<project>/
├── CLAUDE.md                    # Project context (generated + maintained by agents)
├── docker-compose.yml           # Production container
├── docker-compose.staging.yml   # Staging container (x-forge.staging_url for URL)
├── scripts/
│   ├── smoke-test.sh            # Smoke tests (run after every deploy)
│   └── tests/e2e/               # Playwright E2E tests (per-project)
├── .github/workflows/
│   └── forge-ci.yml             # GitHub Actions: build, lint, security, tests
├── spec/
│   ├── MVP.md                   # MVP spec from interview
│   ├── BACKLOG.md               # Prioritized feature backlog
│   ├── ui-spec.md               # UI/design spec (frontend projects only)
│   ├── research/                # Research findings scoped to this project
│   │   └── <topic>.md
│   └── features/
│       ├── 001-auth.md
│       └── 002-dashboard.md
└── .agent/
    ├── tasks/                   # Task specs (Ralph Loop pickup queue)
    ├── STEERING.md              # Edit mid-run to redirect orchestrator
    ├── LOG.md                   # JSONL append-only activity log
    ├── NOTES.md                 # Live testing notes, UX observations
    ├── ERRORS.md                # Error catalog with prevention rules
    ├── DECISIONS.md             # ADR-style architecture decisions
    ├── CONTEXT.md               # Current project state
    └── scores/                  # Per-task quality + model fit scores
```

---

## Testing Strategy

Three layers, each catches different failures:

| Layer | What it catches | When it runs |
|-------|----------------|-------------|
| **GitHub Actions CI** | Build failures, lint errors, dependency vulns, semgrep findings | On every PR push (before merge to staging) |
| **Smoke tests** | Core flows broken (health, auth, session creation, messaging) | After every staging deploy AND production deploy |
| **E2E tests (Playwright)** | UI-level regressions, user flow breakage, functional correctness | After every staging deploy (per-project `tests/e2e/`) |

**Smoke tests** are per-project scripts at `scripts/smoke-test.sh`. They verify the app actually works after deploy — not just that it builds. Template at `templates/smoke-test.sh`.

**E2E tests** use Playwright in each project's `tests/e2e/` directory. They run browser-based tests against the live staging URL after smoke tests pass. Artifacts (screenshots on failure, videos) are served at `{project}-staging.afx.cc/test-artifacts/`. Results sent via Telegram with clickable links. Runner: `forge-e2e.sh`. Report builder: `forge-e2e-report.py`.

**Key rule:** Nothing merges to staging unless CI passes. Nothing promotes to production unless smoke tests pass on staging.

---

## Security Scan

Two-layer gate, runs after PR review:

| Layer | Tools | What it catches |
|-------|-------|----------------|
| Deterministic | bandit, semgrep, gitleaks, npm audit | Known patterns, secrets, dependency vulns |
| LLM | `/security-review` Claude Code skill | Auth bypass, privilege escalation, data exposure |

**Verdicts:** PASS (merge), WARN (merge + log), BLOCK (merge stopped)
**Results posted as PR comment** on GitHub for visibility.
**Script:** `forge-security-scan.sh`

---

## Live Notes (Testing Feedback)

Real-time feedback channel via Telegram while testing a project:

| Signal | Routes to |
|--------|-----------|
| Bug report | `.agent/ERRORS.md` |
| Feature idea | `spec/BACKLOG.md` |
| UX observation | `.agent/NOTES.md` |
| Direction change | `.agent/STEERING.md` |

PM responds with one-line confirmations. No clarifying questions during testing.

---

## Research

PM conducts project-scoped research via web search. Findings saved to `spec/research/<topic>.md`. Workers reference research files when implementing related tasks.

---

## Error Capture — "Don't Make the Same Mistake Twice"

Three layers — every error propagates upward:

| Layer | File | Scope |
|-------|------|-------|
| Task-level | `.agent/ERRORS.md` | This project |
| Stack-level | `templates/stacks/<stack>.md` > Known Issues | All projects on this stack |
| Global | `LEARNINGS.md` | All projects |

**Rule:** No error appears twice without a prevention rule. Workers read ERRORS.md before starting. Reviewer checks diffs against known patterns.

---

## Scoring System

Per-task scorecard at `.agent/scores/task-NNN.json`:
- `reviewer_score` (1-5): quality assessment
- `model_fit` (`under`/`good`/`over`): was the right model tier used?
- `security_verdict` (`PASS`/`WARN`/`BLOCK`)

---

## OpenClaw Integration

**Current setup:** Forge runs through the main OpenClaw Telegram bot via the forge skill. Sonnet is the default model. The forge-api is the brain — PM relays `next_action` guidance from the API.

**Future option:** Standalone Python Telegram bot using dedicated forge bot token (saved at `.forge-bot-token`). Build if context mixing becomes a problem. OpenClaw doesn't support multiple Telegram bots on a single gateway.

---

## forge CLI

```
forge                              # show all commands
forge board <project> [task-id]    # kanban view
forge status [project]             # project status
forge init <name> <stack>          # new project
forge adopt <path> [--stack X]     # onboard existing project
forge promote <name> <stage>       # lifecycle transition
forge plan <project-path>          # generate task queue
forge run <project-path>           # start Ralph Loop
forge deploy <project> production  # ship: staging→main→deploy→smoke tests
forge deploy <project> staging     # deploy staging branch
forge deploy <project> <pr#>       # deploy specific PR to staging
forge deploy <project> teardown    # stop staging
forge security <project-path>      # run security scan
```

---

## forge-api Endpoints (port 8773)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/health` | Health check |
| GET | `/projects` | List all projects by stage with next_action |
| GET | `/projects/{name}/status` | Detailed status + spec completeness + next_action |
| POST | `/projects/new` | Create project (returns interview questions) |
| POST | `/projects/adopt` | Adopt existing project (returns interview if specs incomplete) |
| POST | `/projects/{name}/promote` | Advance lifecycle stage |
| POST | `/projects/{name}/feature` | Add feature to backlog |
| POST | `/projects/{name}/plan` | Generate task queue from feature specs |
| POST | `/projects/{name}/run` | Start Ralph Loop |
| POST | `/projects/{name}/deploy` | Deploy to staging or production (via docker-ops) |
| GET  | `/projects/{name}/staging-report` | Generate staging release report (commits, PRs, review checklist) |
| POST | `/projects/{name}/notify` | Generate staging report + send via Telegram |
| POST | `/projects/{name}/e2e` | Run Playwright E2E tests against staging |

---

## Phase Tracker

- [x] Phase 1 — Foundation: directory structure, agent prompts, stack templates, project scaffold
- [x] Phase 2 — Project Bootstrap: `forge-init.sh`, `forge-promote.sh`, `forge-status.sh`
- [x] Phase 3 — Ralph Loop Runner: `forge-plan.sh`, `forge-run.sh`, `forge-worker.sh`
- [x] Phase 4 — OpenClaw Integration: forge-api (port 8773), skill, SOUL.md + TOOLS.md
- [x] Phase 4c — forge-adopt: onboard existing projects, auto-detect stack, monorepo
- [x] Phase 4d — Security scan: bandit + semgrep + gitleaks + /security-review
- [x] Phase 4e — Staging-first deployment: staging branch, CI gate, auto-merge, smoke tests
- [x] Phase 4f — Production deploy via docker-ops, smoke test verification
- [x] Phase 4g — forge CLI wrapper, forge-board kanban view
- [x] Phase 4b — Standalone forge Telegram bot (@afxForgeBot, port 8774, deterministic commands + LLM for interviews)
- [ ] Phase 5 — Scoring wiring, SCORING-INSIGHTS aggregation
- [x] Phase 6 — Playwright E2E tests (forge-e2e.sh, per-project test suites, artifact serving)
- [ ] Phase 7 — UI Designer agent activation + remaining stack templates
