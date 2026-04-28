"""Anthropic SDK wrapper for LLM-powered features. Sonnet only. No fallbacks."""

import logging

import anthropic

from config import ANTHROPIC_API_KEY, ANTHROPIC_MODEL

logger = logging.getLogger("forge-bot.llm")


async def ask_claude(prompt: str, system: str = "", max_tokens: int = 4096) -> str:
    """Send a prompt to Claude. Returns the text response.

    Raises on failure — NEVER silently fails.
    """
    client = anthropic.AsyncAnthropic(api_key=ANTHROPIC_API_KEY)

    messages = [{"role": "user", "content": prompt}]

    kwargs = {
        "model": ANTHROPIC_MODEL,
        "max_tokens": max_tokens,
        "messages": messages,
    }
    if system:
        kwargs["system"] = system

    response = await client.messages.create(**kwargs)

    if not response.content:
        raise RuntimeError("Claude returned empty response")

    return response.content[0].text


async def classify_note(note: str, project_name: str, existing_issues: list[dict] | None = None) -> dict:
    """Classify a live note and check for duplicates against existing issues.

    Returns: {
        "action": "create"|"comment"|"skip",
        "category": "bug"|"feature"|"ux"|"redirect",
        "summary": "one-line summary",
        "duplicate_of": null or issue number,
        "comment": null or comment text for existing issue
    }
    """
    issues_context = ""
    if existing_issues:
        issues_list = "\n".join(f"  #{i['number']}: {i['title']}" for i in existing_issues)
        issues_context = f"""
Existing open issues for this project:
{issues_list}

IMPORTANT: If this note is about the SAME problem as an existing issue, set action to "comment" and set duplicate_of to that issue number. Only create a new issue if it's genuinely different."""

    prompt = f"""You are triaging a user's testing note for the "{project_name}" project.

Note: "{note}"
{issues_context}
Classify into one category:
- bug: error reports, crashes, broken features, something that doesn't work
- feature: requests for new functionality, "should", "need", "add"
- ux: observations about feel, speed, confusion, design
- redirect: direction changes, "stop", "don't", "wrong approach"

Decide the action:
- "create": this is a NEW issue, not covered by any existing issue
- "comment": this is related to an existing issue — add as a comment instead
- "skip": this is an exact duplicate, already fully captured

Respond with ONLY a JSON object:
{{"action": "create|comment|skip", "category": "bug|feature|ux|redirect", "summary": "concise title for the issue", "duplicate_of": null, "comment": null}}

If action is "comment", set duplicate_of to the issue number and comment to what to add.
If action is "skip", set duplicate_of to the issue number."""

    text = await ask_claude(prompt, max_tokens=300)

    import json

    try:
        result = json.loads(text.strip())
        # Ensure required fields
        result.setdefault("action", "create")
        result.setdefault("category", "ux")
        result.setdefault("summary", note[:100])
        result.setdefault("duplicate_of", None)
        result.setdefault("comment", None)
        return result
    except json.JSONDecodeError:
        logger.warning(
            f"Claude returned unparseable JSON for classify_note, defaulting to 'create ux issue'. Raw response: {text[:200]}"
        )
        return {"action": "create", "category": "ux", "summary": note[:100], "duplicate_of": None, "comment": None}


async def synthesize_specs(project_name: str, questions: list[str], answers: list[str]) -> dict:
    """Synthesize interview Q&A into spec files.

    Returns: {"mvp": "content", "backlog": "content", "context": "content"}
    """
    qa_text = "\n".join(f"Q: {q}\nA: {a}\n" for q, a in zip(questions, answers))

    prompt = f"""You are the forge PM. Based on this interview, write project spec files for "{project_name}".

Interview:
{qa_text}

Write three files. Return as JSON with three keys: "mvp", "backlog", "context".
Each value is the full markdown content for that file.

- mvp: spec/MVP.md — problem, current state, what remains, success criteria
- backlog: spec/BACKLOG.md — prioritized features (P1 active, P2 soon, P3 nice-to-have)
- context: .agent/CONTEXT.md — current project state for workers

Be concise. Reference existing docs rather than duplicating them."""

    text = await ask_claude(prompt, system="You are a technical PM. Output valid JSON only.", max_tokens=4096)

    import json

    try:
        return json.loads(text.strip())
    except json.JSONDecodeError:
        # Try to extract JSON from the response
        start = text.find("{")
        end = text.rfind("}") + 1
        if start >= 0 and end > start:
            return json.loads(text[start:end])
        raise RuntimeError(f"Could not parse specs from Claude response: {text[:200]}")
