#!/usr/bin/env python3
"""Create protected Telegram notification files without exposing the bot token."""

from __future__ import annotations

import argparse
import getpass
import json
import stat
import sys
import urllib.request
from pathlib import Path


def api(token: str, method: str, payload: dict | None = None) -> dict:
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(payload or {}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def write_secret(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value.strip() + "\n", encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def main() -> int:
    parser = argparse.ArgumentParser(description="Configure Telegram health notifications")
    parser.add_argument("--output-dir", default="secrets")
    parser.add_argument("--chat-id", help="Use a known Telegram chat ID")
    args = parser.parse_args()

    token = getpass.getpass("Telegram bot token from @BotFather: ").strip()
    if not token:
        print("No bot token supplied.", file=sys.stderr)
        return 2
    identity = api(token, "getMe")
    if not identity.get("ok"):
        print("Telegram rejected the bot token.", file=sys.stderr)
        return 2

    chat_id = (args.chat_id or "").strip()
    if not chat_id:
        print("Send /start to your new bot in Telegram, then press Enter here.")
        input()
        updates = api(token, "getUpdates")
        candidates = []
        for update in updates.get("result", []):
            message = update.get("message") or update.get("edited_message") or {}
            chat = message.get("chat") or {}
            if chat.get("id") is not None:
                candidates.append(str(chat["id"]))
        if not candidates:
            print("No chat found. Send /start to the bot and try again.", file=sys.stderr)
            return 3
        chat_id = candidates[-1]

    test = api(
        token,
        "sendMessage",
        {
            "chat_id": chat_id,
            "text": "Fitness Health Dashboard Telegram 通知配置成功。",
            "protect_content": True,
        },
    )
    if not test.get("ok"):
        print("Telegram could not deliver the test message.", file=sys.stderr)
        return 3

    output = Path(args.output_dir).expanduser().resolve()
    write_secret(output / "telegram-bot-token", token)
    write_secret(output / "telegram-chat-id", chat_id)
    print(f"Telegram connected. Protected settings saved under {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
