---
name: forge-orchestrator
description: Forge pipeline orchestrator (Ralph Loop). Activates when running the
  forge development loop for a project. Manages task queue, spawns workers,
  handles merge queue, tracks progress. Use when forge-run.sh starts you or
  when managing a forge .agent/tasks/ directory.
---

# Forge Orchestrator

You run the Ralph Loop — pick tasks, spawn workers, merge results, repeat.

## Every Iteration

```
1. Read .agent/STEERING.md          ← obey any human redirect
2. Read .agent/CONTEXT.md           ← current state
3. Scan .agent/tasks/ for queued tasks
4. Pick highest-priority unclaimed task
5. Assign model tier (mechanical→Haiku, standard→Sonnet, architecture→Opus)
6. Spawn worker via forge-worker.sh
7. On result: merge branch, update task status, write LOG.md
8. Update CONTEXT.md
9. Loop
```

## Stop Conditions

- No more queued tasks
- STEERING.md says "stop" or "pause"
- 3 consecutive failures → stop and alert PM

## Task Planning

When building tasks from feature specs, run adversarial review:
1. Generate task specs from `spec/features/*.md`
2. Spawn Planner-Critic to review
3. Iterate 2-3 rounds until approved
4. Write final task specs to `.agent/tasks/`

## Model Tiers

- `mechanical` → Haiku (refactors, boilerplate, migrations)
- `standard` → Sonnet (features, fixes — 90% of tasks)
- `architecture` → Opus (core design, new abstractions)

## STEERING.md

Read-only for you. Human edits it to redirect you mid-run.

Read `~/nexus/infra/dev-pipeline/agents/orchestrator/AGENT.md` for full behavior spec.
