#!/usr/bin/env bash
set -euo pipefail

# forge-run.sh — Execute the Ralph Loop using GitHub Issues as the task queue
#
# Reads open issues labeled 'task' from the project's GitHub repo.
# Picks highest priority, spawns worker, worker's PR closes the issue.
#
# Usage: forge-run.sh <project-path> [--dry-run]

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"
SCRIPTS_DIR="$FORGE_ROOT/scripts"

# Load env vars if running outside systemd
[[ -f "$FORGE_ROOT/.env" ]] && set -a && source "$FORGE_ROOT/.env" && set +a
MAX_CONSECUTIVE_FAILURES=3

usage() {
    echo "Usage: forge-run.sh <project-path> [--dry-run]"
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT_PATH="$(realpath "$1")"
PROJECT_NAME="$(basename "$PROJECT_PATH")"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

# --- Helper: send structured event notification (NEVER swallow failures) ---
notify_event() {
    if ! "$SCRIPTS_DIR/forge-notify-event.sh" "$@"; then
        echo "ERROR: Telegram notification FAILED for event: $*" >&2
        echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) | NOTIFICATION_FAILURE" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "**Event that failed to send:** $*" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "" >> "$PROJECT_PATH/.agent/ERRORS.md"
        return 1
    fi
}

# --- Helper: edit GitHub issue labels (logs failures instead of swallowing) ---
gh_label() {
    local issue="$1"
    shift
    if ! gh issue edit "$issue" "$@" 2>&1; then
        echo "WARNING: gh issue edit #$issue $* failed" >&2
        echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) | GH_LABEL_FAILURE" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "**Failed command:** gh issue edit #$issue $*" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "" >> "$PROJECT_PATH/.agent/ERRORS.md"
        return 1
    fi
}

# --- Helper: read steering directive ---
read_steering() {
    local steering_file="$PROJECT_PATH/.agent/STEERING.md"
    [[ -f "$steering_file" ]] || { echo "continue"; return; }
    local directive
    directive=$(grep -m1 "Current directive:" "$steering_file" 2>/dev/null \
        | sed 's/.*\*\*//;s/\*\*.*//' \
        | tr '[:upper:]' '[:lower:]' \
        | xargs)
    echo "${directive:-continue}"
}

# --- Helper: get open task issues sorted by priority ---
get_next_issue() {
    cd "$PROJECT_PATH"
    # Get open issues labeled 'task', sorted by priority labels
    # P0 first, then P1, then P2, then unlabeled
    local issues
    issues=$(gh issue list --label task --state open --json number,title,labels,body --limit 50 2>/dev/null) || { echo ""; return; }

    # Pick the highest priority unblocked issue (pipe JSON via stdin to avoid quoting issues)
    echo "$issues" | python3 -c "
import json, sys

issues = json.loads(sys.stdin.read())
if not issues:
    sys.exit(0)

def priority(issue):
    labels = [l['name'] for l in issue.get('labels', [])]
    if 'in-progress' in labels: return 99  # skip already in-progress
    if 'P0' in labels: return 0
    if 'P1' in labels: return 1
    if 'P2' in labels: return 2
    return 3

def is_blocked(issue):
    body = issue.get('body', '') or ''
    import re
    blocked_refs = re.findall(r'Blocked by #(\d+)', body, re.IGNORECASE)
    for ref in blocked_refs:
        for other in issues:
            if other['number'] == int(ref):
                return True
    return False

def complexity(issue):
    labels = [l['name'] for l in issue.get('labels', [])]
    if 'architecture' in labels: return 'architecture'
    if 'mechanical' in labels: return 'mechanical'
    return 'standard'

# Sort by priority, filter out in-progress and blocked
candidates = [i for i in issues if priority(i) < 99 and not is_blocked(i)]
candidates.sort(key=priority)

if candidates:
    best = candidates[0]
    print(json.dumps({
        'number': best['number'],
        'title': best['title'],
        'complexity': complexity(best),
        'priority': priority(best),
    }))
"
}

# --- Helper: determine model from complexity ---
task_model() {
    local complexity="$1"
    case "${complexity:-standard}" in
        mechanical)   echo "claude-haiku-4-5-20251001" ;;
        architecture) echo "claude-opus-4-6" ;;
        *)            echo "claude-sonnet-4-6" ;;
    esac
}

# --- Helper: cleanup stale worktrees from crashed workers ---
cleanup_stale_worktrees() {
    local worktree_dir="$PROJECT_PATH/.worktrees"
    [[ ! -d "$worktree_dir" ]] && return 0

    cd "$PROJECT_PATH"

    # Find all worktree directories
    for wt in "$worktree_dir"/issue-*; do
        [[ ! -d "$wt" ]] && continue

        local issue_num=$(basename "$wt" | sed 's/^issue-//')
        local branch_name="issue/$issue_num"

        # Try to remove stale worktree
        if ! git worktree remove "$wt" --force 2>/dev/null; then
            rm -rf "$wt" 2>/dev/null || true
            echo "  Cleaned stale worktree: $wt"
        fi
    done
}

