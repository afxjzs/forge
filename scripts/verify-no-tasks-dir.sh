#!/usr/bin/env bash
set -euo pipefail

# verify-no-tasks-dir.sh — Verify that no .agent/tasks/ directories exist
#
# This script checks that adopted projects don't have legacy .agent/tasks/ directories.
# GitHub Issues is the only task source in the forge pipeline now.

PROJECTS=(
    "/home/afxjzs/nexus/web-apps/omnilingo"
    "/home/afxjzs/nexus/projects/test-project"
    "/home/afxjzs/nexus/projects/corpus"
    "/home/afxjzs/nexus/projects/kalshi-arb"
)

echo "=== Verifying no legacy .agent/tasks/ directories ==="
echo ""

all_clean=true
for proj in "${PROJECTS[@]}"; do
    proj_name="$(basename "$proj")"
    tasks_dir="$proj/.agent/tasks"

    if [[ -d "$tasks_dir" ]]; then
        echo "⚠️  $proj_name: FOUND .agent/tasks/ directory"
        all_clean=false
    else
        echo "✓ $proj_name: Clean (no .agent/tasks/)"
    fi
done

echo ""
if $all_clean; then
    echo "✓ All projects are clean — no legacy .agent/tasks/ directories."
    exit 0
else
    echo "✗ Found legacy .agent/tasks/ directories. Please remove them."
    exit 1
fi
