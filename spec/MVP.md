# forge MVP

## Problem
Agentic dev pipeline that turns PRDs into deployed code. Two loops: human interaction via Telegram (planning, feedback, review) and autonomous worker loop (implements issues, creates PRs, deploys to staging).

## Core Principle
Programmatic foundation with thin LLM layer. Every routing decision, notification, and state transition is deterministic. AI is only used for creative work: planning conversations, code generation, spec assessment.

## Stack
- API: FastAPI (Python) — port 8773
- Bot: python-telegram-bot — port 8774
- Workers: Claude Code CLI subprocesses in git worktrees
- State: GitHub Issues + labels (single source of truth)
- Notifications: Telegram via forge-bot

## What "Done" Looks Like
1. Single Telegram bot with modal sessions ([P] planning, [T] testing, [R] review)
2. Testing mode is fully deterministic (b:/f: prefixes, no LLM)
3. Claude Code relay for planning and review conversations
4. Ralph Loop picks up GitHub Issues, spawns workers, auto-heals on failure
5. 3-strike retry with model escalation before human review
6. All notifications are programmatic templates — no LLM decides what to say
7. GitHub labels are the state machine — single source of truth
8. forge-doctor validates documentation coherence
9. No silent failures, no hardcoded secrets
