"""Modal session manager for vim-like [P]/[T]/[R]/[D] modes.

Each mode wraps a Claude Code subprocess. Sessions are per-chat and exclusive —
only one mode active at a time.
"""

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum

logger = logging.getLogger("forge-bot")


class Mode(str, Enum):
    PLANNING = "P"
    REVIEW = "R"
    DEFAULT = "D"


MODE_LABELS = {
    Mode.PLANNING: "[P]",
    Mode.REVIEW: "[R]",
    Mode.DEFAULT: "[D]",
}

MODE_DESCRIPTIONS = {
    Mode.PLANNING: "Planning",
    Mode.REVIEW: "Review",
    Mode.DEFAULT: "Default",
}


@dataclass
class ModalSession:
    mode: Mode
    project_name: str
    project_path: str
    started_at: str = ""
    message_count: int = 0
    pending_approval: dict | None = None  # {"action": str, "path": str, ...}

    def __post_init__(self):
        if not self.started_at:
            self.started_at = datetime.now(timezone.utc).isoformat()

    @property
    def label(self) -> str:
        return MODE_LABELS[self.mode]


# In-memory store — one session per chat_id.
# No disk persistence needed: sessions are ephemeral (tied to a running claude process).
_sessions: dict[int, ModalSession] = {}


def get_modal_session(chat_id: int) -> ModalSession | None:
    return _sessions.get(chat_id)


def set_modal_session(chat_id: int, session: ModalSession):
    _sessions[chat_id] = session


def clear_modal_session(chat_id: int) -> ModalSession | None:
    return _sessions.pop(chat_id, None)


def has_pending_approval(chat_id: int) -> bool:
    session = _sessions.get(chat_id)
    return session is not None and session.pending_approval is not None
