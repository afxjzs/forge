#!/usr/bin/env bash
set -euo pipefail

# forge-deploy.sh — Deploy a PR branch to staging
#
# Usage:
#   forge-deploy <project> <pr-number>   Deploy PR to staging
#   forge-deploy <project> teardown      Stop and remove staging
#   forge-deploy <project>               Show what's on staging
#
# Requirements per project:
#   - docker-compose.staging.yml in the project root
#   - One-time infra: DNS + tunnel route + Caddy config for staging URL
#
# Database:
#   - Staging gets its own DB (separate from production)
#   - DB is destroyed and recreated on each deploy (clean migrations)
#   - For Postgres: uses <project>_staging database
#   - For SQLite: fresh file each deploy

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"

# Load env vars if running outside systemd
[[ -f "$FORGE_ROOT/.env" ]] && set -a && source "$FORGE_ROOT/.env" && set +a
PROJECTS_DIR="$FORGE_ROOT/projects"
STAGES=("inception" "planning" "active" "paused" "shipped")

usage() {
    cat <<'EOF'
Usage:
  forge deploy <project> <pr-number>   Deploy PR to staging
  forge deploy <project> teardown      Stop and remove staging
  forge deploy <project>               Show what's on staging

Examples:
  forge deploy omnilingo 3
  forge deploy omnilingo teardown
  forge deploy arby 7
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT_NAME="$1"
ACTION="${2:-status}"

# --- Resolve project path ---
PROJECT_PATH=""
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

if [[ -z "$PROJECT_PATH" ]]; then
    echo "Error: Project '$PROJECT_NAME' not found in forge."
    exit 1
fi

STAGING_COMPOSE="$PROJECT_PATH/docker-compose.staging.yml"
STAGING_STATE="$PROJECT_PATH/.agent/staging.json"

# --- Status ---
if [[ "$ACTION" == "status" ]]; then
    if [[ -f "$STAGING_STATE" ]]; then
        echo "Staging for $PROJECT_NAME:"
        python3 -c "
import json
with open('$STAGING_STATE') as f:
    s = json.load(f)
print(f\"  PR: #{s.get('pr_number', '?')}\")
print(f\"  Branch: {s.get('branch', '?')}\")
print(f\"  URL: {s.get('url', '?')}\")
print(f\"  Deployed: {s.get('deployed_at', '?')}\")
print(f\"  Status: {s.get('status', '?')}\")
"
    else
        echo "No staging deployment for $PROJECT_NAME."
    fi
    exit 0
fi

# --- Teardown ---
if [[ "$ACTION" == "teardown" ]]; then
    echo "Tearing down staging for $PROJECT_NAME..."

    if [[ -f "$STAGING_COMPOSE" ]]; then
        cd "$PROJECT_PATH"
        if ! docker compose -f docker-compose.staging.yml down -v 2>&1; then
            echo "ERROR: docker compose down failed. Containers may still be running." >&2
        fi
    fi

    # Clean up staging state
    rm -f "$STAGING_STATE"
    echo "Staging stopped and cleaned up."
    exit 0
fi

# --- Deploy PR ---
PR_NUMBER="$ACTION"

# Validate PR number is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: Expected PR number, got '$PR_NUMBER'."
    usage
fi

echo "=== forge deploy: $PROJECT_NAME PR #$PR_NUMBER ==="

# Look up PR branch
cd "$PROJECT_PATH"
echo "Looking up PR #$PR_NUMBER..."

PR_INFO=$(gh pr view "$PR_NUMBER" --json headRefName,title,state 2>&1) || {
    echo "Error: Could not find PR #$PR_NUMBER."
    echo "Check: gh pr list"
    exit 1
}

PR_BRANCH=$(echo "$PR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['headRefName'])")
PR_TITLE=$(echo "$PR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
PR_STATE=$(echo "$PR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

echo "  Branch: $PR_BRANCH"
echo "  Title:  $PR_TITLE"
echo "  State:  $PR_STATE"
echo ""

if [[ "$PR_STATE" != "OPEN" ]]; then
    echo "Warning: PR #$PR_NUMBER is $PR_STATE (not open). Deploying anyway."
fi

# Fetch the branch
echo "Fetching branch..."
git fetch origin "$PR_BRANCH" 2>&1

# Check for staging compose file
if [[ ! -f "$STAGING_COMPOSE" ]]; then
    echo ""
    echo "Error: No docker-compose.staging.yml found at $PROJECT_PATH"
    echo ""
    echo "Create one for this project. Template:"
    echo ""
    cat <<'TEMPLATE'
# docker-compose.staging.yml
# Staging environment — separate container, separate DB, staging port

services:
  app-staging:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-staging
    environment:
      - NODE_ENV=staging
      - PORT=${STAGING_PORT}
      - DATABASE_URL=postgresql://${PROJECT_NAME}_staging:staging_pass@postgres:5432/${PROJECT_NAME}_staging
      # Or for SQLite:
      # - DATABASE_PATH=/data/staging.db
    networks:
      - caddy_net
    restart: unless-stopped

networks:
  caddy_net:
    external: true
    name: caddy_net
TEMPLATE
    echo ""
    echo "See ~/nexus/infra/dev-pipeline/templates/staging/ for examples."
    exit 1
fi

# --- Tear down existing staging if running ---
echo "Stopping existing staging (if any)..."
if ! docker compose -f docker-compose.staging.yml down -v 2>&1; then
    echo "WARNING: docker compose down failed — old containers may still be running" >&2
fi

# --- Build and start staging from staging branch ---
echo ""

# Staging always deploys from the staging branch (which has merged PRs)
echo "Deploying from staging branch..."
CURRENT_BRANCH=$(git branch --show-current)
git fetch origin staging 2>&1
git checkout staging 2>&1
git pull origin staging 2>&1

docker compose -f docker-compose.staging.yml build 2>&1
docker compose -f docker-compose.staging.yml up -d 2>&1

# Switch back to original branch
git checkout "$CURRENT_BRANCH" 2>&1

# --- Determine staging URL ---
# Read from x-forge.staging_url in compose, or fall back to convention
STAGING_URL=$(grep -A1 "x-forge:" "$STAGING_COMPOSE" 2>/dev/null | grep "staging_url:" | awk '{print $2}' || true)
STAGING_URL="${STAGING_URL:-${PROJECT_NAME}-staging.afx.cc}"

# --- Save staging state ---
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$STAGING_STATE" << EOF
{
    "pr_number": $PR_NUMBER,
    "branch": "$PR_BRANCH",
    "title": "$PR_TITLE",
    "url": "https://$STAGING_URL",
    "deployed_at": "$DEPLOYED_AT",
    "status": "running"
}
EOF

# --- Run smoke tests if available ---
SMOKE_TEST="$PROJECT_PATH/scripts/smoke-test.sh"
if [[ -x "$SMOKE_TEST" ]]; then
    echo ""
    echo "Running smoke tests against staging..."
    echo ""
    set +e
    "$SMOKE_TEST" "https://$STAGING_URL"
    SMOKE_EXIT=$?
    set -e

    if [[ $SMOKE_EXIT -ne 0 ]]; then
        echo ""
        echo "ERROR: Smoke tests FAILED on staging. Do NOT promote to production."
        "$FORGE_ROOT/scripts/forge-notify.sh" "[$PROJECT_NAME] Smoke tests FAILED on staging. Do NOT promote to production." 2>&1 || echo "WARNING: notification failed" >&2
    fi
else
    echo ""
    echo "No smoke tests found at scripts/smoke-test.sh — skipping."
fi

# --- Run E2E tests if available ---
E2E_SCRIPT="$FORGE_ROOT/scripts/forge-e2e.sh"
if [[ -x "$E2E_SCRIPT" ]] && [[ -d "$PROJECT_PATH/tests/e2e" ]]; then
    echo ""
    echo "Running E2E tests against staging..."
    echo ""
    set +e
    "$E2E_SCRIPT" "$PROJECT_NAME" "https://$STAGING_URL"
    E2E_EXIT=$?
    set -e

    if [[ $E2E_EXIT -ne 0 ]]; then
        echo ""
        echo "ERROR: E2E tests FAILED on staging."
        # forge-e2e.sh sends its own notification, but log the failure clearly
        echo "## $(date -u +%Y-%m-%dT%H:%M:%SZ) | E2E_FAILURE" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "**E2E tests failed on staging deploy.**" >> "$PROJECT_PATH/.agent/ERRORS.md"
        echo "" >> "$PROJECT_PATH/.agent/ERRORS.md"
    fi
else
    echo ""
    echo "No E2E tests found — skipping."
fi

echo ""
echo "=== Staging deployed ==="
echo ""
echo "  Project: $PROJECT_NAME"
echo "  PR:      #$PR_NUMBER — $PR_TITLE"
echo "  Branch:  $PR_BRANCH"
echo "  URL:     https://$STAGING_URL"
echo ""
echo "When done reviewing:"
echo "  forge deploy $PROJECT_NAME teardown"
echo ""

# --- Send Telegram notification via forge-api ---
echo "Sending staging notification..."
curl -s -X POST "http://127.0.0.1:8773/projects/$PROJECT_NAME/notify" > /dev/null 2>&1 \
    || echo "Warning: Could not send staging notification (forge-api may be down)."
