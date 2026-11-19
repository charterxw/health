#!/usr/bin/env python3
"""Complete ChatGPT-plan OAuth locally for a self-hosted Fitness Dashboard."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import sys
import threading
import urllib.parse
import urllib.request
import uuid
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import jwt
from jwt import PyJWKClient


AUTHORIZE_ENDPOINT = "https://auth.openai.com/api/accounts/authorize"
TOKEN_ENDPOINT = "https://auth.openai.com/api/accounts/oauth/token"
OIDC_CONFIG = "https://auth.openai.com/.well-known/openid-configuration"
RESOURCE = "https://api.openai.com/v1"
SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def post_form(url: str, fields: dict[str, str]) -> dict:
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(fields).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def write_private_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(stat.S_IRUSR | stat.S_IWUSR)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def existing_registration(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Authorize Fitness Health Dashboard to use your ChatGPT plan."
    )
    parser.add_argument(
        "--output",
        default="work/chatgpt-oauth.json",
        help="Protected credential file to create",
    )
    parser.add_argument(
        "--app-name",
        default="Fitness Health Dashboard",
        help="Name shown during ChatGPT authorization",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Print the authorization URL without opening it",
    )
    args = parser.parse_args()

    output = Path(args.output).expanduser().resolve()
    existing = existing_registration(output)
    host_id = existing.get("ext_agent_host_id") or f"urn:uuid:{uuid.uuid4()}"
    client_id = existing.get("client_id") or "dynamic_agent_client"

    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64url(hashlib.sha256(verifier.encode("ascii")).digest())
    result: dict[str, str] = {}
    done = threading.Event()

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/auth/callback":
                self.send_error(404)
                return
            values = {key: vals[-1] for key, vals in urllib.parse.parse_qs(parsed.query).items()}
            result.update(values)
            ok = values.get("state") == state and bool(values.get("code"))
            body = (
                "<h2>ChatGPT authorization complete</h2><p>You can return to Codex.</p>"
                if ok
                else "<h2>Authorization failed</h2><p>Return to Codex for details.</p>"
            )
            encoded = ("<!doctype html><meta charset='utf-8'>" + body).encode("utf-8")
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            done.set()

        def log_message(self, *_args):
            return

    server = HTTPServer(("127.0.0.1", 0), CallbackHandler)
    server.timeout = 1
    redirect_uri = f"http://127.0.0.1:{server.server_port}/auth/callback"

    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": SCOPES,
        "resource": RESOURCE,
        "state": state,
        "nonce": nonce,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "ext_agent_host_id": host_id,
    }
    if client_id == "dynamic_agent_client":
        params["agent_name_hint"] = args.app_name
    else:
        if existing.get("id_token"):
            params["id_token_hint"] = existing["id_token"]
        if existing.get("email"):
            params["login_hint"] = existing["email"]

    authorize_url = f"{AUTHORIZE_ENDPOINT}?{urllib.parse.urlencode(params)}"
    print("Open this URL to authorize the Fitness Health Dashboard:")
    print(authorize_url)
    if not args.no_browser:
        webbrowser.open(authorize_url)

    deadline = datetime.now(timezone.utc).timestamp() + 600
    while not done.is_set() and datetime.now(timezone.utc).timestamp() < deadline:
        server.handle_request()
    server.server_close()

    if not done.is_set():
        print("Authorization timed out.", file=sys.stderr)
        return 2
    if result.get("state") != state:
        print("Authorization state did not match.", file=sys.stderr)
        return 2
    if result.get("error"):
        print(f"Authorization was not completed: {result['error']}", file=sys.stderr)
        return 2

    issued_client_id = result.get("client_id") or client_id
    if issued_client_id == "dynamic_agent_client":
        print("OpenAI did not return an issued client ID.", file=sys.stderr)
        return 2
    if client_id != "dynamic_agent_client" and issued_client_id != client_id:
        print("OpenAI returned a different client ID than the saved registration.", file=sys.stderr)
        return 2

    token = post_form(
        TOKEN_ENDPOINT,
        {
            "grant_type": "authorization_code",
            "client_id": issued_client_id,
            "code": result["code"],
            "code_verifier": verifier,
            "redirect_uri": redirect_uri,
            "resource": RESOURCE,
        },
    )
    oidc = get_json(OIDC_CONFIG)
    id_token = token.get("id_token")
    if not id_token:
        print("OpenAI did not return an ID token.", file=sys.stderr)
        return 2
    signing_key = PyJWKClient(oidc["jwks_uri"]).get_signing_key_from_jwt(id_token)
    claims = jwt.decode(
        id_token,
        signing_key.key,
        algorithms=["RS256"],
        audience=issued_client_id,
        issuer=oidc["issuer"],
        options={"require": ["exp", "iat", "iss", "sub"]},
    )
    if claims.get("nonce") != nonce:
        print("ID token nonce did not match.", file=sys.stderr)
        return 2

    scopes = sorted(set(str(token.get("scope", "")).split()))
    if "chatgpt.tokens.use.direct" not in scopes:
        print("ChatGPT plan usage permission was not granted.", file=sys.stderr)
        return 3

    credential = {
        "email": claims.get("email"),
        "issuer": claims["iss"],
        "subject": claims["sub"],
        "client_id": issued_client_id,
        "ext_agent_host_id": host_id,
        "id_token": id_token,
        "access_token": token["access_token"],
        "refresh_token": token["refresh_token"],
        "token_type": token.get("token_type", "Bearer"),
        "expires_in": int(token.get("expires_in", 3600)),
        "scopes": scopes,
        "saved_at": datetime.now(timezone.utc).isoformat(),
    }
    write_private_json(output, credential)
    print(f"ChatGPT plan connected. Protected credentials saved to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