# --- Helper: prune orphaned branches (issue/* branches for closed issues) ---
prune_orphaned_branches() {
    cd "$PROJECT_PATH"

    # Get all local issue/* branches
    local branches=$(git branch | grep -oP '^\s+issue/\K\d+' || true)
    [[ -z "$branches" ]] && return 0

    for issue_num in $branches; do
        # Check if issue is closed
        local state=$(gh issue view "$issue_num" --json state -q .state 2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "CLOSED" ]]; then
            local branch_name="issue/$issue_num"
            echo "  Pruning closed issue branch: $branch_name"
            git branch -D "$branch_name" 2>/dev/null || true
            git push origin --delete "$branch_name" 2>/dev/null || true
        fi
    done
}

# --- Pre-flight: verify Claude CLI is authenticated ---
echo "Checking Claude authentication..."
AUTH_CHECK=$(claude -p "echo ok" 2>&1) || true
if echo "$AUTH_CHECK" | grep -qiE "not logged in|not authenticated|session expired|login required|unauthorized|sign in|apikey"; then
    echo "FATAL: Claude CLI is not authenticated. Cannot start pipeline."
    notify_event auth_failure --project "$PROJECT_NAME"
    exit 99
fi
echo "Auth OK."
echo ""

# --- Pre-flight: cleanup stale state ---
echo "Running pre-flight cleanup..."
cd "$PROJECT_PATH"

# Clean up stale worktrees from crashed workers
echo "  Checking for stale worktrees..."
if [[ -d "$PROJECT_PATH/.worktrees" ]]; then
    for wt_dir in "$PROJECT_PATH"/.worktrees/issue-*; do
        if [[ -d "$wt_dir" ]]; then
            if ! git worktree list --porcelain 2>/dev/null | grep -q "$(basename "$wt_dir")"; then
                echo "    Removing stale worktree: $(basename "$wt_dir")"
                rm -rf "$wt_dir"
            fi
        fi
    done
fi
git worktree prune 2>/dev/null

# Clean up branches for closed issues
echo "  Checking for orphaned issue branches..."
open_issues=$(gh issue list --state open --json number --jq '.[].number' 2>/dev/null || echo "")

for branch in $(git branch -r 2>/dev/null | grep "origin/issue/" | sed 's|.*/||' | xargs || true); do
    issue_num="${branch#issue/}"
    if ! echo "$open_issues" | grep -q "^$issue_num$"; then
        echo "    Pruning closed issue branch: $branch"
        git push origin -d "$branch" 2>&1 || echo "WARNING: failed to delete remote branch $branch" >&2
    fi
done

for branch in $(git branch 2>/dev/null | grep "issue/" | sed 's/^[* ] //' | xargs || true); do
    issue_num="${branch#issue/}"
    if ! echo "$open_issues" | grep -q "^$issue_num$"; then
        echo "    Deleting local closed issue branch: $branch"
        git branch -D "$branch" 2>&1 || echo "WARNING: failed to delete local branch $branch" >&2
    fi
done

echo "Pre-flight cleanup complete."
echo ""

# --- Main loop ---
echo "=== forge-run: starting Ralph Loop (GitHub Issues mode) ==="
echo "Project: $PROJECT_PATH"
echo ""

consecutive_failures=0
iteration=0

