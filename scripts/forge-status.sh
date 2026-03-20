#!/usr/bin/env bash
set -euo pipefail

# forge-status.sh — Show status of all forge projects (or one specific project)
#
# Usage: forge-status.sh [project-name]
#   No args: summary of all projects by stage
#   With arg: detailed status of specific project

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
PROJECTS_DIR="$FORGE_ROOT/projects"
STAGES=("inception" "planning" "active" "paused" "shipped")

# --- Resolve actual project path (follows symlinks) ---
resolve_path() {
    local path="$1"
    if [[ -L "$path" ]]; then
        readlink -f "$path"
    else
        echo "$path"
    fi
}

# --- Task counts for a project ---
task_counts() {
    local project_path
    project_path=$(resolve_path "$1")
    local tasks_dir="$project_path/.agent/tasks"

    [[ -d "$tasks_dir" ]] || { echo "no tasks"; return; }

    local queued=0 in_progress=0 done=0 needs_review=0

    for task_file in "$tasks_dir"/task-*.md; do
        [[ -f "$task_file" ]] || continue
        local status
        status=$(grep -m1 "^status:" "$task_file" 2>/dev/null | awk '{print $2}' || echo "unknown")
        case "$status" in
            queued) queued=$((queued + 1)) ;;
            in_progress) in_progress=$((in_progress + 1)) ;;
            done) done=$((done + 1)) ;;
            needs_review) needs_review=$((needs_review + 1)) ;;
        esac
    done

    local total=$((queued + in_progress + done + needs_review))
    if [[ $total -eq 0 ]]; then
        echo "no tasks"
    else
        echo "${done}done ${in_progress}wip ${queued}queued ${needs_review}review"
    fi
}

# --- Last log entry ---
last_activity() {
    local project_path
    project_path=$(resolve_path "$1")
    local log_file="$project_path/.agent/LOG.md"

    [[ -f "$log_file" ]] || { echo "none"; return; }

    # Get last non-schema line
    local last_line
    last_line=$(grep -v "^{\"_schema" "$log_file" | tail -1 2>/dev/null)

    if [[ -z "$last_line" ]]; then
        echo "none"
    else
        # Extract task_id and timestamp
        local task_id timestamp
        task_id=$(echo "$last_line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('task_id','?'))" 2>/dev/null || echo "?")
        timestamp=$(echo "$last_line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('timestamp','?')[:16])" 2>/dev/null || echo "?")
        echo "$task_id @ $timestamp"
    fi
}

# --- Detailed status for one project ---
show_detail() {
    local name="$1"
    local stage=""
    local path=""

    for s in "${STAGES[@]}"; do
        local candidate="$PROJECTS_DIR/$s/$name"
        if [[ -d "$candidate" ]] || [[ -L "$candidate" ]]; then
            stage="$s"
            path="$candidate"
            break
        fi
    done

    if [[ -z "$stage" ]]; then
        echo "Project '$name' not found."
        exit 1
    fi

    local real_path
    real_path=$(resolve_path "$path")

    echo "[$name] Status"
    echo "  Stage:    $stage"
    echo "  Path:     $real_path"

    # Stack
    if [[ -f "$real_path/CLAUDE.md" ]]; then
        local stack
        stack=$(grep -m1 "^## Stack" -A2 "$real_path/CLAUDE.md" 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "unknown")
        echo "  Stack:    $stack"
    fi

    # Tasks
    echo "  Tasks:    $(task_counts "$path")"

    # Last activity
    echo "  Last:     $(last_activity "$path")"

    # Errors count
    local errors=0
    if [[ -f "$real_path/.agent/ERRORS.md" ]]; then
        errors=$(grep -c "^## " "$real_path/.agent/ERRORS.md" 2>/dev/null) || errors=0
    fi
    echo "  Errors:   $errors recorded"

    # Scores
    local score_count=0 score_sum=0
    if [[ -d "$real_path/.agent/scores" ]]; then
        for score_file in "$real_path/.agent/scores"/task-*.json; do
            [[ -f "$score_file" ]] || continue
            local score
            score=$(python3 -c "import sys,json; s=json.load(open('$score_file')); print(s.get('reviewer_score',0) or 0)" 2>/dev/null || echo 0)
            if [[ "$score" != "0" ]]; then
                score_sum=$((score_sum + score))
                score_count=$((score_count + 1))
            fi
        done
    fi
    if [[ $score_count -gt 0 ]]; then
        echo "  Avg score: $(echo "scale=1; $score_sum / $score_count" | bc)/5 ($score_count reviews)"
    fi

    # Steering
    if [[ -f "$real_path/.agent/STEERING.md" ]]; then
        local steering
        steering=$(grep -m1 "Current directive:" "$real_path/.agent/STEERING.md" 2>/dev/null | sed 's/.*\*\*//;s/\*\*//' || echo "unknown")
        echo "  Steering: $steering"
    fi

    echo ""
}

# --- Main ---
if [[ $# -ge 1 ]]; then
    show_detail "$1"
    exit 0
fi

# Summary of all projects
echo "forge — Project Status"
echo "======================"
echo ""

total=0
for stage in "${STAGES[@]}"; do
    stage_dir="$PROJECTS_DIR/$stage"
    projects=()

    for proj in "$stage_dir"/*/; do
        [[ -d "$proj" ]] || continue
        projects+=("$(basename "$proj")")
    done

    if [[ ${#projects[@]} -gt 0 ]]; then
        echo "[$stage] (${#projects[@]})"
        for name in "${projects[@]}"; do
            local_path="$stage_dir/$name"
            if [[ "$stage" == "active" ]] || [[ "$stage" == "planning" ]]; then
                echo "  $name — $(task_counts "$local_path")"
            else
                echo "  $name"
            fi
        done
        echo ""
        total=$((total + ${#projects[@]}))
    fi
done

if [[ $total -eq 0 ]]; then
    echo "No projects yet. Create one with: forge-init.sh <name> <stack>"
fi
