# Forge Task System — GitHub Issues

**GitHub Issues are the single source of truth for all forge tasks.** There are no local task files. The `.agent/tasks/` directory is deprecated and must not be used.

---

## How Work Gets Created

### PRD → Task Issues

1. Write a PRD (Product Requirements Document) — either as a GitHub Issue with the `prd` label, or as a spec file
2. Run `forge-prd-to-issues.sh <project-path> --issue <prd-number>` (or `--file <spec-file>`)
3. Script uses Claude (Sonnet) to break the PRD into implementable task issues
4. Each task issue gets:
   - **`task` label** (if spec passes assessment) OR **`needs-spec` label** (if it fails)
   - **Complexity label**: `mechanical`, `standard`, or `architecture`
   - **Priority label**: `P0`, `P1`, or `P2`
   - **Dependency refs**: "Blocked by #N" in the issue body
   - **Parent PRD reference**: link back to the source PRD issue

### Spec Assessment Gate

Before creating each task issue, the spec is validated:
- File references checked against the codebase
- Dependencies validated (blocked_by refs exist)
- Complexity scored (mechanical tasks can't touch 5+ files)
- LLM clarity check (can an agent implement this without questions?)

If any check fails → issue gets `needs-spec` label + clarifying questions appended.

---

## Issue Labels (State Machine)

| Label | Meaning | Who sets it |
|-------|---------|-------------|
| `prd` | Product requirements document | User / PM |
| `task` | Ready for implementation | `forge-prd-to-issues.sh` |
| `needs-spec` | Spec needs clarification before work can begin | `forge-prd-to-issues.sh` |
| `P0` / `P1` / `P2` | Priority (lower = higher priority) | `forge-prd-to-issues.sh` |
| `mechanical` | Complexity: Haiku-tier (boilerplate, renames, migrations) | `forge-prd-to-issues.sh` |
| `standard` | Complexity: Sonnet-tier (features, bug fixes, CRUD) | `forge-prd-to-issues.sh` |
| `architecture` | Complexity: Opus-tier (new abstractions, system design) | `forge-prd-to-issues.sh` |
| `in-progress` | Worker is actively implementing this | `forge-run.sh` |
| `needs-review` | 3 attempts failed, needs human intervention | `forge-run.sh` |

### State Transitions

```
[open + task]  →  [open + in-progress]  →  CLOSED (PR merged)
                                        →  [open + needs-review] (3 failures)
```

- **Queued** = open issue with `task` label, no `in-progress` label
- **In Progress** = issue has `in-progress` label
- **Done** = issue is CLOSED (PR merged to staging with "Closes #N")
- **Blocked** = issue body contains "Blocked by #N" where #N is still open
- **Needs Review** = `needs-review` label (remove label to re-queue)

---

## Ralph Loop (forge-run.sh)

The orchestrator loop reads GitHub Issues to find work:

```
1. Read .agent/STEERING.md           ← human redirect?
2. gh issue list --label task --state open
3. Sort by priority (P0 → P1 → P2 → unlabeled)
4. Skip blocked issues (check "Blocked by #N" refs)
5. Skip in-progress issues
6. Pick highest-priority unblocked issue
7. Add 'in-progress' label
8. Determine model from complexity label
9. Spawn worker: forge-worker.sh <project> <issue-number> <model>
10. On success: remove 'in-progress' label, issue auto-closes via PR
11. On failure: retry up to 3 times (escalate to Opus on attempt 2+)
12. After 3 failures: add 'needs-review' label, post error summary as comment
13. Loop
```

### Model Assignment

| Complexity label | Model | Examples |
|-----------------|-------|---------|
| `mechanical` | Haiku | Rename files, add boilerplate, format code, migrations |
| `standard` | Sonnet | Feature implementation, bug fixes, CRUD endpoints |
| `architecture` | Opus | New abstractions, system design, auth flows |

Heuristic: when in doubt, go one tier up. Retries from under-allocation cost more than over-allocation.

### Stop Conditions

- No more open task issues with met dependencies
- STEERING.md says "stop" or "pause"
- Circuit breaker: 3 consecutive failures → stop and alert PM

---

## Worker Lifecycle (forge-worker.sh)

```
1. Read issue from GitHub: gh issue view <number>
2. Create worktree: .worktrees/issue-<number>/
3. Create branch: issue/<number> (from staging)
4. Build prompt from issue body + CLAUDE.md + ERRORS.md + stack known issues
5. Run Claude Code in worktree with worker AGENT.md as system prompt
6. Worker implements, lints, tests, commits
7. Push branch, create PR targeting staging ("Closes #<number>")
8. Wait for CI (up to 10 min)
9. CI passes → auto-merge PR → close issue → deploy staging
10. CI fails → mark needs_review
11. Cleanup worktree
```

### Branch & PR Naming

- **Branch**: `issue/<number>` (e.g., `issue/7`)
- **PR title**: Same as issue title
- **PR body**: Issue description + diff stats + "Closes #N"
- **PR target**: Always `staging`, never `main`
- **Commit format**: `feat(#<number>): [short description]`

### Retry Logic (3-strike)

| Attempt | Model | Behavior |
|---------|-------|----------|
| 1 | Assigned tier | Normal attempt |
| 2 | Opus (escalated) | Previous error fed as context |
| 3 | Opus | Previous error fed as context |
| All fail | — | Issue gets `needs-review` label + error summary comment |

---

## Deployment Flow

### Staging (automated after PR merge)
```
PR merged to staging → docker compose -f docker-compose.staging.yml up -d --build
  → smoke tests → Telegram notification
```

### Production (human-triggered only)
```
"ship <project>" → staging merges to main → docker compose up -d --build
  → smoke tests → Telegram notification with commit hash
```

**Golden rule:** Deploy = staging. Ship = production. "Deploy" must NEVER mean production without explicit user approval.

---

## Required GitHub Labels

Every forge-managed repo needs these labels created:

```bash
gh label create task --color 0E8A16 --description "Ready for forge worker"
gh label create prd --color 1D76DB --description "Product requirements document"
gh label create needs-spec --color FBCA04 --description "Spec needs clarification"
gh label create needs-review --color D93F0B --description "Failed 3 attempts, needs human"
gh label create in-progress --color 6F42C1 --description "Worker actively implementing"
gh label create P0 --color B60205 --description "Critical priority"
gh label create P1 --color FF9F1C --description "High priority"
gh label create P2 --color 0075CA --description "Normal priority"
gh label create mechanical --color C5DEF5 --description "Haiku-tier complexity"
gh label create standard --color BFD4F2 --description "Sonnet-tier complexity"
gh label create architecture --color 0052CC --description "Opus-tier complexity"
```

---

## What's Deprecated

- **`.agent/tasks/`** — Old file-based task queue. Do not create or read.
- **`.agent/scores/`** — Old per-task scorecards. Scoring now happens via PR comments.
- **`task/task-NNN` branches** — Old branch naming. Now `issue/<number>`.
- **`feat(task-NNN):` commits** — Old commit format. Now `feat(#<number>):`.
