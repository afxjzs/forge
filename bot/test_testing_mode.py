"""Tests for the deterministic testing mode handler (b:/f: classification).

Tests the pure logic functions without needing Telegram objects or gh CLI.
"""

import tempfile
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Patch SESSIONS_FILE before importing any module that imports config
_tmpdir = tempfile.mkdtemp()
_sessions_file = Path(_tmpdir) / "sessions.json"

with patch("config.SESSIONS_FILE", _sessions_file):
    import sessions
    from sessions import (
        ModalSession,
        Mode,
        SessionType,
        SubSession,
        get_session,
        set_session,
    )

    sessions.SESSIONS_FILE = _sessions_file


@pytest.fixture(autouse=True)
def clean_sessions():
    if _sessions_file.exists():
        _sessions_file.unlink()
    yield
    if _sessions_file.exists():
        _sessions_file.unlink()


# ---- Import _parse_note_type ----
# We need to import after patching config; use importlib to be safe.
import unittest.mock

# Patch out heavy imports so we can import conversations without telegram/services
_mock_modules = {
    "telegram": MagicMock(),
    "telegram.ext": MagicMock(),
    "services.forge_api": MagicMock(),
    "services.formatting": MagicMock(truncate=lambda x: x),
    "services.llm": MagicMock(),
    "services.claude_relay": MagicMock(),
    "config": MagicMock(CHAT_ID=12345, SESSIONS_FILE=_sessions_file, FORGE_ROOT=Path("/tmp")),
}

with unittest.mock.patch.dict("sys.modules", _mock_modules):
    with patch("config.SESSIONS_FILE", _sessions_file):
        import handlers.conversations as conversations

        # Point sessions module at our temp file
        conversations.sessions = sessions


class TestParseNoteType:
    """Test the deterministic b:/f: prefix classifier."""

    def test_bug_prefix_short(self):
        note_type, text = conversations._parse_note_type("b: login button broken")
        assert note_type == "bug"
        assert text == "login button broken"

    def test_bug_prefix_full(self):
        note_type, text = conversations._parse_note_type("bug: login button broken")
        assert note_type == "bug"
        assert text == "login button broken"

    def test_bug_prefix_uppercase(self):
        note_type, text = conversations._parse_note_type("Bug: Something is wrong")
        assert note_type == "bug"
        assert text == "Something is wrong"

    def test_bug_prefix_mixed_case(self):
        note_type, text = conversations._parse_note_type("BUG: crash on submit")
        assert note_type == "bug"
        assert text == "crash on submit"

    def test_feature_prefix_short(self):
        note_type, text = conversations._parse_note_type("f: add dark mode")
        assert note_type == "feature"
        assert text == "add dark mode"

    def test_feature_prefix_full(self):
        note_type, text = conversations._parse_note_type("feature: add dark mode")
        assert note_type == "feature"
        assert text == "add dark mode"

    def test_feature_prefix_uppercase(self):
        note_type, text = conversations._parse_note_type("Feature: dark mode please")
        assert note_type == "feature"
        assert text == "dark mode please"

    def test_no_prefix_returns_none(self):
        note_type, text = conversations._parse_note_type("the app crashes when I log in")
        assert note_type is None
        assert text == "the app crashes when I log in"

    def test_no_prefix_empty(self):
        note_type, text = conversations._parse_note_type("")
        assert note_type is None
        assert text == ""

    def test_b_without_colon_is_not_classified(self):
        note_type, text = conversations._parse_note_type("b the app crashes")
        assert note_type is None

    def test_strips_extra_whitespace(self):
        note_type, text = conversations._parse_note_type("b:   lots of spaces   ")
        assert note_type == "bug"
        assert text == "lots of spaces"


