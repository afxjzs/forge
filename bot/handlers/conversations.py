"""LLM-powered conversation handlers: interviews, live notes, research."""

import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from telegram import Update
from telegram.ext import ContextTypes

from config import CHAT_ID, FORGE_ROOT
from sessions import Session, SessionType, get_session, set_session, clear_session
from services.forge_api import api, ForgeAPIError
from services.llm import ask_claude, classify_note, synthesize_specs
from services.formatting import truncate


def _check_auth(update: Update) -> bool:
    return update.effective_chat.id == CHAT_ID


async def _reply(update: Update, text: str):
    await update.message.reply_text(truncate(text))


def _create_github_issue(project_path: str, title: str, body: str, labels: list[str]) -> str | None:
    """Create a GitHub Issue via gh CLI. Returns issue URL or None."""
    try:
        cmd = ["gh", "issue", "create", "--title", title, "--body", body]
        for label in labels:
            cmd.extend(["--label", label])
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            cwd=project_path,
            env={**__import__("os").environ, "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", "")},
        )
        if result.returncode == 0:
            return result.stdout.strip()
        print(f"gh issue create failed: {result.stderr}")
        return None
    except Exception as e:
        print(f"gh issue create error: {e}")
        return None


# ---- Adoption Interview ----


async def start_adoption_from_api(update: Update, context: ContextTypes.DEFAULT_TYPE, api_data: dict):
    """Called from cmd_adopt when next_action is adoption_interview."""
    na = api_data.get("next_action", {})
    project_name = api_data.get("name", "?")
    questions = na.get("questions", [])
    project_path = api_data.get("path", "")

    session = Session(
        type=SessionType.ADOPTION_INTERVIEW,
        project_name=project_name,
        questions=questions,
        context={"project_path": project_path, "files_to_write": na.get("files_to_write", [])},
    )
    set_session(update.effective_chat.id, session)

    await _reply(update, f"[{project_name}] Specs need filling in. Let me ask a few questions.\n\n{questions[0]}")


async def start_new_project(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Start a new project interview."""
    if not _check_auth(update):
        return

    questions = [
        "What problem does this solve, and who is it for?",
        "What's the MVP — the smallest thing that delivers value? What's explicitly out of scope?",
        "What stack? Any constraints (existing DB, auth provider, deployment target)?",
        "What does 'done' look like for v1?",
        "Timeline pressure? Hard deadlines?",
        "Any reference projects or inspiration?",
    ]

    session = Session(
        type=SessionType.NEW_PROJECT_INTERVIEW,
        project_name="(pending)",
        questions=questions,
    )
    set_session(update.effective_chat.id, session)

    await _reply(update, f"[forge] Starting new project interview.\n\n{questions[0]}")


async def handle_interview_answer(update: Update, session: Session):
    """Process an interview answer, ask next question or finalize."""
    chat_id = update.effective_chat.id
    answer = update.message.text.strip()

    session.answers.append(answer)
    session.current_question_index += 1

    if session.current_question_index < len(session.questions):
        next_q = session.questions[session.current_question_index]
        set_session(chat_id, session)
        await _reply(update, f"[{session.project_name}] Got it.\n\n{next_q}")
    else:
        await _reply(update, f"[{session.project_name}] All questions answered. Writing specs...")

        try:
            specs = await synthesize_specs(session.project_name, session.questions, session.answers)

            project_path = session.context.get("project_path", "")
            if project_path:
                path = Path(project_path)
                if path.exists():
                    (path / "spec").mkdir(parents=True, exist_ok=True)
                    (path / ".agent").mkdir(parents=True, exist_ok=True)

                    if specs.get("mvp"):
                        (path / "spec" / "MVP.md").write_text(specs["mvp"])
                    if specs.get("backlog"):
                        (path / "spec" / "BACKLOG.md").write_text(specs["backlog"])
                    if specs.get("context"):
                        (path / ".agent" / "CONTEXT.md").write_text(specs["context"])

            clear_session(chat_id)

            backlog_count = specs.get("backlog", "").count("- **")
            await _reply(update, (
                f"[{session.project_name}] Adopted and aligned.\n"
                f"MVP spec written. Backlog: {backlog_count} items.\n"
                f"Ready for feature specs whenever you want to start building."
            ))

        except Exception as e:
            await _reply(update, f"[{session.project_name}] Error writing specs: {e}")
            clear_session(chat_id)


# ---- Live Notes ----


async def start_live_notes(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Start a live notes session for a project."""
    if not _check_auth(update):
        return

    if not context.args:
        await _reply(update, "[forge] Usage: /testing <project>")
        return

    project_name = context.args[0]

    try:
        data = await api.project_status(project_name)
        project_path = data.get("path", "")
    except ForgeAPIError:
        await _reply(update, f"[forge] Project '{project_name}' not found.")
        return

    session = Session(
        type=SessionType.LIVE_NOTES,
        project_name=project_name,
        context={"project_path": project_path},
    )
    set_session(update.effective_chat.id, session)

    await _reply(update, f"[{project_name}] Live notes active. Send me bugs, feedback, ideas — each becomes a GitHub Issue.")


def _get_open_issues(project_path: str) -> list[dict]:
    """Get open GitHub Issues for dedup checking."""
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--state", "open", "--json", "number,title", "--limit", "50"],
            capture_output=True, text=True, timeout=15, cwd=project_path,
            env={**__import__("os").environ, "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", "")},
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception:
        pass
    return []


