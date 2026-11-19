"""Revocable, hashed sessions and persistent login throttling."""
import hashlib
import hmac
import ipaddress
import logging
import os
import secrets
import sqlite3
import time

from fastapi import HTTPException, Request
from .database import get_db

logger = logging.getLogger(__name__)
SESSION_COOKIE = 'dashboard_session'
SCHEMA = '''
CREATE TABLE IF NOT EXISTS dashboard_sessions (
 token_hash TEXT PRIMARY KEY, username TEXT NOT NULL, credential_version TEXT NOT NULL,
 created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS dashboard_sessions_expiry ON dashboard_sessions(expires_at);
CREATE TABLE IF NOT EXISTS dashboard_login_limits (
 bucket TEXT PRIMARY KEY, window_start INTEGER NOT NULL, attempts INTEGER NOT NULL);
'''


def init_security():
    with get_db() as conn:
        conn.executescript(SCHEMA)
        conn.commit()


def session_secret():
    value = os.getenv('SESSION_SECRET') or os.getenv('JWT_SECRET', '')
    if len(value) < 32:
        raise HTTPException(503, 'Session signing secret is not configured securely')
    return value.encode()


def credential_version():
    account = os.getenv('DASHBOARD_USER', '').strip()
    password = os.getenv('DASHBOARD_PASS', '')
    return hmac.new(session_secret(), (account+'\0'+password).encode(), hashlib.sha256).hexdigest()


def client_address(request: Request):
    peer = request.client.host if request.client else 'unknown'
    try:
        address = ipaddress.ip_address(peer)
        networks = os.getenv('TRUSTED_PROXY_NETWORKS', '127.0.0.1/32,::1/128').split(',')
        if any(address in ipaddress.ip_network(value.strip()) for value in networks if value.strip()):
            forwarded = request.headers.get('x-real-ip')
            if forwarded:
                return str(ipaddress.ip_address(forwarded))
    except ValueError:
        pass
    return peer


def check_login_rate(request: Request, username: str):
    """Reserve attempts atomically; untrusted forwarded headers cannot change buckets."""
    init_security()
    now = int(time.time())
    address = client_address(request)
    specs = [('ip:'+address, 60, 20), ('account:'+address+':'+username.casefold(), 900, 8)]
    retry_after = 0
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute('DELETE FROM dashboard_login_limits WHERE window_start < ?', (now-1800,))
        for name, window, maximum in specs:
            bucket = hmac.new(session_secret(), name.encode(), hashlib.sha256).hexdigest()
            row = conn.execute('SELECT window_start,attempts FROM dashboard_login_limits WHERE bucket=?', (bucket,)).fetchone()
            if row and row[0]+window > now and row[1] >= maximum:
                retry_after = max(retry_after, row[0]+window-now)
        if not retry_after:
            for name, window, maximum in specs:
                bucket = hmac.new(session_secret(), name.encode(), hashlib.sha256).hexdigest()
                conn.execute('''INSERT INTO dashboard_login_limits VALUES(?,?,1) ON CONFLICT(bucket) DO UPDATE SET
                  attempts=CASE WHEN window_start+?<=? THEN 1 ELSE attempts+1 END,
                  window_start=CASE WHEN window_start+?<=? THEN ? ELSE window_start END''',
                  (bucket,now,window,now,window,now,now))
        conn.commit()
    if retry_after:
        logger.warning('login_throttled source=%s', address)
        raise HTTPException(429, 'Too many login attempts. Try again later.', headers={'Retry-After':str(retry_after)})


def clear_account_failures(request: Request, username: str):
    bucket = hmac.new(session_secret(), ('account:'+client_address(request)+':'+username.casefold()).encode(), hashlib.sha256).hexdigest()
    with get_db() as conn:
        conn.execute('DELETE FROM dashboard_login_limits WHERE bucket=?', (bucket,))
        conn.commit()


def issue_session(username: str):
    token = secrets.token_urlsafe(32)
    now = int(time.time())
    ttl = max(300,min(int(os.getenv('SESSION_TTL_SECONDS','604800')),604800))
    with get_db() as conn:
        conn.execute('DELETE FROM dashboard_sessions WHERE expires_at<=?', (now,))
        conn.execute('INSERT INTO dashboard_sessions VALUES(?,?,?,?,?)',
          (hashlib.sha256(token.encode()).hexdigest(),username,credential_version(),now,now+ttl))
        conn.commit()
    return token,ttl


def is_valid_session(request: Request):
    token = request.cookies.get(SESSION_COOKIE, '')
    if not token or len(token) > 128:
        return False
    try:
        with get_db() as conn:
            row = conn.execute('SELECT username,credential_version,expires_at FROM dashboard_sessions WHERE token_hash=?',
                               (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        return bool(row and row[2]>time.time() and row[0]==os.getenv('DASHBOARD_USER','').strip()
                    and hmac.compare_digest(row[1],credential_version()))
    except (sqlite3.Error,HTTPException):
        return False


def revoke_session(request: Request):
    token = request.cookies.get(SESSION_COOKIE,'')
    if not token or len(token)>128:
        return
    with get_db() as conn:
        conn.execute('DELETE FROM dashboard_sessions WHERE token_hash=?',(hashlib.sha256(token.encode()).hexdigest(),))
        conn.commit()
