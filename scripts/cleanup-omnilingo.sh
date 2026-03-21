#!/usr/bin/env bash
set -euo pipefail

# cleanup-omnilingo.sh — One-time cleanup of stale state in omnilingo
#
# Removes:
# - Stale worktrees from .worktrees/
# - Branches with closed PRs
# - Branches with no associated PR (orphaned)
# - Very old task branches

PROJECT_PATH="/home/afxjzs/nexus/web-apps/omnilingo"
cd "$PROJECT_PATH"

echo "=== Cleaning up omnilingo stale state ==="
echo ""

# 1. Clean up stale worktrees
echo "1. Removing stale worktrees..."
if [[ -d "$PROJECT_PATH/.worktrees" ]]; then
    if [[ -z "$(ls -A "$PROJECT_PATH/.worktrees" 2>/dev/null)" ]]; then
        echo "   No stale worktrees found."
    else
        # Remove all directories in .worktrees
        for wt in "$PROJECT_PATH"/.worktrees/*; do
            if [[ -d "$wt" ]]; then
                echo "   Removing: $(basename "$wt")"
                rm -rf "$wt"
            fi
        done
    fi
fi
echo ""

# 2. Clean up branches with closed PRs and orphaned branches
echo "2. Pruning closed and orphaned branches..."
echo ""

# Branches to delete (those with CLOSED PRs or no PR)
BRANCHES_TO_DELETE=(
    "task/task-004"
    "task/task-005"
    "task/task-006"
    "task/task-007"
    "task/task-012"
    "task/task-016"
    "task/task-020"
    "task/task-021"
    "task/task-028"
    "task/task-030"
    "task/task-031"
    "task/task-032"
    "task/task-033"
)

# Check if remote branches exist before trying to delete
for branch in "${BRANCHES_TO_DELETE[@]}"; do
    if git branch -r 2>/dev/null | grep -q "origin/$branch"; then
        echo "   Deleting remote branch: $branch"
        git push origin -d "$branch" 2>/dev/null || echo "     WARNING: Failed to delete $branch"
    fi

    # Also delete local branch if it exists
    if git branch 2>/dev/null | grep -q "^[* ] $branch$"; then
        echo "   Deleting local branch: $branch"
        git branch -D "$branch" 2>/dev/null || echo "     WARNING: Failed to delete local $branch"
    fi
done

echo ""
echo "3. Final branch status:"
git branch -r 2>/dev/null | grep -E "origin/(task|issue)/" | wc -l | xargs echo "   Remaining remote branches:"
echo ""
echo "=== Cleanup complete ==="
