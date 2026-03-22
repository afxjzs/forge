"""forge-api — Project registry and orchestrator trigger for the forge pipeline."""

import hashlib
import hmac
import json
import logging
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel

logger = logging.getLogger("forge-api")

app = FastAPI(title="forge-api", version="0.2.0")

FORGE_ROOT = Path.home() / "nexus" / "infra" / "dev-pipeline"
PROJECTS_DIR = FORGE_ROOT / "projects"
SCRIPTS_DIR = FORGE_ROOT / "scripts"
NEXUS_PROJECTS = Path.home() / "nexus" / "projects"
NEXUS_WEBAPPS = Path.home() / "nexus" / "web-apps"

STAGES = ["inception", "planning", "active", "paused", "shipped"]
VALID_STACKS = ["nextjs", "fastapi", "react-spa", "python-cli", "typescript-lib"]

DOCKER_OPS_URL = os.getenv("DOCKER_OPS_URL", "http://127.0.0.1:8770")
DOCKER_OPS_TOKEN = os.getenv("DOCKER_OPS_TOKEN", "")
GITHUB_WEBHOOK_SECRET = os.getenv("GITHUB_WEBHOOK_SECRET", "")

ADOPTION_QUESTIONS = [
    "What does this project do in a sentence? What problem does it solve?",
    "What's the current state — working, prototype, half-built? What's solid vs. rough?",
    "What are you working on right now or want to work on next?",
    "Any known issues, tech debt, or things that keep breaking?",
    "What does 'done' look like for this project? Or is it ongoing?",
]

NEW_PROJECT_QUESTIONS = [
    "What problem does this solve, and who is it for?",
    "What's the MVP — the smallest thing that delivers value? What's explicitly out of scope?",
    "What stack? Any constraints (existing DB, auth provider, deployment target)?",
    "What does 'done' look like for v1? How will you know it works?",
    "Timeline pressure? Hard deadlines?",
    "Any reference projects or inspiration?",
]


# --- Models ---


class NewProjectRequest(BaseModel):
    name: str
    stack: str


class AdoptRequest(BaseModel):
    path: str
    name: str | None = None
    stack: str | None = None
    skip_analyze: bool = False


class FeatureRequest(BaseModel):
    title: str
    description: str
    priority: int = 2


class PromoteRequest(BaseModel):
    target_stage: str


class PrdToIssuesRequest(BaseModel):
    issue: int | None = None
    file: str | None = None


# --- Helpers ---


def find_project(name: str) -> tuple[str, Path]:
    """Find a project and return (stage, path). Case-insensitive."""
    name_lower = name.lower()
    for stage in STAGES:
        stage_dir = PROJECTS_DIR / stage
        if not stage_dir.exists():
            continue
        for item in stage_dir.iterdir():
            if item.name.lower() == name_lower:
                real_path = item.resolve() if item.is_symlink() else item
                return stage, real_path
    raise HTTPException(status_code=404, detail=f"Project '{name}' not found")


def find_project_path(name: str) -> Path | None:
    """Try to find a project path by name in common locations. Case-insensitive."""
    name_lower = name.lower()
    for base in [NEXUS_PROJECTS, NEXUS_WEBAPPS]:
        if not base.exists():
            continue
        for item in base.iterdir():
            if item.name.lower() == name_lower:
                return item
    return None


