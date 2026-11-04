"""Logging setup for forge-bot. The bot token must never reach the logs."""

import logging

FORMAT = "%(asctime)s [%(name)s] %(levelname)s: %(message)s"
MASK = "[BOT-TOKEN]"


class _MaskingFormatter(logging.Formatter):
    """Replaces the token in the finished line, so tracebacks are covered too."""

    def __init__(self, secret: str):
        super().__init__(FORMAT)
        self._secret = secret

    def format(self, record: logging.LogRecord) -> str:
        return super().format(record).replace(self._secret, MASK)


def configure_logging(bot_token: str) -> None:
    """Log to stderr at INFO, with the bot token masked in every line.

    Telegram puts the token in every API URL. httpx logs each request URL at
    INFO, which wrote the token to the journal on every 10-second poll, so
    httpx is also capped at WARNING: its per-request lines were pure noise.
    """
    handler = logging.StreamHandler()
    # An empty token has nothing to mask, and masking "" would splice MASK
    # between every character of every line.
    handler.setFormatter(_MaskingFormatter(bot_token) if bot_token else logging.Formatter(FORMAT))
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)
    logging.getLogger("httpx").setLevel(logging.WARNING)
