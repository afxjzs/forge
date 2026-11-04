"""The bot token must never appear in forge-bot's logs.

Telegram puts the token in every API URL, and the journal is readable by more
than the bot. Until 2026-11-04 httpx logged each polling URL at INFO, writing
the token to the journal every 10 seconds.
"""

import logging

import pytest

from log_setup import configure_logging

TOKEN = "123456789:AAFakeTokenForTestsOnly_abcdefghijk"
URL = f"https://api.telegram.org/bot{TOKEN}/getUpdates"


@pytest.fixture(autouse=True)
def _restore_logging():
    """configure_logging rewires the root logger onto this test's captured
    stderr; undo that so later tests don't log into a closed stream."""
    root, httpx_log = logging.getLogger(), logging.getLogger("httpx")
    before, root_level, httpx_level = root.handlers[:], root.level, httpx_log.level
    yield
    for h in root.handlers[:]:
        if h not in before:
            root.removeHandler(h)
    root.setLevel(root_level)
    httpx_log.setLevel(httpx_level)


def test_polling_request_lines_do_not_show_the_token(capsys):
    configure_logging(TOKEN)
    logging.getLogger("httpx").info('HTTP Request: POST %s "HTTP/1.1 200 OK"', URL)
    assert TOKEN not in capsys.readouterr().err


def test_errors_mentioning_the_token_are_still_logged_with_it_masked(capsys):
    configure_logging(TOKEN)
    logging.getLogger("telegram.ext").error("Network error calling %s", URL)
    out = capsys.readouterr().err
    assert TOKEN not in out
    assert "Network error calling" in out


def test_tracebacks_mentioning_the_token_are_masked(capsys):
    configure_logging(TOKEN)
    try:
        raise RuntimeError(f"request to {URL} failed")
    except RuntimeError:
        logging.getLogger("forge-bot").exception("polling failed")
    out = capsys.readouterr().err
    assert TOKEN not in out
    assert "RuntimeError" in out


def test_logs_stay_readable_when_no_token_is_configured(capsys):
    # bot.py logs "No bot token found" in this case; masking an empty string
    # would splice the mask between every character of every line.
    configure_logging("")
    logging.getLogger("forge-bot").error("No bot token found. Check ~/.forge-bot-token")
    assert "No bot token found. Check ~/.forge-bot-token" in capsys.readouterr().err
