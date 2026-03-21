"""Handlers for Claude Code relay modes: /plan, /review, /claude, /done.

Manages modal sessions where user messages are relayed to a Claude Code process.
Supports [P] planning, [R] review, and [D] default modes.
"""

import logging

from telegram import Update
from telegram.ext import ContextTypes

from config import CHAT_ID
from modal_sessions import (
    Mode, ModalSession, MODE_DESCRIPTIONS,
    get_modal_session, set_modal_session, clear_modal_session,
    has_pending_approval,
)
from services.claude_relay import ClaudeSession, send_message, send_wrapup, kill_session
logger = logging.getLogger("forge-bot")

# Store Claude sessions keyed by chat_id
_claude_sessions: dict[int, ClaudeSession] = {}

# Tools that are considered "write" operations
WRITE_TOOL_NAMES = {"Edit", "Write", "Bash", "NotebookEdit"}

# Max Telegram message length
TG_MAX_LEN = 4096


def _check_auth(update: Update) -> bool:
    return update.effective_chat.id == CHAT_ID


async def _reply(update: Update, text: str):
    """Send a reply, splitting if too long for Telegram."""
    if len(text) <= TG_MAX_LEN:
        await update.message.reply_text(text)
    else:
        # Split on paragraph boundaries
        chunks = _split_message(text)
        for chunk in chunks:
            await update.message.reply_text(chunk)


def _split_message(text: str, max_len: int = TG_MAX_LEN) -> list[str]:
    """Split a long message into Telegram-safe chunks."""
    if len(text) <= max_len:
        return [text]

    chunks = []
    while text:
        if len(text) <= max_len:
            chunks.append(text)
            break
        # Find a good split point
        split_at = text.rfind("\n\n", 0, max_len)
        if split_at == -1:
            split_at = text.rfind("\n", 0, max_len)
        if split_at == -1:
            split_at = max_len
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip("\n")
    return chunks


def _get_system_prompt(mode: Mode, project_name: str, project_path: str) -> str:
    """Build the system prompt for a Claude Code session."""
    base = (
        f"You are in a {MODE_DESCRIPTIONS[mode]} session for the project '{project_name}' "
        f"at {project_path}. "
        "The user is communicating via Telegram. Keep responses concise — "
        "Telegram has a 4096 character limit per message. "
        "Use markdown sparingly (Telegram supports basic markdown). "
    )

    if mode == Mode.PLANNING:
        base += (
            "Focus on: understanding requirements, making architectural decisions, "
            "creating specs and PRDs. Read code to understand the codebase. "
            "You can create GitHub Issues for decisions made. "
            "Avoid making code changes unless explicitly asked."
        )
    elif mode == Mode.REVIEW:
        base += (
            "Focus on: reviewing code quality, identifying issues, "
            "suggesting improvements, and tracking decisions. "
            "Create GitHub Issues for any action items. "
            "Read files and search the codebase to understand context."
        )
    else:
        base += (
            "Help the user with whatever they need. "
            "Read and search the codebase freely. "
            "For file modifications, describe what you want to change first."
        )

    return base


async def _enter_mode(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE,
    mode: Mode,
):
    """Enter a Claude Code mode (planning, review, or default)."""
    if not _check_auth(update):
        return

    chat_id = update.effective_chat.id

    # Check for existing session
    existing = get_modal_session(chat_id)
    if existing:
        await _reply(
            update,
            f"{existing.label} Already in {MODE_DESCRIPTIONS[existing.mode]} mode. "
            f"Use /done to end it first."
        )
        return

    # Get project from args
    if not context.args:
        await _reply(update, f"[forge] Usage: /{mode.value.lower()} <project>")
        return

    project_name = context.args[0]

    # Resolve project path — try common locations
    from services.forge_api import api, ForgeAPIError
    try:
        data = await api.project_status(project_name)
        project_path = data.get("path", "")
    except ForgeAPIError:
        # Fallback: try to find project directory
        from pathlib import Path
        candidates = [
            Path.home() / "nexus" / "infra" / project_name,
            Path.home() / "nexus" / "projects" / project_name,
            Path.home() / "nexus" / "web-apps" / project_name,
        ]
        project_path = ""
        for p in candidates:
            if p.exists():
                project_path = str(p)
                break

    if not project_path:
        await _reply(update, f"[forge] Project '{project_name}' not found.")
        return

    # Create sessions
    modal = ModalSession(
        mode=mode,
        project_name=project_name,
        project_path=project_path,
    )
    set_modal_session(chat_id, modal)

    claude = ClaudeSession(
        model="claude-opus-4-6",
        project_path=project_path,
    )
    _claude_sessions[chat_id] = claude

    # Initial message with context
    initial_prompt = context.args[1:] if len(context.args) > 1 else None
    initial_text = " ".join(initial_prompt) if initial_prompt else None

    await _reply(
        update,
        f"{modal.label} {MODE_DESCRIPTIONS[mode]} mode started for {project_name}.\n"
        f"Send messages to chat with Claude. /done to end session."
    )

    # If user provided initial prompt after project name, relay it
    if initial_text:
        await _relay_message(update, modal, claude, initial_text)


async def cmd_claude_plan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter planning mode: /cplan <project> [initial prompt]"""
    await _enter_mode(update, context, Mode.PLANNING)


async def cmd_claude_review(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter review mode: /creview <project> [initial prompt]"""
    await _enter_mode(update, context, Mode.REVIEW)


