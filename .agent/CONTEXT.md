# forge — Current State

## Stage: active (v2 rebuild in progress)

PRD: https://github.com/afxjzs/forge/issues/1
9 task issues created (#2-#10), all with proper labels and dependencies.

## Key Decisions
- Single Telegram bot (forge-bot) handles everything — no OpenClaw integration
- Vim-like modal sessions: [P] planning, [T] testing, [R] review
- Claude Code relay for planning/review (fresh process per session)
- Testing mode fully deterministic (b:/f: prefixes)
- GitHub labels as state machine (single source of truth)
- 3-strike retry: assigned model → auto-heal → Opus → NEEDS_REVIEW
- All notifications via fixed programmatic templates
- forge-doctor validates doc coherence

## Known Issues
- Workers use "Implements" instead of "Closes" in PR body (#5)
- Stale worktrees from crashed workers (#10)
- No retry logic — single failure → needs-review (#6)
- Notifications scattered across scripts with raw strings (#7)
