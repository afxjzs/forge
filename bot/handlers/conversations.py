"""Modal session handlers: mode entry/exit, message routing, interviews, live notes."""

import json
import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger("forge-bot")

from telegram import Update
from telegram.ext import ContextTypes

from config import CHAT_ID
from services.forge_api import ForgeAPIError, api
from services.formatting import truncate
from services.llm import synthesize_specs
from sessions import (
    ModalSession,
    Mode,
    SessionType,
    SubSession,
    clear_session,
    enter_mode,
    get_session,
    set_session,
)


def _check_auth(update: Update) -> bool:
    return update.effective_chat.id == CHAT_ID


async def _reply(update: Update, text: str, session: ModalSession | None = None):
    """Send a reply. Prepends mode tag if session is in a non-default mode."""
    if session and not session.is_default():
        text = f"{session.tag} {text}"
    await update.message.reply_text(truncate(text))


# ---- Mode Entry Commands ----


async def _validate_project(update: Update, context: ContextTypes.DEFAULT_TYPE) -> str | None:
    """Extract and validate project name from command args. Returns project name or None."""
    if not context.args:
        await update.message.reply_text("[forge] Usage: /<command> <project>")
        return None
    project_name = context.args[0]
    try:
        await api.project_status(project_name)
        return project_name
    except ForgeAPIError:
        await update.message.reply_text(f"[forge] Project '{project_name}' not found.")
        return None


async def cmd_plan_mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter Planning mode for a project."""
    if not _check_auth(update):
        return
    project = await _validate_project(update, context)
    if not project:
        return

    chat_id = update.effective_chat.id
    current = get_session(chat_id)
    if not current.is_default():
        await _reply(update, f"Already in {current.mode.value} mode for {current.project}. Use /done first.", current)
        return

    session = enter_mode(chat_id, Mode.PLANNING, project)
    await _reply(
        update,
        f"Planning mode for **{project}**. Send messages to discuss architecture, features, and specs. /done to exit.",
        session,
    )


async def cmd_testing_mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter Testing mode for a project (live notes)."""
    if not _check_auth(update):
        return
    project = await _validate_project(update, context)
    if not project:
        return

    chat_id = update.effective_chat.id
    current = get_session(chat_id)
    if not current.is_default():
        await _reply(update, f"Already in {current.mode.value} mode for {current.project}. Use /done first.", current)
        return

    try:
        data = await api.project_status(project)
        project_path = data.get("path", "")
    except ForgeAPIError:
        project_path = ""

    session = enter_mode(chat_id, Mode.TESTING, project)
    session.sub = SubSession(
        type=SessionType.LIVE_NOTES,
        context={"project_path": project_path},
    )
    set_session(chat_id, session)
    await _reply(
        update,
        f"Testing mode for **{project}**. Send bugs, feedback, ideas — each becomes a GitHub Issue. /done to exit.",
        session,
    )


async def cmd_review_mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter Review mode for a project."""
    if not _check_auth(update):
        return
    project = await _validate_project(update, context)
    if not project:
        return

    chat_id = update.effective_chat.id
    current = get_session(chat_id)
    if not current.is_default():
        await _reply(update, f"Already in {current.mode.value} mode for {current.project}. Use /done first.", current)
        return

    session = enter_mode(chat_id, Mode.REVIEW, project)
    await _reply(
        update,
        f"Review mode for **{project}**. Send messages to discuss PRs, code quality, and deployment readiness. /done to exit.",
        session,
    )


# ---- Mode Exit ----


async def cmd_done(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Exit current mode with mode-specific wrapup."""
    if not _check_auth(update):
        return

    chat_id = update.effective_chat.id
    session = get_session(chat_id)

    if session.is_default():
        await update.message.reply_text("[forge] No active mode to exit.")
        return

    # Mode-specific wrapup
    if session.mode == Mode.TESTING and session.sub and session.sub.type == SessionType.LIVE_NOTES:
        await _wrapup_testing(update, session)
    elif session.mode == Mode.PLANNING:
        await _reply(update, f"Planning session for **{session.project}** ended.", session)
    elif session.mode == Mode.REVIEW:
        await _reply(update, f"Review session for **{session.project}** ended.", session)

    clear_session(chat_id)


async def _wrapup_testing(update: Update, session: ModalSession):
    """Wrapup for testing mode — deterministic summary of bugs and features created."""
    nc = session.sub.notes_captured if session.sub else {}
    bugs = nc.get("bug", 0)
    features = nc.get("feature", 0)
    project = session.project
    await _reply(
        update,
        f"Done. Created {bugs} bugs, {features} features. /kick {project} to start workers.",
        session,
    )