def read_task_counts(project_path: Path) -> dict:
    """Read task counts from GitHub Issues (primary) with local file fallback."""
    counts = {"queued": 0, "in_progress": 0, "done": 0, "needs_review": 0}
    gh_env = {
        **__import__("os").environ,
        "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", ""),
    }

    try:
        # Open task issues = queued (minus in-progress)
        result = subprocess.run(
            ["gh", "issue", "list", "--label", "task", "--state", "open", "--json", "number,labels", "--limit", "100"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(project_path),
            env=gh_env,
        )
        if result.returncode == 0:
            issues = json.loads(result.stdout or "[]")
            for issue in issues:
                labels = [lbl["name"] for lbl in issue.get("labels", [])]
                if "in-progress" in labels:
                    counts["in_progress"] += 1
                elif "needs-review" in labels:
                    counts["needs_review"] += 1
                else:
                    counts["queued"] += 1

        # Closed task issues = done
        result = subprocess.run(
            ["gh", "issue", "list", "--label", "task", "--state", "closed", "--json", "number", "--limit", "100"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(project_path),
            env=gh_env,
        )
        if result.returncode == 0:
            closed = json.loads(result.stdout or "[]")
            counts["done"] = len(closed)

        # If we got any GitHub data, return it
        if any(counts.values()):
            counts["source"] = "github"
            return counts
    except Exception as e:
        import logging

        logging.getLogger("forge-api").warning(
            f"read_task_counts: GitHub Issues lookup failed for {project_path.name}: {e}"
        )

    # Fallback to local task files
    tasks_dir = project_path / ".agent" / "tasks"
    if not tasks_dir.exists():
        counts["source"] = "local_fallback"
        return counts
    for task_file in tasks_dir.glob("task-*.md"):
        content = task_file.read_text()
        for status in counts:
            if status == "source":
                continue
            if f"status: {status}" in content:
                counts[status] += 1
                break
    counts["source"] = "local_fallback"
    return counts


def read_last_log_entry(project_path: Path) -> dict | None:
    """Read the last non-schema line from LOG.md."""
    log_file = project_path / ".agent" / "LOG.md"
    if not log_file.exists():
        return None
    lines = log_file.read_text().strip().split("\n")
    for line in reversed(lines):
        if line.startswith('{"_schema'):
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            logger.warning(f"Corrupted LOG.md line (skipping): {line[:200]}")
            continue
    return None


def read_error_count(project_path: Path) -> int:
    """Count error entries in ERRORS.md."""
    errors_file = project_path / ".agent" / "ERRORS.md"
    if not errors_file.exists():
        return 0
    content = errors_file.read_text()
    return sum(1 for line in content.split("\n") if line.startswith("## 20"))


def check_spec_completeness(project_path: Path) -> dict:
    """Check if spec files are filled in or still scaffolds."""
    result = {"complete": True, "missing": []}

    mvp_file = project_path / "spec" / "MVP.md"
    if not mvp_file.exists():
        result["complete"] = False
        result["missing"].append("spec/MVP.md does not exist")
    else:
        content = mvp_file.read_text()
        if "TODO" in content or "scaffold" in content.lower():
            result["complete"] = False
            result["missing"].append("spec/MVP.md is still a scaffold with TODOs")

    backlog_file = project_path / "spec" / "BACKLOG.md"
    if not backlog_file.exists():
        result["complete"] = False
        result["missing"].append("spec/BACKLOG.md does not exist")
    else:
        content = backlog_file.read_text()
        # Check if backlog has any actual items (not just headers and comments)
        has_items = any(
            line.strip().startswith("- ")
            and not line.strip().startswith("- **")
            or (line.strip().startswith("- **") and "TODO" not in line)
            for line in content.split("\n")
        )
        if not has_items and "TODO" not in content:
            # Empty but no TODOs — might be intentionally empty
            pass
        elif "<!-- Add" in content and not has_items:
            result["complete"] = False
            result["missing"].append("spec/BACKLOG.md is empty (no items added)")

    context_file = project_path / ".agent" / "CONTEXT.md"
    if context_file.exists():
        content = context_file.read_text()
        if "Awaiting interview" in content or "Awaiting spec" in content:
            result["complete"] = False
            result["missing"].append(".agent/CONTEXT.md still awaiting interview")

    return result


def determine_next_action(name: str, stage: str, project_path: Path, tasks: dict) -> dict:
    """Determine what the PM should do next for this project. This is the brain."""
    spec = check_spec_completeness(project_path)

    # Adoption incomplete — needs interview
    if not spec["complete"]:
        return {
            "action": "adoption_interview",
            "message": f"[{name}] is in forge but the specs aren't filled in yet. I need to ask you a few questions to get aligned.",
            "instructions": "Ask the following questions ONE AT A TIME. Wait for each answer before asking the next. After all questions are answered, use the answers to write spec/MVP.md, spec/BACKLOG.md, and .agent/CONTEXT.md.",
            "questions": ADOPTION_QUESTIONS,
            "spec_issues": spec["missing"],
            "files_to_write": [
                f"{project_path}/spec/MVP.md",
                f"{project_path}/spec/BACKLOG.md",
                f"{project_path}/.agent/CONTEXT.md",
            ],
        }

    # Has queued tasks — ready to run
    if tasks["queued"] > 0:
        return {
            "action": "ready_to_run",
            "message": f"[{name}] has {tasks['queued']} queued tasks. Say 'kick off {name}' to start the orchestrator.",
        }

    # Has in-progress tasks
    if tasks["in_progress"] > 0:
        return {
            "action": "in_progress",
            "message": f"[{name}] has {tasks['in_progress']} tasks in progress.",
        }

    # No feature specs yet
    features_dir = project_path / "spec" / "features"
    has_features = features_dir.exists() and list(features_dir.glob("*.md"))
    if not has_features:
        return {
            "action": "needs_features",
            "message": f"[{name}] specs are done but no feature files exist yet. Write feature specs in spec/features/ to break the work into buildable pieces, then run the planner.",
        }

    # Has features but no tasks — needs PRD-to-issues conversion
    if tasks["queued"] == 0 and tasks["in_progress"] == 0:
        return {
            "action": "needs_planning",
            "message": f"[{name}] has feature specs but no task issues. Create a PRD issue, then convert it to task issues with prd-to-issues.",
        }

    # All tasks done
    if tasks["done"] > 0 and tasks["queued"] == 0 and tasks["in_progress"] == 0:
        return {
            "action": "all_done",
            "message": f"[{name}] All {tasks['done']} tasks complete. Add more features or ship it.",
        }

    return {
        "action": "idle",
        "message": f"[{name}] is active with no pending work.",
    }


# --- Endpoints ---


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "forge-api",
        "version": "0.2.0",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/projects")
def list_projects():
    """List all projects grouped by stage, with next action for each."""
    result = {}
    for stage in STAGES:
        stage_dir = PROJECTS_DIR / stage
        projects = []
        if stage_dir.exists():
            for item in sorted(stage_dir.iterdir()):
                if item.name.startswith("."):
                    continue
                # Include next action for active/planning projects
                if stage in ("active", "planning"):
                    try:
                        _, project_path = find_project(item.name)
                        tasks = read_task_counts(project_path)
                        next_action = determine_next_action(item.name, stage, project_path, tasks)
                        projects.append(
                            {
                                "name": item.name,
                                "next_action": next_action["action"],
                                "message": next_action["message"],
                            }
                        )
                    except Exception as e:
                        import logging

                        logging.getLogger("forge-api").warning(
                            f"list_projects: failed to get status for {item.name}: {e}"
                        )
                        projects.append({"name": item.name, "error": str(e)})
                else:
                    projects.append({"name": item.name})
        if projects:
            result[stage] = projects
    return result


@app.get("/projects/{name}/status")
def project_status(name: str):
    """Detailed status for a specific project, with next action guidance."""
    stage, project_path = find_project(name)

    # Read CLAUDE.md for stack info
    stack = "unknown"
    claude_md = project_path / "CLAUDE.md"
    if claude_md.exists():
        content = claude_md.read_text()
        for i, line in enumerate(content.split("\n")):
            if line.strip() == "## Stack":
                next_lines = content.split("\n")[i + 1 : i + 4]
                for nl in next_lines:
                    nl = nl.strip()
                    if nl and not nl.startswith("#"):
                        stack = nl
                        break
                break

    tasks = read_task_counts(project_path)
    last_log = read_last_log_entry(project_path)
    errors = read_error_count(project_path)
    spec = check_spec_completeness(project_path)
    next_action = determine_next_action(name, stage, project_path, tasks)

    # Read steering
    steering = "continue"
    steering_file = project_path / ".agent" / "STEERING.md"
    if steering_file.exists():
        content = steering_file.read_text()
        for line in content.split("\n"):
            if "Current directive:" in line:
                steering = line.split("**")[-2] if "**" in line else "continue"
                break

    return {
        "name": name,
        "stage": stage,
        "stack": stack,
        "path": str(project_path),
        "tasks": tasks,
        "last_activity": last_log,
        "errors_recorded": errors,
        "steering": steering,
        "spec_complete": spec["complete"],
        "spec_issues": spec["missing"],
        "next_action": next_action,
    }


@app.post("/projects/new")
def create_project(req: NewProjectRequest):
    """Create a new project in inception stage."""
    if req.stack not in VALID_STACKS:
        raise HTTPException(status_code=400, detail=f"Invalid stack '{req.stack}'. Valid: {VALID_STACKS}")

    for stage in STAGES:
        if (PROJECTS_DIR / stage / req.name).exists():
            raise HTTPException(status_code=409, detail=f"Project '{req.name}' already exists in stage '{stage}'")

    result = subprocess.run(
        [str(SCRIPTS_DIR / "forge-init.sh"), req.name, req.stack],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Init failed: {result.stderr}")

    return {
        "status": "created",
        "name": req.name,
        "stack": req.stack,
        "stage": "inception",
        "path": str(PROJECTS_DIR / "inception" / req.name),
        "next_action": {
            "action": "new_project_interview",
            "message": f"[{req.name}] Project created. Starting interview to define the spec.",
            "instructions": "Ask the following questions ONE AT A TIME. Wait for each answer before asking the next.",
            "questions": NEW_PROJECT_QUESTIONS,
        },
    }


@app.post("/projects/{name}/promote")
def promote_project(name: str, req: PromoteRequest):
    """Promote a project to the next lifecycle stage."""
    if req.target_stage not in STAGES:
        raise HTTPException(status_code=400, detail=f"Invalid stage '{req.target_stage}'. Valid: {STAGES}")

    find_project(name)

    result = subprocess.run(
        [str(SCRIPTS_DIR / "forge-promote.sh"), name, req.target_stage],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Promote failed: {result.stderr}\n{result.stdout}")

    return {"status": "promoted", "name": name, "stage": req.target_stage}


@app.post("/projects/{name}/feature")
def add_feature(name: str, req: FeatureRequest):
    """Add a feature to a project's backlog."""
    stage, project_path = find_project(name)

    backlog_file = project_path / "spec" / "BACKLOG.md"
    if not backlog_file.exists():
        raise HTTPException(status_code=404, detail="No BACKLOG.md found")

    priority_headers = {1: "## Priority 1", 2: "## Priority 2", 3: "## Priority 3"}
    header = priority_headers.get(req.priority, "## Priority 2")

    content = backlog_file.read_text()
    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    entry = f"\n- **{req.title}** ({date}): {req.description}"

    if header in content:
        lines = content.split("\n")
        for i, line in enumerate(lines):
            if line.startswith(header):
                insert_at = i + 1
                for j in range(i + 1, len(lines)):
                    if lines[j].startswith("## "):
                        insert_at = j
                        break
                    insert_at = j + 1
                lines.insert(insert_at, entry)
                break
        content = "\n".join(lines)
    else:
        content += f"\n{header}\n{entry}\n"

    backlog_file.write_text(content)

    return {"status": "added", "project": name, "feature": req.title, "priority": req.priority}


@app.post("/projects/{name}/run")
def trigger_orchestrator(name: str):
    """Trigger the orchestrator (forge-run.sh) for a project."""
    stage, project_path = find_project(name)

    if stage != "active":
        raise HTTPException(status_code=400, detail=f"Project must be in 'active' stage. Currently: '{stage}'")

    # Check GitHub Issues for open tasks
    import logging

    logger = logging.getLogger("forge-api")
    gh_env = {**os.environ, "PATH": "/home/linuxbrew/.linuxbrew/bin:" + os.environ.get("PATH", "")}
    open_issues = 0
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--label", "task", "--state", "open", "--json", "number", "--jq", "length"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(project_path),
            env=gh_env,
        )
        if result.returncode == 0:
            open_issues = int(result.stdout.strip() or "0")
        else:
            logger.error(f"trigger_orchestrator: gh issue list failed: {result.stderr.strip()}")
    except Exception as e:
        logger.error(f"trigger_orchestrator: gh command failed: {e}")

    # Fallback to local task files
    if open_issues == 0:
        tasks = read_task_counts(project_path)
        if tasks["queued"] == 0:
            raise HTTPException(
                status_code=400,
                detail="No open issues or queued tasks. Create issues first (use /write-a-prd then /prd-to-issues).",
            )

    log_file = project_path / ".agent" / "orchestrator-run.log"
    with open(log_file, "w") as f:
        process = subprocess.Popen(
            [str(SCRIPTS_DIR / "forge-run.sh"), str(project_path)],
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    # Verify the process actually started
    if process.poll() is not None and process.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"forge-run.sh failed to start (exit code {process.returncode}). Check {log_file}",
        )

    return {"status": "started", "name": name, "pid": process.pid, "open_issues": open_issues, "log": str(log_file)}


@app.post("/projects/{name}/plan")
def trigger_planner(name: str):
    """Trigger the planner (forge-plan.sh) to generate task queue from feature specs."""
    stage, project_path = find_project(name)

    if stage not in ("active", "planning"):
        raise HTTPException(
            status_code=400, detail=f"Project must be in 'active' or 'planning' stage. Currently: '{stage}'"
        )

    features_dir = project_path / "spec" / "features"
    if not features_dir.exists() or not list(features_dir.glob("*.md")):
        raise HTTPException(status_code=400, detail="No feature specs in spec/features/. Write feature specs first.")

    log_file = project_path / ".agent" / "planner-run.log"
    with open(log_file, "w") as f:
        process = subprocess.Popen(
            [str(SCRIPTS_DIR / "forge-plan.sh"), str(project_path)],
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    # Verify the process actually started
    if process.poll() is not None and process.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"forge-plan.sh failed to start (exit code {process.returncode}). Check {log_file}",
        )

    return {"status": "started", "name": name, "pid": process.pid, "log": str(log_file)}


@app.post("/projects/{name}/prd-to-issues")
def prd_to_issues(name: str, req: PrdToIssuesRequest):
    """Convert a PRD (GitHub Issue or spec file) into task issues."""
    stage, project_path = find_project(name)

    if stage not in ("active", "planning"):
        raise HTTPException(
            status_code=400, detail=f"Project must be in 'active' or 'planning' stage. Currently: '{stage}'"
        )

    if not req.issue and not req.file:
        raise HTTPException(
            status_code=400, detail="Provide either 'issue' (GitHub Issue number) or 'file' (spec file path)"
        )

    cmd = [str(SCRIPTS_DIR / "forge-prd-to-issues.sh"), str(project_path)]
    if req.issue:
        cmd += ["--issue", str(req.issue)]
    elif req.file:
        cmd += ["--file", req.file]

    log_file = project_path / ".agent" / "prd-to-issues-run.log"
    with open(log_file, "w") as f:
        process = subprocess.Popen(
            cmd,
            stdout=f,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    # Verify the process actually started
    if process.poll() is not None and process.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"forge-prd-to-issues.sh failed to start (exit code {process.returncode}). Check {log_file}",
        )

    return {"status": "started", "name": name, "pid": process.pid, "log": str(log_file)}


@app.post("/projects/adopt")
def adopt_project(req: AdoptRequest):
    """Adopt an existing project into the forge pipeline."""
    project_path = Path(req.path).expanduser().resolve()

    if not project_path.exists():
        raise HTTPException(status_code=404, detail=f"Path '{req.path}' does not exist")

    name = req.name or project_path.name

    # Check if already adopted — if so, return status with next action
    for stage in STAGES:
        if (PROJECTS_DIR / stage / name).exists():
            _, real_path = find_project(name)
            tasks = read_task_counts(real_path)
            next_action = determine_next_action(name, stage, real_path, tasks)
            return {
                "status": "already_adopted",
                "name": name,
                "stage": stage,
                "path": str(real_path),
                "next_action": next_action,
            }

    # Not yet adopted — run forge-adopt.sh
    cmd = [str(SCRIPTS_DIR / "forge-adopt.sh"), str(project_path)]
    if req.stack:
        cmd.extend(["--stack", req.stack])
    if req.name:
        cmd.extend(["--name", req.name])
    cmd.append("--skip-analyze")  # Always skip — PM handles interview

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)

    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Adopt failed: {result.stderr}\n{result.stdout}")

    # Return with next action (will be adoption_interview since specs are TODOs)
    adopted_path = (PROJECTS_DIR / "active" / name).resolve()
    tasks = read_task_counts(adopted_path)
    next_action = determine_next_action(name, "active", adopted_path, tasks)

    return {
        "status": "adopted",
        "name": name,
        "path": str(adopted_path),
        "stack": req.stack or "auto-detected",
        "stage": "active",
        "next_action": next_action,
    }


class DeployRequest(BaseModel):
    environment: str  # "production" or "staging"
    pr_number: int | None = None  # required for staging


# Map forge project names to docker-ops project names
# Most match, but some differ (e.g., forge "arby" = docker-ops "arby")
DOCKER_OPS_PROJECT_MAP = {
    "omnilingo": "omnilingo",
    "arby": "arby",
    "corpus": "corpus",
}


@app.post("/projects/{name}/deploy")
async def deploy_project(name: str, req: DeployRequest):
    """Deploy a project to production or staging via docker-ops."""
    stage, project_path = find_project(name)
    timestamp = datetime.now(timezone.utc).isoformat()

    if req.environment == "production":
        # Safety gate: verify staging was deployed and tested before production
        staging_file = project_path / ".agent" / "staging.json"
        if not staging_file.exists():
            raise HTTPException(
                status_code=400,
                detail="Cannot deploy to production — no staging deployment found. Deploy to staging first, review it, then promote.",
            )

        # Check if E2E tests have been run (results.json exists)
        e2e_results = project_path / "test-artifacts" / "results.json"
        if (project_path / "tests" / "e2e").exists() and not e2e_results.exists():
            raise HTTPException(
                status_code=400,
                detail="Cannot deploy to production — E2E tests have not been run on staging. Run E2E tests first.",
            )

        # Production deploy: merge staging→main, then rebuild via docker-ops
        docker_ops_name = DOCKER_OPS_PROJECT_MAP.get(name, name)

        # Check if staging branch exists
        staging_check = subprocess.run(
            ["git", "rev-parse", "--verify", "staging"],
            cwd=str(project_path),
            capture_output=True,
            text=True,
        )

        if staging_check.returncode != 0:
            raise HTTPException(
                status_code=400,
                detail=f"Staging branch does not exist in {name}. Cannot promote to production without a staging branch.",
            )

        # Merge staging into main
        subprocess.run(["git", "checkout", "main"], cwd=str(project_path), capture_output=True)
        merge_result = subprocess.run(
            ["git", "merge", "staging", "--no-edit", "-m", "promote: staging → main"],
            cwd=str(project_path),
            capture_output=True,
            text=True,
        )
        if merge_result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Merge staging→main failed: {merge_result.stderr}",
            )
        # Push main to remote
        subprocess.run(
            ["git", "push", "origin", "main"],
            cwd=str(project_path),
            capture_output=True,
        )

        # Call docker-ops to rebuild
        async with httpx.AsyncClient(timeout=300) as client:
            resp = await client.post(
                f"{DOCKER_OPS_URL}/docker/compose/up",
                json={"project": docker_ops_name, "build": True, "services": []},
                headers={"Authorization": f"Bearer {DOCKER_OPS_TOKEN}"},
            )

        if resp.status_code != 200:
            raise HTTPException(
                status_code=500,
                detail=f"Docker-ops deploy failed: {resp.text}",
            )

        resp.json()  # Validate response is valid JSON

        # Verify container is running
        async with httpx.AsyncClient(timeout=30) as client:
            status_resp = await client.get(
                f"{DOCKER_OPS_URL}/docker/compose/status",
                params={"project": docker_ops_name},
                headers={"Authorization": f"Bearer {DOCKER_OPS_TOKEN}"},
            )

        services = status_resp.json().get("services", []) if status_resp.status_code == 200 else []
        running = any(s.get("State") == "running" for s in services)

        # Get the commit that was deployed
        commit_result = subprocess.run(
            ["git", "log", "--oneline", "-1"],
            cwd=str(project_path),
            capture_output=True,
            text=True,
        )
        commit = commit_result.stdout.strip() if commit_result.returncode == 0 else "unknown"

        # Run smoke tests if available
        smoke_test = project_path / "scripts" / "smoke-test.sh"
        smoke_passed = None
        if smoke_test.exists() and running:
            # Determine production URL from Caddyfile or convention
            prod_urls = {
                "omnilingo": "https://omni.afx.cc",
                "arby": "https://arby.afx.cc",
                "corpus": "https://corpus.afx.cc",
            }
            prod_url = prod_urls.get(name)
            if prod_url:
                import time

                time.sleep(5)  # Wait for container to fully start
                smoke_result = subprocess.run(
                    [str(smoke_test), prod_url],
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                smoke_passed = smoke_result.returncode == 0

        # Log the deploy
        log_file = project_path / ".agent" / "LOG.md"
        if log_file.exists():
            log_entry = json.dumps(
                {
                    "action": "deploy",
                    "environment": "production",
                    "timestamp": timestamp,
                    "commit": commit,
                    "status": "success" if running else "failed",
                    "smoke_tests": "passed" if smoke_passed else ("failed" if smoke_passed is False else "skipped"),
                }
            )
            with open(log_file, "a") as f:
                f.write(log_entry + "\n")

        smoke_msg = ""
        if smoke_passed is True:
            smoke_msg = " Smoke tests passed."
        elif smoke_passed is False:
            smoke_msg = " ⚠️ SMOKE TESTS FAILED — check immediately."

        return {
            "status": "deployed" if running else "failed",
            "name": name,
            "environment": "production",
            "commit": commit,
            "container_running": running,
            "smoke_tests": "passed" if smoke_passed else ("failed" if smoke_passed is False else "skipped"),
            "message": f"[{name}] {'Deployed to production.' if running else 'Deploy failed — check logs.'} Commit: {commit}.{smoke_msg}",
        }

    elif req.environment == "staging":
        if req.pr_number is None:
            raise HTTPException(status_code=400, detail="pr_number required for staging deploys")

        # Staging deploy via forge-deploy.sh
        result = subprocess.run(
            [str(SCRIPTS_DIR / "forge-deploy.sh"), name, str(req.pr_number)],
            capture_output=True,
            text=True,
            timeout=300,
        )

        if result.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=f"Staging deploy failed: {result.stderr}\n{result.stdout}",
            )

        # Read staging state
        staging_state = {}
        staging_file = project_path / ".agent" / "staging.json"
        if staging_file.exists():
            staging_state = json.loads(staging_file.read_text())

        return {
            "status": "deployed",
            "name": name,
            "environment": "staging",
            "pr_number": req.pr_number,
            "url": staging_state.get("url", "unknown"),
            "message": f"[{name}] PR #{req.pr_number} deployed to staging. Test at {staging_state.get('url', 'unknown')}",
        }

    else:
        raise HTTPException(
            status_code=400, detail=f"Invalid environment '{req.environment}'. Use 'production' or 'staging'."
        )


@app.get("/projects/{name}/staging-report")
def staging_report(name: str):
    """Generate a staging release report: what changed, what to review, unpromoted PRs."""
    stage, project_path = find_project(name)

    # Get commits on staging that aren't on main
    diff_log = subprocess.run(
        ["git", "log", "main..staging", "--oneline", "--no-merges"],
        cwd=str(project_path),
        capture_output=True,
        text=True,
    )
    commits = diff_log.stdout.strip().split("\n") if diff_log.returncode == 0 and diff_log.stdout.strip() else []

    # Get merge commits (PRs) on staging not on main
    merge_log = subprocess.run(
        ["git", "log", "main..staging", "--oneline", "--merges"],
        cwd=str(project_path),
        capture_output=True,
        text=True,
    )
    merges = merge_log.stdout.strip().split("\n") if merge_log.returncode == 0 and merge_log.stdout.strip() else []

    # Get file-level diff summary
    diff_stat = subprocess.run(
        ["git", "diff", "main..staging", "--stat"],
        cwd=str(project_path),
        capture_output=True,
        text=True,
    )
    stat = diff_stat.stdout.strip() if diff_stat.returncode == 0 else ""

    # Read staging state if available
    staging_state = {}
    staging_file = project_path / ".agent" / "staging.json"
    if staging_file.exists():
        staging_state = json.loads(staging_file.read_text())

    # Read recent log entries for context on what tasks completed
    log_file = project_path / ".agent" / "LOG.md"
    recent_tasks = []
    if log_file.exists():
        lines = log_file.read_text().strip().split("\n")
        for line in reversed(lines[-20:]):
            try:
                entry = json.loads(line)
                if entry.get("status") == "done" and entry.get("task_id"):
                    recent_tasks.append(entry["task_id"])
            except json.JSONDecodeError:
                continue

    # Read task summaries for completed tasks
    task_summaries = []
    tasks_dir = project_path / ".agent" / "tasks"
    if tasks_dir.exists():
        for tid in recent_tasks[:10]:
            task_file = tasks_dir / f"{tid}.md"
            if task_file.exists():
                content = task_file.read_text()
                title_line = ""
                for line in content.split("\n"):
                    if line.startswith("title:"):
                        title_line = line.replace("title:", "").strip()
                        break
                    if line.startswith("# "):
                        title_line = line.lstrip("# ").strip()
                        break
                if title_line:
                    task_summaries.append(f"{tid}: {title_line}")

    # Build the report
    staging_url = staging_state.get("url", f"https://{name}-staging.afx.cc")

    report_lines = [f"*[{name}] New staging deploy*", ""]

    if staging_url:
        report_lines.append(f"URL: {staging_url}")
        report_lines.append("")

    if task_summaries:
        report_lines.append("*What changed:*")
        for ts in task_summaries:
            report_lines.append(f"  - {ts}")
        report_lines.append("")

    if commits:
        report_lines.append(f"*Commits on staging (not in prod):* {len(commits)}")
        for c in commits[:10]:
            report_lines.append(f"  - {c}")
        if len(commits) > 10:
            report_lines.append(f"  ... and {len(commits) - 10} more")
        report_lines.append("")

    if merges:
        report_lines.append(f"*PRs on staging (not promoted to prod):* {len(merges)}")
        for m in merges:
            report_lines.append(f"  - {m}")
        report_lines.append("")

    if stat:
        # Just the summary line (last line of --stat)
        stat_lines = stat.split("\n")
        summary_line = stat_lines[-1] if stat_lines else ""
        if summary_line:
            report_lines.append(f"*Diff summary:* {summary_line.strip()}")
            report_lines.append("")

    # GitHub compare URL for visual diff
    gh_remote = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=str(project_path),
        capture_output=True,
        text=True,
    )
    if gh_remote.returncode == 0 and "github.com" in gh_remote.stdout:
        # Convert git URL to compare URL
        repo_url = gh_remote.stdout.strip().replace(".git", "").replace("git@github.com:", "https://github.com/")
        report_lines.append(f"*Full diff:* {repo_url}/compare/main...staging")
        report_lines.append("")

    report_lines.append(f'When ready: "ship {name}" to promote to production')

    report = "\n".join(report_lines)

    return {
        "name": name,
        "staging_url": staging_url,
        "commits_ahead": len(commits),
        "unpromoted_merges": len(merges),
        "task_summaries": task_summaries,
        "report": report,
    }


