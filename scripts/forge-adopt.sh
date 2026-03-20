#!/usr/bin/env bash
set -euo pipefail

# forge-adopt.sh — Onboard an existing project into the forge pipeline
#
# Usage: forge-adopt.sh <project-path> [--stack <stack>] [--name <name>] [--skip-analyze]
#
# What it does (additive only — never modifies existing code):
#   1. Auto-detects stack from project files (or uses --stack override)
#   2. Creates .agent/ scaffold (tasks, steering, log, errors, decisions, context, scores)
#   3. Creates spec/ directory if missing (MVP.md, BACKLOG.md, features/)
#   4. Appends forge section to existing CLAUDE.md (or creates one)
#   5. Registers project as active in forge project registry (symlink)
#   6. Optionally spawns Claude Code to analyze codebase and generate context
#
# Handles:
#   - Projects in ~/nexus/projects/ OR ~/nexus/web-apps/
#   - Existing CLAUDE.md (appends, never overwrites)
#   - Existing .claude/ directory (preserves)
#   - Existing docs/, tests/, tasks/ (preserves, references)
#   - Already-initialized git repos (never re-inits)

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
SCAFFOLD="$FORGE_ROOT/templates/project-scaffold"
STACKS="$FORGE_ROOT/templates/stacks"
PROJECTS_DIR="$FORGE_ROOT/projects"

usage() {
    echo "Usage: forge-adopt.sh <project-path> [--stack <stack>] [--name <name>] [--skip-analyze]"
    echo ""
    echo "Options:"
    echo "  --stack <stack>    Override auto-detected stack (nextjs, fastapi, react-spa, python-cli, typescript-lib)"
    echo "  --name <name>     Override project name (default: directory name)"
    echo "  --skip-analyze    Skip Claude Code codebase analysis"
    echo ""
    echo "Examples:"
    echo "  forge-adopt.sh ~/nexus/projects/kalshi-arb"
    echo "  forge-adopt.sh ~/nexus/web-apps/omnilingo --stack react-spa --name omnilingo"
    exit 1
}

[[ $# -lt 1 ]] && usage

# --- Parse args ---
PROJECT_PATH=""
STACK_OVERRIDE=""
NAME_OVERRIDE=""
SKIP_ANALYZE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack) STACK_OVERRIDE="$2"; shift 2 ;;
        --name) NAME_OVERRIDE="$2"; shift 2 ;;
        --skip-analyze) SKIP_ANALYZE=true; shift ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) PROJECT_PATH="$(realpath "$1")"; shift ;;
    esac
done

[[ -z "$PROJECT_PATH" ]] && usage

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project path '$PROJECT_PATH' does not exist."
    exit 1
fi

PROJECT_NAME="${NAME_OVERRIDE:-$(basename "$PROJECT_PATH")}"
DATE=$(date +%Y-%m-%d)

echo "=== forge-adopt: onboarding '$PROJECT_NAME' ==="
echo "Path: $PROJECT_PATH"
echo ""

# --- Check if already adopted ---
for stage in inception planning active paused shipped; do
    if [[ -e "$PROJECTS_DIR/$stage/$PROJECT_NAME" ]]; then
        echo "Error: Project '$PROJECT_NAME' already exists in forge ($stage stage)."
        echo "If you want to re-adopt, remove: $PROJECTS_DIR/$stage/$PROJECT_NAME"
        exit 1
    fi
done