async def cmd_claude_default(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enter default mode: /claude <project> [initial prompt]"""
    await _enter_mode(update, context, Mode.DEFAULT)


async def cmd_done(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """End the current Claude mode session with a wrapup summary."""
    if not _check_auth(update):
        return

    chat_id = update.effective_chat.id
    modal = get_modal_session(chat_id)

    if not modal:
        # Fall through to old /done handler for live notes
        return False

    claude = _claude_sessions.get(chat_id)
    label = modal.label

    await _reply(update, f"{label} Wrapping up...")

    if claude and claude.session_id:
        # Send wrapup prompt
        async def heartbeat(status):
            await update.message.reply_text(f"{label} {status}")

        wrapup = await send_wrapup(
            claude, modal.mode.value, modal.project_name,
            heartbeat_callback=heartbeat,
        )

        if wrapup.text:
            await _reply(update, f"{label} Summary:\n\n{wrapup.text}")

        if wrapup.error:
            await _reply(update, f"{label} Wrapup error: {wrapup.error}")

        # Show session stats
        await _reply(
            update,
            f"{label} Session ended. "
            f"{claude.total_turns} turns, ${claude.total_cost_usd:.4f} total."
        )

        kill_session(claude)

    # Clean up
    clear_modal_session(chat_id)
    _claude_sessions.pop(chat_id, None)

    return True


async def handle_approval_response(update: Update, modal: ModalSession) -> bool:
    """Handle y/n response to a pending permission approval.

    Returns True if the message was consumed as an approval response.
    """
    if not modal.pending_approval:
        return False

    text = update.message.text.strip().lower()
    if text not in ("y", "n", "yes", "no"):
        return False

    chat_id = update.effective_chat.id
    claude = _claude_sessions.get(chat_id)
    approval = modal.pending_approval
    modal.pending_approval = None
    set_modal_session(chat_id, modal)

    approved = text in ("y", "yes")
    tool_name = approval.get("tool", "unknown")

    if approved and claude:
        # Add tool to allowed list and retry
        claude.allowed_write_tools.add(tool_name)
        await _reply(update, f"{modal.label} Approved. Allowing {tool_name}.")

        # Re-send the original message that triggered the tool use
        original_msg = approval.get("original_message", "")
        if original_msg:
            await _relay_message(update, modal, claude, original_msg)
    else:
        await _reply(update, f"{modal.label} Denied. Skipping {tool_name}.")

    return True


async def _relay_message(
    update: Update,
    modal: ModalSession,
    claude: ClaudeSession,
    text: str,
):
    """Relay a user message to Claude and send the response back."""
    chat_id = update.effective_chat.id
    label = modal.label

    async def heartbeat(status):
        await update.message.reply_text(f"{label} {status}")

    async def on_tool_use(tool_info):
        tool = tool_info.get("tool", "")
        if tool in WRITE_TOOL_NAMES and tool not in claude.allowed_write_tools:
            tool_input = tool_info.get("input", {})
            path = tool_input.get("file_path", tool_input.get("command", ""))[:100]
            logger.info(f"Claude relay: write tool detected: {tool} on {path}")

    # Send to Claude
    result = await send_message(
        text,
        claude,
        system_prompt=_get_system_prompt(modal.mode, modal.project_name, modal.project_path)
        if not claude.session_id else "",  # Only send system prompt on first turn
        heartbeat_callback=heartbeat,
        tool_use_callback=on_tool_use,
    )

    modal.message_count += 1
    set_modal_session(chat_id, modal)

    # Check for permission denials — offer approval
    if result.permission_denials:
        denied_tools = set()
        for denial in result.permission_denials:
            tool_name = denial if isinstance(denial, str) else denial.get("tool", "unknown")
            denied_tools.add(tool_name)

        for tool in denied_tools:
            modal.pending_approval = {
                "tool": tool,
                "original_message": text,
            }
            set_modal_session(chat_id, modal)
            await _reply(
                update,
                f"{label} Claude wants to use {tool}. Approve? (y/n)"
            )
            return  # Wait for approval response

    # Send response
    if result.text:
        await _reply(update, result.text)
    elif result.error:
        await _reply(update, f"{label} Error: {result.error}")
    else:
        await _reply(update, f"{label} (no response)")

    # Notify about tool uses
    write_tools_used = [
        t for t in result.tool_uses
        if t.get("tool") in WRITE_TOOL_NAMES
    ]
    if write_tools_used:
        tool_summary = ", ".join(
            f"{t['tool']}({t.get('input', {}).get('file_path', '')[:50]})"
            for t in write_tools_used
        )
        await _reply(update, f"{label} Tools used: {tool_summary}")


async def handle_claude_message(update: Update, modal: ModalSession):
    """Handle a message in an active Claude mode session."""
    if not _check_auth(update):
        return

    chat_id = update.effective_chat.id

    # Check for pending approval first
    if has_pending_approval(chat_id):
        consumed = await handle_approval_response(update, modal)
        if consumed:
            return

    claude = _claude_sessions.get(chat_id)
    if not claude:
        # Session exists but no Claude process — create one
        claude = ClaudeSession(
            model="claude-opus-4-6",
            project_path=modal.project_path,
        )
        _claude_sessions[chat_id] = claude

    text = update.message.text.strip()
    await _relay_message(update, modal, claude, text)


def cleanup_all_sessions():
    """Clean up all Claude sessions. Called on bot shutdown."""
    for chat_id, claude in _claude_sessions.items():
        kill_session(claude)
    _claude_sessions.clear()

    # Clear modal sessions too
    from modal_sessions import _sessions
    _sessions.clear()

    logger.info("All Claude relay sessions cleaned up.")
