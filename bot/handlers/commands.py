"""Deterministic command handlers. No LLM. Call forge-api, format, reply."""

import subprocess
from telegram import Update
from telegram.ext import ContextTypes

from config import CHAT_ID, FORGE_ROOT
from services.forge_api import api, ForgeAPIError
from services.formatting import format_status, format_projects, format_deploy, truncate


def _check_auth(update: Update) -> bool:
    """Only respond to authorized user."""
    return update.effective_chat.id == CHAT_ID


async def _reply(update: Update, text: str):
    """Send a reply, truncating if needed."""
    await update.message.reply_text(truncate(text))


async def _error_reply(update: Update, e: Exception):
    """Send error reply. NEVER silently fail."""
    if isinstance(e, ForgeAPIError):
        await _reply(update, f"[forge] API error ({e.status_code}): {e.detail[:300]}")
    else:
        await _reply(update, f"[forge] Error: {e}")


def _get_project(context: ContextTypes.DEFAULT_TYPE) -> str | None:
    """Extract project name from command args."""
    if context.args:
        return context.args[0]
    return None


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    await _reply(update, """[forge] Commands:

Modes (modal sessions):
/plan <project>       — Enter [P] Planning mode
/testing <project>    — Enter [T] Testing mode (live notes)
/review <project>     — Enter [R] Review mode
/done                 — Exit current mode

Actions (work in any mode):
/status [project]     — Project status (all or one)
/board <project>      — Kanban task board
/deploy <project>     — Deploy staging branch
/ship <project>       — Promote staging → production
/kick <project>       — Start the orchestrator
/adopt <path>         — Onboard existing project
/newproject           — Start new project interview
/projects             — List all projects
/staging <project>    — What's on staging
/e2e <project>        — Run E2E tests
/help                 — This message""")


async def cmd_projects(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    try:
        data = await api.list_projects()
        await _reply(update, format_projects(data))
    except Exception as e:
        await _error_reply(update, e)


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    try:
        if project:
            data = await api.project_status(project)
            await _reply(update, format_status(data))
        else:
            data = await api.list_projects()
            await _reply(update, format_projects(data))
    except Exception as e:
        await _error_reply(update, e)


async def cmd_board(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /board <project> [task-id]")
        return
    try:
        args = [str(FORGE_ROOT / "scripts" / "forge-board.sh"), project]
        if len(context.args) > 1:
            args.append(context.args[1])
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        output = result.stdout or result.stderr or "No output"
        await _reply(update, f"```\n{output}\n```")
    except Exception as e:
        await _error_reply(update, e)


async def cmd_deploy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /deploy <project>")
        return
    try:
        data = await api.deploy(project, "staging")
        await _reply(update, format_deploy(data))
    except Exception as e:
        await _error_reply(update, e)


async def cmd_ship(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /ship <project>")
        return
    try:
        data = await api.deploy(project, "production")
        await _reply(update, format_deploy(data))
    except Exception as e:
        await _error_reply(update, e)


async def cmd_kick(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /kick <project>")
        return
    try:
        data = await api.run(project)
        issues = data.get('open_issues', data.get('queued_tasks', 0))
        await _reply(update, f"[{project}] Orchestrator started. {issues} open issues.")
    except Exception as e:
        await _error_reply(update, e)



async def cmd_adopt(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Adopt an existing project. If next_action is adoption_interview, hand off to conversation handler."""
    if not _check_auth(update):
        return
    if not context.args:
        await _reply(update, "[forge] Usage: /adopt <path> [--stack X] [--name Y]")
        return

    path = context.args[0]
    name = None
    stack = None
    args = context.args[1:]
    i = 0
    while i < len(args):
        if args[i] == "--name" and i + 1 < len(args):
            name = args[i + 1]
            i += 2
        elif args[i] == "--stack" and i + 1 < len(args):
            stack = args[i + 1]
            i += 2
        else:
            i += 1

    try:
        data = await api.adopt(path, name=name, stack=stack)
        na = data.get("next_action", {})

        if na.get("action") == "adoption_interview":
            # Hand off to conversation handler
            from handlers.conversations import start_adoption_from_api
            await start_adoption_from_api(update, context, data)
        else:
            project_name = data.get("name", "?")
            await _reply(update, f"[{project_name}] Adopted. {na.get('message', '')}")
    except Exception as e:
        await _error_reply(update, e)


async def cmd_staging(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /staging <project>")
        return
    try:
        data = await api.staging_report(project)
        report = data.get("report", "No staging data.")
        await _reply(update, report)
    except Exception as e:
        await _error_reply(update, e)


async def cmd_e2e(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _check_auth(update):
        return
    project = _get_project(context)
    if not project:
        await _reply(update, "[forge] Usage: /e2e <project>")
        return
    try:
        data = await api.trigger_e2e(project)
        status = data.get("status", "?")
        await _reply(update, f"[{project}] E2E tests: {status}")
    except Exception as e:
        await _error_reply(update, e)
