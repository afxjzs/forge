#!/usr/bin/env bash
set -euo pipefail

# forge-prd-to-issues.sh — Convert a PRD into GitHub task issues
#
# Takes a PRD (GitHub Issue with 'prd' label, or a spec file) and uses Claude
# to break it into implementable task issues with proper labels and dependencies.
#
# Usage:
#   forge-prd-to-issues.sh <project-path> --issue <prd-issue-number>
#   forge-prd-to-issues.sh <project-path> --file <spec-file-path>
#
# Creates GitHub Issues with:
#   - 'task' label
#   - Complexity label (mechanical/standard/architecture)
#   - Priority label (P0/P1/P2)
#   - "Blocked by #N" references for dependencies
#   - Parent PRD reference

export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"

usage() {
    echo "Usage:"
    echo "  forge-prd-to-issues.sh <project-path> --issue <prd-issue-number>"
    echo "  forge-prd-to-issues.sh <project-path> --file <spec-file-path>"
    exit 1
}

[[ $# -lt 3 ]] && usage

PROJECT_PATH="$(realpath "$1")"
shift

PRD_SOURCE=""
PRD_CONTENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            PRD_SOURCE="issue"
            PRD_NUMBER="$2"
            shift 2
            ;;
        --file)
            PRD_SOURCE="file"
            PRD_FILE="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -z "$PRD_SOURCE" ]] && usage

# --- Fetch PRD content ---
if [[ "$PRD_SOURCE" == "issue" ]]; then
    echo "Reading PRD from GitHub Issue #$PRD_NUMBER..."
    cd "$PROJECT_PATH"
    PRD_CONTENT=$(gh issue view "$PRD_NUMBER" --json title,body --jq '"# " + .title + "\n\n" + .body')
    if [[ -z "$PRD_CONTENT" ]]; then
        echo "Error: Could not read issue #$PRD_NUMBER"
        exit 1
    fi
elif [[ "$PRD_SOURCE" == "file" ]]; then
    PRD_FILE_PATH="$(realpath "$PRD_FILE")"
    if [[ ! -f "$PRD_FILE_PATH" ]]; then
        echo "Error: File '$PRD_FILE' does not exist"
        exit 1
    fi
    echo "Reading PRD from file: $PRD_FILE_PATH"
    PRD_CONTENT=$(cat "$PRD_FILE_PATH")
fi

# --- Read project context ---
PROJECT_NAME="$(basename "$PROJECT_PATH")"
CLAUDE_MD=""
[[ -f "$PROJECT_PATH/CLAUDE.md" ]] && CLAUDE_MD=$(cat "$PROJECT_PATH/CLAUDE.md")

echo ""
echo "=== forge-prd-to-issues: breaking PRD into task issues ==="
echo "Project: $PROJECT_NAME"
echo ""

# --- Use Claude to generate task JSON ---
# Unset so Claude Code uses OAuth, not the bot's API key
unset ANTHROPIC_API_KEY

TASK_JSON=$(claude \
    --model claude-sonnet-4-6 \
    --dangerously-skip-permissions \
    -p \
    "You are a technical project manager breaking a PRD into implementable GitHub Issues.

PROJECT: $PROJECT_NAME
PROJECT PATH: $PROJECT_PATH

PROJECT CONTEXT (CLAUDE.md):
$CLAUDE_MD

PRD TO BREAK DOWN:
$PRD_CONTENT

Break this PRD into the smallest implementable tasks. Each task should be completable by a single developer in a single session.

Output ONLY a JSON array. No markdown, no explanation, just the JSON:

[
  {
    \"title\": \"Short imperative title (e.g., 'Add user auth middleware')\",
    \"body\": \"### Parent PRD\n#${PRD_NUMBER:-N/A}\n\n## What to build\n\nConcise description referencing PRD sections.\n\n## Acceptance criteria\n\n- [ ] Criterion 1\n- [ ] Criterion 2\n\n## Blocked by\n\n- None\n\n## Complexity\n\nstandard\n\n## User stories addressed\n\n- Relevant user story from PRD\",
    \"complexity\": \"standard\",
    \"priority\": \"P1\",
    \"blocked_by_index\": []
  }
]

Rules:
- complexity: mechanical (rename/boilerplate), standard (features/bugs), architecture (new patterns/system design)
- priority: P0 (must have, blocking), P1 (must have), P2 (nice to have)
- blocked_by_index: array of 0-based indices of OTHER tasks in this array that must complete first
- Keep tasks small and focused — one concern per task
- Include acceptance criteria that are testable
- Order tasks by dependency (blockers first, dependents later)
- Output ONLY the JSON array, nothing else")

if [[ -z "$TASK_JSON" ]]; then
    echo "Error: Claude returned empty response"
    exit 1
fi

# --- Create GitHub Issues from JSON ---
cd "$PROJECT_PATH"

echo "Creating GitHub Issues..."
echo ""

# Parse JSON and create issues, tracking created issue numbers for dependency mapping
CREATED_ISSUES=()

TASK_COUNT=$(echo "$TASK_JSON" | python3 -c "
import sys, json
try:
    tasks = json.loads(sys.stdin.read())
    if not isinstance(tasks, list):
        print('Error: Claude returned non-array JSON', file=sys.stderr)
        sys.exit(1)
    print(len(tasks))
except json.JSONDecodeError as e:
    print(f'Error: Failed to parse Claude response as JSON: {e}', file=sys.stderr)
    sys.exit(1)
") || { echo "Error: Could not parse task JSON from Claude response"; exit 1; }
echo "Tasks to create: $TASK_COUNT"
echo ""

for i in $(seq 0 $((TASK_COUNT - 1))); do
    TASK=$(echo "$TASK_JSON" | python3 -c "
import sys, json
tasks = json.loads(sys.stdin.read())
t = tasks[$i]
print(json.dumps(t))
")

    TITLE=$(echo "$TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    BODY=$(echo "$TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")
    COMPLEXITY=$(echo "$TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['complexity'])")
    PRIORITY=$(echo "$TASK" | python3 -c "import sys,json; print(json.load(sys.stdin)['priority'])")
    BLOCKED_INDICES=$(echo "$TASK" | python3 -c "import sys,json; print(' '.join(str(x) for x in json.load(sys.stdin).get('blocked_by_index', [])))")

    # Build blocked-by references from already-created issues
    if [[ -n "$BLOCKED_INDICES" ]]; then
        BLOCKED_REFS=""
        for idx in $BLOCKED_INDICES; do
            if [[ $idx -lt ${#CREATED_ISSUES[@]} ]]; then
                BLOCKED_REFS="${BLOCKED_REFS}\nBlocked by #${CREATED_ISSUES[$idx]}"
            fi
        done
        if [[ -n "$BLOCKED_REFS" ]]; then
            BODY=$(echo "$BODY" | sed "s/- None.*can start immediately/$(echo -e "$BLOCKED_REFS" | sed 's/$/\\n/' | tr -d '\n')/")
        fi
    fi

    # Create the issue
    ISSUE_URL=$(gh issue create \
        --title "$TITLE" \
        --body "$BODY" \
        --label "task,$COMPLEXITY,$PRIORITY" \
        2>&1)

    ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oP '\d+$')
    CREATED_ISSUES+=("$ISSUE_NUM")

    echo "  #$ISSUE_NUM — $TITLE [$COMPLEXITY, $PRIORITY]"
done

echo ""
echo "=== forge-prd-to-issues: done ==="
echo "Created ${#CREATED_ISSUES[@]} task issues from PRD"
echo ""

# Output JSON summary for API consumption
python3 -c "
import json
issues = [int(x) for x in '${CREATED_ISSUES[*]}'.split()]
print(json.dumps({'created_issues': issues, 'count': len(issues)}))
"
