from fastapi import APIRouter, Request, Response, HTTPException
from fastapi.responses import RedirectResponse, JSONResponse
from pydantic import BaseModel, Field
import os
import secrets
from ..google_health import get_auth_url, exchange_code, is_authenticated
from ..security import (SESSION_COOKIE, is_valid_session, check_login_rate,
                        clear_account_failures, issue_session, revoke_session, logger)

router = APIRouter(prefix="/api/auth", tags=["auth"])
OAUTH_STATE_COOKIE = "oauth_state"

class LoginRequest(BaseModel):
    username: str = Field(min_length=1,max_length=128)
    password: str = Field(min_length=1,max_length=1024)

def _cookie_secure() -> bool:
    configured = os.getenv("COOKIE_SECURE")
    if configured is not None:
        return configured.lower() in ("1", "true", "yes", "on")
    return os.getenv("GOOGLE_REDIRECT_URI", "").startswith("https://")


@router.post("/app-login")
def app_login(req: LoginRequest, request: Request, response: Response):
    expected_user = os.getenv("DASHBOARD_USER", "").strip()
    expected_pass = os.getenv("DASHBOARD_PASS", "")
    if not expected_user or not expected_pass:
        raise HTTPException(status_code=503, detail="Dashboard credentials are not configured")
    
    check_login_rate(request,req.username)
    if secrets.compare_digest(req.username.encode(),expected_user.encode()) and secrets.compare_digest(req.password.encode(),expected_pass.encode()):
        clear_account_failures(request,req.username)
        token,ttl = issue_session(req.username)
        response.set_cookie(
            SESSION_COOKIE,
            token,
            max_age=ttl,
            httponly=True,
            secure=_cookie_secure(),
            samesite="lax",
            path="/",
        )
        return {"authenticated": True}
    
    from ..security import client_address
    logger.warning('login_failed source=%s',client_address(request))
    raise HTTPException(status_code=401, detail="Invalid username or password")


@router.get("/app-status")
def app_status(request: Request):
    return {"authenticated": is_valid_session(request)}


@router.post("/logout")
def logout(request: Request, response: Response):
    revoke_session(request)
    response.delete_cookie(SESSION_COOKIE, path="/", secure=_cookie_secure(), httponly=True,samesite='lax')
    return {"authenticated": False}


@router.get("/status")
def auth_status():
    return {"authenticated": is_authenticated()}


@router.get("/login")
def login(device_sync: bool = False):
    state = secrets.token_urlsafe(32)
    response = RedirectResponse(url=get_auth_url(state, device_sync=device_sync))
    response.set_cookie(
        OAUTH_STATE_COOKIE,
        state,
        max_age=600,
        httponly=True,
        secure=_cookie_secure(),
        samesite="lax",
        path="/api/auth",
    )
    return response


@router.get("/callback")
async def callback(request: Request, code: str = "", state: str = ""):
    expected_state = request.cookies.get(OAUTH_STATE_COOKIE, "")
    if not code or not state or not expected_state or not secrets.compare_digest(state, expected_state):
        return JSONResponse({"error": "Invalid OAuth callback state"}, status_code=400)
    try:
        await exchange_code(code)
        from ..database import get_db
        with get_db() as conn:
            if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='home_snapshots'").fetchone():
                conn.execute("DELETE FROM home_snapshots WHERE key='freshness'")
            conn.commit()
        # Redirect to frontend after successful auth
        response = RedirectResponse(url="/")
        response.delete_cookie(OAUTH_STATE_COOKIE, path="/api/auth")
        return response
    except Exception as e:
        return JSONResponse({"error": f"Google authorization failed: {type(e).__name__}"}, status_code=502)
