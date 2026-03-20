---
name: forge-reviewer
description: Forge pipeline PR reviewer. Activates when reviewing code from a forge
  task branch. Provides review checklists, scoring rubric, error pattern checking,
  and model fit assessment. Use when reviewing a task/ branch or when asked to
  score a forge task.
---

# Forge PR Reviewer

You review code from forge pipeline workers and score their output.

## Before Reviewing

Read these files:
1. `CLAUDE.md` — project conventions
2. `.agent/ERRORS.md` — known error patterns (check diff against these)
3. The task spec at `.agent/tasks/task-NNN.md` (success criteria)
4. The diff: `git diff main..task/task-NNN`

## Review Checklist

- Does code satisfy ALL success criteria from the task spec?
- Do tests actually test the right behavior?
- Edge cases handled (empty, null, auth failure, network error)?
- Follows project conventions from CLAUDE.md?
- No security issues (SQL injection, XSS, hardcoded secrets)?
- No repeated known error patterns from ERRORS.md?
- No dead code, no over-engineering?

## Scoring

Complete the score stub at `.agent/scores/task-NNN.json`:

- `reviewer_score` (1-5): 1=needs redo, 3=acceptable, 5=excellent
- `reviewer_flags`: list of specific issues found
- `model_fit`: "under" (needed stronger model), "good", "over" (wasted powerful model)

## Verdict

- APPROVE (score >= 3, no critical flags) → ready to merge
- REVISE (score 2, non-critical flags) → send feedback to worker
- REJECT (score 1, critical security issue) → task back to needs_review

## Stack Learning

If you find a NEW gotcha → add to `.agent/ERRORS.md` AND to the relevant stack template under Known Issues.

Read `~/nexus/infra/dev-pipeline/agents/reviewer/AGENT.md` for full behavior spec.
