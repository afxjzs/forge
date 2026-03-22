#!/usr/bin/env bash
# forge-doctor.sh — Documentation coherence validator for forge pipeline
#
# Validates that all forge instructions, configs, and docs are consistent
# with each other and with the actual codebase.
#
# Usage:
#   forge-doctor.sh [project-path]
#   forge-doctor.sh --self        # validate forge pipeline itself
#
# Exit codes:
#   0 = no ERRORs found (WARNs/INFOs are OK)
#   1 = one or more ERRORs found

set -uo pipefail

FORGE_ROOT="${FORGE_ROOT:-$HOME/nexus/infra/dev-pipeline}"

# ── Colors & formatting ────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Counters ───────────────────────────────────────────────────────────────────
ERRORS=0
WARNS=0
INFOS=0

# ── Reporting helpers ──────────────────────────────────────────────────────────
report_error() {
    local msg="$1"
    echo -e "  ${RED}[ERROR]${RESET} $msg"
    ERRORS=$((ERRORS + 1))
}

report_warn() {
    local msg="$1"
    echo -e "  ${YELLOW}[WARN]${RESET}  $msg"
    WARNS=$((WARNS + 1))
}

report_info() {
    local msg="$1"
    echo -e "  ${BLUE}[INFO]${RESET}  $msg"
    INFOS=$((INFOS + 1))
}

report_ok() {
    local msg="$1"
    echo -e "  ${BOLD}[OK]${RESET}    $msg"
}

section() {
    local title="$1"
    echo ""
    echo -e "${BOLD}━━━ $title ━━━${RESET}"
}

# ── Argument parsing ───────────────────────────────────────────────────────────
TARGET_PATH="$FORGE_ROOT"

if [[ "${1:-}" == "--self" ]]; then
    TARGET_PATH="$FORGE_ROOT"
    shift
