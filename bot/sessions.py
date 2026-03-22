"""Session management for forge-bot.

Two layers:
1. Modal session — tracks which mode the user is in (default/planning/testing/review)
2. Sub-session  — mode-specific state (interview questions, live notes, etc.)

Persisted to disk as JSON.
"""

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum

from config import SESSIONS_FILE

# ---- Mode (top-level modal state) ----


class Mode(str, Enum):
    DEFAULT = "default"
    PLANNING = "planning"
    TESTING = "testing"
    REVIEW = "review"


MODE_TAGS = {
    Mode.PLANNING: "[P]",
    Mode.TESTING: "[T]",
    Mode.REVIEW: "[R]",
}


def mode_tag(mode: Mode) -> str:
    """Return the tag prefix for a mode, or empty string for default."""
    return MODE_TAGS.get(mode, "")


# ---- Sub-session types (state within a mode) ----


class SessionType(str, Enum):
    NEW_PROJECT_INTERVIEW = "new_project_interview"
    ADOPTION_INTERVIEW = "adoption_interview"
    LIVE_NOTES = "live_notes"
    RESEARCH = "research"


@dataclass
class SubSession:
    """Mode-specific state (interview progress, live notes counters, etc.)."""

    type: SessionType
    questions: list[str] = field(default_factory=list)
    answers: list[str] = field(default_factory=list)
    current_question_index: int = 0
    context: dict = field(default_factory=dict)
    notes_captured: dict = field(default_factory=lambda: {"bug": 0, "feature": 0, "ux": 0, "redirect": 0})


# ---- Modal session (one per chat) ----


@dataclass
class ModalSession:
    """Top-level session state per chat."""

    mode: Mode = Mode.DEFAULT
    project: str = ""
    started_at: str = ""
    sub: SubSession | None = None

    def __post_init__(self):
        if not self.started_at:
            self.started_at = datetime.now(timezone.utc).isoformat()

    @property
    def tag(self) -> str:
        return mode_tag(self.mode)

    def is_default(self) -> bool:
        return self.mode == Mode.DEFAULT


# ---- Persistence ----


def _load() -> dict:
    if SESSIONS_FILE.exists():
        try:
            return json.loads(SESSIONS_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save(data: dict):
    SESSIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    SESSIONS_FILE.write_text(json.dumps(data, indent=2))


def _session_to_dict(session: ModalSession) -> dict:
    d = {
        "mode": session.mode.value,
        "project": session.project,
        "started_at": session.started_at,
    }
    if session.sub:
        d["sub"] = asdict(session.sub)
    return d


def _session_from_dict(d: dict) -> ModalSession:
    sub = None
    if "sub" in d and d["sub"]:
        sd = d["sub"]
        sub = SubSession(
            type=SessionType(sd["type"]),
            questions=sd.get("questions", []),
            answers=sd.get("answers", []),
            current_question_index=sd.get("current_question_index", 0),
            context=sd.get("context", {}),
            notes_captured=sd.get("notes_captured", {"bug": 0, "feature": 0, "ux": 0, "redirect": 0}),
        )
    return ModalSession(
        mode=Mode(d.get("mode", "default")),
        project=d.get("project", ""),
        started_at=d.get("started_at", ""),
        sub=sub,
    )


def get_session(chat_id: int) -> ModalSession:
    """Get modal session for a chat. Returns default-mode session if none exists."""
    data = _load()
    key = str(chat_id)
    if key in data:
        return _session_from_dict(data[key])
    return ModalSession()


def set_session(chat_id: int, session: ModalSession):
    data = _load()
    data[str(chat_id)] = _session_to_dict(session)
    _save(data)


def clear_session(chat_id: int):
    """Reset chat to default mode."""
    data = _load()
    data.pop(str(chat_id), None)
    _save(data)


def enter_mode(chat_id: int, mode: Mode, project: str) -> ModalSession:
    """Enter a mode for a project. Returns the new session."""
    session = ModalSession(mode=mode, project=project)
    set_session(chat_id, session)
    return session


def exit_mode(chat_id: int) -> ModalSession | None:
    """Exit current mode, return the session that was active (for wrapup)."""
    session = get_session(chat_id)
    if session.is_default():
        return None
    clear_session(chat_id)
    return session
