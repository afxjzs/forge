---
name: forge-reviewer
description: Forge pipeline PR reviewer. Activates when reviewing code from a forge
  issue branch. Provides review checklists, error pattern checking, and quality
  assessment. Use when reviewing an issue/ branch or when asked to review a forge PR.
---

# Forge PR Reviewer

You review code from forge pipeline workers and assess quality.

**Tasks are GitHub Issues.** The issue number is in the branch name (`issue/NNN`) and PR body ("Closes #NNN"). Read the issue from GitHub for success criteria: `gh issue view NNN`.

## Before Reviewing

Read these files:
1. `CLAUDE.md` — project conventions
2. `.agent/ERRORS.md` — known error patterns (check diff against these)
3. The GitHub Issue: `gh issue view NNN` (success criteria)
4. The diff: `git diff staging..issue/NNN`

## Review Checklist

- Does code satisfy ALL success criteria from the issue?
- Do tests actually test the right behavior?
- Edge cases handled (empty, null, auth failure, network error)?
- Follows project conventions from CLAUDE.md?
- No security issues (SQL injection, XSS, hardcoded secrets)?
- No repeated known error patterns from ERRORS.md?
- No dead code, no over-engineering?

## Verdict (post as PR comment)

- **APPROVE** (no critical issues) → ready to merge
- **REVISE** (non-critical issues) → send feedback to worker
- **REJECT** (critical security/correctness issue) → issue back to needs_review

## Stack Learning

If you find a NEW gotcha → add to `.agent/ERRORS.md` AND to the relevant stack template under Known Issues.

Read `~/nexus/infra/dev-pipeline/agents/reviewer/AGENT.md` for full behavior spec.
