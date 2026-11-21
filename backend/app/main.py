import os
from contextlib import asynccontextmanager
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware

load_dotenv()  # loads from .env in cwd, or env vars from Docker

from .database import init_db
from .scheduler import start_scheduler, stop_scheduler
from .routes.health import router as health_router
from .routes.workouts import router as workouts_router
from .routes.insights import router as insights_router
from .routes.auth import router as auth_router, is_valid_session
from .routes.integrations import router as integrations_router
from .routes.strength import router as strength_router
from .routes.web_push import router as web_push_router
from .home_dashboard import router as home_router
from .home_brief import router as brief_router
from .body_log import router as body_router
from .media_bridge import start_media_bridge
from .security import init_security, session_secret
from .system_health import router as system_router
from .ui_layout_diagnostics import router as ui_layout_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize DB schema
    init_db()
    init_security()
    from .database import get_db
    from .home_brief import ensure_schema
    with get_db() as conn:
        ensure_schema(conn)
        conn.commit()
    required = [name for name in ("DASHBOARD_USER", "DASHBOARD_PASS", "JWT_SECRET") if not os.getenv(name)]
    if required:
        raise RuntimeError(f"Missing required configuration: {', '.join(required)}")
    session_secret()
    
    # Start background jobs
    jobs_enabled=os.getenv('ENABLE_BACKGROUND_JOBS','true').lower()=='true'
    if jobs_enabled:start_scheduler()
    bridge = None
    try:
        bridge = start_media_bridge()
    except Exception as error:
        print(f"Media AI bridge unavailable: {type(error).__name__}")
    try:
        yield
    finally:
        if bridge:bridge.close()
        if jobs_enabled:stop_scheduler()


app = FastAPI(
    title="Fitness Dashboard API",
    version="1.1.0",
    lifespan=lifespan,
    docs_url='/docs' if os.getenv('ENABLE_API_DOCS')=='true' else None,
    redoc_url=None,
    openapi_url='/openapi.json' if os.getenv('ENABLE_API_DOCS')=='true' else None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv('CORS_ORIGINS','https://health.frankandpatrick.com').split(','),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def jwt_auth_middleware(request: Request, call_next):
    path = request.scope['path']
    public_paths = {
        "/api/status",
        "/api/livez",
        "/api/readyz",
        "/api/auth/app-login",
        "/api/auth/app-status",
        "/api/auth/callback",
    }
    origins=os.getenv('CORS_ORIGINS','https://health.frankandpatrick.com').split(',')
    unsafe=request.method not in {'GET','HEAD','OPTIONS'}
    origin=request.headers.get('origin')
    if unsafe and ((origin and origin not in origins) or request.headers.get('sec-fetch-site')=='cross-site'):
        response=JSONResponse(status_code=403,content={'detail':'Untrusted request origin'})
    elif request.method!='OPTIONS' and path.startswith('/api/') and path not in public_paths and not is_valid_session(request):
        response=JSONResponse(status_code=401,content={'detail':'Missing or invalid session'})
    else:
        response=await call_next(request)
    if path.startswith('/api/'):
        response.headers['Cache-Control']='no-store, private'
        response.headers['Pragma']='no-cache'
    response.headers['X-Content-Type-Options']='nosniff'
    response.headers['Referrer-Policy']='same-origin'
    response.headers['X-Frame-Options']='DENY'
    return response

app.add_middleware(TrustedHostMiddleware,
    allowed_hosts=os.getenv('ALLOWED_HOSTS','health.frankandpatrick.com,localhost,127.0.0.1,backend,192.168.1.225').split(','),
    www_redirect=False)

app.include_router(health_router)
app.include_router(workouts_router)
app.include_router(insights_router)
app.include_router(auth_router)
app.include_router(integrations_router)
app.include_router(strength_router)
app.include_router(web_push_router)
app.include_router(home_router)
app.include_router(brief_router)
app.include_router(body_router)
app.include_router(system_router)
app.include_router(ui_layout_router)


@app.get("/api/status")
def status():
    from .system_health import readiness
    ready=readiness()
    return JSONResponse({'status':'ok' if ready else 'not_ready','version':os.getenv('APP_VERSION','security-hardening-v1')},status_code=200 if ready else 503)
