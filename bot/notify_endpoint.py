"""Notification endpoint. Forge scripts POST here to send Telegram messages."""

import logging

import httpx
from fastapi import FastAPI
from pydantic import BaseModel

from config import BOT_TOKEN, CHAT_ID

logger = logging.getLogger("forge-bot.notify")

notify_app = FastAPI(title="forge-bot-notify", version="0.1.0")


class NotifyRequest(BaseModel):
    message: str
    parse_mode: str | None = None  # "Markdown" or "HTML" or None


@notify_app.post("/notify")
async def send_notification(req: NotifyRequest):
    """Send a Telegram message to the user. Called by forge scripts."""
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    payload = {"chat_id": CHAT_ID, "text": req.message}
    if req.parse_mode:
        payload["parse_mode"] = req.parse_mode

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(url, json=payload)

        if resp.status_code != 200 and req.parse_mode:
            logger.warning(f"Retrying notification without parse_mode due to: {resp.status_code}")
            payload.pop("parse_mode", None)
            resp = await client.post(url, json=payload)

        if resp.status_code != 200:
            error = resp.text[:300]
            logger.error(f"NOTIFY FAILED: {resp.status_code} {error}")
            return {"status": "failed", "error": error}

    return {"status": "sent"}


@notify_app.get("/health")
def health():
    return {"status": "ok", "service": "forge-bot-notify"}