@app.post("/projects/{name}/notify")
async def notify_project(name: str):
    """Generate staging report and send via Telegram notification."""
    report_data = staging_report(name)
    message = report_data["report"]

    # Send via forge-notify.sh
    result = subprocess.run(
        [str(SCRIPTS_DIR / "forge-notify.sh"), message],
        capture_output=True,
        text=True,
        timeout=30,
    )

    return {
        "status": "sent" if result.returncode == 0 else "failed",
        "message": message,
        "notify_output": result.stdout.strip(),
        "notify_error": result.stderr.strip() if result.returncode != 0 else None,
    }


@app.post("/projects/{name}/e2e")
def trigger_e2e(name: str):
    """Run E2E tests against staging."""
    stage, project_path = find_project(name)

    staging_file = project_path / ".agent" / "staging.json"
    if not staging_file.exists():
        raise HTTPException(status_code=400, detail="No staging deployment found")

    staging_state = json.loads(staging_file.read_text())
    staging_url = staging_state.get("url", f"https://{name}-staging.afx.cc")

    e2e_script = SCRIPTS_DIR / "forge-e2e.sh"
    if not e2e_script.exists():
        raise HTTPException(status_code=500, detail="forge-e2e.sh not found")

    result = subprocess.run(
        [str(e2e_script), name, staging_url],
        capture_output=True,
        text=True,
        timeout=600,
    )

    # Read results.json if available
    results_file = project_path / "test-artifacts" / "results.json"
    results = None
    if results_file.exists():
        try:
            results = json.loads(results_file.read_text())
        except json.JSONDecodeError:
            pass

    return {
        "status": "passed" if result.returncode == 0 else "failed",
        "exit_code": result.returncode,
        "results": results,
        "artifacts_url": f"{staging_url}/test-artifacts/",
    }


