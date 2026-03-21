"""Claude Code relay — manages Claude CLI sessions for modal conversations.

Spawns `claude -p` per message with `--resume` for multi-turn.
Parses stream-json output for real-time content and tool use events.
Sends heartbeat updates during long-running operations.
"""

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from config import FORGE_ROOT

logger = logging.getLogger("forge-bot")

# Claude CLI path
CLAUDE_BIN = "/home/afxjzs/.local/bin/claude"

# Read-only tools — always allowed without approval
READ_ONLY_TOOLS = [
    "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    "Agent", "TodoWrite", "ToolSearch",
]

# Write tools — require Telegram approval
WRITE_TOOLS = [
    "Edit", "Write", "Bash", "NotebookEdit",
]

# Heartbeat interval in seconds
HEARTBEAT_INTERVAL = 30


@dataclass
class ClaudeSession:
    """Tracks a Claude Code session across multiple turns."""
    session_id: str | None = None
    model: str = "claude-opus-4-6"
    project_path: str = ""
    allowed_write_tools: set = field(default_factory=set)
    total_cost_usd: float = 0.0
    total_turns: int = 0
    tool_uses: list = field(default_factory=list)


@dataclass
class RelayResult:
    """Result from sending a message to Claude."""
    text: str = ""
    tool_uses: list = field(default_factory=list)
    permission_denials: list = field(default_factory=list)
    cost_usd: float = 0.0
    duration_ms: int = 0
    session_id: str = ""
    error: str | None = None


def _build_allowed_tools(session: ClaudeSession) -> list[str]:
    """Build the allowedTools list based on session state."""
    tools = list(READ_ONLY_TOOLS)
    tools.extend(session.allowed_write_tools)
    return tools


def _build_command(
    message: str,
    session: ClaudeSession,
    system_prompt: str = "",
    skip_permissions: bool = False,
) -> list[str]:
    """Build the claude CLI command."""
    cmd = [
        CLAUDE_BIN, "-p", message,
        "--output-format", "stream-json",
        "--verbose",
        "--model", session.model,
    ]

    if session.session_id:
        cmd.extend(["--resume", session.session_id])

    if session.project_path:
        cmd.extend(["--add-dir", session.project_path])

    if skip_permissions:
        cmd.append("--dangerously-skip-permissions")
    else:
        # Use allowlist for permission control
        allowed = _build_allowed_tools(session)
        if allowed:
            cmd.extend(["--allowedTools", " ".join(allowed)])

    if system_prompt:
        cmd.extend(["--append-system-prompt", system_prompt])

    return cmd


