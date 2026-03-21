"""forge-bot — Standalone Telegram bot for the forge development pipeline.

Runs two things concurrently:
1. Telegram polling (python-telegram-bot) — handles user commands
2. Notification HTTP endpoint (FastAPI on port 8774) — receives forge script notifications
"""

import asyncio
import logging
import threading

import uvicorn
from telegram.ext import ApplicationBuilder, CommandHandler, MessageHandler, filters

from config import BOT_TOKEN, NOTIFY_PORT
from handlers.commands import (
    cmd_help, cmd_projects, cmd_status, cmd_board,
    cmd_deploy, cmd_ship, cmd_kick,
    cmd_adopt, cmd_staging, cmd_e2e,
)
from handlers.conversations import (
    start_new_project, cmd_plan_mode, cmd_testing_mode, cmd_review_mode,
    cmd_done, route_message,
)
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


def main():
    if not BOT_TOKEN:
        log.error("No bot token found. Check ~/.forge-bot-token")
        return

    # Start notification server in background thread
    notify_thread = threading.Thread(target=run_notify_server, daemon=True)
    notify_thread.start()
    log.info(f"Notification endpoint started on port {NOTIFY_PORT}")

    # Build Telegram bot
    application = ApplicationBuilder().token(BOT_TOKEN).build()

    # Modal session commands (mode entry/exit)
    application.add_handler(CommandHandler("plan", cmd_plan_mode))
    application.add_handler(CommandHandler("testing", cmd_testing_mode))
    application.add_handler(CommandHandler("review", cmd_review_mode))
    application.add_handler(CommandHandler("done", cmd_done))

    # Deterministic command handlers (work in any mode)
    application.add_handler(CommandHandler("start", cmd_help))
    application.add_handler(CommandHandler("help", cmd_help))
    application.add_handler(CommandHandler("projects", cmd_projects))
    application.add_handler(CommandHandler("status", cmd_status))
    application.add_handler(CommandHandler("board", cmd_board))
    application.add_handler(CommandHandler("deploy", cmd_deploy))
    application.add_handler(CommandHandler("ship", cmd_ship))
    application.add_handler(CommandHandler("kick", cmd_kick))
    application.add_handler(CommandHandler("adopt", cmd_adopt))
    application.add_handler(CommandHandler("staging", cmd_staging))
    application.add_handler(CommandHandler("e2e", cmd_e2e))

    # New project interview (runs in default mode)
    application.add_handler(CommandHandler("newproject", start_new_project))

    # Non-command messages → modal session router
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, route_message))

    log.info("forge-bot starting (modal sessions enabled). Polling for Telegram messages...")
    application.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
