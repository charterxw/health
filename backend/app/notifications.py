"""Optional delivery of completed AI analysis to a private Telegram chat."""

from __future__ import annotations

import logging
import os

import httpx


logger = logging.getLogger(__name__)


def _secret(env_name: str, file_env_name: str, default_file: str) -> str:
    direct = os.getenv(env_name, "").strip()
    if direct:
        return direct
    path = os.getenv(file_env_name, default_file).strip()
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def _bot_token() -> str:
    return _secret(
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_BOT_TOKEN_FILE",
        "/run/secrets/fitness/telegram-bot-token",
    )


def _chat_id() -> str:
    return _secret(
        "TELEGRAM_CHAT_ID",
        "TELEGRAM_CHAT_ID_FILE",
        "/run/secrets/fitness/telegram-chat-id",
    )


def notifications_enabled() -> bool:
    enabled = os.getenv("TELEGRAM_NOTIFICATIONS_ENABLED", "true").lower()
    return (
        enabled in {"1", "true", "yes", "on"}
        and bool(_bot_token())
        and bool(_chat_id())
    )


def get_notification_status() -> dict:
    return {
        "provider": "telegram",
        "configured": bool(_bot_token() and _chat_id()),
        "enabled": notifications_enabled(),
    }


def _message(title: str, content: str, date: str | None = None) -> str:
    heading = f"健康分析 · {title}"
    if date:
        heading += f" · {date}"
    text = f"{heading}\n\n{content.strip()}"
    if len(text) > 4096:
        text = text[:4060].rstrip() + "\n\n（内容过长，已截断）"
    return text


def send_telegram_message(title: str, content: str, date: str | None = None) -> bool:
    """Send one private notification; failures never invalidate saved analysis."""
    if not notifications_enabled():
        return False

    token = _bot_token()
    chat_id = _chat_id()
    try:
        response = httpx.post(
            f"https://api.telegram.org/bot{token}/sendMessage",
            json={
                "chat_id": chat_id,
                "text": _message(title, content, date),
                "protect_content": True,
                "link_preview_options": {"is_disabled": True},
            },
            timeout=15.0,
        )
        if response.status_code != 200:
            logger.warning("Telegram notification failed with HTTP %s", response.status_code)
            return False
        payload = response.json()
        if not payload.get("ok"):
            logger.warning("Telegram notification was rejected")
            return False
        return True
    except (httpx.HTTPError, ValueError):
        logger.warning("Telegram notification could not be delivered")
        return False


def send_telegram_message_once(
    event_key: str,
    title: str,
    content: str,
    date: str,
) -> bool:
    """Deliver at most one copy of an operational reminder per local date."""
    from .database import get_db

    with get_db() as conn:
        already_sent = conn.execute(
            "SELECT 1 FROM notification_events WHERE event_date = ? AND event_key = ?",
            (date, event_key),
        ).fetchone()
    if already_sent:
        return False

    if not send_telegram_message(title, content, date):
        return False

    with get_db() as conn:
        conn.execute(
            """INSERT OR IGNORE INTO notification_events
               (event_date, event_key) VALUES (?, ?)""",
            (date, event_key),
        )
        conn.commit()
    return True


def notify_analysis(title: str, content: str, date: str | None = None) -> None:
    send_telegram_message(title, content, date)
