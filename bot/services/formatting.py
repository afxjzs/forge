"""Telegram message formatting utilities."""


def escape_md(text: str) -> str:
    """Escape special characters for Telegram MarkdownV2."""
    chars = r"_*[]()~`>#+-=|{}.!"
    for c in chars:
        text = text.replace(c, f"\\{c}")
    return text


def format_status(data: dict) -> str:
    """Format a project status response for Telegram."""
    name = data["name"]
    stage = data["stage"]
    stack = data.get("stack", "?")
    tasks = data.get("tasks", {})
    errors = data.get("errors_recorded", 0)
    na = data.get("next_action", {})

    lines = [f"[{name}] Status"]
    lines.append(f"Stage: {stage} | Stack: {stack}")

    t_done = tasks.get("done", 0)
    t_wip = tasks.get("in_progress", 0)
    t_queued = tasks.get("queued", 0)
    t_review = tasks.get("needs_review", 0)
    total = t_done + t_wip + t_queued + t_review

    if total > 0:
        lines.append(f"Tasks: {t_done} done | {t_wip} wip | {t_queued} queued | {t_review} review")
    else:
        lines.append("Tasks: none")

    if errors:
        lines.append(f"Errors: {errors} recorded")

    last = data.get("last_activity")
    if last and isinstance(last, dict):
        lines.append(f"Last: {last.get('task_id', '?')} @ {last.get('timestamp', '?')[:16]}")

    if na and na.get("message"):
        lines.append("")
        lines.append(f"Next: {na['message']}")

    return "\n".join(lines)


def format_projects(data: dict) -> str:
    """Format project list for Telegram."""
    if not data:
        return "[forge] No projects. Use /adopt or /newproject to get started."

    lines = ["[forge] Projects"]
    for stage, projects in data.items():
        lines.append(f"\n{stage.upper()}:")
        for p in projects:
            if isinstance(p, dict):
                name = p["name"]
                msg = p.get("message", "")
                lines.append(f"  {name}" + (f" — {msg}" if msg else ""))
            else:
                lines.append(f"  {p}")

    return "\n".join(lines)


def format_deploy(data: dict) -> str:
    """Format deploy response for Telegram."""
    return data.get("message", f"[{data.get('name', '?')}] Deploy result: {data.get('status', '?')}")


def format_board(output: str) -> str:
    """Format forge board CLI output for Telegram. Already formatted, just return."""
    return output


def truncate(text: str, max_len: int = 4000) -> str:
    """Telegram messages max 4096 chars. Truncate with notice."""
    if len(text) <= max_len:
        return text
    return text[:max_len] + "\n\n... (truncated)"
