#!/usr/bin/env bash
set -euo pipefail

# forge-worker.sh — Spawn a single worker for a GitHub Issue
#
# Usage: forge-worker.sh <project-path> <issue-number> <model>
#
# Reads issue body from GitHub, creates a git worktree, runs Claude Code,
# creates PR that closes the issue, auto-merges to staging after CI passes.
#
# Exit codes:
#   0  = success (PR created and merged)
#   1  = failure (error during execution)
#   2  = needs_review (worker flagged for human review)
#   99 = auth failure (Claude not logged in)

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"
SCRIPTS_DIR="$FORGE_ROOT/scripts"

# Load env vars if running outside systemd
[[ -f "$FORGE_ROOT/.env" ]] && set -a && source "$FORGE_ROOT/.env" && set +a
WORKER_PROMPT="$FORGE_ROOT/agents/worker/AGENT.md"
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

[[ $# -lt 3 ]] && { echo "Usage: forge-worker.sh <project-path> <issue-number> <model>"; exit 1; }

PROJECT_PATH="$(realpath "$1")"
ISSUE_NUMBER="$2"
MODEL="$3"
PROJECT_NAME="$(basename "$PROJECT_PATH")"

WORKTREE_DIR="$PROJECT_PATH/.worktrees/issue-$ISSUE_NUMBER"
BRANCH_NAME="issue/$ISSUE_NUMBER"

# --- Cleanup trap: ensure worktree removal on all exits ---
cleanup_worktree() {
    cd "$PROJECT_PATH" 2>/dev/null || true
    if [[ -d "$WORKTREE_DIR" ]]; then
        if ! git worktree remove "$WORKTREE_DIR" --force 2>/dev/null; then
            rm -rf "$WORKTREE_DIR" 2>/dev/null || true
        fi
    fi
}
trap cleanup_worktree EXIT

# --- Helper: send structured event notification (NEVER swallow failures) ---
notify_event() {
    if ! "$SCRIPTS_DIR/forge-notify-event.sh" "$@"; then
        echo "ERROR: Notification FAILED for event: $*" >&2
        echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) | NOTIFICATION_FAILURE" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "**Event that failed to send:** $*" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "" >> "$PROJECT_PATH/.agent/ERRORS.md"
    fi
}

# --- Read issue from GitHub ---
echo "Reading issue #$ISSUE_NUMBER..."
cd "$PROJECT_PATH"
ISSUE_JSON=$(gh issue view "$ISSUE_NUMBER" --json title,body,labels 2>&1) || {
    echo "Error: Could not read issue #$ISSUE_NUMBER"
    exit 1
}
ISSUE_TITLE=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
ISSUE_BODY=$(echo "$ISSUE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")

echo "Issue: #$ISSUE_NUMBER — $ISSUE_TITLE"

# --- Create git worktree ---
echo "Creating worktree..."
mkdir -p "$PROJECT_PATH/.worktrees"
git branch "$BRANCH_NAME" staging 2>/dev/null || true
if [[ -d "$WORKTREE_DIR" ]]; then
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi
git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"

# --- Build worker prompt ---
STACK=$(grep -m1 "^## Stack" -A2 "$PROJECT_PATH/CLAUDE.md" 2>/dev/null | tail -1 | xargs || echo "unknown")
STACK_FILE="$FORGE_ROOT/templates/stacks/$STACK.md"
STACK_ISSUES=""
if [[ -f "$STACK_FILE" ]]; then
    STACK_ISSUES=$(sed -n '/## Known Issues/,/^## /p' "$STACK_FILE" | head -30)
fi

WORKER_INSTRUCTIONS=$(cat "$WORKER_PROMPT")
ERRORS_CONTENT=""
[[ -f "$PROJECT_PATH/.agent/ERRORS.md" ]] && ERRORS_CONTENT=$(tail -50 "$PROJECT_PATH/.agent/ERRORS.md")

FULL_PROMPT="You are a forge pipeline worker implementing GitHub Issue #$ISSUE_NUMBER.

PROJECT: $PROJECT_PATH
ISSUE: #$ISSUE_NUMBER — $ISSUE_TITLE
WORKTREE: $WORKTREE_DIR
MODEL: $MODEL

## Issue Description
$ISSUE_BODY

## Known Issues (DO NOT REPEAT THESE)
$ERRORS_CONTENT

## Stack Known Issues
$STACK_ISSUES

## Instructions
1. Read CLAUDE.md for project conventions and commands
2. Read .agent/CONTEXT.md for current state
3. Implement the issue in your worktree
4. Run \`uv run ruff check . --fix && uv run ruff format .\` in each package dir you changed (bot/, api/, etc.)
5. Run tests (command from CLAUDE.md)
6. Commit with format: feat(#$ISSUE_NUMBER): [description]
7. If anything fails: write error entry to .agent/ERRORS.md

IMPORTANT: Work ONLY in the worktree at $WORKTREE_DIR.
IMPORTANT: Lint is mandatory. CI WILL reject your PR if ruff fails. Lint before committing.
The PR will reference 'Closes #$ISSUE_NUMBER' to auto-close the issue.
If you fail the same approach twice, exit and the issue will be flagged for review."

# --- Pre-flight auth check ---
echo "Checking Claude authentication..."
AUTH_CHECK=$(claude -p "echo ok" 2>&1) || true
if echo "$AUTH_CHECK" | grep -qiE "not logged in|not authenticated|session expired|login required|unauthorized|sign in|apikey"; then
    echo "FATAL: Claude CLI is not authenticated."
    cd "$PROJECT_PATH"
    git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    exit 99
fi
echo "Auth OK."

# --- Run Claude Code ---
echo "Starting Claude Code worker ($MODEL)..."
echo ""

# Unset ANTHROPIC_API_KEY so Claude Code uses its own OAuth session, not the bot's API key
unset ANTHROPIC_API_KEY

CLAUDE_STDERR_FILE=$(mktemp)
set +e
claude \
    --model "$MODEL" \
    --append-system-prompt "$WORKER_INSTRUCTIONS" \
    --dangerously-skip-permissions \
    -p \
    "$FULL_PROMPT" \
    2> >(tee "$CLAUDE_STDERR_FILE" >&2)

CLAUDE_EXIT=$?
# Do NOT re-enable set -e here. The remaining code (CI checks, merge, cleanup)
# uses if-blocks for error handling. set -e would cause gh/git failures to
# kill the script before our error handling runs (e.g., exit code 8 from
# gh pr merge when checks are still pending).

# --- Check for auth failure mid-run ---
if [[ $CLAUDE_EXIT -ne 0 ]]; then
    if grep -qiE "not logged in|not authenticated|session expired|login required|unauthorized" "$CLAUDE_STDERR_FILE" 2>/dev/null; then
        echo "FATAL: Claude authentication lost during execution."
        rm -f "$CLAUDE_STDERR_FILE"
        cd "$PROJECT_PATH"
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
        exit 99
    fi
fi
rm -f "$CLAUDE_STDERR_FILE"

# --- Check if worker committed ---
cd "$WORKTREE_DIR" 2>/dev/null || true
COMMITTED=false
if git log --oneline staging.."$BRANCH_NAME" 2>/dev/null | grep -q .; then
    COMMITTED=true
fi

FINAL_STATUS="failed"

# --- Create PR if committed ---
if $COMMITTED; then
    echo ""
    echo "Worker committed. Pushing branch and creating PR..."
    cd "$WORKTREE_DIR"

    git push origin "$BRANCH_NAME" --force-with-lease 2>&1 || {
        echo "Warning: Could not push to remote."
    }

    # Check if an OPEN PR already exists for this branch (ignore closed/merged)
    PR_URL=$(gh pr view "$BRANCH_NAME" --json url,state -q 'select(.state == "OPEN") | .url' 2>/dev/null || true)
    if [[ -z "$PR_URL" ]]; then
        DIFF_STAT=$(git diff --stat staging.."$BRANCH_NAME" 2>/dev/null || true)
        FILES_CHANGED=$(git diff --name-only staging.."$BRANCH_NAME" 2>/dev/null || true)
        FILE_GROUPS=$(echo "$FILES_CHANGED" | sed 's|/[^/]*$||' | sort -u | while read -r dir; do
            count=$(echo "$FILES_CHANGED" | grep "^$dir/" | wc -l)
            echo "- \`$dir/\` ($count files)"
        done)

        PR_BODY="## Summary

$ISSUE_BODY

## Where to Look

$FILE_GROUPS

<details>
<summary>Diff stat</summary>

\`\`\`
$DIFF_STAT
\`\`\`
</details>

---
🤖 forge pipeline | Model: \`$MODEL\`

Closes #$ISSUE_NUMBER"

        PR_URL=$(gh pr create \
            --title "$ISSUE_TITLE" \
            --body "$PR_BODY" \
            --head "$BRANCH_NAME" \
            --base staging \
            2>&1) || {
            echo "ERROR: PR creation failed."
            PR_URL=""
        }
    fi

    if [[ -n "$PR_URL" ]]; then
        echo "PR: $PR_URL"
        PR_NUMBER=$(echo "$PR_URL" | grep -oP '\d+$' || true)

        if [[ -n "$PR_NUMBER" ]]; then
            # Wait for CI, then auto-merge
            CI_PASSED=false

            # Fast path: if no CI workflows exist, skip the wait entirely
            if [[ ! -d "$PROJECT_PATH/.github/workflows" ]] || [[ -z "$(ls "$PROJECT_PATH/.github/workflows/"*.yml 2>/dev/null)" ]]; then
                echo "No CI workflows configured — skipping check wait."
                CI_PASSED=true
            else
                echo "Waiting for CI checks on PR #$PR_NUMBER..."
                MAX_WAIT=600
                WAITED=0

                while [[ $WAITED -lt $MAX_WAIT ]]; do
                    CHECK_STATUS=$(gh pr checks "$PR_NUMBER" 2>&1)
                    GH_EXIT=$?

                    # "no checks reported" returns exit code 1 — not an error
                    if echo "$CHECK_STATUS" | grep -qi "no checks"; then
                        CI_PASSED=true
                        echo "No CI checks reported — proceeding."
                        break
                    fi

                    if [[ $GH_EXIT -ne 0 ]]; then
                        echo "WARNING: gh pr checks returned exit $GH_EXIT — retrying"
                        sleep 15
                        WAITED=$((WAITED + 15))
                        continue
                    fi

                    if echo "$CHECK_STATUS" | grep -q "fail"; then
                        echo "CI FAILED:"
                        echo "$CHECK_STATUS"
                        FINAL_STATUS="needs_review"
                        break
                    fi

                    if echo "$CHECK_STATUS" | grep -q "pass" && ! echo "$CHECK_STATUS" | grep -q "pending"; then
                        CI_PASSED=true
                        echo "CI passed."
                        break
                    fi

                    sleep 15
                    WAITED=$((WAITED + 15))
                    echo "  CI pending... ($WAITED/${MAX_WAIT}s)"
                done

                if [[ $WAITED -ge $MAX_WAIT ]] && ! $CI_PASSED; then
                    echo "CI timed out after ${MAX_WAIT}s. PR created but not merged."
                    FINAL_STATUS="needs_review"
                fi
            fi

            if $CI_PASSED; then
                echo "CI passed. Auto-merging to staging..."
                if gh pr merge "$PR_NUMBER" --merge --delete-branch 2>&1; then
                    notify_event pr_merged --project "$PROJECT_NAME" --pr "$PR_NUMBER"

                    # Close the issue (GitHub auto-close only works on default branch,
                    # but PRs target staging, not main)
                    echo "Closing issue #$ISSUE_NUMBER..."
                    if ! gh issue close "$ISSUE_NUMBER" 2>&1; then
                        echo "WARNING: Could not close issue #$ISSUE_NUMBER" >&2
                    fi
                else
                    echo "ERROR: Auto-merge failed for PR #$PR_NUMBER" >&2
                    notify_event needs_review --project "$PROJECT_NAME" --issue "$ISSUE_NUMBER" --error "PR #$PR_NUMBER merge FAILED — needs manual merge"
                fi

                # Trigger staging deploy
                echo "Triggering staging deploy..."
                if ! curl -s -X POST "http://127.0.0.1:8773/projects/$PROJECT_NAME/deploy" \
                    -H "Content-Type: application/json" \
                    -d '{"environment":"staging"}' \
                    2>&1; then
                    echo "ERROR: Staging deploy trigger failed" >&2
                fi

                FINAL_STATUS="done"
            fi
        fi
    else
        echo "ERROR: Branch pushed but PR creation failed."
        notify_event needs_review --project "$PROJECT_NAME" --issue "$ISSUE_NUMBER" --error "branch pushed but PR creation failed"
        FINAL_STATUS="needs_review"
    fi
fi

# --- Cleanup worktree (always, on success or failure) ---
cd "$PROJECT_PATH"
echo "Cleaning up worktree..."

# Try normal removal first
if git worktree remove "$WORKTREE_DIR" --force 2>/dev/null; then
    echo "  Worktree removed cleanly."
else
    echo "  git worktree remove failed, attempting force cleanup..." >&2
    # If git removal fails, force-delete the directory
    if [[ -d "$WORKTREE_DIR" ]]; then
        rm -rf "$WORKTREE_DIR"
        echo "  Worktree directory forcefully removed."
    fi
fi

# Prune any stale branches (in case of abrupt failures)
if ! git branch -D "$BRANCH_NAME" 2>/dev/null; then
    true  # Branch may already be deleted, that's OK
fi

echo ""
echo "Worker result: $FINAL_STATUS"

case "$FINAL_STATUS" in
    done)         exit 0 ;;
    needs_review) exit 2 ;;
    *)            exit 1 ;;
esac
