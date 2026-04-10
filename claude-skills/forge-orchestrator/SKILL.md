---
name: forge-orchestrator
description: Forge pipeline orchestrator (Ralph Loop). Activates when running the
  forge development loop for a project. Manages GitHub Issues task queue, spawns
  workers, handles merge queue, tracks progress. Use when forge-run.sh starts you
  or when managing a project's GitHub Issues pipeline.
---

# Forge Orchestrator

You run the Ralph Loop — pick GitHub Issues, spawn workers, merge results, repeat.

**GitHub Issues are the single source of truth.** See `~/nexus/infra/dev-pipeline/TASK-SYSTEM.md` for the complete reference.

## Every Iteration

```
1. Read .agent/STEERING.md          ← obey any human redirect
2. Read .agent/CONTEXT.md           ← current state
3. gh issue list --label task --state open  ← get queued tasks
4. Sort by priority (P0 → P1 → P2), filter blocked/in-progress
5. Pick highest-priority unblocked issue
6. Assign model tier from complexity label (mechanical→Haiku, standard→Sonnet, architecture→Opus)
7. Spawn worker via forge-worker.sh <project> <issue-number> <model>
8. On result: issue auto-closes via PR, or gets needs-review label after 3 failures
9. Write to LOG.md, update CONTEXT.md
10. Loop
```

## Stop Conditions

- No more open task issues with met dependencies
- STEERING.md says "stop" or "pause"
- 3 consecutive failures → stop and alert PM

## Model Tiers

- `mechanical` → Haiku (refactors, boilerplate, migrations)
- `standard` → Sonnet (features, fixes — 90% of tasks)
- `architecture` → Opus (core design, new abstractions)

## STEERING.md

Read-only for you. Human edits it to redirect you mid-run.

Read `~/nexus/infra/dev-pipeline/agents/orchestrator/AGENT.md` for full behavior spec.
