"""Claude Code subprocess relay for planning, review, and default mode sessions.

Spawns a Claude Code CLI process per session, relays messages bidirectionally
between Telegram and Claude's stdin/stdout. Supports heartbeat updates,
permission gating, and mode-specific wrapup prompts.
"""

import asyncio
import json
import logging
import os
from datetime import datetime, timezone
from typing import Awaitable, Callable
from uuid import uuid4

logger = logging.getLogger("forge-bot.relay")

CLAUDE_BIN = os.getenv("CLAUDE_BIN", "/home/afxjzs/.local/bin/claude")
DEFAULT_MODEL = "claude-opus-4-6"
HEARTBEAT_INTERVAL = 30  # seconds


# Tools that are safe to auto-approve (read-only operations)
READ_ONLY_TOOLS = [
    "Read",
    "Glob",
    "Grep",
    "Agent",
    "WebSearch",
    "WebFetch",
    "ToolSearch",
    "TodoWrite",
]

# Wrapup prompts per mode
PLANNING_WRAPUP = """This planning session is ending. Please provide:

1. **Summary of key decisions** made during this session
2. If a PRD (Product Requirements Document) was discussed, create it as a GitHub Issue using the `gh` CLI:
   - Title: "PRD: <feature/project name>"
   - Body: full PRD content in markdown
   - Labels: "prd"
   - Command: `gh issue create --title "PRD: ..." --body "..." --label prd`
3. If a PRD was created, suggest running `prd-to-issues` to break it into tasks

Be concise. Output the summary, then any gh commands needed."""

REVIEW_WRAPUP = """This review session is ending. Please provide:

1. **Summary of resolutions** — what was reviewed, what decisions were made
2. For any decisions that need tracking, create or update GitHub Issues using `gh`:
   - New decisions: `gh issue create --title "..." --body "..." --label decision`
   - Updates to existing: `gh issue comment <number> --body "..."`

Be concise. Output the summary, then any gh commands needed."""


