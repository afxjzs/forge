# forge — Global Learnings

Cross-project patterns, orchestrator failures, model tier insights.
Append-only. Never delete entries — mark obsolete with `~~strikethrough~~`.

---

## 2026-03-15 | forge-worker.sh merged directly into main
**What failed:** forge-worker.sh was written to merge worker branches directly into main. User explicitly stated "the last step will be me finally merging into the production branch" — this directive was ignored during implementation.
**Root cause:** Builder (Claude) implemented the fastest path (direct merge) instead of following the stated requirement (PR-based review flow).
**Fix applied:** Rewrote forge-worker.sh to: create PRs targeting staging → auto-merge to staging after CI passes → user reviews live staging app → user says "ship X" to promote staging→main→production.
**Prevention rule:** When a user states a hard requirement about control flow (who merges, who approves, who deploys), implement it as stated. Never take shortcuts on human-in-the-loop gates. Test the exact flow before running on real projects.
**Damage:** 6+ commits merged directly into omnilingo main without PR review.
**Current model (updated):** PRs auto-merge to staging (no approval needed). ONLY staging→main promotion requires user approval ("ship X"). Never tell the user PRs need their approval.

## 2026-03-15 | Tasks marked done despite PR creation failure
**What failed:** Tasks 018-022 in omnilingo pushed branches but `gh pr create` failed silently. Tasks were marked `done` anyway. Code sat orphaned on remote branches — fixes never deployed.
**Root cause:** forge-worker.sh marked task status as `done` unconditionally after a commit, even when PR creation failed. The error was caught but only printed a warning. Also `$PROJECT_NAME` was undefined in the script, causing staging deploy triggers to fail.
**Fix applied:** Task now marked `needs_review` if PR creation fails. Telegram alert sent on failure. Added `$PROJECT_NAME` variable. Created forge-check-orphans.sh to detect stranded branches.
**Prevention rule:** Never advance pipeline state (task done, deploy complete, etc.) without verifying the actual artifact exists (PR created, container running, etc.). Silent failures that advance state are the worst kind of bug — they look like success.

## 2026-03-16 | Workers treated auth failure as task failure
**What failed:** When Anthropic logs the user out, `claude` CLI fails with exit code 1. Workers marked tasks as `needs_review` instead of recognizing this as a system-wide issue. The pipeline burned through 3 tasks before the circuit breaker tripped, each needlessly marked as failed.
**Root cause:** No auth pre-flight check before spawning workers. All non-zero exit codes treated identically. No stderr parsing to distinguish auth errors from execution errors.
**Fix applied:** Added pre-flight auth check (`claude -p "echo ok"`) in both forge-run.sh and forge-worker.sh. Auth failures return exit code 99. forge-run.sh stops immediately on exit 99, sends Telegram alert with login instructions, and does NOT mark the task as failed (reverts to queued). Also captures stderr during execution to detect mid-run logouts.
**Prevention rule:** System-wide failures (auth, network, disk full) must be distinguished from task-specific failures. A task should never be penalized for an environment problem it can't control. Pre-flight checks before expensive operations.

## 2026-03-16 | PM bot deployed directly to production — skipped staging entirely
**What failed:** The Telegram PM bot called `POST /deploy {"environment":"production"}` without deploying to staging first. It treated "deploy" as "deploy to production" and pushed untested code to the live production container.
**Root cause:** (1) The skill file mapped "deploy X" to production by default. (2) The API had no guard — it accepted production deploys even when staging had never been tested. (3) The PM had no hard rule distinguishing "deploy" from "ship".
**Fix applied:** (1) Skill file: "deploy X" now defaults to staging. Only "ship X" triggers production. Added hard rule #8. (2) API: production deploys now rejected unless staging.json exists AND E2E tests have been run. (3) PM agent doc updated with "CRITICAL: deploy=staging, ship=production" rule.
**Prevention rule:** Production deploys must be gated at BOTH the documentation layer (agent instructions) AND the enforcement layer (API validation). Never rely on the agent "knowing" the right thing — enforce it in code. The word "deploy" must NEVER mean production.

## 2026-03-16 | Telegram bot systematically ignoring forge rules
**What failed:** The OpenClaw bot (main agent) repeatedly violated forge rules: deployed to production without staging, didn't send PR review notifications, dropped [project-name] prefix, skipped interview steps. Every time the user checked, something was wrong.
**Root cause:** Three compounding failures: (1) Silent model fallback from Sonnet→Haiku when Sonnet was overloaded — Haiku can't follow complex rulesets. (2) All forge logic ran on the `main` agent which handles 15+ skills in a crowded context window — rules got truncated or ignored. (3) Notification failures in forge-run.sh were suppressed with `|| true`, so the user was never alerted.
**Fix applied:** (1) Removed ALL automatic model fallbacks from every OpenClaw agent — empty `"fallbacks": []`. If model unavailable, request fails visibly. (2) Restructured forge skill: SKILL.md is now a thin dispatch layer that routes to `forge-pm` agent; full PM instructions moved to FORGE-PM.md. (3) Replaced all `|| true` on notification calls with a `notify()` helper that logs failures to ERRORS.md. (4) Added no-fallback and no-silent-failure rules to AGENT-PREFERENCES.md.
**Prevention rules:** (A) NEVER configure automatic model fallbacks — visible failure > silent degradation. (B) NEVER suppress errors with `|| true` on important operations — log them, alert on them, or fail the parent. (C) Complex agent behaviors should run on dedicated agents with focused context, not on the main agent that handles everything.
