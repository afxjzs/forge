#!/usr/bin/env bash
set -euo pipefail

# forge-cleanup.sh — Helper functions for cleanup operations
#
# Functions:
#   - cleanup_stale_worktrees <project-path>
#   - cleanup_orphaned_branches <project-path>
#   - cleanup_tasks_directory <project-path>

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"

# --- Cleanup stale worktrees (from crashed workers) ---
cleanup_stale_worktrees() {
    local project_path="$1"
    local worktree_dir="$project_path/.worktrees"

    if [[ ! -d "$worktree_dir" ]]; then
        return 0
    fi

    local found_stale=0
    cd "$project_path"

    # List all worktrees
    local worktrees
    worktrees=$(git worktree list --porcelain 2>/dev/null || echo "")

    # Find .worktrees/issue-* directories
    for wt_dir in "$worktree_dir"/issue-*; do
        if [[ ! -d "$wt_dir" ]]; then
            continue
        fi

        # Check if this worktree is registered in git
        if ! echo "$worktrees" | grep -q "$(basename "$wt_dir")"; then
            echo "  Cleaning stale worktree: $(basename "$wt_dir")"
            rm -rf "$wt_dir"
            found_stale=$((found_stale + 1))
        fi
    done

    return 0
}

# --- Cleanup orphaned branches for closed issues ---
cleanup_orphaned_branches() {
    local project_path="$1"
    cd "$project_path"

    # Get all issue numbers that are currently open
    local open_issues
    open_issues=$(gh issue list --state open --json number --jq '.[].number' 2>/dev/null || echo "")

    local deleted=0

    # Find all issue/* branches
    local remote_branches
    remote_branches=$(git branch -r 2>/dev/null | grep "origin/issue/" | sed 's|.*/||' | xargs || true)

    for branch in $remote_branches; do
        # Extract issue number from branch name
        local issue_num="${branch#issue/}"

        # Check if this issue is open
        if ! echo "$open_issues" | grep -q "^$issue_num$"; then
            # Issue is closed, remove the branch
            echo "  Pruning closed issue branch: $branch"
            git push origin -d "$branch" 2>/dev/null || true
            deleted=$((deleted + 1))
        fi
    done

    # Also check local branches
    for branch in $(git branch 2>/dev/null | grep "issue/" | sed 's/^[* ] //' | xargs || true); do
        local issue_num="${branch#issue/}"
        if ! echo "$open_issues" | grep -q "^$issue_num$"; then
            echo "  Deleting local closed issue branch: $branch"
            git branch -D "$branch" 2>/dev/null || true
        fi
    done

    return 0
}

# --- Cleanup task directories (legacy) ---
cleanup_tasks_directory() {
    local project_path="$1"
    local tasks_dir="$project_path/.agent/tasks"

    if [[ -d "$tasks_dir" ]]; then
        echo "  Removing legacy .agent/tasks directory: $tasks_dir"
        rm -rf "$tasks_dir"
    fi

    return 0
}

# --- Main: called with function name ---
if [[ $# -lt 2 ]]; then
    echo "Usage: forge-cleanup.sh <function> <project-path>"
    echo "Functions: cleanup_stale_worktrees, cleanup_orphaned_branches, cleanup_tasks_directory"
    exit 1
fi

func="$1"
project_path="$2"

case "$func" in
    cleanup_stale_worktrees|cleanup_orphaned_branches|cleanup_tasks_directory)
        "$func" "$project_path"
        ;;
    *)
        echo "Unknown function: $func"
        exit 1
        ;;
esac
