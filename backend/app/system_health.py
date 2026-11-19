"""Separate process liveness, essential readiness and optional-service degradation."""
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from fastapi import APIRouter
from fastapi.responses import JSONResponse
from .database import get_db_path
from .security import session_secret

router=APIRouter(prefix='/api',tags=['system'])


def readiness():
    try:
        session_secret()
        if not os.getenv('DASHBOARD_USER','').strip() or not os.getenv('DASHBOARD_PASS',''):
            return False
        with sqlite3.connect(Path(get_db_path()).resolve().as_uri()+'?mode=ro',uri=True,timeout=2) as db:
            db.execute('SELECT 1 FROM dashboard_sessions LIMIT 1').fetchone()
            db.execute('SELECT 1 FROM strength_sessions LIMIT 1').fetchone()
        from .scheduler import scheduler
        return scheduler.running or os.getenv('ENABLE_BACKGROUND_JOBS','true').lower()=='false'
    except Exception:
        return False


@router.get('/livez')
def livez():
    return {'status':'ok','version':os.getenv('APP_VERSION','security-hardening-v1')}


@router.get('/readyz')
def readyz():
    ready=readiness()
    return JSONResponse({'status':'ready' if ready else 'not_ready'},status_code=200 if ready else 503)


@router.get('/system/health')
def details():
    from .chatgpt_auth import is_chatgpt_connected
    from .google_health import is_authenticated
    now=datetime.now(timezone.utc)
    checks={'database':readiness(),'google_configured':is_authenticated(),'ai_configured':is_chatgpt_connected()}
    sources={};briefs=[]
    try:
        with sqlite3.connect(Path(get_db_path()).resolve().as_uri()+'?mode=ro',uri=True,timeout=2) as db:
            for key,fetched in db.execute('SELECT key,fetched_at FROM home_snapshots'):
                instant=datetime.fromisoformat(fetched.replace('Z','+00:00'))
                sources[key]={'fetched_at':fetched,'age_seconds':max(0,int((now-instant).total_seconds()))}
            columns={r[1] for r in db.execute('PRAGMA table_info(home_briefs)')}
            if 'error_code' in columns:
                rows=db.execute('SELECT date,period,status,error_code,error_at FROM home_briefs ORDER BY date DESC,period LIMIT 4')
                briefs=[dict(zip(['date','period','status','error_code','error_at'],r)) for r in rows]
            else:
                briefs=[dict(zip(['date','period','status'],r)) for r in db.execute('SELECT date,period,status FROM home_briefs ORDER BY date DESC LIMIT 4')]
    except sqlite3.Error:
        pass
    degraded=not checks['google_configured'] or not checks['ai_configured'] or any(r['status']=='error' for r in briefs[:2])
    if any(value['age_seconds']>86400 for value in sources.values()):degraded=True
    return {'status':'not_ready' if not checks['database'] else 'degraded' if degraded else 'ok',
            'checked_at':now.isoformat(),'checks':checks,'sources':sources,'briefs':briefs}