# --- GitHub Webhook ---


def _verify_github_signature(body: bytes, signature: str) -> bool:
    """Verify HMAC-SHA256 signature from GitHub webhook."""
    if not GITHUB_WEBHOOK_SECRET:
        logger.error("GITHUB_WEBHOOK_SECRET not configured — rejecting webhook")
        return False
    expected = "sha256=" + hmac.new(
        GITHUB_WEBHOOK_SECRET.encode(), body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(signature, expected)


def _repo_to_project_name(repo_full_name: str) -> str | None:
    """Map GitHub repo (e.g. 'afxjzs/OmniLingo') to forge project name.

    Walks adopted projects in active/ and matches by git remote URL.
    """
    repo_lower = repo_full_name.lower()
    active_dir = PROJECTS_DIR / "active"
    if not active_dir.exists():
        return None

    for item in active_dir.iterdir():
        project_path = item.resolve() if item.is_symlink() else item
        try:
            result = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                capture_output=True, text=True, timeout=5,
                cwd=str(project_path),
            )
            if result.returncode == 0:
                remote_url = result.stdout.strip().lower()
                # Match "afxjzs/OmniLingo" against remote URL
                if repo_lower in remote_url:
                    return item.name
        except Exception:
            continue
    return None


@app.post("/webhooks/github")
async def github_webhook(request: Request):
    """Receive GitHub webhook events and trigger orchestrator for new task issues."""
    body = await request.body()
    signature = request.headers.get("X-Hub-Signature-256", "")
    event_type = request.headers.get("X-GitHub-Event", "")

    if not _verify_github_signature(body, signature):
        logger.warning(f"GitHub webhook: invalid signature (event={event_type})")
        raise HTTPException(status_code=401, detail="Invalid signature")

    payload = json.loads(body)

    # Ping event — GitHub sends this when webhook is first configured
    if event_type == "ping":
        logger.info(f"GitHub webhook: ping received for {payload.get('repository', {}).get('full_name', '?')}")
        return {"status": "pong"}

    # Issues event — trigger orchestrator when a task issue is opened or labeled
    if event_type == "issues":
        action = payload.get("action")
        issue = payload.get("issue", {})
        labels = [l["name"] for l in issue.get("labels", [])]
        repo_name = payload.get("repository", {}).get("full_name", "")

        if action in ("opened", "labeled") and "task" in labels:
            project_name = _repo_to_project_name(repo_name)
            if not project_name:
                logger.warning(f"GitHub webhook: repo {repo_name} not mapped to any forge project")
                return {"status": "ignored", "reason": "repo not mapped"}

            logger.info(f"GitHub webhook: new task issue #{issue.get('number')} in {repo_name} → triggering orchestrator for {project_name}")
            try:
                trigger_orchestrator(project_name)
                return {"status": "triggered", "project": project_name, "issue": issue.get("number")}
            except HTTPException as e:
                logger.warning(f"GitHub webhook: orchestrator trigger failed for {project_name}: {e.detail}")
                return {"status": "skipped", "reason": e.detail}
        else:
            return {"status": "ignored", "reason": f"action={action}, no task label"}

    # All other events — acknowledge but ignore
    return {"status": "ignored", "event": event_type}
