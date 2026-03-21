"""Tests for Claude mode handlers — message splitting and system prompts."""

from handlers.claude_mode import _split_message, _get_system_prompt, TG_MAX_LEN, WRITE_TOOL_NAMES
from modal_sessions import Mode


class TestSplitMessage:
    def test_short_message(self):
        chunks = _split_message("hello")
        assert chunks == ["hello"]

    def test_exact_limit(self):
        text = "x" * TG_MAX_LEN
        chunks = _split_message(text)
        assert chunks == [text]

    def test_splits_on_double_newline(self):
        part1 = "a" * 3000
        part2 = "b" * 3000
        text = part1 + "\n\n" + part2
        chunks = _split_message(text)
        assert len(chunks) == 2
        assert chunks[0] == part1
        assert chunks[1] == part2

    def test_splits_on_single_newline_fallback(self):
        part1 = "a" * 3000
        part2 = "b" * 3000
        text = part1 + "\n" + part2
        chunks = _split_message(text)
        assert len(chunks) >= 2
        # All chunks should be under limit
        for chunk in chunks:
            assert len(chunk) <= TG_MAX_LEN

    def test_hard_split_no_newlines(self):
        text = "x" * 8000
        chunks = _split_message(text)
        assert len(chunks) >= 2
        for chunk in chunks:
            assert len(chunk) <= TG_MAX_LEN


class TestGetSystemPrompt:
    def test_planning_mode(self):
        prompt = _get_system_prompt(Mode.PLANNING, "myproject", "/home/user/myproject")
        assert "Planning" in prompt
        assert "myproject" in prompt
        assert "PRD" in prompt or "requirements" in prompt
        assert "code changes" in prompt.lower() or "avoid" in prompt.lower()

    def test_review_mode(self):
        prompt = _get_system_prompt(Mode.REVIEW, "myproject", "/home/user/myproject")
        assert "Review" in prompt
        assert "myproject" in prompt
        assert "review" in prompt.lower()

    def test_default_mode(self):
        prompt = _get_system_prompt(Mode.DEFAULT, "myproject", "/home/user/myproject")
        assert "myproject" in prompt
        assert "4096" in prompt  # Telegram limit mentioned

    def test_all_modes_mention_telegram(self):
        for mode in Mode:
            prompt = _get_system_prompt(mode, "proj", "/tmp")
            assert "Telegram" in prompt


class TestWriteToolNames:
    def test_contains_expected(self):
        assert "Edit" in WRITE_TOOL_NAMES
        assert "Write" in WRITE_TOOL_NAMES
        assert "Bash" in WRITE_TOOL_NAMES
        assert "NotebookEdit" in WRITE_TOOL_NAMES

    def test_read_tools_excluded(self):
        assert "Read" not in WRITE_TOOL_NAMES
        assert "Grep" not in WRITE_TOOL_NAMES
        assert "Glob" not in WRITE_TOOL_NAMES
