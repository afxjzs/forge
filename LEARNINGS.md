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

## 2026-04-03 | forge-prd-to-issues spec assessment fails 91% of tasks on new projects
**What failed:** First run of `forge-prd-to-issues.sh` on a new project (conga) resulted in 21/23 tasks flagged as `needs-spec`. The spec assessment gate was unusable — every task needed manual relabeling.
**Root cause:** Three compounding issues: (1) File existence check flagged files that don't exist YET but will be CREATED by the task or its dependencies. On a brand new project, nothing exists. (2) The Haiku LLM clarity check received zero project context — no CLAUDE.md, no PRD, no architecture decisions. So it asked questions already answered in CLAUDE.md (e.g., "which ORM?" when CLAUDE.md says SQLAlchemy). (3) The Haiku prompt said "Be strict" which caused it to fail everything on a new project.
**Fix applied:** (1) File check now skips files under standard source paths (`app/`, `src/`, `lib/`, `tests/`, `scripts/`), bare filenames without directory paths, and files near create-type verbs in the task body. (2) Haiku clarity check now receives the full CLAUDE.md as context and is told not to flag decisions already documented, library API questions the agent can discover, or file references for files being created. (3) Task generation prompt now tells Sonnet to make each task body self-contained with specific technical details. Result: 16/18 passed (89%) on re-run.
## 2026-04-03 | forge-worker.sh merge + close failures cause cascading retry waste
**What failed:** After a worker successfully implemented an issue, the PR merge (`gh pr merge`) returned non-zero (checks still registering). This triggered: (1) "merge FAILED" notification even though the merge actually succeeded moments later, (2) issue never closed because `gh issue close` was inside the merge-success branch, (3) pipeline re-picked the open issue, spawned 3 more workers that found nothing to do, wasted 9 Opus-tier attempts across 3 issues.
**Root cause:** Three compounding failures: (1) `gh pr merge` is not idempotent — transient GitHub API timing causes false failures. No retry logic. (2) `gh issue close` only ran inside the merge-success path — if merge "failed" (but actually succeeded), issue was never closed. "Closes #N" in PR body doesn't auto-close on staging branch merges, only default branch. (3) Ralph Loop (`forge-run.sh`) had no pre-check for already-completed work — if an issue was open but its PR was already merged, it spawned a worker anyway.
**Fix applied:** (1) Merge now retries 3× with 10s backoff, then verifies actual PR state via `gh pr view --json state`. (2) Issue close retries 3× with 5s backoff, logs CRITICAL to ERRORS.md if all attempts fail. (3) `forge-run.sh` pre-checks for merged PRs before spawning workers — if `gh pr list --state merged --head issue/N` returns a result, it closes the issue and skips. (4) Staging deploy failure no longer blocks task completion (FINAL_STATUS="done" set before deploy).
**Prevention rules:** (A) Any GitHub API write operation (`gh pr merge`, `gh issue close`, `gh issue edit`) must retry with backoff — GitHub's API has transient failures. (B) Always verify actual state after a failed write — the operation may have succeeded despite the error. (C) The pipeline must be idempotent — re-running on an already-completed issue must be a no-op, not a 9-attempt failure cascade.

**Prevention rules:** (A) Spec assessment must always include CLAUDE.md context — the whole point of the design interview is to pre-answer these questions. (B) File existence checks must distinguish "read dependency" from "file to create" — new projects have no files. (C) Never tell an assessment LLM to "be strict" without giving it the full decision context — strictness without context is just noise.
