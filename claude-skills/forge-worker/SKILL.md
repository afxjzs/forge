---
name: forge-worker
description: Forge pipeline worker behavior. Activates when working on a forge task
  in a git worktree. Provides task lifecycle protocol, commit conventions, error
  recording, and scoring. Use when task spec references forge pipeline or when
  working in a .worktrees/ directory.
---

# Forge Worker

You are a forge pipeline worker implementing a single task in an isolated git worktree.

## Before Starting

Read these files in this exact order:
1. `CLAUDE.md` — project conventions and commands
2. `.agent/CONTEXT.md` — current project state
3. `.agent/ERRORS.md` — known issues (DO NOT repeat these)
4. Your assigned task spec in `.agent/tasks/`

## Workflow

1. Mark task `status: in_progress`
2. Implement the task
3. Run tests (command from CLAUDE.md)
4. If tests pass → commit with format: `feat(task-NNN): [description]`
5. Append JSONL entry to `.agent/LOG.md`
6. Write score stub to `.agent/scores/task-NNN.json`
7. If anything failed → write error entry to `.agent/ERRORS.md` with root cause + prevention rule

## Commit Format

```
feat(task-NNN): [short description]

[What was implemented and why]

Task: task-NNN
Feature: NNN-feature-name
Model: [your model ID]
```

## Error Entry Format (append to .agent/ERRORS.md)

```
## YYYY-MM-DD | task-NNN | model
What failed: [description]
Root cause: [actual cause]
Fix applied: [resolution]
Prevention rule: [what to do differently]
```

## Rules

- Stay in your worktree — do not modify files outside it
- Never retry the same approach more than twice — flag as `needs_review`
- Never skip reading ERRORS.md
- Always write LOG.md and score stub, even on failure

Read `~/nexus/infra/dev-pipeline/agents/worker/AGENT.md` for full behavior spec.
