"""ChatGPT-plan OAuth credential management for a self-hosted dashboard."""

from __future__ import annotations

import json
import os
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx


TOKEN_ENDPOINT = "https://auth.openai.com/api/accounts/oauth/token"
RESOURCE = "https://api.openai.com/v1"
REQUIRED_SCOPE = "chatgpt.tokens.use.direct"
_refresh_lock = threading.Lock()


class ChatGPTAuthError(RuntimeError):
    """Raised when ChatGPT-plan credentials are missing or cannot be renewed."""

    def __init__(self, message: str, code: str = "chatgpt_auth_error"):
        super().__init__(message)
        self.code = code


def credentials_path() -> Path:
    return Path(
        os.getenv(
            "CHATGPT_CREDENTIALS_FILE",
            "/run/secrets/fitness/chatgpt-oauth.json",
        )
    )


def _parse_saved_at(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _load_credentials() -> dict:
    path = credentials_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ChatGPTAuthError(
            "ChatGPT is not connected. Complete Sign in with ChatGPT first.",
            "chatgpt_not_connected",
        ) from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise ChatGPTAuthError(
            "The saved ChatGPT connection is unreadable. Sign in again.",
            "chatgpt_credentials_invalid",
        ) from exc

    scopes = set(data.get("scopes") or str(data.get("scope", "")).split())
    required_fields = ("client_id", "access_token", "refresh_token", "saved_at")
    if any(not data.get(field) for field in required_fields) or REQUIRED_SCOPE not in scopes:
        raise ChatGPTAuthError(
            "The saved ChatGPT connection cannot use plan allowance. Sign in again.",
            "chatgpt_plan_scope_missing",
        )
    data["scopes"] = sorted(scopes)
    return data


def _write_credentials(data: dict) -> None:
    path = credentials_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    owner = None
    try:
        stat = path.stat()
        owner = (stat.st_uid, stat.st_gid)
    except FileNotFoundError:
        pass

    fd, temporary_name = tempfile.mkstemp(prefix=".chatgpt-oauth-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o600)
        if owner and os.geteuid() == 0:
            os.chown(temporary_name, owner[0], owner[1])
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def _expires_at(data: dict) -> datetime:
    return _parse_saved_at(data["saved_at"]) + timedelta(
        seconds=int(data.get("expires_in", 3600))
    )


def _refresh_credentials(data: dict) -> dict:
    try:
        response = httpx.post(
            TOKEN_ENDPOINT,
            data={
                "grant_type": "refresh_token",
                "client_id": data["client_id"],
                "refresh_token": data["refresh_token"],
                "resource": RESOURCE,
            },
            timeout=20.0,
        )
    except httpx.HTTPError as exc:
        raise ChatGPTAuthError(
            "ChatGPT sign-in could not be renewed. Try again shortly.",
            "chatgpt_refresh_unavailable",
        ) from exc

    if response.status_code != 200:
        try:
            error_code = response.json().get("error", "chatgpt_refresh_failed")
        except ValueError:
            error_code = "chatgpt_refresh_failed"
        if error_code in {
            "invalid_grant",
            "invalid_refresh_token",
            "token_expired",
            "refresh_token_expired",
            "refresh_token_invalidated",
            "refresh_token_reused",
        }:
            raise ChatGPTAuthError(
                "The ChatGPT connection expired. Sign in again.",
                "chatgpt_relogin_required",
            )
        raise ChatGPTAuthError(
            "ChatGPT sign-in could not be renewed. Try again shortly.",
            str(error_code),
        )

    token = response.json()
    refreshed = dict(data)
    for key in (
        "access_token",
        "refresh_token",
        "id_token",
        "token_type",
        "expires_in",
    ):
        if token.get(key) is not None:
            refreshed[key] = token[key]
    if token.get("scope"):
        refreshed["scopes"] = sorted(set(token["scope"].split()))
    refreshed["saved_at"] = datetime.now(timezone.utc).isoformat()
    _write_credentials(refreshed)
    return refreshed


def get_access_token() -> str:
    """Return a valid plan-usage access token, refreshing it when needed."""
    with _refresh_lock:
        data = _load_credentials()
        if datetime.now(timezone.utc) >= _expires_at(data) - timedelta(minutes=5):
            data = _refresh_credentials(data)
        return data["access_token"]


def is_chatgpt_connected() -> bool:
    try:
        _load_credentials()
        return True
    except ChatGPTAuthError:
        return False


def get_chatgpt_status() -> dict:
    try:
        data = _load_credentials()
        expires_at = _expires_at(data)
        return {
            "connected": True,
            "email": data.get("email"),
            "plan_usage_enabled": REQUIRED_SCOPE in set(data.get("scopes", [])),
            "token_refresh_due": datetime.now(timezone.utc)
            >= expires_at - timedelta(minutes=5),
            "manage_usage_url": "https://chatgpt.com/#settings/usage",
        }
    except ChatGPTAuthError as exc:
        return {
            "connected": False,
            "plan_usage_enabled": False,
            "reason": str(exc),
            "manage_usage_url": "https://chatgpt.com/#settings/usage",
        }
