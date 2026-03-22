"""Tests for the modal session manager."""

import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

# Patch SESSIONS_FILE before importing sessions
_tmpdir = tempfile.mkdtemp()
_sessions_file = Path(_tmpdir) / "sessions.json"

with patch("config.SESSIONS_FILE", _sessions_file):
    import sessions
    from sessions import (
        ModalSession,
        Mode,
        SessionType,
        SubSession,
        clear_session,
        enter_mode,
        exit_mode,
        get_session,
        mode_tag,
        set_session,
    )

    sessions.SESSIONS_FILE = _sessions_file


@pytest.fixture(autouse=True)
def clean_sessions():
    """Clean session file before each test."""
    if _sessions_file.exists():
        _sessions_file.unlink()
    yield
    if _sessions_file.exists():
        _sessions_file.unlink()


class TestModeTag:
    def test_planning_tag(self):
        assert mode_tag(Mode.PLANNING) == "[P]"

    def test_testing_tag(self):
        assert mode_tag(Mode.TESTING) == "[T]"

    def test_review_tag(self):
        assert mode_tag(Mode.REVIEW) == "[R]"

    def test_default_no_tag(self):
        assert mode_tag(Mode.DEFAULT) == ""


class TestModalSession:
    def test_default_session(self):
        s = ModalSession()
        assert s.mode == Mode.DEFAULT
        assert s.is_default()
        assert s.tag == ""
        assert s.project == ""
        assert s.started_at != ""

    def test_planning_session(self):
        s = ModalSession(mode=Mode.PLANNING, project="myapp")
        assert not s.is_default()
        assert s.tag == "[P]"
        assert s.project == "myapp"

    def test_session_has_timestamp(self):
        s = ModalSession()
        assert "T" in s.started_at  # ISO format


class TestPersistence:
    def test_get_returns_default_when_empty(self):
        session = get_session(12345)
        assert session.is_default()
        assert session.project == ""

    def test_set_and_get(self):
        session = ModalSession(mode=Mode.TESTING, project="foo")
        set_session(100, session)
        loaded = get_session(100)
        assert loaded.mode == Mode.TESTING
        assert loaded.project == "foo"

    def test_clear(self):
        set_session(100, ModalSession(mode=Mode.REVIEW, project="bar"))
        clear_session(100)
        assert get_session(100).is_default()

    def test_multiple_chats_independent(self):
        set_session(1, ModalSession(mode=Mode.PLANNING, project="a"))
        set_session(2, ModalSession(mode=Mode.TESTING, project="b"))
        assert get_session(1).mode == Mode.PLANNING
        assert get_session(2).mode == Mode.TESTING

    def test_subsession_persists(self):
        session = ModalSession(mode=Mode.TESTING, project="app")
        session.sub = SubSession(
            type=SessionType.LIVE_NOTES,
            context={"project_path": "/tmp/app"},
        )
        session.sub.notes_captured["bug"] = 3
        set_session(100, session)

        loaded = get_session(100)
        assert loaded.sub is not None
        assert loaded.sub.type == SessionType.LIVE_NOTES
        assert loaded.sub.notes_captured["bug"] == 3
        assert loaded.sub.context["project_path"] == "/tmp/app"


class TestEnterExitMode:
    def test_enter_mode(self):
        session = enter_mode(100, Mode.PLANNING, "myapp")
        assert session.mode == Mode.PLANNING
        assert session.project == "myapp"
        # Verify persisted
        assert get_session(100).mode == Mode.PLANNING

    def test_exit_mode_returns_old_session(self):
        enter_mode(100, Mode.REVIEW, "proj")
        old = exit_mode(100)
        assert old is not None
        assert old.mode == Mode.REVIEW
        assert old.project == "proj"
        # Now should be cleared
        assert get_session(100).is_default()

    def test_exit_default_returns_none(self):
        assert exit_mode(999) is None

    def test_done_from_any_mode(self):
        """Verify /done works from all modes."""
        for mode in [Mode.PLANNING, Mode.TESTING, Mode.REVIEW]:
            enter_mode(100, mode, "proj")
            old = exit_mode(100)
            assert old.mode == mode
            assert get_session(100).is_default()


class TestCorruptFile:
    def test_corrupt_json_returns_empty(self):
        _sessions_file.write_text("{bad json")
        session = get_session(100)
        assert session.is_default()