class TestHandleLiveNote:
    """Test the _handle_live_note handler end-to-end logic."""

    def _make_update(self, message_text: str, chat_id: int = 12345):
        update = MagicMock()
        update.effective_chat.id = chat_id
        update.message.text = message_text
        update.message.reply_text = AsyncMock()
        return update

    def _make_testing_session(self, project_path: str = "/tmp/myapp") -> ModalSession:
        session = ModalSession(mode=Mode.TESTING, project="myapp")
        session.sub = SubSession(
            type=SessionType.LIVE_NOTES,
            context={"project_path": project_path},
        )
        return session

    @pytest.mark.asyncio
    async def test_bug_prefix_creates_issue(self):
        update = self._make_update("b: login crashes on submit")
        session = self._make_testing_session()
        set_session(12345, session)

        with patch.object(conversations, "_create_github_issue", return_value="https://github.com/org/repo/issues/42"):
            await conversations._handle_live_note(update, session)

        loaded = get_session(12345)
        assert loaded.sub.notes_captured.get("bug", 0) == 1
        assert loaded.sub.context.get("pending_text") is None
        update.message.reply_text.assert_called_once()
        reply_text = update.message.reply_text.call_args[0][0]
        assert "#42" in reply_text
        assert "bug" in reply_text

    @pytest.mark.asyncio
    async def test_feature_prefix_creates_issue(self):
        update = self._make_update("f: add export to CSV")
        session = self._make_testing_session()
        set_session(12345, session)

        with patch.object(conversations, "_create_github_issue", return_value="https://github.com/org/repo/issues/7"):
            await conversations._handle_live_note(update, session)

        loaded = get_session(12345)
        assert loaded.sub.notes_captured.get("feature", 0) == 1
        reply_text = update.message.reply_text.call_args[0][0]
        assert "#7" in reply_text
        assert "feature" in reply_text

    @pytest.mark.asyncio
    async def test_no_prefix_asks_clarification(self):
        update = self._make_update("the save button is confusing")
        session = self._make_testing_session()
        set_session(12345, session)

        await conversations._handle_live_note(update, session)

        loaded = get_session(12345)
        assert loaded.sub.context.get("pending_text") == "the save button is confusing"
        reply_text = update.message.reply_text.call_args[0][0]
        assert "bug or a feature" in reply_text
        assert "(b/f)" in reply_text

    @pytest.mark.asyncio
    async def test_b_reply_after_clarification_creates_bug(self):
        update = self._make_update("b")
        session = self._make_testing_session()
        session.sub.context["pending_text"] = "the save button is confusing"
        set_session(12345, session)

        with patch.object(conversations, "_create_github_issue", return_value="https://github.com/org/repo/issues/10"):
            await conversations._handle_live_note(update, session)

        loaded = get_session(12345)
        assert loaded.sub.notes_captured.get("bug", 0) == 1
        assert loaded.sub.context.get("pending_text") is None

    @pytest.mark.asyncio
    async def test_f_reply_after_clarification_creates_feature(self):
        update = self._make_update("f")
        session = self._make_testing_session()
        session.sub.context["pending_text"] = "would be nice to have dark mode"
        set_session(12345, session)

        with patch.object(conversations, "_create_github_issue", return_value="https://github.com/org/repo/issues/11"):
            await conversations._handle_live_note(update, session)

        loaded = get_session(12345)
        assert loaded.sub.notes_captured.get("feature", 0) == 1
        assert loaded.sub.context.get("pending_text") is None

    @pytest.mark.asyncio
    async def test_invalid_reply_re_prompts(self):
        update = self._make_update("maybe")
        session = self._make_testing_session()
        session.sub.context["pending_text"] = "dark mode"
        set_session(12345, session)

        await conversations._handle_live_note(update, session)

        # pending_text should still be there (not consumed)
        loaded = get_session(12345)
        assert loaded.sub.context.get("pending_text") == "dark mode"
        reply_text = update.message.reply_text.call_args[0][0]
        assert "bug or a feature" in reply_text

    @pytest.mark.asyncio
    async def test_issue_creation_uses_correct_bug_labels(self):
        update = self._make_update("b: button is broken")
        session = self._make_testing_session()
        set_session(12345, session)

        captured_labels = []

        def mock_create(path, title, body, labels):
            captured_labels.extend(labels)
            return "https://github.com/org/repo/issues/1"

        with patch.object(conversations, "_create_github_issue", side_effect=mock_create):
            await conversations._handle_live_note(update, session)

        assert "task" in captured_labels
        assert "bug" in captured_labels
        assert "P0" in captured_labels
        assert "standard" in captured_labels

    @pytest.mark.asyncio
    async def test_issue_creation_uses_correct_feature_labels(self):
        update = self._make_update("f: add dark mode")
        session = self._make_testing_session()
        set_session(12345, session)

        captured_labels = []

        def mock_create(path, title, body, labels):
            captured_labels.extend(labels)
            return "https://github.com/org/repo/issues/2"

        with patch.object(conversations, "_create_github_issue", side_effect=mock_create):
            await conversations._handle_live_note(update, session)

        assert "task" in captured_labels
        assert "enhancement" in captured_labels
        assert "P1" in captured_labels
        assert "standard" in captured_labels

    @pytest.mark.asyncio
    async def test_issue_body_format(self):
        update = self._make_update("b: login crashes")
        session = self._make_testing_session()
        set_session(12345, session)

        captured_body = []

        def mock_create(path, title, body, labels):
            captured_body.append(body)
            return "https://github.com/org/repo/issues/5"

        with patch.object(conversations, "_create_github_issue", side_effect=mock_create):
            await conversations._handle_live_note(update, session)

        body = captured_body[0]
        assert "## From live testing session" in body
        assert "login crashes" in body
        assert "Reported via forge-bot /testing session" in body

    @pytest.mark.asyncio
    async def test_gh_failure_replies_with_error(self):
        update = self._make_update("b: something broke")
        session = self._make_testing_session()
        set_session(12345, session)

        with patch.object(conversations, "_create_github_issue", return_value=None):
            await conversations._handle_live_note(update, session)

        reply_text = update.message.reply_text.call_args[0][0]
        assert "failed" in reply_text.lower()