elif [[ $# -ge 1 ]]; then
    TARGET_PATH="$(realpath "$1")"
fi

if [[ ! -d "$TARGET_PATH" ]]; then
    echo "ERROR: Path not found: $TARGET_PATH"
    exit 1
fi

echo ""
echo -e "${BOLD}forge-doctor — coherence report${RESET}"
echo "Target: $TARGET_PATH"
echo "Date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Check 1: API endpoint consistency ─────────────────────────────────────────
section "Check 1: API Endpoint Consistency"

API_FILE="$TARGET_PATH/api/api.py"

if [[ ! -f "$API_FILE" ]]; then
    report_info "No api/api.py found — skipping endpoint checks"
else
    # Extract endpoints from api.py
    mapfile -t CODE_ENDPOINTS < <(
        grep -oP '@app\.(get|post|put|patch|delete)\("[^"]+"\)' "$API_FILE" \
        | sed 's/@app\.\(get\|post\|put\|patch\|delete\)("\(.*\)")/\U\1 \2/' \
        | sort
    )

    if [[ ${#CODE_ENDPOINTS[@]} -eq 0 ]]; then
        report_warn "No endpoints found in api/api.py"
    else
        report_ok "Found ${#CODE_ENDPOINTS[@]} endpoints in api/api.py"
    fi

    # Find any markdown files that document endpoints
    DOC_FILES=()
    while IFS= read -r -d '' f; do
        DOC_FILES+=("$f")
    done < <(find "$TARGET_PATH" \( -path "*/.venv" -o -path "*/.git" -o -path "*/.worktrees" \) -prune \
        -o -name "*.md" -print0 2>/dev/null)

    # Check each documented endpoint pattern exists in code
    DOCUMENTED_ENDPOINTS=0
    UNDOCUMENTED_ENDPOINTS=0
    for doc_file in "${DOC_FILES[@]}"; do
        while IFS= read -r line; do
            # Match patterns like POST /projects/new or GET /health
            if echo "$line" | grep -qP '(GET|POST|PUT|PATCH|DELETE)\s+/\S+'; then
                DOCUMENTED_ENDPOINTS=$((DOCUMENTED_ENDPOINTS + 1))
                # Extract method and path
                method=$(echo "$line" | grep -oP '(GET|POST|PUT|PATCH|DELETE)' | head -1)
                path=$(echo "$line" | grep -oP '(GET|POST|PUT|PATCH|DELETE)\s+(/[^\s`|]+)' | sed 's/^[A-Z]* //' | head -1)
                if [[ -n "$path" ]]; then
                    # Normalize path for comparison (replace {param} with regex)
                    path_norm=$(echo "$path" | sed 's/{[^}]*}/{name}/g')
                    found=false
                    for ep in "${CODE_ENDPOINTS[@]}"; do
                        ep_method=$(echo "$ep" | awk '{print $1}')
                        ep_path=$(echo "$ep" | awk '{print $2}' | sed 's/{[^}]*}/{name}/g')
                        if [[ "$ep_method" == "$method" && "$ep_path" == "$path_norm" ]]; then
                            found=true
                            break
                        fi
                    done
                    if ! $found; then
                        rel_doc="${doc_file#$TARGET_PATH/}"
                        report_warn "Endpoint in docs not found in code: $method $path (in $rel_doc)"
                    fi
                fi
            fi
        done < "$doc_file"
    done

    # Check for endpoints in code that have no documentation mention
    for ep in "${CODE_ENDPOINTS[@]}"; do
        ep_method=$(echo "$ep" | awk '{print $1}')
        ep_path=$(echo "$ep" | awk '{print $2}')
        # Skip health endpoint — no need to document
        [[ "$ep_path" == "/health" ]] && continue
        found_in_doc=false
        for doc_file in "${DOC_FILES[@]}"; do
            if grep -qP "${ep_method}\s+${ep_path//\//\\/}" "$doc_file" 2>/dev/null; then
                found_in_doc=true
                break
            fi
        done
        if ! $found_in_doc; then
            UNDOCUMENTED_ENDPOINTS=$((UNDOCUMENTED_ENDPOINTS + 1))
        fi
    done

    if [[ $UNDOCUMENTED_ENDPOINTS -gt 0 ]]; then
        report_info "$UNDOCUMENTED_ENDPOINTS code endpoint(s) have no matching documentation mention"
    else
        report_ok "All code endpoints have documentation mentions"
    fi
fi

# ── Check 2: GitHub label consistency ─────────────────────────────────────────
section "Check 2: GitHub Label Consistency"

# Labels referenced in scripts (hardcoded — these are the canonical set)
SCRIPT_LABELS=("task" "P0" "P1" "P2" "in-progress" "needs-review" "architecture" "mechanical" "prd" "bug" "standard")

# Try to get GitHub labels (only if gh CLI is available and repo exists)
if command -v gh &>/dev/null && cd "$TARGET_PATH" && gh repo view &>/dev/null 2>&1; then
    mapfile -t GH_LABELS < <(gh label list --limit 100 --json name --jq '.[].name' 2>/dev/null | sort)

    if [[ ${#GH_LABELS[@]} -eq 0 ]]; then
        report_warn "Could not fetch labels from GitHub (no labels found or not a GitHub repo)"
    else
        report_ok "Found ${#GH_LABELS[@]} labels on GitHub"

        # Check script labels exist on GitHub
        for label in "${SCRIPT_LABELS[@]}"; do
            [[ "$label" == "standard" ]] && continue  # not a real GH label
            found=false
            for gh_label in "${GH_LABELS[@]}"; do
                if [[ "$gh_label" == "$label" ]]; then
                    found=true
                    break
                fi
            done
            if ! $found; then
                report_error "Label '$label' referenced in scripts but NOT found on GitHub"
            fi
        done

        # Check GitHub labels are known (warn on undocumented labels)
        for gh_label in "${GH_LABELS[@]}"; do
            found=false
            for s_label in "${SCRIPT_LABELS[@]}"; do
                if [[ "$s_label" == "$gh_label" ]]; then
                    found=true
                    break
                fi
            done
            if ! $found; then
                report_info "GitHub label '$gh_label' not referenced in any forge script"
            fi
        done
    fi
else
    report_info "GitHub CLI not available or not in a GitHub repo — skipping label check"
fi

# ── Check 3: File path references ─────────────────────────────────────────────
section "Check 3: File Path References"

# Scan markdown and shell files for path references
FILE_REF_ERRORS=0
FILE_REF_CHECKED=0

# Patterns to match file path references in docs
# Matches things like: `path/to/file.md`, path/to/file, ~/path/to/file
while IFS= read -r -d '' doc_file; do
    rel_doc="${doc_file#$TARGET_PATH/}"
    while IFS= read -r line; do
        # Match backtick-quoted paths that look like real file paths (contain / and extension or known dirs)
        while IFS= read -r ref_path; do
            # Skip empty, URLs, and single-component names
            [[ -z "$ref_path" ]] && continue
            echo "$ref_path" | grep -qP 'https?://' && continue
            echo "$ref_path" | grep -qP '^[a-zA-Z0-9_-]+$' && continue

            # Resolve path
            resolved=""
            if [[ "$ref_path" == ~* ]]; then
                resolved="${HOME}${ref_path:1}"
            elif [[ "$ref_path" == /* ]]; then
                resolved="$ref_path"
            else
                resolved="$TARGET_PATH/$ref_path"
            fi

            # Skip placeholder paths (contain <...>, NNN, *, or {param})
            echo "$ref_path" | grep -qP '(<[^>]+>|\*|NNN|\{[^}]+\})' && continue

            # Only check paths with a recognizable extension or ending in /
            if echo "$resolved" | grep -qP '\.(md|sh|py|json|yaml|yml|toml|env|txt)$'; then
                FILE_REF_CHECKED=$((FILE_REF_CHECKED + 1))
                if [[ ! -f "$resolved" && ! -d "$resolved" ]]; then
                    report_warn "File reference not found: $ref_path (in $rel_doc)"
                    FILE_REF_ERRORS=$((FILE_REF_ERRORS + 1))
                fi
            fi
        done < <(echo "$line" | grep -oP '`[^`]+`' | sed "s/\`//g" | grep -P '/')
    done < "$doc_file"
done < <(find "$TARGET_PATH" \( -path "*/.venv" -o -path "*/.git" -o -path "*/.worktrees" \) -prune \
    -o \( -name "*.md" -o -name "*.sh" \) -print0 2>/dev/null)

if [[ $FILE_REF_CHECKED -eq 0 ]]; then
    report_info "No resolvable file references found in docs"
elif [[ $FILE_REF_ERRORS -eq 0 ]]; then
    report_ok "All $FILE_REF_CHECKED file references resolve correctly"
fi

# ── Check 4: Contradiction patterns ───────────────────────────────────────────
section "Check 4: Contradiction Detection"

CONTRADICTION_FOUND=0

# Known contradiction patterns: look for "do X" near "do NOT X" for the same topic
# We check pairs of keywords that frequently appear together as contradictions
TOPIC_PAIRS=(
    "never pip:use pip"
    "never sudo:use sudo"
    "no sqlite:use sqlite"
    "do not merge:auto-merge"
    "no direct push:push directly"
    "staging only:deploy to production"
)

for pair in "${TOPIC_PAIRS[@]}"; do
    positive="${pair%%:*}"
    negative="${pair##*:}"
    pos_files=()
    neg_files=()
    while IFS= read -r f; do pos_files+=("$f"); done < <(
        grep -rlI "$positive" "$TARGET_PATH" \
            --exclude-dir=".venv" --exclude-dir=".git" --exclude-dir=".worktrees" 2>/dev/null || true
    )
    while IFS= read -r f; do neg_files+=("$f"); done < <(
        grep -rlI "$negative" "$TARGET_PATH" \
            --exclude-dir=".venv" --exclude-dir=".git" --exclude-dir=".worktrees" 2>/dev/null || true
    )
    if [[ ${#pos_files[@]} -gt 0 && ${#neg_files[@]} -gt 0 ]]; then
        # Only flag if the same file has both patterns — that's a real contradiction
        for f in "${pos_files[@]}"; do
            for nf in "${neg_files[@]}"; do
                if [[ "$f" == "$nf" ]]; then
                    rel="$f"
                    [[ "$f" == "$TARGET_PATH"* ]] && rel="${f#$TARGET_PATH/}"
                    report_warn "Possible contradiction in $rel: found both '$positive' and '$negative'"
                    CONTRADICTION_FOUND=$((CONTRADICTION_FOUND + 1))
                fi
            done
        done
    fi
done

if [[ $CONTRADICTION_FOUND -eq 0 ]]; then
    report_ok "No contradiction patterns detected"
fi

# ── Check 5: Stale references ─────────────────────────────────────────────────
section "Check 5: Stale Reference Detection"

STALE_PATTERNS=(
    "FORGE-PM.md:This file was renamed — check for current equivalent"
    "anthropic/claude-3:Outdated model reference — update to claude-4 family"
    "claude-3-sonnet:Outdated model reference — use claude-sonnet-4-6"
    "claude-3-opus:Outdated model reference — use claude-opus-4-6"
    "claude-3-haiku:Outdated model reference — use claude-haiku-4-5"
    "forge-api.*8772:Port 8772 was old forge-api port, now 8773"
)

STALE_FOUND=0
for pattern_entry in "${STALE_PATTERNS[@]}"; do
    pattern="${pattern_entry%%:*}"
    explanation="${pattern_entry##*:}"

    while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        file="${match%%:*}"
        # Skip template files where placeholder is expected
        echo "$file" | grep -qP "(template|example|\.sh\.example)" && continue
        # Skip this script itself
        echo "$file" | grep -q "forge-doctor" && continue
        rel="${file#$TARGET_PATH/}"
        report_warn "Stale reference in $rel: $explanation (pattern: $pattern)"
        STALE_FOUND=$((STALE_FOUND + 1))
    done < <(
        grep -rnI "$pattern" "$TARGET_PATH" \
            --exclude-dir=".venv" --exclude-dir=".git" --exclude-dir=".worktrees" \
            --include="*.md" --include="*.sh" --include="*.py" --include="*.json" \
            2>/dev/null | head -20 || true
    )
done

# Check for unfilled TODOs in CLAUDE.md specifically
if [[ -f "$TARGET_PATH/CLAUDE.md" ]]; then
    if grep -qP '# TODO: set|TODO: Set|TODO: Fill in' "$TARGET_PATH/CLAUDE.md" 2>/dev/null; then
        report_warn "CLAUDE.md has unfilled TODO placeholders — fill in Problem, Commands, and Conventions"
        STALE_FOUND=$((STALE_FOUND + 1))
    fi
fi

if [[ $STALE_FOUND -eq 0 ]]; then
    report_ok "No stale references detected"
fi

# ── Check 6: Secret scan ───────────────────────────────────────────────────────
section "Check 6: Secret Scan"

SECRET_FOUND=0

# Secret patterns (avoid false positives on env var reads and examples)
SECRET_PATTERNS=(
    "sk-ant-[a-zA-Z0-9]"
    "ghp_[a-zA-Z0-9]{20}"
    "TELEGRAM_TOKEN\s*=\s*['\"][0-9]"
    "API_KEY\s*=\s*['\"][a-zA-Z0-9]"
    "password\s*=\s*['\"][^'\"{}$\$]"
    "secret\s*=\s*['\"][^'\"{}$\$]"
    "Bearer [a-zA-Z0-9._-]{20}"
    "token\s*=\s*['\"][a-zA-Z0-9._-]{10}"
)

while IFS= read -r -d '' file; do
    rel="${file#$TARGET_PATH/}"
    # Skip .env files (they're supposed to have secrets, but not tracked)
    [[ "$rel" == ".env" || "$rel" == *"/.env" ]] && continue
    # Skip .env.example files
    echo "$rel" | grep -q "\.env\.example" && continue
    # Skip test fixtures
    echo "$rel" | grep -q "test.*fixture\|fixture.*test" && continue

    for pattern in "${SECRET_PATTERNS[@]}"; do
        matches=$(grep -nIP "$pattern" "$file" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            while IFS= read -r match_line; do
                # Skip comment lines
                echo "$match_line" | grep -qP '^\s*[#*]' && continue
                # Skip os.getenv and process.env (these are reads, not hardcodes)
                echo "$match_line" | grep -qP '(os\.getenv|process\.env|environ\.get|getenv\()' && continue
                # Skip lines that reference .env files
                echo "$match_line" | grep -qP '\.env|env_file|EnvironmentFile' && continue
                # Skip lines that are placeholder/example patterns
                echo "$match_line" | grep -qP '(your_|<[A-Z_]+>|YOUR_|REPLACE_|CHANGEME|example|xxx)' && continue

                line_num="${match_line%%:*}"
                content="${match_line#*:}"
                report_error "Possible hardcoded secret in $rel:$line_num — matches pattern '$pattern'"
                SECRET_FOUND=$((SECRET_FOUND + 1))
            done <<< "$matches"
        fi
    done
done < <(find "$TARGET_PATH" \
    \( -path "*/.venv" -o -path "*/.git" -o -path "*/.worktrees" -o -name "*.pyc" \) -prune \
    -o -type f \( -name "*.py" -o -name "*.sh" -o -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.env" -o -name "*.md" \) \
    -print0 2>/dev/null)

if [[ $SECRET_FOUND -eq 0 ]]; then
    report_ok "No hardcoded secrets detected"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
section "Summary"

echo ""
echo -e "  ${RED}ERRORs: $ERRORS${RESET}  (blocks pipeline — must fix)"
echo -e "  ${YELLOW}WARNs:  $WARNS${RESET}  (should fix)"
echo -e "  ${BLUE}INFOs:  $INFOS${RESET}  (cleanup / FYI)"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}${BOLD}RESULT: FAIL — $ERRORS error(s) found${RESET}"
    echo ""
    exit 1
else
    echo -e "${BOLD}RESULT: PASS — no errors found${RESET}"
    if [[ $WARNS -gt 0 ]]; then
        echo "  ($WARNS warning(s) worth investigating)"
    fi
    echo ""
    exit 0
fi
