#!/usr/bin/env bash
set -euo pipefail

# forge-notify-event.sh — Send structured event notifications with fixed templates
#
# Usage: forge-notify-event.sh <event> [options]
#
# Events and templates:
#   worker_done      --project P --issue N --title T    → ✓ [P] #N done — T
#   pr_merged        --project P --pr N                 → 📦 [P] PR #N merged to staging
#   retrying         --project P --issue N --attempt X  → ⟳ [P] #N attempt X failed, retrying with opus
#   needs_review     --project P --issue N [--error E]  → 🔔 [P] #N needs review — E
#   needs_spec       --project P --issue N [--q Q]      → 📋 [P] #N needs better spec — Q
#   all_done         --project P                        → ✅ [P] all issues closed. /ship when ready
#   circuit_breaker  --project P --failures N           → 🛑 [P] circuit breaker — N consecutive failures
#   auth_failure     --project P                        → 🔑 [P] pipeline stopped — claude not logged in
#   paused           --project P                        → ⏸ [P] pipeline paused by steering directive
#   staging_deployed --project P --pr N [--url U]       → 🚀 [P] PR #N deployed to staging: U
#   smoke_failed     --project P                        → 💥 [P] smoke tests FAILED on staging — do not promote
#   e2e_passed       --project P                        → ✅ [P] E2E tests: all passed
#   e2e_failed       --project P --url U                → 💥 [P] E2E tests FAILED — check U/test-artifacts/ for screenshots
#   e2e_crashed      --project P                        → 🔥 [P] E2E runner crashed — check forge-e2e.sh logs
#   orphans_found    --project P --count N              → 🌿 [P] N orphaned branch(es) with no PR

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"
SCRIPTS_DIR="$FORGE_ROOT/scripts"

usage() {
    cat >&2 <<'EOF'
Usage: forge-notify-event.sh <event> [options]

Events:
  worker_done      --project P --issue N --title T
  pr_merged        --project P --pr N
  retrying         --project P --issue N --attempt X
  needs_review     --project P --issue N [--error E]
  needs_spec       --project P --issue N [--questions Q]
  all_done         --project P
  circuit_breaker  --project P --failures N
  auth_failure     --project P
  paused           --project P
  staging_deployed --project P --pr N [--url U]
  smoke_failed     --project P
  e2e_passed       --project P
  e2e_failed       --project P --url U
  e2e_crashed      --project P
  orphans_found    --project P --count N
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage

EVENT="$1"
shift

# Parse options
PROJECT=""
ISSUE=""
TITLE=""
PR=""
ATTEMPT=""
ERROR_CTX=""
QUESTIONS=""
FAILURES=""
URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)   PROJECT="$2";   shift 2 ;;
        --issue)     ISSUE="$2";     shift 2 ;;
        --title)     TITLE="$2";     shift 2 ;;
        --pr)        PR="$2";        shift 2 ;;
        --attempt)   ATTEMPT="$2";   shift 2 ;;
        --error)     ERROR_CTX="$2"; shift 2 ;;
        --questions) QUESTIONS="$2"; shift 2 ;;
        --failures)  FAILURES="$2";  shift 2 ;;
        --count)     FAILURES="$2";  shift 2 ;;
        --url)       URL="$2";       shift 2 ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

[[ -z "$PROJECT" ]] && { echo "ERROR: --project required" >&2; exit 1; }

# Build message from fixed template — no LLM, no ad-hoc strings
case "$EVENT" in
    worker_done)
        [[ -z "$ISSUE" || -z "$TITLE" ]] && { echo "ERROR: worker_done requires --issue and --title" >&2; exit 1; }
        MESSAGE="✓ [$PROJECT] #$ISSUE done — $TITLE"
        ;;
    pr_merged)
        [[ -z "$PR" ]] && { echo "ERROR: pr_merged requires --pr" >&2; exit 1; }
        MESSAGE="📦 [$PROJECT] PR #$PR merged to staging"
        ;;
    retrying)
        [[ -z "$ISSUE" || -z "$ATTEMPT" ]] && { echo "ERROR: retrying requires --issue and --attempt" >&2; exit 1; }
        MESSAGE="⟳ [$PROJECT] #$ISSUE attempt $ATTEMPT failed, retrying with opus"
        ;;
    needs_review)
        [[ -z "$ISSUE" ]] && { echo "ERROR: needs_review requires --issue" >&2; exit 1; }
        if [[ -n "$ERROR_CTX" ]]; then
            MESSAGE="🔔 [$PROJECT] #$ISSUE needs review — $ERROR_CTX"
        else
            MESSAGE="🔔 [$PROJECT] #$ISSUE needs review"
        fi
        ;;
    needs_spec)
        [[ -z "$ISSUE" ]] && { echo "ERROR: needs_spec requires --issue" >&2; exit 1; }
        if [[ -n "$QUESTIONS" ]]; then
            MESSAGE="📋 [$PROJECT] #$ISSUE needs better spec — $QUESTIONS"
        else
            MESSAGE="📋 [$PROJECT] #$ISSUE needs better spec"
        fi
        ;;
    all_done)
        MESSAGE="✅ [$PROJECT] all issues closed. /ship when ready"
        ;;
    circuit_breaker)
        [[ -z "$FAILURES" ]] && { echo "ERROR: circuit_breaker requires --failures" >&2; exit 1; }
        MESSAGE="🛑 [$PROJECT] circuit breaker — $FAILURES consecutive failures"
        ;;
    auth_failure)
        MESSAGE="🔑 [$PROJECT] pipeline stopped — claude not logged in"
        ;;
    paused)
        MESSAGE="⏸ [$PROJECT] pipeline paused by steering directive"
        ;;
    staging_deployed)
        [[ -z "$PR" ]] && { echo "ERROR: staging_deployed requires --pr" >&2; exit 1; }
        if [[ -n "$URL" ]]; then
            MESSAGE="🚀 [$PROJECT] PR #$PR deployed to staging: $URL"
        else
            MESSAGE="🚀 [$PROJECT] PR #$PR deployed to staging"
        fi
        ;;
    smoke_failed)
        MESSAGE="💥 [$PROJECT] smoke tests FAILED on staging — do not promote"
        ;;
    e2e_passed)
        MESSAGE="✅ [$PROJECT] E2E tests: all passed"
        ;;
    e2e_failed)
        [[ -z "$URL" ]] && { echo "ERROR: e2e_failed requires --url" >&2; exit 1; }
        MESSAGE="💥 [$PROJECT] E2E tests FAILED — check $URL/test-artifacts/ for screenshots"
        ;;
    e2e_crashed)
        MESSAGE="🔥 [$PROJECT] E2E runner crashed — check forge-e2e.sh logs"
        ;;
    orphans_found)
        [[ -z "$FAILURES" ]] && { echo "ERROR: orphans_found requires --count" >&2; exit 1; }
        MESSAGE="🌿 [$PROJECT] $FAILURES orphaned branch(es) with no PR — branches have unsubmitted code"
        ;;
    *)
        echo "ERROR: Unknown event '$EVENT'" >&2
        usage
        ;;
esac

# Delegate to forge-notify.sh for actual delivery
exec "$SCRIPTS_DIR/forge-notify.sh" "$MESSAGE"
