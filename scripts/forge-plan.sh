#!/usr/bin/env bash
set -euo pipefail

# forge-plan.sh — Run Orchestrator in planning mode
#
# Takes feature specs in spec/features/*.md and generates task queue in .agent/tasks/
# Also runs adversarial plan review (Planner-Critic) before finalizing tasks.
#
# Usage: forge-plan.sh <project-path>
#
# This spawns a Claude Code session with the Orchestrator prompt.
# The Orchestrator reads feature specs and writes task files.

FORGE_ROOT="$HOME/nexus/infra/dev-pipeline"
ORCHESTRATOR_PROMPT="$FORGE_ROOT/agents/orchestrator/AGENT.md"
CRITIC_PROMPT="$FORGE_ROOT/agents/planner-critic/AGENT.md"

usage() {
    echo "Usage: forge-plan.sh <project-path>"
    echo ""
    echo "  <project-path>  Path to the project (e.g., ~/nexus/projects/my-app)"
    exit 1
}

[[ $# -lt 1 ]] && usage

PROJECT_PATH="$(realpath "$1")"

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project path '$PROJECT_PATH' does not exist."
    exit 1
fi

if [[ ! -d "$PROJECT_PATH/spec" ]]; then
    echo "Error: No spec/ directory found. Run PM interview first."
    exit 1
fi

# Check for feature specs
FEATURE_COUNT=$(find "$PROJECT_PATH/spec/features" -name "*.md" 2>/dev/null | wc -l)
if [[ "$FEATURE_COUNT" -eq 0 ]]; then
    echo "Error: No feature specs found in spec/features/."
    echo "The PM agent should create these during interview."
    exit 1
fi

echo "=== forge-plan: generating task queue ==="
echo "Project: $PROJECT_PATH"
echo "Features: $FEATURE_COUNT specs found"
echo ""

# --- Phase 1: Generate task specs ---
echo "Phase 1: Generating task specs from feature specs..."
echo ""

# Unset so Claude Code uses OAuth, not the bot's API key
unset ANTHROPIC_API_KEY

claude \
    --model claude-opus-4-6 \
    --append-system-prompt "$(cat "$ORCHESTRATOR_PROMPT")" \
    --dangerously-skip-permissions \
    -p \
    "You are the forge Orchestrator in PLANNING MODE.

Project path: $PROJECT_PATH

Read the following files to understand the project:
1. $PROJECT_PATH/CLAUDE.md
2. $PROJECT_PATH/spec/MVP.md
3. All files in $PROJECT_PATH/spec/features/

Then generate task specs in $PROJECT_PATH/.agent/tasks/ following the format in your AGENT.md.
Each task file should be named task-NNN.md (e.g., task-001.md).
Set all tasks to status: queued.
Assign complexity (mechanical/standard/architecture) to each task.
Set priority numbers (lower = higher priority).
Respect dependencies between tasks.

Write the task files now."

echo ""
echo "Phase 1 complete. Checking generated tasks..."
echo ""

TASK_COUNT=$(find "$PROJECT_PATH/.agent/tasks" -name "task-*.md" 2>/dev/null | wc -l)
echo "Generated $TASK_COUNT tasks."

if [[ "$TASK_COUNT" -eq 0 ]]; then
    echo "Error: No tasks generated. Check Claude Code output above."
    exit 1
fi

# --- Phase 2: Adversarial plan review ---
echo ""
echo "Phase 2: Running Planner-Critic review..."
echo ""

claude \
    --model claude-sonnet-4-6 \
    --append-system-prompt "$(cat "$CRITIC_PROMPT")" \
    --dangerously-skip-permissions \
    -p \
    "You are the forge Planner-Critic.

Review the task specs in $PROJECT_PATH/.agent/tasks/ against:
1. The MVP spec at $PROJECT_PATH/spec/MVP.md
2. The feature specs in $PROJECT_PATH/spec/features/
3. The project CLAUDE.md at $PROJECT_PATH/CLAUDE.md
4. Known error patterns in $PROJECT_PATH/.agent/ERRORS.md (if any exist)

For each task, evaluate using your review checklist (auth, schema, dependencies, edge cases, security, testing, complexity rating, missing tasks, scope creep).

Output your review in the format specified in your AGENT.md.
If any tasks need REVISE or REJECT, explain specifically what needs to change."

echo ""
echo "=== forge-plan complete ==="
echo ""
echo "Review the tasks at: $PROJECT_PATH/.agent/tasks/"
echo "If Planner-Critic flagged issues, edit the task files before running forge-run.sh"
echo ""
echo "When ready: forge-run.sh $PROJECT_PATH"
