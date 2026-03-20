"""Session management for multi-turn conversations. Persisted to disk."""

import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path

from config import SESSIONS_FILE


class SessionType(str, Enum):
    NEW_PROJECT_INTERVIEW = "new_project_interview"
    ADOPTION_INTERVIEW = "adoption_interview"
    LIVE_NOTES = "live_notes"
    RESEARCH = "research"


@dataclass
class Session:
    type: SessionType
    project_name: str
    started_at: str = ""
    questions: list[str] = field(default_factory=list)
    answers: list[str] = field(default_factory=list)
    current_question_index: int = 0
    context: dict = field(default_factory=dict)
    notes_captured: dict = field(default_factory=lambda: {"bug": 0, "feature": 0, "ux": 0, "redirect": 0})

    def __post_init__(self):
        if not self.started_at:
            self.started_at = datetime.now(timezone.utc).isoformat()


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


def get_session(chat_id: int) -> Session | None:
    data = _load()
    key = str(chat_id)
    if key not in data:
        return None
    d = data[key]
    return Session(
        type=SessionType(d["type"]),
        project_name=d["project_name"],
        started_at=d.get("started_at", ""),
        questions=d.get("questions", []),
        answers=d.get("answers", []),
        current_question_index=d.get("current_question_index", 0),
        context=d.get("context", {}),
        notes_captured=d.get("notes_captured", {"bug": 0, "feature": 0, "ux": 0, "redirect": 0}),
    )


def set_session(chat_id: int, session: Session):
    data = _load()
    data[str(chat_id)] = asdict(session)
    _save(data)


def clear_session(chat_id: int):
    data = _load()
    data.pop(str(chat_id), None)
    _save(data)
