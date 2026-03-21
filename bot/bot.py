"""forge-bot — Standalone Telegram bot for the forge development pipeline.

Runs two things concurrently:
1. Telegram polling (python-telegram-bot) — handles user commands
2. Notification HTTP endpoint (FastAPI on port 8774) — receives forge script notifications
"""

import atexit
import logging
import threading

import uvicorn
from telegram import Update
from telegram.ext import ApplicationBuilder, CommandHandler, MessageHandler, ContextTypes, filters

from config import BOT_TOKEN, CHAT_ID, NOTIFY_PORT
from handlers.commands import (
    cmd_help, cmd_projects, cmd_status, cmd_board,
    cmd_deploy, cmd_ship, cmd_kick, cmd_plan,
    cmd_adopt, cmd_staging, cmd_e2e,
)
from handlers.conversations import (
    start_new_project, start_live_notes, end_live_notes, route_message,
)
from handlers.claude_mode import (
    cmd_claude_plan, cmd_claude_review, cmd_claude_default,
    cmd_done as claude_cmd_done,
    handle_claude_message, cleanup_all_sessions,
)
from modal_sessions import get_modal_session
from notify_endpoint import notify_app

logging.basicConfig(
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("forge-bot")


def run_notify_server():
    """Run the notification FastAPI server in a background thread."""
    config = uvicorn.Config(
        notify_app,
        host="127.0.0.1",
        port=NOTIFY_PORT,
        log_level="warning",
    )
    server = uvicorn.Server(config)
    server.run()


async def unified_done(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Unified /done handler — routes to Claude mode or live notes."""
    if update.effective_chat.id != CHAT_ID:
        return

    # Try Claude mode first
    modal = get_modal_session(update.effective_chat.id)
    if modal:
        await claude_cmd_done(update, context)
        return

    # Fall through to live notes
    await end_live_notes(update, context)


async def unified_route_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Unified message router — Claude mode takes priority over old sessions."""
    if update.effective_chat.id != CHAT_ID:
        return

    chat_id = update.effective_chat.id

    # Claude modal session takes priority
    modal = get_modal_session(chat_id)
    if modal:
        await handle_claude_message(update, modal)
        return

    # Fall through to old session router (interviews, live notes)
    await route_message(update, context)


def main():
    if not BOT_TOKEN:
        log.error("No bot token found. Check ~/.forge-bot-token")
        return

    # Clean up Claude sessions on exit
    atexit.register(cleanup_all_sessions)

    # Start notification server in background thread
    notify_thread = threading.Thread(target=run_notify_server, daemon=True)
    notify_thread.start()
    log.info(f"Notification endpoint started on port {NOTIFY_PORT}")

    # Build Telegram bot
    application = ApplicationBuilder().token(BOT_TOKEN).build()

    # Deterministic command handlers
    application.add_handler(CommandHandler("start", cmd_help))
    application.add_handler(CommandHandler("help", cmd_help))
    application.add_handler(CommandHandler("projects", cmd_projects))
    application.add_handler(CommandHandler("status", cmd_status))
    application.add_handler(CommandHandler("board", cmd_board))
    application.add_handler(CommandHandler("deploy", cmd_deploy))
    application.add_handler(CommandHandler("ship", cmd_ship))
    application.add_handler(CommandHandler("kick", cmd_kick))
    application.add_handler(CommandHandler("plan", cmd_plan))
    application.add_handler(CommandHandler("adopt", cmd_adopt))
    application.add_handler(CommandHandler("staging", cmd_staging))
    application.add_handler(CommandHandler("e2e", cmd_e2e))

    # Claude Code relay modes
    application.add_handler(CommandHandler("cplan", cmd_claude_plan))
    application.add_handler(CommandHandler("creview", cmd_claude_review))
    application.add_handler(CommandHandler("claude", cmd_claude_default))

    # LLM-powered conversation handlers
    application.add_handler(CommandHandler("newproject", start_new_project))
    application.add_handler(CommandHandler("testing", start_live_notes))

    # Unified /done — handles both Claude mode and live notes
    application.add_handler(CommandHandler("done", unified_done))

    # Non-command messages → unified router
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, unified_route_message))

    log.info("forge-bot starting. Polling for Telegram messages...")
    application.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
