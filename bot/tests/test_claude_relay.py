"""Tests for Claude Code relay service."""


from services.claude_relay import (
    ClaudeSession,
    RelayResult,
    _build_allowed_tools,
    _build_command,
    kill_session,
    READ_ONLY_TOOLS,
    WRITE_TOOLS,
    HEARTBEAT_INTERVAL,
)


class TestClaudeSession:
    def test_defaults(self):
        s = ClaudeSession()
        assert s.session_id is None
        assert s.model == "claude-opus-4-6"
        assert s.project_path == ""
        assert s.allowed_write_tools == set()
        assert s.total_cost_usd == 0.0
        assert s.total_turns == 0
        assert s.tool_uses == []

    def test_custom_values(self):
        s = ClaudeSession(
            session_id="abc-123",
            model="claude-sonnet-4-6-20250514",
            project_path="/home/user/project",
            allowed_write_tools={"Edit", "Write"},
        )
        assert s.session_id == "abc-123"
        assert s.model == "claude-sonnet-4-6-20250514"
        assert "Edit" in s.allowed_write_tools


class TestRelayResult:
    def test_defaults(self):
        r = RelayResult()
        assert r.text == ""
        assert r.tool_uses == []
        assert r.permission_denials == []
        assert r.cost_usd == 0.0
        assert r.error is None


class TestBuildAllowedTools:
    def test_read_only_by_default(self):
        s = ClaudeSession()
        tools = _build_allowed_tools(s)
        assert tools == READ_ONLY_TOOLS

    def test_includes_approved_write_tools(self):
        s = ClaudeSession(allowed_write_tools={"Edit", "Write"})
        tools = _build_allowed_tools(s)
        assert "Edit" in tools
        assert "Write" in tools
        # Read-only tools still present
        assert "Read" in tools
        assert "Grep" in tools


class TestBuildCommand:
    def test_basic_command(self):
        s = ClaudeSession(model="claude-opus-4-6")
        cmd = _build_command("hello", s)
        assert cmd[0].endswith("claude")
        assert "-p" in cmd
        assert "hello" in cmd
        assert "--output-format" in cmd
        assert "stream-json" in cmd
        assert "--model" in cmd
        assert "claude-opus-4-6" in cmd

    def test_resume_session(self):
        s = ClaudeSession(session_id="sess-123")
        cmd = _build_command("hello", s)
        assert "--resume" in cmd
        idx = cmd.index("--resume")
        assert cmd[idx + 1] == "sess-123"

    def test_project_path(self):
        s = ClaudeSession(project_path="/tmp/proj")
        cmd = _build_command("hello", s)
        assert "--add-dir" in cmd
        assert "/tmp/proj" in cmd

    def test_skip_permissions(self):
        s = ClaudeSession()
        cmd = _build_command("hello", s, skip_permissions=True)
        assert "--dangerously-skip-permissions" in cmd
        assert "--allowedTools" not in cmd

    def test_allowed_tools_without_skip(self):
        s = ClaudeSession()
        cmd = _build_command("hello", s, skip_permissions=False)
        assert "--allowedTools" in cmd
        assert "--dangerously-skip-permissions" not in cmd

    def test_system_prompt(self):
        s = ClaudeSession()
        cmd = _build_command("hello", s, system_prompt="You are helpful")
        assert "--append-system-prompt" in cmd
        assert "You are helpful" in cmd

    def test_no_system_prompt_when_empty(self):
        s = ClaudeSession()
        cmd = _build_command("hello", s, system_prompt="")
        assert "--append-system-prompt" not in cmd


class TestConstants:
    def test_heartbeat_interval(self):
        assert HEARTBEAT_INTERVAL == 30

    def test_read_only_tools(self):
        assert "Read" in READ_ONLY_TOOLS
        assert "Glob" in READ_ONLY_TOOLS
        assert "Grep" in READ_ONLY_TOOLS
        # Write tools should NOT be in read-only
        assert "Edit" not in READ_ONLY_TOOLS
        assert "Write" not in READ_ONLY_TOOLS
        assert "Bash" not in READ_ONLY_TOOLS

    def test_write_tools(self):
        assert "Edit" in WRITE_TOOLS
        assert "Write" in WRITE_TOOLS
        assert "Bash" in WRITE_TOOLS
        assert "NotebookEdit" in WRITE_TOOLS


class TestKillSession:
    def test_kill_logs_stats(self):
        s = ClaudeSession(
            session_id="test-sess",
            total_turns=5,
            total_cost_usd=0.05,
        )
        # Should not raise
        kill_session(s)
