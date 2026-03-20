#!/usr/bin/env python3
"""forge-e2e-report.py — Parse Playwright results and send Telegram notification.

Usage: forge-e2e-report.py <project-name> <staging-url> <artifacts-dir> <exit-code>
"""

import json
import subprocess
import sys
from pathlib import Path

FORGE_ROOT = Path.home() / "nexus" / "infra" / "dev-pipeline"
NOTIFY_SCRIPT = FORGE_ROOT / "scripts" / "forge-notify.sh"


def find_screenshots(artifacts_dir: Path) -> dict[str, str]:
    """Map test names to screenshot paths."""
    screenshots = {}
    for f in artifacts_dir.rglob("*.png"):
        screenshots[f.stem] = f.name
    return screenshots


def find_videos(artifacts_dir: Path) -> dict[str, str]:
    """Map test names to video paths."""
    videos = {}
    for f in artifacts_dir.rglob("*.webm"):
        videos[f.stem] = f.name
    return videos


def parse_results(artifacts_dir: Path) -> dict | None:
    """Parse Playwright JSON reporter output."""
    results_file = artifacts_dir / "results.json"
    if not results_file.exists():
        return None
    try:
        return json.loads(results_file.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def extract_test_results(data: dict) -> list[dict]:
    """Extract individual test results from Playwright JSON output."""
    tests = []

    def walk_suites(suites: list, prefix: str = ""):
        for suite in suites:
            suite_title = suite.get("title", "")
            current = f"{prefix} > {suite_title}" if prefix else suite_title

            # Process specs (actual tests) in this suite
            for spec in suite.get("specs", []):
                spec_title = spec.get("title", "")
                full_title = f"{current} > {spec_title}" if current else spec_title

                for t in spec.get("tests", []):
                    results = t.get("results", [{}])
                    for r in results:
                        duration_ms = r.get("duration", 0)
                        attachments = r.get("attachments", [])
                        screenshot = None
                        video = None
                        for att in attachments:
                            if att.get("contentType", "").startswith("image/"):
                                screenshot = Path(att.get("path", "")).name if att.get("path") else None
                            if att.get("contentType", "").startswith("video/"):
                                video = Path(att.get("path", "")).name if att.get("path") else None

                        tests.append({
                            "title": full_title,
                            "status": t.get("status", "expected"),
                            "duration_ms": duration_ms,
                            "screenshot": screenshot,
                            "video": video,
                        })

            # Recurse into nested suites (describe blocks)
            walk_suites(suite.get("suites", []), current)

    walk_suites(data.get("suites", []))
    return tests


def build_message(
    project_name: str,
    staging_url: str,
    tests: list[dict],
    artifacts_url: str,
    exit_code: int,
    duration_ms: int,
) -> str:
    passed = sum(1 for t in tests if t["status"] == "expected")
    failed = sum(1 for t in tests if t["status"] in ("unexpected", "failed"))
    skipped = sum(1 for t in tests if t["status"] == "skipped")
    total = len(tests)
    duration_s = duration_ms / 1000

    if failed == 0 and exit_code == 0:
        return f"[{project_name}] E2E: {passed}/{total} passed ({duration_s:.0f}s)"

    lines = [f"[{project_name}] E2E: {failed} FAILED, {passed} passed ({duration_s:.0f}s)", ""]

    lines.append("Failed:")
    for t in tests:
        if t["status"] in ("unexpected", "failed"):
            lines.append(f"  - {t['title']}")
            if t.get("screenshot"):
                lines.append(f"    Screenshot: {artifacts_url}{t['screenshot']}")
            if t.get("video"):
                lines.append(f"    Video: {artifacts_url}{t['video']}")

    lines.append("")
    lines.append(f"Full log: {artifacts_url}e2e-run.log")
    lines.append("")
    lines.append("Reply 'fix e2e' within 10 min to have workers investigate.")
    lines.append("Default: no action.")

    return "\n".join(lines)


def send_notification(message: str) -> None:
    try:
        subprocess.run(
            [str(NOTIFY_SCRIPT), message],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:
        print(f"Warning: notification failed: {e}", file=sys.stderr)


def main():
    if len(sys.argv) < 5:
        print("Usage: forge-e2e-report.py <project> <staging-url> <artifacts-dir> <exit-code>")
        sys.exit(1)

    project_name = sys.argv[1]
    staging_url = sys.argv[2]
    artifacts_dir = Path(sys.argv[3])
    exit_code = int(sys.argv[4])

    artifacts_url = f"{staging_url}/test-artifacts/"

    data = parse_results(artifacts_dir)
    if data is None:
        # No results.json — playwright may have crashed before producing output
        if exit_code != 0:
            msg = f"[{project_name}] E2E tests crashed — no results produced. Check {artifacts_url}e2e-run.log"
            send_notification(msg)
        else:
            msg = f"[{project_name}] E2E: passed (no JSON report)"
            send_notification(msg)
        return

    tests = extract_test_results(data)
    duration_ms = data.get("stats", {}).get("duration", 0)

    # Also scan for screenshots not in results (e.g., from Playwright's outputDir)
    screenshots = find_screenshots(artifacts_dir)
    for t in tests:
        if not t.get("screenshot") and t["status"] in ("unexpected", "failed"):
            # Try to find a matching screenshot by test name
            slug = t["title"].lower().replace(" > ", "-").replace(" ", "-")
            for name, filename in screenshots.items():
                if slug in name.lower():
                    t["screenshot"] = filename
                    break

    message = build_message(project_name, staging_url, tests, artifacts_url, exit_code, duration_ms)
    print(message)
    send_notification(message)


if __name__ == "__main__":
    main()
