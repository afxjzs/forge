"""forge-bot configuration. All secrets and constants in one place."""

import os
from pathlib import Path

# Telegram
_token_file = Path.home() / ".forge-bot-token"
BOT_TOKEN = os.getenv("FORGE_BOT_TOKEN") or (_token_file.read_text().strip() if _token_file.exists() else "")
CHAT_ID = int(os.getenv("FORGE_CHAT_ID", "0")) or 0

# forge-api (the brain — bot is just a thin adapter)
FORGE_API_URL = os.getenv("FORGE_API_URL", "http://127.0.0.1:8773")

# Notification endpoint (forge scripts POST here)
NOTIFY_PORT = int(os.getenv("FORGE_NOTIFY_PORT", "8774"))

# Anthropic (for LLM-powered features only)
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.getenv("ANTHROPIC_MODEL", "claude-sonnet-4-6-20250514")

# Paths
FORGE_ROOT = Path(os.getenv("FORGE_ROOT", str(Path.home() / "nexus" / "infra" / "dev-pipeline")))
SESSIONS_FILE = FORGE_ROOT / "bot" / ".sessions.json"
DEPLOY_LOCK_DIR = Path("/tmp/forge-locks")
