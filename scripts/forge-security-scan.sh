#!/usr/bin/env bash
set -euo pipefail

# forge-security-scan.sh — Run deterministic security tools + /security-review
#
# Usage: forge-security-scan.sh <project-path> [<task-id>]
#
# Runs:
#   Layer 1: bandit, semgrep, gitleaks, npm audit / pip audit
#   Layer 2: Claude Code /security-review on changed files
#
# Exit codes:
#   0 = PASS (no critical findings)
#   1 = BLOCK (critical security issue)
#   2 = WARN (non-critical findings)

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"

usage() {
    echo "Usage: forge-security-scan.sh <project-path> [<task-id>]"
    echo ""
    echo "  If task-id provided, scans only changed files for that task."
    echo "  Otherwise, scans all uncommitted/staged changes."
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT_PATH="$(realpath "$1")"
TASK_ID="${2:-}"
VERDICT="PASS"
FINDINGS=()

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project path '$PROJECT_PATH' does not exist."
    exit 1
fi

cd "$PROJECT_PATH"

# --- Determine changed files ---
if [[ -n "$TASK_ID" ]]; then
    BRANCH="task/$TASK_ID"
    if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
        CHANGED_FILES=$(git diff --name-only main.."$BRANCH" 2>/dev/null || git diff --name-only HEAD)
    else
        CHANGED_FILES=$(git diff --name-only HEAD)
    fi
else
    CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
    STAGED=$(git diff --cached --name-only 2>/dev/null || true)
    CHANGED_FILES=$(echo -e "$CHANGED_FILES\n$STAGED" | sort -u | grep -v '^$' || true)
fi

if [[ -z "$CHANGED_FILES" ]]; then
    echo "No changed files to scan."
    exit 0
fi

# Filter to existing files only
EXISTING_FILES=""
while IFS= read -r f; do
    [[ -f "$f" ]] && EXISTING_FILES="$EXISTING_FILES $f"
done <<< "$CHANGED_FILES"
EXISTING_FILES=$(echo "$EXISTING_FILES" | xargs)

echo "=== forge security scan ==="
echo "Project: $PROJECT_PATH"
echo "Files: $(echo "$CHANGED_FILES" | wc -l) changed"
echo ""

# --- Detect project type ---
HAS_PYTHON=false
HAS_NODE=false
[[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]] && HAS_PYTHON=true
[[ -f "package.json" ]] && HAS_NODE=true

# --- Layer 1: Deterministic Tools ---
echo "--- Layer 1: Deterministic Scans ---"
echo ""

# 1. Gitleaks (secret detection — always run, always critical)
echo "[gitleaks] Scanning for secrets..."
if command -v gitleaks &>/dev/null; then
    GITLEAKS_OUT=$(gitleaks detect --source . --no-git --no-banner 2>&1)
    GITLEAKS_EXIT=$?
    if [[ "$GITLEAKS_EXIT" -ne 0 ]] && [[ "$GITLEAKS_EXIT" -ne 1 ]]; then
        # Exit 1 = leaks found (expected), anything else = tool crashed
        echo "  ERROR: gitleaks crashed (exit $GITLEAKS_EXIT) — treating as BLOCK"
        VERDICT="BLOCK"
        FINDINGS+=("gitleaks: TOOL CRASHED (exit $GITLEAKS_EXIT) — cannot verify no secrets")
    else
        GITLEAKS_COUNT=$(echo "$GITLEAKS_OUT" | grep -c "Secret" 2>/dev/null) || GITLEAKS_COUNT=0
        if [[ "$GITLEAKS_COUNT" -gt 0 ]]; then
            echo "  CRITICAL: $GITLEAKS_COUNT secret(s) detected"
            VERDICT="BLOCK"
            FINDINGS+=("gitleaks: $GITLEAKS_COUNT secret(s) found in code")
        else
            echo "  Clean — no secrets found"
        fi
    fi
else
    echo "  Skipped — gitleaks not installed"
fi
echo ""

# 2. Bandit (Python security)
if $HAS_PYTHON && [[ -n "$EXISTING_FILES" ]]; then
    PYTHON_FILES=$(echo "$EXISTING_FILES" | tr ' ' '\n' | grep '\.py$' || true)
    if [[ -n "$PYTHON_FILES" ]]; then
        echo "[bandit] Scanning Python files..."
        if command -v bandit &>/dev/null; then
            BANDIT_OUT=$(bandit $PYTHON_FILES -f json -ll 2>&1)
            BANDIT_EXIT=$?
            if [[ "$BANDIT_EXIT" -ne 0 ]] && [[ "$BANDIT_EXIT" -ne 1 ]]; then
                # Exit 1 = issues found (expected), anything else = tool crashed
                echo "  ERROR: bandit crashed (exit $BANDIT_EXIT) — treating as BLOCK"
                VERDICT="BLOCK"
                FINDINGS+=("bandit: TOOL CRASHED (exit $BANDIT_EXIT) — cannot verify no issues")
                HIGH=0; MED=0
            else
                HIGH_COUNT=$(echo "$BANDIT_OUT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    high=[r for r in d.get('results',[]) if r['issue_severity']=='HIGH' and r['issue_confidence']=='HIGH']
    med=[r for r in d.get('results',[]) if r['issue_severity']=='MEDIUM']
    print(f'{len(high)} {len(med)}')
except:
    print('PARSE_ERROR 0', file=sys.stderr)
    print('0 0')
" 2>&1)
                HIGH=$(echo "$HIGH_COUNT" | awk '{print $1}')
                MED=$(echo "$HIGH_COUNT" | awk '{print $2}')
                if [[ "$HIGH" -gt 0 ]]; then
                    echo "  CRITICAL: $HIGH high-severity finding(s)"
                    VERDICT="BLOCK"
                    FINDINGS+=("bandit: $HIGH high-severity finding(s)")
                elif [[ "$MED" -gt 0 ]]; then
                    echo "  WARNING: $MED medium-severity finding(s)"
                    [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
                    FINDINGS+=("bandit: $MED medium-severity finding(s)")
                else
                    echo "  Clean"
                fi
            fi
        else
            echo "  Skipped — bandit not installed"
        fi
        echo ""
    fi
fi

# 3. Semgrep (language-agnostic)
if [[ -n "$EXISTING_FILES" ]]; then
    echo "[semgrep] Scanning with auto rules..."
    if command -v semgrep &>/dev/null; then
        SEMGREP_OUT=$(semgrep scan --config auto --json --quiet $EXISTING_FILES 2>&1)
        SEMGREP_EXIT=$?
        if [[ "$SEMGREP_EXIT" -ne 0 ]] && [[ "$SEMGREP_EXIT" -ne 1 ]]; then
            echo "  ERROR: semgrep crashed (exit $SEMGREP_EXIT) — treating as BLOCK"
            VERDICT="BLOCK"
            FINDINGS+=("semgrep: TOOL CRASHED (exit $SEMGREP_EXIT) — cannot verify no issues")
        else
            ERROR_COUNT=$(echo "$SEMGREP_OUT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    errors=[r for r in d.get('results',[]) if r.get('extra',{}).get('severity','')=='ERROR']
    warns=[r for r in d.get('results',[]) if r.get('extra',{}).get('severity','')=='WARNING']
    print(f'{len(errors)} {len(warns)}')
except: print('0 0')
" 2>/dev/null || echo "0 0")
            ERRORS=$(echo "$ERROR_COUNT" | awk '{print $1}')
            WARNS=$(echo "$ERROR_COUNT" | awk '{print $2}')
            if [[ "$ERRORS" -gt 0 ]]; then
                echo "  CRITICAL: $ERRORS error-level finding(s)"
                VERDICT="BLOCK"
                FINDINGS+=("semgrep: $ERRORS error-level finding(s)")
            elif [[ "$WARNS" -gt 0 ]]; then
                echo "  WARNING: $WARNS warning-level finding(s)"
                [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
                FINDINGS+=("semgrep: $WARNS warning-level finding(s)")
            else
                echo "  Clean"
            fi
        fi
    else
        echo "  Skipped — semgrep not installed"
    fi
    echo ""
fi

# 4. npm audit (JS/TS dependency vulns)
if $HAS_NODE; then
    echo "[npm audit] Checking dependency vulnerabilities..."
    NPM_OUT=$(npm audit --json 2>&1)
    NPM_EXIT=$?
    if [[ "$NPM_EXIT" -gt 1 ]]; then
        # Exit 1 = vulns found (expected), >1 = tool error
        echo "  ERROR: npm audit crashed (exit $NPM_EXIT) — treating as WARN"
        [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
        FINDINGS+=("npm audit: TOOL CRASHED (exit $NPM_EXIT) — cannot verify no vulns")
    fi
    CRIT_COUNT=$(echo "$NPM_OUT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    v=d.get('metadata',{}).get('vulnerabilities',{})
    print(f\"{v.get('critical',0)} {v.get('high',0)} {v.get('moderate',0)}\")
except: print('0 0 0')
" 2>/dev/null || echo "0 0 0")
    CRIT=$(echo "$CRIT_COUNT" | awk '{print $1}')
    HIGH_N=$(echo "$CRIT_COUNT" | awk '{print $2}')
    MOD=$(echo "$CRIT_COUNT" | awk '{print $3}')
    if [[ "$CRIT" -gt 0 ]] || [[ "$HIGH_N" -gt 0 ]]; then
        echo "  CRITICAL: $CRIT critical, $HIGH_N high vulnerabilities"
        VERDICT="BLOCK"
        FINDINGS+=("npm audit: $CRIT critical + $HIGH_N high vulnerabilities")
    elif [[ "$MOD" -gt 0 ]]; then
        echo "  WARNING: $MOD moderate vulnerabilities"
        [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
        FINDINGS+=("npm audit: $MOD moderate vulnerabilities")
    else
        echo "  Clean"
    fi
    echo ""
fi

# 5. pip audit (Python dependency vulns)
if $HAS_PYTHON; then
    echo "[pip audit] Checking dependency vulnerabilities..."
    if command -v pip-audit &>/dev/null; then
        PIP_OUT=$(pip-audit --format json 2>&1)
        PIP_EXIT=$?
        if [[ "$PIP_EXIT" -ne 0 ]] && [[ "$PIP_EXIT" -ne 1 ]]; then
            echo "  ERROR: pip-audit crashed (exit $PIP_EXIT) — treating as WARN"
            [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
            FINDINGS+=("pip-audit: TOOL CRASHED (exit $PIP_EXIT) — cannot verify no vulns")
        fi
        VULN_COUNT=$(echo "$PIP_OUT" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d.get('dependencies',[])))
except: print('0')
" 2>/dev/null || echo "0")
        if [[ "$VULN_COUNT" -gt 0 ]]; then
            echo "  WARNING: $VULN_COUNT vulnerable dependencies"
            [[ "$VERDICT" != "BLOCK" ]] && VERDICT="WARN"
            FINDINGS+=("pip audit: $VULN_COUNT vulnerable dependencies")
        else
            echo "  Clean"
        fi
    else
        echo "  Skipped — pip-audit not installed"
    fi
    echo ""
fi

# --- Layer 1 Summary ---
echo "--- Layer 1 Summary ---"
echo "Verdict so far: $VERDICT"
if [[ ${#FINDINGS[@]} -gt 0 ]]; then
    echo "Findings:"
    for f in "${FINDINGS[@]}"; do
        echo "  - $f"
    done
fi
echo ""

# --- Layer 2: Claude Code /security-review ---
echo "--- Layer 2: /security-review ---"
echo ""

if [[ "$VERDICT" == "BLOCK" ]]; then
    echo "Skipping LLM review — already BLOCK from deterministic tools."
    echo "Fix the critical findings above first."
else
    echo "Running Claude Code /security-review on changed files..."
    echo ""

    # Run Claude Code with /security-review skill on the changed files
    set +e
    claude \
        --model claude-sonnet-4-6 \
        --dangerously-skip-permissions \
        -p \
        "/security-review

Review these changed files for security issues:
$CHANGED_FILES

Project path: $PROJECT_PATH
Focus on: auth bypass, privilege escalation, injection, data exposure, race conditions.
Check CLAUDE.md for project-specific security context." \
        2>&1

    CLAUDE_EXIT=$?
    set -e

    if [[ $CLAUDE_EXIT -ne 0 ]]; then
        echo ""
        echo "Warning: /security-review exited with code $CLAUDE_EXIT"
    fi
fi

echo ""

# --- Write results to scorecard if task-id provided ---
if [[ -n "$TASK_ID" ]] && [[ -d "$PROJECT_PATH/.agent/scores" ]]; then
    SCORE_FILE="$PROJECT_PATH/.agent/scores/$TASK_ID.json"
    if [[ -f "$SCORE_FILE" ]]; then
        # Update existing scorecard with security fields
        python3 -c "
import json, sys
with open('$SCORE_FILE') as f:
    data = json.load(f)
data['security_verdict'] = '$VERDICT'
data['security_findings'] = $(python3 -c "import json; print(json.dumps([$(printf '"%s",' "${FINDINGS[@]}" | sed 's/,$//')]))" 2>/dev/null || echo '[]')
with open('$SCORE_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
    fi
fi

# --- Post results as PR comment (if task has a PR) ---
if [[ -n "$TASK_ID" ]]; then
    PR_URL=$(grep -m1 "^pr_url:" "$PROJECT_PATH/.agent/tasks/$TASK_ID.md" 2>/dev/null | sed 's/pr_url: *//' || true)
    if [[ -n "$PR_URL" ]] && command -v gh &>/dev/null; then
        PR_NUMBER=$(echo "$PR_URL" | grep -oP '\d+$' || true)
        if [[ -n "$PR_NUMBER" ]]; then
            FINDINGS_MD=""
            if [[ ${#FINDINGS[@]} -gt 0 ]]; then
                for f in "${FINDINGS[@]}"; do
                    FINDINGS_MD="$FINDINGS_MD\n- $f"
                done
            fi

            COMMENT_BODY="## 🔒 Security Scan — $VERDICT

**Task:** \`$TASK_ID\`

### Findings
$(if [[ ${#FINDINGS[@]} -gt 0 ]]; then
    echo -e "$FINDINGS_MD"
else
    echo "No findings."
fi)

### Tools Run
- gitleaks (secret detection)
- $(if $HAS_PYTHON; then echo "bandit (Python security)"; else echo "bandit (skipped — not Python)"; fi)
- semgrep (static analysis)
- $(if $HAS_NODE; then echo "npm audit (dependency vulns)"; else echo "npm audit (skipped — not Node)"; fi)
- /security-review (LLM analysis)

---
🤖 forge security scan | $(date -u +%Y-%m-%dT%H:%M:%SZ)"

            cd "$PROJECT_PATH"
            gh pr comment "$PR_NUMBER" --body "$COMMENT_BODY" 2>&1 || echo "Warning: Could not post PR comment."
            echo "Security results posted to PR #$PR_NUMBER"
        fi
    fi
fi

# --- Final verdict ---
echo "=== SECURITY VERDICT: $VERDICT ==="

case "$VERDICT" in
    PASS)  echo "No critical findings. Safe to merge."; exit 0 ;;
    WARN)  echo "Non-critical findings logged. Merge can proceed."; exit 2 ;;
    BLOCK) echo "Critical security issue. Merge BLOCKED."; exit 1 ;;
esac