while true; do
    iteration=$((iteration + 1))
    echo "--- Iteration $iteration ---"

    # 1. Check steering
    steering=$(read_steering)
    case "$steering" in
        stop)
            echo "STEERING: stop directive received. Exiting."
            break ;;
        pause)
            echo "STEERING: pause directive received. Exiting."
            notify_event paused --project "$PROJECT_NAME"
            break ;;
        continue|"") ;;
        *)
            echo "STEERING: custom directive: $steering" ;;
    esac

    # 1.5. Quick cleanup of orphaned issue branches (periodic)
    if [[ $((iteration % 5)) -eq 0 ]]; then
        cd "$PROJECT_PATH"
        open_issues=$(gh issue list --state open --json number --jq '.[].number' 2>/dev/null || echo "")
        remote_branches=$(git branch -r 2>/dev/null | grep "origin/issue/" | sed 's|.*/||' | xargs || true)
        for branch in $remote_branches; do
            issue_num="${branch#issue/}"
            if ! echo "$open_issues" | grep -q "^$issue_num$"; then
                git push origin -d "$branch" 2>&1 || echo "WARNING: failed to delete remote branch $branch" >&2
            fi
        done
    fi

    # 2. Pick next issue
    cd "$PROJECT_PATH"
    next_issue=$(get_next_issue)

    if [[ -z "$next_issue" ]]; then
        echo "No more open task issues with met dependencies. Done."
        break
    fi

    issue_number=$(echo "$next_issue" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
    issue_title=$(echo "$next_issue" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    complexity=$(echo "$next_issue" | python3 -c "import sys,json; print(json.load(sys.stdin)['complexity'])")
    model=$(task_model "$complexity")

    echo "Issue:      #$issue_number — $issue_title"
    echo "Complexity: $complexity"
    echo "Model:      $model"

    if $DRY_RUN; then
        echo "(dry run — skipping execution)"
        echo ""
        continue
    fi

    # 3. Mark issue as in-progress
    gh_label "$issue_number" --add-label "in-progress"

    # 4. 3-strike retry loop
    MAX_ATTEMPTS=3
    OPUS_MODEL="claude-opus-4-6"
    attempt=0
    issue_resolved=false
    last_error=""
    attempt_model="$model"

    while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
        attempt=$((attempt + 1))
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        # Check if issue was already closed (by a previous attempt's successful merge)
        issue_state=$(gh issue view "$issue_number" --json state -q .state 2>/dev/null || echo "OPEN")
        if [[ "$issue_state" == "CLOSED" ]]; then
            echo "  Issue #$issue_number is already closed — skipping."
            issue_resolved=true
            break
        fi

        # Escalate to Opus on attempt 2+
        if [[ $attempt -ge 2 ]]; then
            attempt_model="$OPUS_MODEL"
        fi

        echo ""
        echo "  Attempt $attempt/$MAX_ATTEMPTS (model: $attempt_model)"

        # --- Auto-heal before retry (attempts 2+) ---
        if [[ $attempt -ge 2 ]]; then
            echo "  Auto-healing before retry..."
            cd "$PROJECT_PATH"
            worktree_dir="$PROJECT_PATH/.worktrees/issue-$issue_number"
            branch_name="issue/$issue_number"

            # Detect failure type and heal
            if echo "$last_error" | grep -qiE "merge conflict|conflict|CONFLICT"; then
                echo "    Detected merge conflict — rebasing on latest staging..."
                if [[ -d "$worktree_dir" ]]; then
                    cd "$worktree_dir"
                    git fetch origin staging 2>/dev/null || true
                    if ! git rebase origin/staging 2>/dev/null; then
                        git rebase --abort 2>/dev/null || true
                        echo "    Rebase failed — cleaning worktree for fresh start"
                        cd "$PROJECT_PATH"
                        git worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
                        git branch -D "$branch_name" 2>/dev/null || true
                    fi
                    cd "$PROJECT_PATH"
                fi
            elif echo "$last_error" | grep -qiE "worktree|gitdir|not a git repository|lock|index.lock"; then
                echo "    Detected worktree/git issue — cleaning worktree for fresh start..."
                cd "$PROJECT_PATH"
                git worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
                git branch -D "$branch_name" 2>/dev/null || true
            else
                echo "    CI/build failure — feeding error context to next attempt"
                # Clean worktree so worker starts fresh but keep error context
                cd "$PROJECT_PATH"
                git worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
                git branch -D "$branch_name" 2>/dev/null || true
            fi

            cd "$PROJECT_PATH"
        fi

        # --- Spawn worker ---
        echo "  Spawning worker..."
        WORKER_LOG=$(mktemp)
        set +e
        "$SCRIPTS_DIR/forge-worker.sh" "$PROJECT_PATH" "$issue_number" "$attempt_model" \
            2>&1 | tee "$WORKER_LOG"
        worker_exit=${PIPESTATUS[0]}
        set -e

        # Capture last ~50 lines of output for error context
        last_error=$(tail -50 "$WORKER_LOG" 2>/dev/null || true)
        rm -f "$WORKER_LOG"

        # --- Auth failure: do NOT count as attempt ---
        if [[ $worker_exit -eq 99 ]]; then
            echo "  AUTH FAILURE: Claude CLI is not authenticated."
            gh_label "$issue_number" --remove-label "in-progress"
            notify_event auth_failure --project "$PROJECT_NAME"
            # Post comment about auth failure (not counted)
            gh issue comment "$issue_number" --body "⚠️ Auth failure during attempt $attempt/$MAX_ATTEMPTS ($attempt_model) — not counted as an attempt. Pipeline stopped." 2>/dev/null || true
            # Break out of both loops
            issue_resolved="auth_failure"
            break
        fi

        # --- Success ---
        if [[ $worker_exit -eq 0 ]]; then
            echo "  Worker completed successfully on attempt $attempt."
            issue_resolved=true
            consecutive_failures=0
            gh_label "$issue_number" --remove-label "in-progress"
            notify_event worker_done --project "$PROJECT_NAME" --issue "$issue_number" --title "$issue_title"

            # Post success comment
            gh issue comment "$issue_number" --body "✅ Attempt $attempt/$MAX_ATTEMPTS ($attempt_model): success" 2>/dev/null || true

            echo "{\"issue\":$issue_number,\"title\":\"$issue_title\",\"status\":\"done\",\"model\":\"$attempt_model\",\"timestamp\":\"$timestamp\",\"attempts\":$attempt}" \
                >> "$PROJECT_PATH/.agent/LOG.md"

            # Clean up retry context file on success
            rm -f "$PROJECT_PATH/.agent/.retry-context-$issue_number"
            break
        fi

        # --- Failure: extract error summary ---
        error_summary="exit code $worker_exit"
        if [[ $worker_exit -eq 2 ]]; then
            error_summary="worker flagged for review"
        fi
        # Try to extract a more specific error from output
        specific_error=$(echo "$last_error" | grep -iE "error:|failed:|FATAL:|Error:" | tail -3 | head -3 || true)
        if [[ -n "$specific_error" ]]; then
            # Truncate to 200 chars for comment readability
            error_summary=$(echo "$specific_error" | head -c 200)
        fi

        # --- Post attempt comment to issue ---
        gh issue comment "$issue_number" --body "$(cat <<EOF
Attempt $attempt/$MAX_ATTEMPTS ($attempt_model): ❌ failed
\`\`\`
$error_summary
\`\`\`
EOF
)" 2>/dev/null || true

        # --- If not last attempt, notify retry and build context ---
        if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
            next_model="$OPUS_MODEL"
            notify_event retrying --project "$PROJECT_NAME" --issue "$issue_number" --attempt "$attempt"

            # Store error context in a file the worker will read on next attempt
            ERROR_CONTEXT_FILE="$PROJECT_PATH/.agent/.retry-context-$issue_number"
            cat > "$ERROR_CONTEXT_FILE" <<EORETRY
## Previous Attempt Failed (attempt $attempt/$MAX_ATTEMPTS, model: $attempt_model)

The previous attempt failed. Here is the error output — use this to fix the issue:

\`\`\`
$(echo "$last_error" | tail -30)
\`\`\`

IMPORTANT: Do NOT repeat the same approach that failed. Analyze the error and try a different strategy.
EORETRY
            echo "  Attempt $attempt failed. Retrying with $next_model..."
        fi
    done

    # --- All attempts exhausted ---
    if [[ "$issue_resolved" == "auth_failure" ]]; then
        # Auth failure already handled above — break the main loop
        break
    elif [[ "$issue_resolved" != "true" ]]; then
        timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        consecutive_failures=$((consecutive_failures + 1))
        gh_label "$issue_number" --remove-label "in-progress" --add-label "needs-review"

        # Post final summary comment
        gh issue comment "$issue_number" --body "$(cat <<EOF
→ NEEDS_REVIEW

$MAX_ATTEMPTS attempts exhausted. Last error:
\`\`\`
$(echo "$last_error" | tail -20 | head -c 500)
\`\`\`

Please review and fix manually, then remove the \`needs-review\` label to re-queue.
EOF
)" 2>/dev/null || true

        notify_event needs_review --project "$PROJECT_NAME" --issue "$issue_number" \
            --error "$MAX_ATTEMPTS attempts failed"

        echo "{\"issue\":$issue_number,\"title\":\"$issue_title\",\"status\":\"needs_review\",\"model\":\"$attempt_model\",\"timestamp\":\"$timestamp\",\"attempts\":$attempt}" \
            >> "$PROJECT_PATH/.agent/LOG.md"

        # Clean up retry context file
        rm -f "$PROJECT_PATH/.agent/.retry-context-$issue_number"
    fi

    # 6. Circuit breaker
    if [[ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        echo ""
        echo "CIRCUIT BREAKER: $MAX_CONSECUTIVE_FAILURES consecutive failures."
        notify_event circuit_breaker --project "$PROJECT_NAME" --failures "$MAX_CONSECUTIVE_FAILURES"
        break
    fi

    echo ""
done

echo ""
echo "=== forge-run: loop ended ==="
echo "Total iterations: $iteration"

# Summary
cd "$PROJECT_PATH"
open_tasks=$(gh issue list --label task --state open --json number --jq length 2>/dev/null || echo "?")
echo "Open task issues: $open_tasks"

if [[ "$open_tasks" == "0" ]] && [[ $consecutive_failures -lt $MAX_CONSECUTIVE_FAILURES ]]; then
    notify_event all_done --project "$PROJECT_NAME"
fi
