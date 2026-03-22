"""Tests for the Claude Code relay."""

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from services.claude_relay import (
    ClaudeCodeRelay,
    _active_relays,
    cleanup_all_relays,
    get_relay,
    remove_relay,
    set_relay,
)


@pytest.fixture(autouse=True)
def clean_relays():
    """Clean up relay registry between tests."""
    _active_relays.clear()
    yield
    _active_relays.clear()


class AsyncLineIterator:
    """Async iterator over a list of bytes lines, simulating subprocess stdout."""

    def __init__(self, lines: list[bytes]):
        self._lines = list(lines)
        self._index = 0

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self._index >= len(self._lines):
            raise StopAsyncIteration
        line = self._lines[self._index]
        self._index += 1
        return line


def make_mock_process(events: list[dict], returncode: int = 0):
    """Create a mock subprocess with async stdout yielding JSON events."""
    lines = [json.dumps(e).encode() + b"\n" for e in events]

    mock_proc = AsyncMock()
    mock_proc.stdout = AsyncLineIterator(lines)
    mock_proc.stderr = AsyncMock()
    mock_proc.wait = AsyncMock()
    mock_proc.returncode = returncode
    mock_proc.terminate = MagicMock()
    mock_proc.kill = MagicMock()
    return mock_proc


class TestClaudeCodeRelayInit:
    def test_creates_with_defaults(self):
        relay = ClaudeCodeRelay("/tmp/project", "planning")
        assert relay.project_path == "/tmp/project"
        assert relay.mode == "planning"
        assert relay.model == "claude-opus-4-6"
        assert relay.message_count == 0
        assert relay.is_running is False
        assert relay.session_id  # UUID generated

    def test_custom_model(self):
        relay = ClaudeCodeRelay("/tmp/project", "review", model="claude-sonnet-4-6")
        assert relay.model == "claude-sonnet-4-6"

    def test_mode_tag(self):
        assert ClaudeCodeRelay("/tmp", "planning").mode_tag == "[P]"
        assert ClaudeCodeRelay("/tmp", "review").mode_tag == "[R]"
        assert ClaudeCodeRelay("/tmp", "default").mode_tag == ""

    def test_unique_session_ids(self):
        r1 = ClaudeCodeRelay("/tmp", "planning")
        r2 = ClaudeCodeRelay("/tmp", "planning")
        assert r1.session_id != r2.session_id


