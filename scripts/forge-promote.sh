#!/usr/bin/env bash
set -euo pipefail

# forge-promote.sh — Move a project between lifecycle stages
#
# Usage: forge-promote.sh <project-name> <target-stage>
# Stages: inception, planning, active, paused, shipped
#
# When promoting to 'active':
#   - Moves project to ~/nexus/projects/<name>/
#   - Creates symlink from projects/active/<name> → ~/nexus/projects/<name>/

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
PROJECTS_DIR="$FORGE_ROOT/projects"
NEXUS_PROJECTS="$HOME/nexus/projects"

VALID_STAGES=("inception" "planning" "active" "paused" "shipped")

usage() {
    echo "Usage: forge-promote.sh <project-name> <target-stage>"
    echo ""
    echo "Stages: ${VALID_STAGES[*]}"
    exit 1
}

[[ $# -lt 2 ]] && usage

PROJECT_NAME="$1"
TARGET_STAGE="$2"

# Validate target stage
valid=false
for stage in "${VALID_STAGES[@]}"; do
    [[ "$stage" == "$TARGET_STAGE" ]] && valid=true
done
$valid || { echo "Error: Invalid stage '$TARGET_STAGE'. Valid: ${VALID_STAGES[*]}"; exit 1; }

# Find current stage
CURRENT_STAGE=""
CURRENT_PATH=""
for stage in "${VALID_STAGES[@]}"; do
    candidate="$PROJECTS_DIR/$stage/$PROJECT_NAME"
    if [[ -d "$candidate" ]] || [[ -L "$candidate" ]]; then
        CURRENT_STAGE="$stage"
        CURRENT_PATH="$candidate"
        break
    fi
done

if [[ -z "$CURRENT_STAGE" ]]; then
    echo "Error: Project '$PROJECT_NAME' not found in any stage."
    echo ""
    echo "Existing projects:"
    for stage in "${VALID_STAGES[@]}"; do
        for proj in "$PROJECTS_DIR/$stage"/*/; do
            [[ -d "$proj" ]] && echo "  [$stage] $(basename "$proj")"
        done
    done
    exit 1
fi

if [[ "$CURRENT_STAGE" == "$TARGET_STAGE" ]]; then
    echo "Project '$PROJECT_NAME' is already in stage '$TARGET_STAGE'."
    exit 0
fi

echo "Promoting '$PROJECT_NAME': $CURRENT_STAGE → $TARGET_STAGE"

# --- Handle promotion to 'active' (special case) ---
if [[ "$TARGET_STAGE" == "active" ]]; then
    REAL_PATH="$NEXUS_PROJECTS/$PROJECT_NAME"

    # If currently a symlink (e.g., coming back from paused), resolve it
    if [[ -L "$CURRENT_PATH" ]]; then
        # Remove old symlink, create new one in active
        rm "$CURRENT_PATH"
    else
        # Move actual directory to ~/nexus/projects/
        mv "$CURRENT_PATH" "$REAL_PATH"
    fi

    # Create symlink in active/
    ln -s "$REAL_PATH" "$PROJECTS_DIR/active/$PROJECT_NAME"

    echo "Moved to: $REAL_PATH"
    echo "Symlink: $PROJECTS_DIR/active/$PROJECT_NAME → $REAL_PATH"

# --- Handle demotion FROM 'active' (e.g., active → paused) ---
elif [[ "$CURRENT_STAGE" == "active" ]]; then
    # The actual project lives at ~/nexus/projects/<name>
    # Remove the active symlink
    rm "$CURRENT_PATH"

    # Create symlink in target stage
    REAL_PATH="$NEXUS_PROJECTS/$PROJECT_NAME"
    if [[ -d "$REAL_PATH" ]]; then
        ln -s "$REAL_PATH" "$PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME"
        echo "Symlink: $PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME → $REAL_PATH"
    else
        echo "Warning: Expected $REAL_PATH but not found. Check manually."
        exit 1
    fi

# --- Normal stage transition (non-active) ---
else
    mv "$CURRENT_PATH" "$PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME"
    echo "Moved to: $PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME"
fi

# --- Update CONTEXT.md ---
CONTEXT_FILE=""
if [[ "$TARGET_STAGE" == "active" ]]; then
    CONTEXT_FILE="$NEXUS_PROJECTS/$PROJECT_NAME/.agent/CONTEXT.md"
elif [[ -L "$PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME" ]]; then
    CONTEXT_FILE="$(readlink -f "$PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME")/.agent/CONTEXT.md"
else
    CONTEXT_FILE="$PROJECTS_DIR/$TARGET_STAGE/$PROJECT_NAME/.agent/CONTEXT.md"
fi

if [[ -f "$CONTEXT_FILE" ]]; then
    # Update the stage line in CONTEXT.md
    sed -i "s/^Stage: .*/Stage: $TARGET_STAGE/" "$CONTEXT_FILE"
    echo "Updated CONTEXT.md stage → $TARGET_STAGE"
fi

echo ""
echo "Done. Project '$PROJECT_NAME' is now in stage '$TARGET_STAGE'."