class ClaudeCodeRelay:
    """Manages a Claude Code subprocess for a single session.

    Each relay instance owns one Claude Code process. Messages are sent
    as individual `claude -p` subprocess calls with `--resume` for
    session continuity.
    """

    def __init__(
        self,
        project_path: str,
        mode: str,
        model: str = DEFAULT_MODEL,
        send_heartbeat: Callable[[str], Awaitable[None]] | None = None,
    ):
        self.project_path = project_path
        self.mode = mode
        self.model = model
        self.session_id = str(uuid4())
        self.send_heartbeat = send_heartbeat
        self.message_count = 0
        self.is_running = False
        self._current_process: asyncio.subprocess.Process | None = None
        self._heartbeat_task: asyncio.Task | None = None
        self.started_at = datetime.now(timezone.utc)

    @property
    def mode_tag(self) -> str:
        tags = {"planning": "[P]", "review": "[R]"}
        return tags.get(self.mode, "")

    def _base_cmd(self, write_approved: bool = False) -> list[str]:
        """Build the base claude command."""
        cmd = [
            CLAUDE_BIN,
            "-p",
            "--output-format",
            "stream-json",
            "--model",
            self.model,
            "--bare",
        ]

        if write_approved:
            cmd.append("--dangerously-skip-permissions")
        else:
            # Read-only: only allow safe tools
            cmd.extend(["--allowedTools", ",".join(READ_ONLY_TOOLS)])
            cmd.append("--dangerously-skip-permissions")

        return cmd

    async def send_message(
        self,
        text: str,
        write_approved: bool = False,
    ) -> str:
        """Send a message to Claude and return the response.

        Spawns a `claude -p` subprocess for each message, using --resume
        for session continuity after the first message.
        """
        self.is_running = True
        cmd = self._base_cmd(write_approved)

        if self.message_count == 0:
            cmd.extend(["--session-id", self.session_id])
        else:
            cmd.extend(["--resume", self.session_id])

        # Message goes as the positional argument
        cmd.append(text)

        logger.info(f"Relay [{self.mode}] sending message #{self.message_count} (session: {self.session_id[:8]})")

        # Start heartbeat
        self._start_heartbeat()

        try:
            self._current_process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.project_path,
            )

            response_text = await self._read_stream_response()
            self.message_count += 1
            return response_text

        except asyncio.CancelledError:
            await self._kill_process()
            raise
        except Exception as e:
            logger.error(f"Relay [{self.mode}] error: {e}")
            raise
        finally:
            self.is_running = False
            self._stop_heartbeat()
            self._current_process = None

    async def _read_stream_response(self) -> str:
        """Read streaming JSON output from Claude and assemble the response text."""
        if not self._current_process or not self._current_process.stdout:
            return ""

        response_parts = []
        result_text = None

        async for raw_line in self._current_process.stdout:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                logger.debug(f"Non-JSON line from Claude: {line[:200]}")
                continue

            event_type = event.get("type", "")

            if event_type == "result":
                # Final result event
                result_text = event.get("result", "")
                if event.get("is_error"):
                    error_msg = result_text or "Unknown error from Claude Code"
                    logger.error(f"Relay [{self.mode}] Claude error: {error_msg}")
                    return f"Error: {error_msg}"
                break

            elif event_type == "assistant":
                # Intermediate assistant message with content
                content = event.get("message", {}).get("content", [])
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        response_parts.append(block.get("text", ""))
                    elif isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_name = block.get("name", "?")
                        # Update heartbeat with tool activity
                        if self.send_heartbeat:
                            asyncio.create_task(self.send_heartbeat(f"{self.mode_tag} using {tool_name}..."))

            elif event_type == "content_block_delta":
                delta = event.get("delta", {})
                if delta.get("type") == "text_delta":
                    response_parts.append(delta.get("text", ""))

        # Wait for process to finish
        await self._current_process.wait()

        # Prefer result text if available, fall back to assembled parts
        if result_text is not None:
            return result_text
        return "".join(response_parts) if response_parts else "(no response)"

    def _start_heartbeat(self):
        """Start sending periodic heartbeat updates."""
        if self.send_heartbeat:
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())

    def _stop_heartbeat(self):
        """Stop the heartbeat loop."""
        if self._heartbeat_task and not self._heartbeat_task.done():
            self._heartbeat_task.cancel()
            self._heartbeat_task = None

    async def _heartbeat_loop(self):
        """Send heartbeat messages every HEARTBEAT_INTERVAL seconds."""
        try:
            while True:
                await asyncio.sleep(HEARTBEAT_INTERVAL)
                if self.is_running and self.send_heartbeat:
                    await self.send_heartbeat(f"{self.mode_tag} still working...")
        except asyncio.CancelledError:
            pass

    async def wrapup(self) -> str:
        """Send mode-specific wrapup prompt and return the summary."""
        if self.mode == "planning":
            prompt = PLANNING_WRAPUP
        elif self.mode == "review":
            prompt = REVIEW_WRAPUP
        else:
            prompt = "Summarize what was discussed in this session. Be concise."

        try:
            return await self.send_message(prompt, write_approved=True)
        except Exception as e:
            logger.error(f"Relay [{self.mode}] wrapup failed: {e}")
            return f"Wrapup failed: {e}"

    async def stop(self):
        """Kill the Claude Code process and clean up."""
        self._stop_heartbeat()
        await self._kill_process()
        self.is_running = False
        logger.info(f"Relay [{self.mode}] stopped (session: {self.session_id[:8]})")

    async def _kill_process(self):
        """Terminate the current subprocess if running."""
        proc = self._current_process
        if proc and proc.returncode is None:
            try:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=5)
                except asyncio.TimeoutError:
                    proc.kill()
                    await proc.wait()
            except ProcessLookupError:
                logger.debug("Process already terminated")


# ---- Relay Registry (in-memory, per bot process) ----

_active_relays: dict[int, ClaudeCodeRelay] = {}


def get_relay(chat_id: int) -> ClaudeCodeRelay | None:
    """Get the active relay for a chat, if any."""
    return _active_relays.get(chat_id)


def set_relay(chat_id: int, relay: ClaudeCodeRelay):
    """Register a relay for a chat."""
    _active_relays[chat_id] = relay


async def remove_relay(chat_id: int):
    """Stop and remove the relay for a chat."""
    relay = _active_relays.pop(chat_id, None)
    if relay:
        await relay.stop()


async def cleanup_all_relays():
    """Stop all active relays (called on bot shutdown)."""
    for chat_id in list(_active_relays.keys()):
        await remove_relay(chat_id)
    logger.info("All relays cleaned up")
