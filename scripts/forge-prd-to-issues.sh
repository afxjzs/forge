#!/usr/bin/env bash
set -euo pipefail

# forge-prd-to-issues.sh — Convert a PRD into GitHub task issues
#
# Takes a PRD (GitHub Issue with 'prd' label, or a spec file) and uses Claude
# to break it into implementable task issues with proper labels and dependencies.
# Runs spec assessment on each generated task before creating the GitHub Issue.
#
# Usage:
#   forge-prd-to-issues.sh <project-path> --issue <prd-issue-number>
#   forge-prd-to-issues.sh <project-path> --file <spec-file-path>
#
# Creates GitHub Issues with:
#   - 'task' label (spec passed) OR 'needs-spec' label (spec failed)
#   - Complexity label (mechanical/standard/architecture)
#   - Priority label (P0/P1/P2)
#   - "Blocked by #N" references for dependencies
#   - Parent PRD reference
#   - Clarifying questions appended when spec needs work

export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCRIPTS_DIR="$FORGE_ROOT/scripts"

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
PRD_NUMBER=""

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

# --- Parse task count ---
cd "$PROJECT_PATH"

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
echo "Running spec assessment on each task..."
echo ""

# --- Assess spec quality for each task ---
# Returns: "pass" or "fail:<questions>"
assess_spec() {
    local title="$1"
    local body="$2"
    local complexity="$3"
    local blocked_indices="$4"

    local fail_reasons=()
    local llm_questions=""

    # Check 1: File/path references exist in codebase
    local missing_files
    missing_files=$(python3 - "$body" "$PROJECT_PATH" <<'PYEOF'
import sys, re, os

body = sys.argv[1]
project_path = sys.argv[2]

# Extract backtick-quoted strings that look like file paths
patterns = [
    r'`([^`]+\.(py|ts|js|sh|yml|yaml|json|md|toml|go|rb|rs|tf))`',
    r'`((?:src|api|bot|app|scripts|lib|tests?|spec)/[^`]+)`',
]

refs = set()
for pattern in patterns:
    for m in re.finditer(pattern, body):
        refs.add(m.group(1))

missing = []
for ref in refs:
    full_path = os.path.join(project_path, ref)
    if not os.path.exists(full_path):
        missing.append(ref)

if missing:
    print('\n'.join(missing))
PYEOF
)
    if [[ -n "$missing_files" ]]; then
        local missing_list
        missing_list=$(echo "$missing_files" | tr '\n' ', ' | sed 's/, $//')
        fail_reasons+=("Referenced files not found in codebase: $missing_list")
    fi

    # Check 2: blocked_by_index values are valid (within task array bounds)
    if [[ -n "$blocked_indices" ]]; then
        for idx in $blocked_indices; do
            if [[ $idx -ge $TASK_COUNT ]]; then
                fail_reasons+=("Invalid blocked_by_index $idx (max valid index: $((TASK_COUNT - 1)))")
            fi
        done
    fi

    # Check 3: Complexity vs scope mismatch
    local file_mention_count
    file_mention_count=$(echo "$body" | grep -oP '`[^`]+\.(py|ts|js|sh|yml|yaml|json|md|toml)`' | wc -l)
    if [[ "$complexity" == "mechanical" && $file_mention_count -gt 4 ]]; then
        fail_reasons+=("Complexity 'mechanical' but $file_mention_count files mentioned — consider 'standard'")
    fi

    # Check 4: LLM clarity check (Haiku for speed/cost)
    llm_questions=$(claude \
        --model claude-haiku-4-5-20251001 \
        --dangerously-skip-permissions \
        -p \
        "You are a forge pipeline spec validator. Evaluate this task spec for implementability.

PROJECT: $PROJECT_NAME
TASK TITLE: $title
TASK BODY:
$body

Can an AI coding agent implement this task completely without asking any clarifying questions?

Reply ONLY in this exact format:
CLEAR: yes

or if not clear:
CLEAR: no
QUESTIONS:
- question 1
- question 2

Be strict. Flag: ambiguous implementation approach, unknown dependencies, unclear scope, missing technical details, underspecified acceptance criteria." 2>/dev/null || echo "CLEAR: yes")

    if echo "$llm_questions" | grep -q "^CLEAR: no"; then
        local q_text
        q_text=$(echo "$llm_questions" | sed -n '/^QUESTIONS:/,$ p' | tail -n +2)
        fail_reasons+=("LLM clarity check failed")
        if [[ -n "$q_text" ]]; then
            llm_questions="$q_text"
        else
            llm_questions=""
        fi
    else
        llm_questions=""
    fi

    # --- Emit result ---
    if [[ ${#fail_reasons[@]} -eq 0 ]]; then
        echo "pass"
    else
        local reasons_text
        reasons_text=$(printf '%s\n' "${fail_reasons[@]}")
        if [[ -n "$llm_questions" ]]; then
            echo "fail:${reasons_text}
CLARIFYING_QUESTIONS:
$llm_questions"
        else
            echo "fail:${reasons_text}"
        fi
    fi
}

# --- Create GitHub Issues from JSON ---
echo "Creating GitHub Issues..."
echo ""

# Ensure 'needs-spec' label exists
gh label list 2>/dev/null | grep -q "needs-spec" || \
    gh label create "needs-spec" --color "FFA500" --description "Task spec needs clarification before work can begin" 2>/dev/null || true

CREATED_ISSUES=()
NEEDS_SPEC_ISSUES=()

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

    # --- Run spec assessment ---
    echo "  Assessing spec for: $TITLE"
    ASSESSMENT=$(assess_spec "$TITLE" "$BODY" "$COMPLEXITY" "$BLOCKED_INDICES")

    if [[ "$ASSESSMENT" == "pass" ]]; then
        ISSUE_LABELS="task,$COMPLEXITY,$PRIORITY"
        FINAL_BODY="$BODY"
        SPEC_STATUS="✓ ready"
    else
        ISSUE_LABELS="needs-spec,$COMPLEXITY,$PRIORITY"

        # Extract failure reasons and questions from assessment
        FAIL_CONTENT=$(echo "$ASSESSMENT" | sed 's/^fail://')
        FAIL_REASONS=$(echo "$FAIL_CONTENT" | sed -n '1,/^CLARIFYING_QUESTIONS:/p' | grep -v "^CLARIFYING_QUESTIONS:" || echo "$FAIL_CONTENT")
        CLARIFYING_QS=$(echo "$FAIL_CONTENT" | sed -n '/^CLARIFYING_QUESTIONS:/,$ p' | tail -n +2 || true)

        ASSESSMENT_SECTION="

---

## ⚠️ Spec Assessment: Needs Clarification

### Issues Found

$(echo "$FAIL_REASONS" | sed 's/^/- /')"

        if [[ -n "$CLARIFYING_QS" ]]; then
            ASSESSMENT_SECTION="$ASSESSMENT_SECTION

### Questions for Spec Author

$CLARIFYING_QS"
        fi

        FINAL_BODY="${BODY}${ASSESSMENT_SECTION}"
        SPEC_STATUS="⚠️  needs-spec"
    fi

    # Create the issue
    ISSUE_URL=$(gh issue create \
        --title "$TITLE" \
        --body "$FINAL_BODY" \
        --label "$ISSUE_LABELS" \
        2>&1)

    ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oP '\d+$')
    CREATED_ISSUES+=("$ISSUE_NUM")

    echo "  #$ISSUE_NUM — $TITLE [$COMPLEXITY, $PRIORITY] $SPEC_STATUS"

    # Notify for needs-spec issues
    if [[ "$ASSESSMENT" != "pass" ]]; then
        NEEDS_SPEC_ISSUES+=("$ISSUE_NUM")
        FIRST_Q=$(echo "$CLARIFYING_QS" | head -1 | sed 's/^- //')
        "$SCRIPTS_DIR/forge-notify-event.sh" needs_spec \
            --project "$PROJECT_NAME" \
            --issue "$ISSUE_NUM" \
            ${FIRST_Q:+--questions "$FIRST_Q"} 2>/dev/null || true
    fi
done

echo ""
echo "=== forge-prd-to-issues: done ==="
echo "Created ${#CREATED_ISSUES[@]} task issues from PRD"
if [[ ${#NEEDS_SPEC_ISSUES[@]} -gt 0 ]]; then
    echo "Needs spec: ${NEEDS_SPEC_ISSUES[*]} (labeled 'needs-spec', questions attached)"
fi
echo ""

# Output JSON summary for API consumption
python3 -c "
import json
issues = [int(x) for x in '${CREATED_ISSUES[*]}'.split()]
needs_spec = [int(x) for x in '${NEEDS_SPEC_ISSUES[*]:-}'.split() if x]
print(json.dumps({'created_issues': issues, 'count': len(issues), 'needs_spec': needs_spec}))
"
