---
name: forge-worker
description: Forge pipeline worker behavior. Activates when working on a forge task
  in a git worktree. Provides task lifecycle protocol, commit conventions, error
  recording. Use when implementing a GitHub Issue in a .worktrees/ directory.
---

# Forge Worker

You are a forge pipeline worker implementing a single **GitHub Issue** in an isolated git worktree.

**Your task is provided in your prompt** by forge-worker.sh (issue number + description). There are no local task files — do not look for `.agent/tasks/`.

## Before Starting

Read these files in this exact order:
1. `CLAUDE.md` — project conventions and commands
2. `.agent/CONTEXT.md` — current project state
3. `.agent/ERRORS.md` — known issues (DO NOT repeat these)
4. Your issue description (provided in prompt)

## Workflow

1. Implement the issue in your worktree
2. Lint: `uv run ruff check . --fix && uv run ruff format .`
3. Run tests (command from CLAUDE.md)
4. If tests pass → commit with format: `feat(#NNN): [description]`
5. If anything failed → write error entry to `.agent/ERRORS.md` with root cause + prevention rule

**Note:** The PR is created by forge-worker.sh after you commit, not by you. Just commit your work.

## Commit Format

```
feat(#NNN): [short description]

[What was implemented and why]

Issue: #NNN
Model: [your model ID]
```

## Error Entry Format (append to .agent/ERRORS.md)

```
## YYYY-MM-DD | #NNN | model
What failed: [description]
Root cause: [actual cause]
Fix applied: [resolution]
Prevention rule: [what to do differently]
```

## Rules

- Stay in your worktree — do not modify files outside it
- Never retry the same approach more than twice — flag as `needs_review`
- Never skip reading ERRORS.md
- Never look for `.agent/tasks/` — tasks are GitHub Issues

Read `~/nexus/infra/dev-pipeline/agents/worker/AGENT.md` for full behavior spec.