# --- Auto-detect stack ---
detect_stack() {
    local path="$1"

    # Check package.json (root + workspace subdirs for monorepos)
    if [[ -f "$path/package.json" ]]; then
        # Scan root + all immediate subdirectory package.json files
        local all_deps=""
        for pkg_file in "$path/package.json" "$path"/*/package.json; do
            [[ -f "$pkg_file" ]] || continue
            all_deps="$all_deps $(cat "$pkg_file")"
        done

        if echo "$all_deps" | grep -q '"next"'; then
            echo "nextjs"; return
        fi
        if echo "$all_deps" | grep -qE '"expo"|"react-native"'; then
            echo "react-spa"; return
        fi
        if echo "$all_deps" | grep -q '"react"'; then
            echo "react-spa"; return
        fi

        echo "typescript-lib"; return
    fi

    # Check Python projects (pyproject.toml, requirements.txt, or both)
    if [[ -f "$path/pyproject.toml" ]] || [[ -f "$path/requirements.txt" ]]; then
        # Check all Python dependency files for fastapi
        if grep -qi "fastapi" "$path/pyproject.toml" "$path/requirements.txt" "$path/Dockerfile" 2>/dev/null; then
            echo "fastapi"; return
        fi
        echo "python-cli"; return
    fi

    echo "unknown"
}

if [[ -n "$STACK_OVERRIDE" ]]; then
    STACK="$STACK_OVERRIDE"
    echo "Stack: $STACK (override)"
else
    STACK=$(detect_stack "$PROJECT_PATH")
    echo "Stack: $STACK (auto-detected)"
fi

if [[ "$STACK" == "unknown" ]]; then
    echo ""
    echo "Could not auto-detect stack. Use --stack to specify:"
    echo "  forge-adopt.sh $PROJECT_PATH --stack <nextjs|fastapi|react-spa|python-cli|typescript-lib>"
    exit 1
fi

STACK_FILE="$STACKS/$STACK.md"
if [[ ! -f "$STACK_FILE" ]]; then
    echo "Warning: No stack template for '$STACK'. Continuing without stack-specific rules."
    STACK_FILE=""
fi

# --- Create .agent/ scaffold (non-destructive) ---
echo ""
echo "Creating .agent/ scaffold..."

AGENT_DIR="$PROJECT_PATH/.agent"
mkdir -p "$AGENT_DIR/tasks" "$AGENT_DIR/scores"

# Only create files that don't exist — never overwrite
create_if_missing() {
    local target="$1"
    local source="$2"
    if [[ ! -f "$target" ]]; then
        cp "$source" "$target"
        echo "  Created: $(basename "$target")"
    else
        echo "  Exists:  $(basename "$target") (preserved)"
    fi
}

create_if_missing "$AGENT_DIR/STEERING.md" "$SCAFFOLD/.agent/STEERING.md"
create_if_missing "$AGENT_DIR/ERRORS.md" "$SCAFFOLD/.agent/ERRORS.md"
create_if_missing "$AGENT_DIR/DECISIONS.md" "$SCAFFOLD/.agent/DECISIONS.md"

# LOG.md — create if missing
if [[ ! -f "$AGENT_DIR/LOG.md" ]]; then
    cp "$SCAFFOLD/.agent/LOG.md" "$AGENT_DIR/LOG.md"
    echo "  Created: LOG.md"
else
    echo "  Exists:  LOG.md (preserved)"
fi

# CONTEXT.md — always generate fresh for adopted projects
cat > "$AGENT_DIR/CONTEXT.md" << EOF
# Project Context — $PROJECT_NAME

Updated by the Orchestrator after each planning run.
Workers read this to understand current project state without reading full history.

---

## Current State

Project: $PROJECT_NAME
Stack: $STACK
Stage: active (adopted into forge on $DATE)
Tasks completed: 0
Tasks in progress: 0
Tasks queued: 0

## Active Blockers

None identified yet. Run forge-plan.sh after writing feature specs.

## Recent Decisions

Project adopted into forge pipeline on $DATE.

## Next Steps

1. Review generated spec/MVP.md (if analysis was run)
2. Write feature specs in spec/features/
3. Run forge-plan.sh to generate task queue
4. Run forge-run.sh to start the Ralph Loop
EOF
echo "  Created: CONTEXT.md (fresh)"

# --- Create spec/ directory (non-destructive) ---
echo ""
echo "Creating spec/ directory..."

SPEC_DIR="$PROJECT_PATH/spec"
mkdir -p "$SPEC_DIR/features"

if [[ ! -f "$SPEC_DIR/MVP.md" ]]; then
    cat > "$SPEC_DIR/MVP.md" << EOF
# $PROJECT_NAME — MVP Spec (Retrospective)

**Author:** forge-adopt (auto-generated scaffold)
**Date:** $DATE
**Status:** draft — needs review and completion

---

## Problem Statement

TODO: Describe what this project solves.

## Stack

$STACK

## What's Already Built

TODO: Summarize current state of the codebase.

## What Remains

TODO: List what's left to build or improve.

## Success Criteria

TODO: How do we know this project is "done"?
EOF
    echo "  Created: spec/MVP.md (scaffold — needs editing)"
else
    echo "  Exists:  spec/MVP.md (preserved)"
fi

if [[ ! -f "$SPEC_DIR/BACKLOG.md" ]]; then
    cat > "$SPEC_DIR/BACKLOG.md" << EOF
# $PROJECT_NAME — Feature Backlog

Prioritized list. Top = next to build. Move items up/down to reprioritize.

---

## Priority 1 (Active work)

<!-- Add current priorities here -->

## Priority 2 (Soon)

<!-- Add upcoming work here -->

## Priority 3 (Nice to have)

<!-- Add wishlist items here -->

## Icebox

<!-- Parked ideas -->
EOF
    echo "  Created: spec/BACKLOG.md (empty — needs editing)"
else
    echo "  Exists:  spec/BACKLOG.md (preserved)"
fi

# --- Handle CLAUDE.md ---
echo ""
echo "Configuring CLAUDE.md..."

FORGE_SECTION="
---

## forge Pipeline

This project is managed by the forge agentic development pipeline.

| File | Purpose |
|------|---------|
| \`.agent/CONTEXT.md\` | Current project state (maintained by Orchestrator) |
| \`.agent/ERRORS.md\` | Error catalog with prevention rules |
| \`.agent/DECISIONS.md\` | Architecture decision records |
| \`.agent/tasks/\` | Task queue (Ralph Loop) |
| \`.agent/STEERING.md\` | Edit to redirect Orchestrator mid-run |
| \`.agent/LOG.md\` | Activity history (JSONL) |
| \`.agent/scores/\` | Task quality metrics |
| \`spec/MVP.md\` | MVP spec |
| \`spec/BACKLOG.md\` | Prioritized feature backlog |
| \`spec/features/\` | Individual feature specs |
"

CLAUDE_MD="$PROJECT_PATH/CLAUDE.md"

if [[ -f "$CLAUDE_MD" ]]; then
    # Check if forge section already exists
    if grep -q "forge Pipeline" "$CLAUDE_MD" 2>/dev/null; then
        echo "  CLAUDE.md already has forge section (skipped)"
    else
        echo "$FORGE_SECTION" >> "$CLAUDE_MD"
        echo "  Appended forge section to existing CLAUDE.md"
    fi
elif [[ -f "$PROJECT_PATH/.claude" ]] && [[ ! -d "$PROJECT_PATH/.claude" ]]; then
    # .claude is a file (like corpus), create CLAUDE.md alongside it
    cat > "$CLAUDE_MD" << EOF
# $PROJECT_NAME

## Stack

$STACK

## Commands

\`\`\`bash
# TODO: Fill in project-specific commands
\`\`\`

## Conventions

TODO: Document project conventions.

## Known Footguns

<!-- Populated by agents as they discover issues. -->
$FORGE_SECTION
EOF
    echo "  Created CLAUDE.md (alongside existing .claude file)"
elif [[ -d "$PROJECT_PATH/.claude" ]]; then
    # .claude is a directory (like arby), create CLAUDE.md
    cat > "$CLAUDE_MD" << EOF
# $PROJECT_NAME

## Stack

$STACK

## Commands

\`\`\`bash
# TODO: Fill in project-specific commands
\`\`\`

## Conventions

TODO: Document project conventions.

## Known Footguns

<!-- Populated by agents as they discover issues. -->
$FORGE_SECTION
EOF
    echo "  Created CLAUDE.md (alongside existing .claude/ directory)"
else
    # No CLAUDE.md or .claude at all — create from template + stack
    sed -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
        -e "s/{{STACK}}/$STACK/g" \
        -e "s/{{PROBLEM_STATEMENT}}/TODO: Fill in/g" \
        -e "s/{{DEV_COMMAND}}/# TODO: set/g" \
        -e "s/{{BUILD_COMMAND}}/# TODO: set/g" \
        -e "s/{{TEST_COMMAND}}/# TODO: set/g" \
        -e "s/{{LINT_COMMAND}}/# TODO: set/g" \
        -e "s/{{CONVENTIONS}}/TODO: Set/g" \
        "$SCAFFOLD/CLAUDE.md.template" > "$CLAUDE_MD"

    if [[ -n "$STACK_FILE" ]]; then
        echo "" >> "$CLAUDE_MD"
        echo "---" >> "$CLAUDE_MD"
        echo "" >> "$CLAUDE_MD"
        echo "## Stack Reference" >> "$CLAUDE_MD"
        echo "" >> "$CLAUDE_MD"
        cat "$STACK_FILE" >> "$CLAUDE_MD"
    fi
    echo "  Created CLAUDE.md from template"
fi

# --- Register in forge project registry ---
echo ""
echo "Registering in forge..."

ln -sfn "$PROJECT_PATH" "$PROJECTS_DIR/active/$PROJECT_NAME"
echo "  Symlink: projects/active/$PROJECT_NAME → $PROJECT_PATH"

# --- Update .gitignore if needed ---
if [[ -f "$PROJECT_PATH/.gitignore" ]]; then
    if ! grep -q "\.agent/scores/" "$PROJECT_PATH/.gitignore" 2>/dev/null; then
        echo "" >> "$PROJECT_PATH/.gitignore"
        echo "# forge pipeline (optional — scores are ephemeral)" >> "$PROJECT_PATH/.gitignore"
        echo ".agent/scores/" >> "$PROJECT_PATH/.gitignore"
        echo "  Updated .gitignore (added .agent/scores/)"
    fi
fi

# --- Run Claude Code analysis (optional) ---
if ! $SKIP_ANALYZE; then
    echo ""
    echo "=== Codebase Analysis ==="
    echo "Spawning Claude Code to analyze the codebase and generate context..."
    echo "(Use --skip-analyze to skip this step)"
    echo ""

    # Build list of existing docs for Claude to reference
    EXISTING_DOCS=""
    [[ -f "$PROJECT_PATH/README.md" ]] && EXISTING_DOCS="$EXISTING_DOCS- README.md\n"
    [[ -d "$PROJECT_PATH/docs" ]] && EXISTING_DOCS="$EXISTING_DOCS- docs/ directory\n"
    [[ -f "$PROJECT_PATH/PLAN.md" ]] && EXISTING_DOCS="$EXISTING_DOCS- PLAN.md\n"
    [[ -f "$PROJECT_PATH/CONTEXT.md" ]] && EXISTING_DOCS="$EXISTING_DOCS- CONTEXT.md\n"
    [[ -d "$PROJECT_PATH/tasks" ]] && EXISTING_DOCS="$EXISTING_DOCS- tasks/ directory\n"

    claude \
        --model claude-sonnet-4-6 \
        --dangerously-skip-permissions \
        -p \
        "You are analyzing an existing codebase that has been adopted into the forge development pipeline.

Project: $PROJECT_NAME
Path: $PROJECT_PATH
Stack: $STACK
Date: $DATE

Existing documentation found:
$(echo -e "$EXISTING_DOCS")

Your job: Read the codebase and generate useful context files. Do NOT modify any existing code or config. Only write to these specific files:

1. **$PROJECT_PATH/spec/MVP.md** — Write a retrospective MVP spec:
   - What problem does this project solve?
   - What's already built (key features, endpoints, components)?
   - What's the current state (working, partially built, prototype)?
   - Reference any existing docs (README.md, PLAN.md, docs/) rather than duplicating them.
   - Keep it under 80 lines.

2. **$PROJECT_PATH/spec/BACKLOG.md** — Seed the backlog:
   - Extract TODOs, FIXMEs from the code (grep for them)
   - Check existing task files (tasks/todo.md, PLAN.md, TODO-PLAN.md)
   - Check git log for any 'WIP' or incomplete work
   - Organize by priority: P1 (actively needed), P2 (soon), P3 (nice to have)
   - Keep each item to one line with a brief description.

3. **$PROJECT_PATH/.agent/CONTEXT.md** — Update with actual project state:
   - Current branch and any uncommitted changes
   - What the project does in 2-3 sentences
   - Any existing tests and how to run them
   - Any existing CI/CD or deployment setup
   - Known issues or technical debt

Rules:
- Read broadly but write concisely.
- Reference existing docs by path rather than duplicating their content.
- If the project has existing TODO/task tracking, import items into BACKLOG.md.
- Do NOT touch any existing files except the three above.
- Do NOT modify CLAUDE.md, .claude/, or any source code." \
        2>&1

    echo ""
    echo "Analysis complete."
fi

# --- Summary ---
echo ""
echo "=== forge-adopt complete ==="
echo ""
echo "Project '$PROJECT_NAME' adopted into forge pipeline."
echo ""
echo "  Registry:    $PROJECTS_DIR/active/$PROJECT_NAME"
echo "  Agent dir:   $PROJECT_PATH/.agent/"
echo "  Spec dir:    $PROJECT_PATH/spec/"
echo "  CLAUDE.md:   $PROJECT_PATH/CLAUDE.md"
echo ""
echo "Next steps:"
echo "  1. Review spec/MVP.md and spec/BACKLOG.md"
echo "  2. Write feature specs in spec/features/ for what you want to build next"
echo "  3. Run: forge-plan.sh $PROJECT_PATH"
echo "  4. Run: forge-run.sh $PROJECT_PATH"
echo ""
