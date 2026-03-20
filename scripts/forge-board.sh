#!/usr/bin/env bash
set -euo pipefail

# forge-board.sh — Show GitHub Issues as a kanban board
#
# Usage: forge-board.sh <project-name-or-path> [issue-number]

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
PROJECTS_DIR="$FORGE_ROOT/projects"
STAGES=("inception" "planning" "active" "paused" "shipped")

[[ $# -lt 1 ]] && { echo "Usage: forge-board.sh <project> [issue-number]"; exit 1; }

INPUT="$1"

# Resolve project path
PROJECT_PATH=""
if [[ -d "$INPUT/.git" ]] || [[ -d "$INPUT/.agent" ]]; then
    PROJECT_PATH="$(realpath "$INPUT")"
else
    for stage in "${STAGES[@]}"; do
        candidate="$PROJECTS_DIR/$stage/$INPUT"
        if [[ -e "$candidate" ]]; then
            PROJECT_PATH="$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
            break
        fi
    done
fi

if [[ -z "$PROJECT_PATH" ]]; then
    echo "Error: Project '$INPUT' not found."
    exit 1
fi

PROJECT_NAME=$(basename "$PROJECT_PATH")
cd "$PROJECT_PATH"

# --- Detail view for a specific issue ---
if [[ $# -ge 2 ]]; then
    gh issue view "$2" 2>&1
    exit 0
fi

# --- Board view ---
echo ""
echo "╔══════════════════════════════════════════════════════╗"
printf "║  forge board: %-37s  ║\n" "$PROJECT_NAME"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Get all open issues
ISSUES=$(gh issue list --state open --json number,title,labels --limit 100 2>/dev/null) || {
    echo "Error: Could not read issues. Check gh auth."
    exit 1
}

# Categorize
python3 -c "
import json

issues = json.loads('''$ISSUES''')

def get_labels(issue):
    return [l['name'] for l in issue.get('labels', [])]

blocked = []
review = []
progress = []
prd = []
tasks = []
bugs = []

for i in issues:
    labels = get_labels(i)
    num = i['number']
    title = i['title'][:55]

    # Priority tag
    pri = ''
    if 'P0' in labels: pri = 'P0'
    elif 'P1' in labels: pri = 'P1'
    elif 'P2' in labels: pri = 'P2'

    # Complexity tag
    tier = 'S'
    if 'mechanical' in labels: tier = 'H'
    elif 'architecture' in labels: tier = 'O'

    tag = f'[{tier}|{pri}]' if pri else f'[{tier}]'
    entry = f'  #{num:<4} {tag:8} {title}'

    if 'needs-review' in labels:
        review.append(entry)
    elif 'in-progress' in labels:
        progress.append(entry)
    elif 'prd' in labels:
        prd.append(entry)
    elif 'bug' in labels:
        bugs.append(entry)
    elif 'task' in labels:
        tasks.append(entry)
    else:
        tasks.append(entry)  # unlabeled goes to tasks

if review:
    print(f'⚠  NEEDS REVIEW ({len(review)})')
    print('─' * 53)
    for e in review: print(e)
    print()

if progress:
    print(f'🔄 IN PROGRESS ({len(progress)})')
    print('─' * 53)
    for e in progress: print(e)
    print()

if bugs:
    print(f'🐛 BUGS ({len(bugs)})')
    print('─' * 53)
    for e in bugs: print(e)
    print()

if prd:
    print(f'📋 PRDs ({len(prd)})')
    print('─' * 53)
    for e in prd: print(e)
    print()

if tasks:
    print(f'📦 TASKS ({len(tasks)})')
    print('─' * 53)
    for e in tasks: print(e)
    print()

total = len(issues)
if total == 0:
    print('  No open issues. Clean slate.')
    print()

# Closed recently (last 10)
" 2>/dev/null

# Show recently closed
echo "✅ RECENTLY CLOSED"
echo "─────────────────────────────────────────────────"
gh issue list --state closed --limit 5 --json number,title --jq '.[] | "  #\(.number)  \(.title[:55])"' 2>/dev/null || echo "  (none)"
echo ""
echo "View on GitHub: $(gh repo view --json url -q .url 2>/dev/null)/issues"