class TestWrapupTesting:
    """/done in testing mode: summarize the notes, then start workers on them.

    Since 944cf34 (2026-03-22), /done starts the orchestrator itself when any
    issues were filed, instead of telling the user to run /kick.
    """

    def _make_update(self, chat_id: int = 12345):
        update = MagicMock()
        update.effective_chat.id = chat_id
        update.message = MagicMock()
        update.message.reply_text = AsyncMock()
        return update

    def _replies(self, update) -> list[str]:
        return [c.args[0] for c in update.message.reply_text.call_args_list]

    def _session(self, project: str, bugs: int = 0, features: int = 0) -> ModalSession:
        session = ModalSession(mode=Mode.TESTING, project=project)
        session.sub = SubSession(type=SessionType.LIVE_NOTES)
        if bugs:
            session.sub.notes_captured["bug"] = bugs
        if features:
            session.sub.notes_captured["feature"] = features
        return session

    @pytest.mark.asyncio
    async def test_done_reports_counts_and_starts_workers(self):
        update = self._make_update()
        forge = MagicMock(run=AsyncMock(return_value={"open_issues": 5}))

        with patch.object(conversations, "api", forge):
            await conversations._wrapup_testing(update, self._session("myapp", bugs=3, features=2))

        replies = self._replies(update)
        assert any("3 bugs" in r and "2 features" in r for r in replies)
        forge.run.assert_awaited_once_with("myapp")
        assert "Orchestrator started" in replies[-1]
        assert "5 open issues" in replies[-1]

    @pytest.mark.asyncio
    async def test_done_tells_user_to_kick_manually_when_starting_workers_fails(self):
        update = self._make_update()
        forge = MagicMock(run=AsyncMock(side_effect=RuntimeError("forge-api unreachable")))

        with patch.object(conversations, "api", forge):
            await conversations._wrapup_testing(update, self._session("myapp", bugs=1))

        last = self._replies(update)[-1]
        assert "failed" in last.lower()
        assert "forge-api unreachable" in last
        assert "/kick myapp" in last

    @pytest.mark.asyncio
    async def test_done_with_no_notes_starts_no_workers(self):
        update = self._make_update()
        forge = MagicMock(run=AsyncMock())

        with patch.object(conversations, "api", forge):
            await conversations._wrapup_testing(update, self._session("proj"))

        assert "No issues created" in self._replies(update)[-1]
        forge.run.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_done_replies_carry_the_testing_mode_tag(self):
        update = self._make_update()
        forge = MagicMock(run=AsyncMock(return_value={"open_issues": 1}))

        with patch.object(conversations, "api", forge):
            await conversations._wrapup_testing(update, self._session("myapp", bugs=1))

        assert all(r.startswith("[T]") for r in self._replies(update))
