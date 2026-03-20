#!/usr/bin/env bash
set -euo pipefail

# forge-init.sh — Bootstrap a new project from scaffold + stack template
#
# Usage: forge-init.sh <project-name> <stack>
# Stacks: nextjs, fastapi, react-spa, python-cli, typescript-lib
#
# Creates project in projects/inception/<name>/ with:
#   - CLAUDE.md (from template + stack additions)
#   - spec/ directory (MVP.md, BACKLOG.md templates)
#   - .agent/ directory (STEERING.md, LOG.md, ERRORS.md, etc.)
#   - Initialized git repo

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCAFFOLD="$FORGE_ROOT/templates/project-scaffold"
STACKS="$FORGE_ROOT/templates/stacks"

usage() {
    echo "Usage: forge-init.sh <project-name> <stack>"
    echo ""
    echo "Available stacks:"
    for f in "$STACKS"/*.md; do
        basename "$f" .md
    done
    exit 1
}

# --- Validate args ---
[[ $# -lt 2 ]] && usage

PROJECT_NAME="$1"
STACK="$2"
DATE=$(date +%Y-%m-%d)

# Sanitize project name (lowercase, hyphens only)
PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')

PROJECT_DIR="$FORGE_ROOT/projects/inception/$PROJECT_NAME"
STACK_FILE="$STACKS/$STACK.md"

if [[ -d "$PROJECT_DIR" ]]; then
    echo "Error: Project '$PROJECT_NAME' already exists at $PROJECT_DIR"
    exit 1
fi

if [[ ! -f "$STACK_FILE" ]]; then
    echo "Error: Unknown stack '$STACK'"
    echo "Available stacks:"
    for f in "$STACKS"/*.md; do
        basename "$f" .md
    done
    exit 1
fi

# --- Create project from scaffold ---
echo "Creating project '$PROJECT_NAME' with stack '$STACK'..."

# Copy scaffold
cp -r "$SCAFFOLD" "$PROJECT_DIR"

# --- Fill in CLAUDE.md template ---
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md.template"
CLAUDE_MD_FINAL="$PROJECT_DIR/CLAUDE.md"

sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
    -e "s/{{DATE}}/$DATE/g" \
    -e "s/{{STACK}}/$STACK/g" \
    -e "s/{{PROBLEM_STATEMENT}}/TODO: Fill in during interview/g" \
    -e "s/{{DEV_COMMAND}}/# TODO: set during interview/g" \
    -e "s/{{BUILD_COMMAND}}/# TODO: set during interview/g" \
    -e "s/{{TEST_COMMAND}}/# TODO: set during interview/g" \
    -e "s/{{LINT_COMMAND}}/# TODO: set during interview/g" \
    -e "s/{{CONVENTIONS}}/TODO: Set during interview/g" \
    "$CLAUDE_MD" > "$CLAUDE_MD_FINAL"

rm "$CLAUDE_MD"

# Append stack-specific content
echo "" >> "$CLAUDE_MD_FINAL"
echo "---" >> "$CLAUDE_MD_FINAL"
echo "" >> "$CLAUDE_MD_FINAL"
echo "## Stack Reference" >> "$CLAUDE_MD_FINAL"
echo "" >> "$CLAUDE_MD_FINAL"
cat "$STACK_FILE" >> "$CLAUDE_MD_FINAL"

# --- Fill in spec templates ---
for template in "$PROJECT_DIR"/spec/*.template; do
    [[ -f "$template" ]] || continue
    final="${template%.template}"
    sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
        -e "s/{{DATE}}/$DATE/g" \
        "$template" > "$final"
    rm "$template"
done

# --- Update CONTEXT.md with project info ---
cat > "$PROJECT_DIR/.agent/CONTEXT.md" << EOF
# Project Context — $PROJECT_NAME

Updated by the Orchestrator after each planning run.
Workers read this to understand current project state without reading full history.

---

## Current State

Project: $PROJECT_NAME
Stack: $STACK
Stage: inception
Created: $DATE
Tasks completed: 0
Tasks in progress: 0
Tasks queued: 0

## Active Blockers

Awaiting interview completion and spec approval.

## Recent Decisions

None yet.

## Next Steps

1. Complete PM interview to fill in CLAUDE.md and spec/MVP.md
2. Review and approve spec
3. Promote to planning (forge-promote.sh $PROJECT_NAME planning)
EOF

# --- Initialize git repo ---
cd "$PROJECT_DIR"
git init -q
git add -A
git commit -q -m "feat: initialize $PROJECT_NAME project scaffold

Stack: $STACK
Pipeline: forge
Stage: inception"

echo ""
echo "Project created: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "  1. Run PM interview to fill in spec/MVP.md and CLAUDE.md"
echo "  2. Review the spec"
echo "  3. Promote: forge-promote.sh $PROJECT_NAME planning"
echo ""
