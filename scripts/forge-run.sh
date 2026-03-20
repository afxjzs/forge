#!/usr/bin/env bash
set -euo pipefail

# forge-run.sh — Execute the Ralph Loop using GitHub Issues as the task queue
#
# Reads open issues labeled 'task' from the project's GitHub repo.
# Picks highest priority, spawns worker, worker's PR closes the issue.
#
# Usage: forge-run.sh <project-path> [--dry-run]

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCRIPTS_DIR="$FORGE_ROOT/scripts"
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

# --- Helper: send notification (NEVER swallow failures) ---
notify() {
    local msg="$1"
    if ! "$SCRIPTS_DIR/forge-notify.sh" "$msg"; then
        echo "ERROR: Telegram notification FAILED for message: $msg" >&2
        echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) | NOTIFICATION_FAILURE" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "**Message that failed to send:** $msg" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "" >> "$PROJECT_PATH/.agent/ERRORS.md"
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

    # Pick the highest priority unblocked issue
    python3 -c "
import json, sys

issues = json.loads('''$issues''')
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
    # Check for 'Blocked by #N' where that issue is still open
    import re
    blocked_refs = re.findall(r'Blocked by #(\d+)', body, re.IGNORECASE)
    for ref in blocked_refs:
        # Check if blocking issue is still open
        for other in issues:
            if other['number'] == int(ref) and True:  # it's in open issues = still open
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
" 2>/dev/null
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

# --- Pre-flight: verify Claude CLI is authenticated ---
echo "Checking Claude authentication..."
AUTH_CHECK=$(claude -p "echo ok" 2>&1) || true
if echo "$AUTH_CHECK" | grep -qiE "not logged in|not authenticated|session expired|login required|unauthorized|sign in|apikey"; then
    echo "FATAL: Claude CLI is not authenticated. Cannot start pipeline."
    notify "[$PROJECT_NAME] Pipeline cannot start — Claude is not logged in. Run '/login' to re-authenticate."
    exit 99
fi
echo "Auth OK."
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
            notify "[$PROJECT_NAME] Pipeline paused by steering directive."
            break ;;
        continue|"") ;;
        *)
            echo "STEERING: custom directive: $steering" ;;
    esac

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
    gh issue edit "$issue_number" --add-label "in-progress" 2>/dev/null || true

    # 4. Spawn worker
    echo "Spawning worker..."
    set +e
    "$SCRIPTS_DIR/forge-worker.sh" "$PROJECT_PATH" "$issue_number" "$model"
    worker_exit=$?
    set -e

    # 5. Handle result
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ $worker_exit -eq 99 ]]; then
        echo "AUTH FAILURE: Claude CLI is not authenticated."
        gh issue edit "$issue_number" --remove-label "in-progress" 2>/dev/null || true
        notify "[$PROJECT_NAME] Pipeline STOPPED — Claude is not logged in. Run '/login' to re-authenticate."
        break
    fi

    if [[ $worker_exit -eq 0 ]]; then
        echo "Worker completed successfully."
        consecutive_failures=0

        # Remove in-progress label (PR will close the issue)
        gh issue edit "$issue_number" --remove-label "in-progress" 2>/dev/null || true

        echo "{\"issue\":$issue_number,\"title\":\"$issue_title\",\"status\":\"done\",\"model\":\"$model\",\"timestamp\":\"$timestamp\"}" \
            >> "$PROJECT_PATH/.agent/LOG.md"

    elif [[ $worker_exit -eq 2 ]]; then
        echo "Worker flagged issue for review."
        consecutive_failures=$((consecutive_failures + 1))
        gh issue edit "$issue_number" --remove-label "in-progress" --add-label "needs-review" 2>/dev/null || true
        notify "[$PROJECT_NAME] Issue #$issue_number needs review — worker flagged it."

        echo "{\"issue\":$issue_number,\"title\":\"$issue_title\",\"status\":\"needs_review\",\"model\":\"$model\",\"timestamp\":\"$timestamp\"}" \
            >> "$PROJECT_PATH/.agent/LOG.md"

    else
        echo "Worker failed (exit code: $worker_exit)."
        consecutive_failures=$((consecutive_failures + 1))
        gh issue edit "$issue_number" --remove-label "in-progress" --add-label "needs-review" 2>/dev/null || true
        notify "[$PROJECT_NAME] Issue #$issue_number failed (exit $worker_exit)."

        echo "{\"issue\":$issue_number,\"title\":\"$issue_title\",\"status\":\"failed\",\"model\":\"$model\",\"timestamp\":\"$timestamp\",\"exit_code\":$worker_exit}" \
            >> "$PROJECT_PATH/.agent/LOG.md"
    fi

    # 6. Circuit breaker
    if [[ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        echo ""
        echo "CIRCUIT BREAKER: $MAX_CONSECUTIVE_FAILURES consecutive failures."
        notify "[$PROJECT_NAME] Circuit breaker tripped — $MAX_CONSECUTIVE_FAILURES consecutive failures."
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
    notify "[$PROJECT_NAME] All task issues completed. Check staging."
fi