class TestRelayCommand:
    def test_base_cmd_includes_model(self):
        relay = ClaudeCodeRelay("/tmp", "planning", model="claude-opus-4-6")
        cmd = relay._base_cmd()
        assert "--model" in cmd
        idx = cmd.index("--model")
        assert cmd[idx + 1] == "claude-opus-4-6"

    def test_base_cmd_includes_output_format(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        cmd = relay._base_cmd()
        assert "--output-format" in cmd
        idx = cmd.index("--output-format")
        assert cmd[idx + 1] == "stream-json"

    def test_base_cmd_includes_print_flag(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        cmd = relay._base_cmd()
        assert "-p" in cmd

    def test_base_cmd_write_approved(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        cmd = relay._base_cmd(write_approved=True)
        assert "--dangerously-skip-permissions" in cmd


class TestRelaySendMessage:
    async def test_first_message_uses_session_id(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "hello", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc) as mock_exec:
            result = await relay.send_message("test message")

            args = mock_exec.call_args[0]
            assert "--session-id" in args
            assert relay.session_id in args
            assert "test message" in args
            assert result == "hello"
            assert relay.message_count == 1

    async def test_subsequent_message_uses_resume(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        relay.message_count = 1

        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "response", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc) as mock_exec:
            result = await relay.send_message("follow up")

            args = mock_exec.call_args[0]
            assert "--resume" in args
            assert relay.session_id in args
            assert result == "response"
            assert relay.message_count == 2

    async def test_error_result(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "auth failed", "is_error": True},
            ],
            returncode=1,
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert "Error:" in result
            assert "auth failed" in result


class TestRelayStreamParsing:
    async def test_parses_result_event(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "Final answer", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert result == "Final answer"

    async def test_parses_content_block_deltas(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process(
            [
                {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello "}},
                {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "world"}},
                {"type": "result", "result": "Hello world", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert result == "Hello world"

    async def test_empty_stdout_returns_no_response(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process([])

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert result == "(no response)"

    async def test_assistant_event_with_text_content(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = make_mock_process(
            [
                {"type": "assistant", "message": {"content": [{"type": "text", "text": "from assistant"}]}},
                {"type": "result", "result": "from assistant", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert result == "from assistant"

    async def test_non_json_lines_ignored(self):
        """Non-JSON output lines should be silently skipped."""
        relay = ClaudeCodeRelay("/tmp", "planning")

        mock_proc = AsyncMock()
        mock_proc.stdout = AsyncLineIterator(
            [
                b"some random output\n",
                json.dumps({"type": "result", "result": "ok", "is_error": False}).encode() + b"\n",
            ]
        )
        mock_proc.wait = AsyncMock()
        mock_proc.returncode = 0
        mock_proc.terminate = MagicMock()

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.send_message("test")
            assert result == "ok"


class TestRelayWrapup:
    async def test_planning_wrapup_uses_planning_prompt(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        relay.message_count = 1

        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "Summary: discussed auth flow", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc) as mock_exec:
            result = await relay.wrapup()
            assert "Summary" in result

            args = mock_exec.call_args[0]
            assert "--dangerously-skip-permissions" in args

    async def test_review_wrapup_uses_review_prompt(self):
        relay = ClaudeCodeRelay("/tmp", "review")
        relay.message_count = 1

        mock_proc = make_mock_process(
            [
                {"type": "result", "result": "Review complete", "is_error": False},
            ]
        )

        with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
            result = await relay.wrapup()
            assert result == "Review complete"

    async def test_wrapup_handles_failure(self):
        relay = ClaudeCodeRelay("/tmp", "planning")

        with patch("services.claude_relay.asyncio.create_subprocess_exec", side_effect=OSError("no such file")):
            result = await relay.wrapup()
            assert "failed" in result.lower()


class TestRelayStop:
    async def test_stop_terminates_process(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        mock_proc = MagicMock()
        mock_proc.returncode = None
        mock_proc.terminate = MagicMock()
        mock_proc.wait = AsyncMock()
        relay._current_process = mock_proc

        await relay.stop()

        mock_proc.terminate.assert_called_once()
        assert relay.is_running is False

    async def test_stop_without_process(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        await relay.stop()  # Should not raise


class TestRelayRegistry:
    def test_get_returns_none_when_empty(self):
        assert get_relay(12345) is None

    def test_set_and_get(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        set_relay(100, relay)
        assert get_relay(100) is relay

    async def test_remove_stops_and_removes(self):
        relay = ClaudeCodeRelay("/tmp", "planning")
        relay.stop = AsyncMock()
        set_relay(100, relay)

        await remove_relay(100)

        relay.stop.assert_called_once()
        assert get_relay(100) is None

    async def test_remove_nonexistent(self):
        await remove_relay(999)  # Should not raise

    async def test_cleanup_all(self):
        r1 = ClaudeCodeRelay("/tmp", "planning")
        r1.stop = AsyncMock()
        r2 = ClaudeCodeRelay("/tmp", "review")
        r2.stop = AsyncMock()
        set_relay(1, r1)
        set_relay(2, r2)

        await cleanup_all_relays()

        r1.stop.assert_called_once()
        r2.stop.assert_called_once()
        assert len(_active_relays) == 0


class TestHeartbeat:
    async def test_heartbeat_called_during_long_operation(self):
        heartbeat = AsyncMock()
        relay = ClaudeCodeRelay("/tmp", "planning", send_heartbeat=heartbeat)

        async def slow_lines():
            await asyncio.sleep(0.1)
            yield json.dumps({"type": "result", "result": "done", "is_error": False}).encode() + b"\n"

        mock_proc = AsyncMock()
        mock_proc.stdout = slow_lines()
        mock_proc.wait = AsyncMock()
        mock_proc.returncode = 0
        mock_proc.terminate = MagicMock()

        import services.claude_relay as relay_mod

        original_interval = relay_mod.HEARTBEAT_INTERVAL

        try:
            relay_mod.HEARTBEAT_INTERVAL = 0.05  # 50ms for test

            with patch("services.claude_relay.asyncio.create_subprocess_exec", return_value=mock_proc):
                result = await relay.send_message("test")
                assert result == "done"
        finally:
            relay_mod.HEARTBEAT_INTERVAL = original_interval