# ---- New Project Interview (runs in default mode) ----


async def start_new_project(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Start a new project interview (operates in default mode with sub-session)."""
    if not _check_auth(update):
        return

    chat_id = update.effective_chat.id
    current = get_session(chat_id)
    if not current.is_default():
        await _reply(update, f"Already in {current.mode.value} mode. Use /done first.", current)
        return

    questions = [
        "What problem does this solve, and who is it for?",
        "What's the MVP — the smallest thing that delivers value? What's explicitly out of scope?",
        "What stack? Any constraints (existing DB, auth provider, deployment target)?",
        "What does 'done' look like for v1?",
        "Timeline pressure? Hard deadlines?",
        "Any reference projects or inspiration?",
    ]

    session = ModalSession(
        mode=Mode.DEFAULT,
        project="(pending)",
        sub=SubSession(
            type=SessionType.NEW_PROJECT_INTERVIEW,
            questions=questions,
        ),
    )
    set_session(chat_id, session)

    await update.message.reply_text(f"[forge] Starting new project interview.\n\n{questions[0]}")


async def start_adoption_from_api(update: Update, context: ContextTypes.DEFAULT_TYPE, api_data: dict):
    """Called from cmd_adopt when next_action is adoption_interview."""
    na = api_data.get("next_action", {})
    project_name = api_data.get("name", "?")
    questions = na.get("questions", [])
    project_path = api_data.get("path", "")

    session = ModalSession(
        mode=Mode.DEFAULT,
        project=project_name,
        sub=SubSession(
            type=SessionType.ADOPTION_INTERVIEW,
            questions=questions,
            context={"project_path": project_path, "files_to_write": na.get("files_to_write", [])},
        ),
    )
    set_session(update.effective_chat.id, session)

    await update.message.reply_text(
        f"[{project_name}] Specs need filling in. Let me ask a few questions.\n\n{questions[0]}"
    )


async def _handle_interview_answer(update: Update, session: ModalSession):
    """Process an interview answer, ask next question or finalize."""
    chat_id = update.effective_chat.id
    answer = update.message.text.strip()
    sub = session.sub

    sub.answers.append(answer)
    sub.current_question_index += 1

    if sub.current_question_index < len(sub.questions):
        next_q = sub.questions[sub.current_question_index]
        set_session(chat_id, session)
        await update.message.reply_text(f"[{session.project}] Got it.\n\n{next_q}")
    else:
        await update.message.reply_text(f"[{session.project}] All questions answered. Writing specs...")

        try:
            specs = await synthesize_specs(session.project, sub.questions, sub.answers)

            project_path = sub.context.get("project_path", "")
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
            await update.message.reply_text(
                truncate(
                    f"[{session.project}] Adopted and aligned.\n"
                    f"MVP spec written. Backlog: {backlog_count} items.\n"
                    f"Ready for feature specs whenever you want to start building."
                )
            )

        except Exception as e:
            await update.message.reply_text(truncate(f"[{session.project}] Error writing specs: {e}"))
            clear_session(chat_id)


# ---- Live Notes (Testing mode) ----


def _create_github_issue(project_path: str, title: str, body: str, labels: list[str]) -> str | None:
    """Create a GitHub Issue via gh CLI. Returns issue URL or None."""
    try:
        cmd = ["gh", "issue", "create", "--title", title, "--body", body]
        for label in labels:
            cmd.extend(["--label", label])
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            cwd=project_path,
            env={
                **__import__("os").environ,
                "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", ""),
            },
        )
        if result.returncode == 0:
            return result.stdout.strip()
        print(f"gh issue create failed: {result.stderr}")
        return None
    except Exception as e:
        print(f"gh issue create error: {e}")
        return None


def _get_open_issues(project_path: str) -> list[dict]:
    """Get open GitHub Issues for dedup checking."""
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--state", "open", "--json", "number,title", "--limit", "50"],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=project_path,
            env={
                **__import__("os").environ,
                "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", ""),
            },
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception as e:
        logger.warning(f"_get_open_issues: gh command failed: {e}")
    return []


def _comment_on_issue(project_path: str, issue_number: int, comment: str) -> bool:
    """Add a comment to an existing GitHub Issue."""
    try:
        result = subprocess.run(
            ["gh", "issue", "comment", str(issue_number), "--body", comment],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=project_path,
            env={
                **__import__("os").environ,
                "PATH": "/home/linuxbrew/.linuxbrew/bin:" + __import__("os").environ.get("PATH", ""),
            },
        )
        if result.returncode != 0:
            logger.error(f"_comment_on_issue: gh comment on #{issue_number} failed: {result.stderr.strip()}")
        return result.returncode == 0
    except Exception as e:
        logger.error(f"_comment_on_issue: gh command failed: {e}")
        return False


def _parse_note_type(text: str) -> tuple[str | None, str]:
    """Deterministically classify a note by prefix.

    Returns (note_type, clean_text) where note_type is 'bug', 'feature', or None.
    None means no prefix — caller should ask for clarification.
    """
    lower = text.lower()
    for prefix in ("bug:", "b:"):
        if lower.startswith(prefix):
            return "bug", text[len(prefix) :].strip()
    for prefix in ("feature:", "f:"):
        if lower.startswith(prefix):
            return "feature", text[len(prefix) :].strip()
    return None, text


async def _create_testing_issue(
    update: Update,
    session: ModalSession,
    note_type: str,
    text: str,
):
    """Create a GitHub Issue for a testing-mode note (bug or feature)."""
    sub = session.sub
    project_path = sub.context.get("project_path", "")

    label_map = {
        "bug": (["task", "bug", "P0", "standard"], "Bug"),
        "feature": (["task", "enhancement", "P1", "standard"], "Feature"),
    }
    labels, prefix = label_map[note_type]

    issue_title = f"{prefix}: {text}"
    issue_body = f"## From live testing session\n\n{text}\n\n---\nReported via forge-bot /testing session"

    issue_url = _create_github_issue(project_path, issue_title, issue_body, labels)

    sub.notes_captured[note_type] = sub.notes_captured.get(note_type, 0) + 1
    # Clear any pending state
    sub.context.pop("pending_text", None)
    set_session(update.effective_chat.id, session)

    if issue_url:
        issue_num = issue_url.split("/")[-1]
        await _reply(update, f"#{issue_num} created ({note_type}).", session)
    else:
        await _reply(update, "Issue creation failed — logged locally.", session)
        if project_path:
            notes_file = Path(project_path) / ".agent" / "NOTES.md"
            if notes_file.exists():
                with open(notes_file, "a") as f:
                    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
                    f.write(f"\n- [{now}] [{note_type}] {text}\n")


async def _handle_live_note(update: Update, session: ModalSession):
    """Deterministically classify a note by b:/f: prefix and create GitHub Issue."""
    sub = session.sub
    message = update.message.text.strip()

    # Check if we're waiting for a b/f clarification reply
    pending_text = sub.context.get("pending_text")
    if pending_text:
        reply = message.lower()
        if reply == "b":
            await _create_testing_issue(update, session, "bug", pending_text)
        elif reply == "f":
            await _create_testing_issue(update, session, "feature", pending_text)
        else:
            await _reply(update, f'Is "{pending_text[:80]}" a bug or a feature? (b/f)', session)
        return

    # Parse prefix
    note_type, clean_text = _parse_note_type(message)

    if note_type:
        await _create_testing_issue(update, session, note_type, clean_text)
    else:
        # No prefix — ask for clarification and store pending text
        sub.context["pending_text"] = message
        set_session(update.effective_chat.id, session)
        await _reply(update, f'Is "{message[:80]}" a bug or a feature? (b/f)', session)


# ---- Message Router ----


async def route_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Route non-command messages based on modal session state."""
    if not _check_auth(update):
        return

    session = get_session(update.effective_chat.id)

    # Default mode with no sub-session — nothing to route to
    if session.is_default() and session.sub is None:
        await update.message.reply_text("[forge] No active session. Use /help for commands.")
        return

    # Sub-session routing (interviews work in default mode)
    if session.sub:
        if session.sub.type in (SessionType.NEW_PROJECT_INTERVIEW, SessionType.ADOPTION_INTERVIEW):
            await _handle_interview_answer(update, session)
            return
        elif session.sub.type == SessionType.LIVE_NOTES and session.mode == Mode.TESTING:
            await _handle_live_note(update, session)
            return

    # Mode-specific free-form routing (planning, review)
    if session.mode == Mode.PLANNING:
        await _reply(update, "Planning mode active. Claude Code relay coming soon. Use /done to exit.", session)
        return

    if session.mode == Mode.REVIEW:
        await _reply(update, "Review mode active. Claude Code relay coming soon. Use /done to exit.", session)
        return

    await _reply(update, "Unknown session state. Use /done to exit, /help for commands.", session)
