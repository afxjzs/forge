#!/usr/bin/env bash
set -euo pipefail

# forge-e2e.sh — Run Playwright E2E tests for a forge project
#
# Usage: forge-e2e.sh <project-name> <staging-url>
#
# Expects:
#   - Project has tests/e2e/ directory with playwright.config.ts
#   - npx playwright available in tests/e2e/
#   - Artifacts written to test-artifacts/ in the project root
#
# Exit codes:
#   0 = all tests passed
#   1 = test failures or runner error

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCRIPTS_DIR="$FORGE_ROOT/scripts"
PROJECTS_DIR="$FORGE_ROOT/projects"
STAGES=("inception" "planning" "active" "paused" "shipped")
NEXUS_PROJECTS="$HOME/nexus/projects"
NEXUS_WEBAPPS="$HOME/nexus/web-apps"

# Crash handler — no silent failures
# Only triggers for unexpected errors, not Playwright test failures (those are handled below)
_e2e_crashed() {
    local line=$1
    echo "E2E runner crashed at line $line"
    if ! "$SCRIPTS_DIR/forge-notify.sh" "[$PROJECT_NAME] E2E runner crashed (line $line). Check forge-e2e.sh logs." 2>/dev/null; then
        echo "ERROR: Notification also failed for E2E crash at line $line" >&2
    fi
}
trap '_e2e_crashed $LINENO' ERR

usage() {
    echo "Usage: forge-e2e.sh <project-name> <staging-url>"
    exit 1
}

[[ $# -lt 2 ]] && usage

PROJECT_NAME="$1"
STAGING_URL="$2"

# --- Resolve project path ---
PROJECT_PATH=""

# Check forge projects directory (symlinks to real paths)
for stage in "${STAGES[@]}"; do
    candidate="$PROJECTS_DIR/$stage/$PROJECT_NAME"
    if [[ -e "$candidate" ]]; then
        if [[ -L "$candidate" ]]; then
            PROJECT_PATH="$(readlink -f "$candidate")"
        else
            PROJECT_PATH="$candidate"
        fi
        break
    fi
done

# Fall back to direct nexus paths
if [[ -z "$PROJECT_PATH" ]]; then
    for base in "$NEXUS_WEBAPPS" "$NEXUS_PROJECTS"; do
        if [[ -d "$base/$PROJECT_NAME" ]]; then
            PROJECT_PATH="$base/$PROJECT_NAME"
            break
        fi
    done
fi

if [[ -z "$PROJECT_PATH" ]]; then
    echo "Error: Project '$PROJECT_NAME' not found."
    exit 1
fi

E2E_DIR="$PROJECT_PATH/tests/e2e"
ARTIFACTS_DIR="$PROJECT_PATH/test-artifacts"

# --- Check for E2E tests ---
if [[ ! -f "$E2E_DIR/playwright.config.ts" ]]; then
    echo "No E2E tests found at $E2E_DIR/playwright.config.ts — skipping."
    exit 0
fi

echo "=== forge-e2e: running Playwright tests ==="
echo "Project:  $PROJECT_NAME"
echo "URL:      $STAGING_URL"
echo "Tests:    $E2E_DIR"
echo ""

# --- Clean previous artifacts (preserve directory inode for Docker bind mount) ---
mkdir -p "$ARTIFACTS_DIR"
rm -rf "${ARTIFACTS_DIR:?}"/* "${ARTIFACTS_DIR}"/.[!.]* 2>/dev/null || true

# --- Run Playwright ---
export E2E_BASE_URL="$STAGING_URL"
export E2E_ARTIFACTS_DIR="$ARTIFACTS_DIR"

# Disable ERR trap during playwright run — non-zero exit is expected on test failures
trap - ERR
cd "$E2E_DIR"
npx playwright test --config playwright.config.ts 2>&1 | tee "${ARTIFACTS_DIR}/e2e-run.log"
E2E_EXIT=${PIPESTATUS[0]}
trap '_e2e_crashed $LINENO' ERR

echo ""
echo "Playwright exit code: $E2E_EXIT"

# --- Generate report and notify ---
REPORT_SCRIPT="$SCRIPTS_DIR/forge-e2e-report.py"
if [[ -x "$REPORT_SCRIPT" ]] || [[ -f "$REPORT_SCRIPT" ]]; then
    python3 "$REPORT_SCRIPT" "$PROJECT_NAME" "$STAGING_URL" "$ARTIFACTS_DIR" "$E2E_EXIT"
else
    # Fallback: simple notification
    if [[ $E2E_EXIT -eq 0 ]]; then
        if ! "$SCRIPTS_DIR/forge-notify.sh" "[$PROJECT_NAME] E2E tests: all passed"; then
            echo "ERROR: Failed to send E2E pass notification" >&2
        fi
    else
        if ! "$SCRIPTS_DIR/forge-notify.sh" "[$PROJECT_NAME] E2E tests: FAILED (exit $E2E_EXIT). Check $STAGING_URL/test-artifacts/ for screenshots."; then
            echo "ERROR: Failed to send E2E failure notification" >&2
        fi
    fi
fi

echo ""
echo "=== forge-e2e: done ==="

exit $E2E_EXIT
