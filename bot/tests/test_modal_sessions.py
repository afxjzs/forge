"""Tests for modal session manager."""

from modal_sessions import (
    Mode, ModalSession, MODE_LABELS, MODE_DESCRIPTIONS,
    get_modal_session, set_modal_session, clear_modal_session,
    has_pending_approval, _sessions,
)


class TestMode:
    def test_values(self):
        assert Mode.PLANNING.value == "P"
        assert Mode.REVIEW.value == "R"
        assert Mode.DEFAULT.value == "D"

    def test_labels(self):
        assert MODE_LABELS[Mode.PLANNING] == "[P]"
        assert MODE_LABELS[Mode.REVIEW] == "[R]"
        assert MODE_LABELS[Mode.DEFAULT] == "[D]"

    def test_descriptions(self):
        assert MODE_DESCRIPTIONS[Mode.PLANNING] == "Planning"
        assert MODE_DESCRIPTIONS[Mode.REVIEW] == "Review"
        assert MODE_DESCRIPTIONS[Mode.DEFAULT] == "Default"


class TestModalSession:
    def test_defaults(self):
        s = ModalSession(mode=Mode.PLANNING, project_name="test", project_path="/tmp")
        assert s.mode == Mode.PLANNING
        assert s.project_name == "test"
        assert s.project_path == "/tmp"
        assert s.message_count == 0
        assert s.pending_approval is None
        assert s.started_at  # should be auto-set

    def test_label(self):
        s = ModalSession(mode=Mode.REVIEW, project_name="x", project_path="/tmp")
        assert s.label == "[R]"

    def test_started_at_auto(self):
        s = ModalSession(mode=Mode.DEFAULT, project_name="x", project_path="/tmp")
        assert "T" in s.started_at  # ISO format


class TestSessionStore:
    def setup_method(self):
        _sessions.clear()

    def test_set_and_get(self):
        s = ModalSession(mode=Mode.PLANNING, project_name="proj", project_path="/tmp")
        set_modal_session(123, s)
        got = get_modal_session(123)
        assert got is not None
        assert got.mode == Mode.PLANNING
        assert got.project_name == "proj"

    def test_get_missing(self):
        assert get_modal_session(999) is None

    def test_clear(self):
        s = ModalSession(mode=Mode.DEFAULT, project_name="x", project_path="/tmp")
        set_modal_session(123, s)
        cleared = clear_modal_session(123)
        assert cleared is not None
        assert cleared.mode == Mode.DEFAULT
        assert get_modal_session(123) is None

    def test_clear_missing(self):
        assert clear_modal_session(999) is None

    def test_has_pending_approval_false(self):
        s = ModalSession(mode=Mode.PLANNING, project_name="x", project_path="/tmp")
        set_modal_session(123, s)
        assert has_pending_approval(123) is False

    def test_has_pending_approval_true(self):
        s = ModalSession(
            mode=Mode.PLANNING,
            project_name="x",
            project_path="/tmp",
            pending_approval={"tool": "Edit", "original_message": "fix it"},
        )
        set_modal_session(123, s)
        assert has_pending_approval(123) is True

    def test_has_pending_approval_no_session(self):
        assert has_pending_approval(999) is False

    def test_exclusive_sessions(self):
        """Only one session per chat_id."""
        s1 = ModalSession(mode=Mode.PLANNING, project_name="a", project_path="/tmp")
        s2 = ModalSession(mode=Mode.REVIEW, project_name="b", project_path="/tmp")
        set_modal_session(123, s1)
        set_modal_session(123, s2)
        got = get_modal_session(123)
        assert got.mode == Mode.REVIEW
        assert got.project_name == "b"
