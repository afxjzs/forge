#!/usr/bin/env bash
set -euo pipefail

# forge-check-orphans.sh — Find task branches with no PR
#
# Usage: forge-check-orphans.sh <project-path> [--notify]
#
# Checks for remote task/* branches that don't have an open or merged PR.
# With --notify, sends a Telegram alert listing orphaned branches.

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCRIPTS_DIR="$FORGE_ROOT/scripts"

usage() {
    echo "Usage: forge-check-orphans.sh <project-path> [--notify]"
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT_PATH="$(realpath "$1")"
NOTIFY=false
[[ "${2:-}" == "--notify" ]] && NOTIFY=true
PROJECT_NAME="$(basename "$PROJECT_PATH")"

cd "$PROJECT_PATH"

# Get all remote task/ branches
REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep "origin/task/" | sed 's|origin/||' | xargs || true)

if [[ -z "$REMOTE_BRANCHES" ]]; then
    echo "No remote task branches found."
    exit 0
fi

ORPHANS=()

for branch in $REMOTE_BRANCHES; do
    # Check if there's an open or merged PR for this branch
    PR_STATE=$(gh pr list --head "$branch" --state all --json state --jq '.[0].state' 2>/dev/null || true)

    if [[ -z "$PR_STATE" ]]; then
        ORPHANS+=("$branch")
        echo "ORPHAN: $branch — no PR exists"
    elif [[ "$PR_STATE" == "OPEN" ]]; then
        echo "OK:     $branch — PR open"
    elif [[ "$PR_STATE" == "MERGED" ]]; then
        echo "OK:     $branch — PR merged"
    elif [[ "$PR_STATE" == "CLOSED" ]]; then
        echo "CLOSED: $branch — PR was closed (not merged)"
    fi
done

echo ""
echo "Total remote task branches: $(echo "$REMOTE_BRANCHES" | wc -w)"
echo "Orphaned (no PR): ${#ORPHANS[@]}"

if [[ ${#ORPHANS[@]} -gt 0 ]] && $NOTIFY; then
    ORPHAN_LIST=$(printf '  - %s\n' "${ORPHANS[@]}")
    "$SCRIPTS_DIR/forge-notify.sh" "[$PROJECT_NAME] ${#ORPHANS[@]} orphaned branch(es) with no PR:
$ORPHAN_LIST
These branches have code that was never submitted for review." || true
fi