async def send_message(
    message: str,
    session: ClaudeSession,
    system_prompt: str = "",
    heartbeat_callback=None,
    tool_use_callback=None,
    skip_permissions: bool = False,
    timeout_seconds: int = 300,
) -> RelayResult:
    """Send a message to Claude Code and stream the response.

    Args:
        message: User message to send
        session: ClaudeSession tracking state across turns
        system_prompt: Optional system prompt to append
        heartbeat_callback: async fn(str) called every 30s with status
        tool_use_callback: async fn(dict) called when tool use detected
        skip_permissions: If True, use --dangerously-skip-permissions
        timeout_seconds: Max time to wait for response

    Returns:
        RelayResult with text content, tool uses, and metadata
    """
    cmd = _build_command(message, session, system_prompt, skip_permissions)
    result = RelayResult()

    logger.info(f"Claude relay: sending message ({len(message)} chars), session={session.session_id or 'new'}")

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=session.project_path or str(FORGE_ROOT),
        )

        text_parts = []
        last_heartbeat = time.monotonic()
        current_tool = None

        async def read_stream():
            nonlocal last_heartbeat, current_tool

            while True:
                line = await proc.stdout.readline()
                if not line:
                    break

                line_str = line.decode("utf-8", errors="replace").strip()
                if not line_str:
                    continue

                try:
                    event = json.loads(line_str)
                except json.JSONDecodeError:
                    logger.debug(f"Non-JSON line from claude: {line_str[:100]}")
                    continue

                event_type = event.get("type", "")

                if event_type == "assistant":
                    msg = event.get("message", {})
                    content_blocks = msg.get("content", [])
                    for block in content_blocks:
                        if block.get("type") == "text":
                            text_parts.append(block["text"])
                        elif block.get("type") == "tool_use":
                            tool_info = {
                                "tool": block.get("name", ""),
                                "input": block.get("input", {}),
                                "id": block.get("id", ""),
                            }
                            result.tool_uses.append(tool_info)
                            current_tool = tool_info["tool"]
                            if tool_use_callback:
                                await tool_use_callback(tool_info)

                elif event_type == "result":
                    result.text = event.get("result", "")
                    result.cost_usd = event.get("total_cost_usd", 0.0)
                    result.duration_ms = event.get("duration_ms", 0)
                    result.session_id = event.get("session_id", "")
                    result.permission_denials = event.get("permission_denials", [])

                    if not result.text and text_parts:
                        result.text = "".join(text_parts)

                # Heartbeat check
                now = time.monotonic()
                if now - last_heartbeat >= HEARTBEAT_INTERVAL and heartbeat_callback:
                    status = f"working on: {current_tool}..." if current_tool else "still thinking..."
                    await heartbeat_callback(status)
                    last_heartbeat = now

        try:
            await asyncio.wait_for(read_stream(), timeout=timeout_seconds)
        except asyncio.TimeoutError:
            proc.kill()
            result.error = f"Timed out after {timeout_seconds}s"
            logger.error(f"Claude relay: timeout after {timeout_seconds}s")

        await proc.wait()

        # Read stderr for errors
        stderr = await proc.stderr.read()
        if proc.returncode != 0 and not result.text:
            stderr_text = stderr.decode("utf-8", errors="replace").strip()
            result.error = stderr_text or f"Process exited with code {proc.returncode}"
            logger.error(f"Claude relay: error: {result.error[:200]}")

    except Exception as e:
        result.error = str(e)
        logger.error(f"Claude relay: exception: {e}")

    # Update session state
    if result.session_id:
        session.session_id = result.session_id
    session.total_cost_usd += result.cost_usd
    session.total_turns += 1
    session.tool_uses.extend(result.tool_uses)

    logger.info(
        f"Claude relay: done. {len(result.text)} chars, "
        f"{len(result.tool_uses)} tool uses, "
        f"${result.cost_usd:.4f}, {result.duration_ms}ms"
    )

    return result


async def send_wrapup(
    session: ClaudeSession,
    mode: str,
    project_name: str,
    heartbeat_callback=None,
) -> RelayResult:
    """Send a mode-specific wrapup prompt and return the summary.

    Args:
        session: Active ClaudeSession
        mode: "P" (planning), "R" (review), or "D" (default)
        project_name: Name of the project
        heartbeat_callback: async fn(str) called every 30s
    """
    if mode == "P":
        prompt = (
            "We're wrapping up this planning session. Please:\n"
            "1. Summarize the key decisions we made\n"
            "2. If we discussed a PRD or product requirements, create it as a GitHub Issue "
            f"in the {project_name} repo with the label 'prd'\n"
            "3. If a PRD was created, suggest running prd-to-issues to break it into tasks\n"
            "4. List any open questions or next steps"
        )
    elif mode == "R":
        prompt = (
            "We're wrapping up this review session. Please:\n"
            "1. Summarize the resolutions and decisions made\n"
            "2. Create or update GitHub Issues for any decisions or action items\n"
            "3. List any unresolved items that need follow-up"
        )
    else:  # Default mode
        prompt = (
            "We're wrapping up this session. Please:\n"
            "1. Summarize what we accomplished\n"
            "2. List any files changed or created\n"
            "3. Note any follow-up items"
        )

    return await send_message(
        prompt,
        session,
        heartbeat_callback=heartbeat_callback,
        skip_permissions=True,
        timeout_seconds=120,
    )


def kill_session(session: ClaudeSession):
    """Clean up a Claude session. Session state is server-side, nothing to kill locally."""
    logger.info(
        f"Claude session ended: {session.session_id}, "
        f"{session.total_turns} turns, ${session.total_cost_usd:.4f}"
    )