def _comment_on_issue(project_path: str, issue_number: int, comment: str) -> bool:
    """Add a comment to an existing GitHub Issue."""
    try:
        result = subprocess.run(
            ["gh", "issue", "comment", str(issue_number), "--body", comment],
            capture_output=True, text=True, timeout=15, cwd=project_path,
            env={**__import__("os").environ, "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", "")},
        )
        return result.returncode == 0
    except Exception:
        return False


async def handle_live_note(update: Update, session: Session):
    """Classify a note, check for duplicates, create or comment on GitHub Issue."""
    note = update.message.text.strip()
    project_path = session.context.get("project_path", "")

    # Fetch existing issues for dedup
    existing_issues = _get_open_issues(project_path)

    try:
        result = await classify_note(note, session.project_name, existing_issues)
    except Exception:
        result = {"action": "create", "category": "ux", "summary": f"[needs-triage] {note[:100]}", "duplicate_of": None, "comment": None}

    action = result.get("action", "create")
    category = result.get("category", "ux")
    summary = result.get("summary", note[:100])
    duplicate_of = result.get("duplicate_of")
    comment_text = result.get("comment")

    if action == "skip" and duplicate_of:
        # Exact duplicate — don't create anything
        session.notes_captured[category] = session.notes_captured.get(category, 0) + 1
        set_session(update.effective_chat.id, session)
        await _reply(update, f"[{session.project_name}] Already tracked in #{duplicate_of}.")
        return

    if action == "comment" and duplicate_of:
        # Related to existing issue — add comment
        body = comment_text or f"Additional note from testing session:\n\n{note}"
        success = _comment_on_issue(project_path, duplicate_of, body)
        session.notes_captured[category] = session.notes_captured.get(category, 0) + 1
        set_session(update.effective_chat.id, session)
        if success:
            await _reply(update, f"[{session.project_name}] Added to #{duplicate_of} ({category}).")
        else:
            await _reply(update, f"[{session.project_name}] Comment on #{duplicate_of} failed — creating new issue.")
            action = "create"  # Fall through to create

    if action == "create":
        # New issue
        label_map = {
            "bug": (["task", "bug", "P0"], "Bug"),
            "feature": (["task", "enhancement", "P1"], "Feature"),
            "ux": (["task", "enhancement", "P2"], "UX"),
            "redirect": (["task", "P0"], "Direction change"),
        }
        labels, prefix = label_map.get(category, (["enhancement"], "Note"))

        issue_title = f"{prefix}: {summary}"
        issue_body = f"## From live testing session\n\n{note}\n\n---\nCaptured via forge bot /testing session\nCategory: {category}"

        issue_url = _create_github_issue(project_path, issue_title, issue_body, labels)

        session.notes_captured[category] = session.notes_captured.get(category, 0) + 1
        set_session(update.effective_chat.id, session)

        if issue_url:
            issue_num = issue_url.split("/")[-1]
            await _reply(update, f"[{session.project_name}] #{issue_num} created ({category}).")
        else:
            await _reply(update, f"[{session.project_name}] Issue creation failed — logged locally.")
            if project_path:
                notes_file = Path(project_path) / ".agent" / "NOTES.md"
                if notes_file.exists():
                    with open(notes_file, "a") as f:
                        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
                        f.write(f"\n- [{now}] [{category}] {note}\n")


async def end_live_notes(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """End live notes session with summary."""
    if not _check_auth(update):
        return

    session = get_session(update.effective_chat.id)
    if not session or session.type != SessionType.LIVE_NOTES:
        await _reply(update, "[forge] No active testing session.")
        return

    nc = session.notes_captured
    parts = []
    total = 0
    for cat, count in nc.items():
        if count > 0:
            parts.append(f"{count} {cat}")
            total += count

    summary = ", ".join(parts) if parts else "nothing captured"

    clear_session(update.effective_chat.id)
    await _reply(update, f"[{session.project_name}] Session ended. {total} GitHub Issues created: {summary}")


# ---- Message Router ----


async def route_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Route non-command messages to the active session handler."""
    if not _check_auth(update):
        return

    session = get_session(update.effective_chat.id)

    if session is None:
        await _reply(update, "[forge] No active session. Use /help for commands.")
        return

    if session.type in (SessionType.NEW_PROJECT_INTERVIEW, SessionType.ADOPTION_INTERVIEW):
        await handle_interview_answer(update, session)
    elif session.type == SessionType.LIVE_NOTES:
        await handle_live_note(update, session)
    else:
        await _reply(update, "[forge] Unknown session type. Use /done to end, /help for commands.")
