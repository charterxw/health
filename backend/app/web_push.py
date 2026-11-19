"""Authenticated Web Push subscriptions and durable report notifications."""
import base64
import hashlib
import json
import os
import tempfile
import threading
from datetime import timedelta
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pywebpush import webpush, WebPushException

from .database import get_db, get_db_path
from .recorded_sessions import instant, iso

_key_lock = threading.Lock()
OBSERVATION_TITLES = {"morning": "早间睡眠分析", "evening": "晚间健康分析", "weekly": "每周观察"}


def now_utc():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc)


def key_path():
    return Path(os.getenv('WEB_PUSH_PRIVATE_KEY_FILE') or Path(get_db_path()).with_name('webpush-vapid.pem'))


def vapid_key():
    path = key_path()
    with _key_lock:
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            private = ec.generate_private_key(ec.SECP256R1())
            data = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
            fd, temporary = tempfile.mkstemp(prefix='.vapid-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as handle:
                    handle.write(data); handle.flush(); os.fsync(handle.fileno())
                try:
                    os.link(temporary, path)  # Publish a complete key, never replace an existing one.
                except FileExistsError:
                    pass
            finally:
                os.unlink(temporary)
        private = serialization.load_pem_private_key(path.read_bytes(), password=None)
    if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP256R1):
        raise ValueError('Invalid Web Push key')
    return private


def public_key():
    raw = vapid_key().public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


def decode_key(value):
    return base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)


class PushKeys(BaseModel):
    model_config = ConfigDict(extra='forbid')
    p256dh: str = Field(min_length=80, max_length=100)
    auth: str = Field(min_length=20, max_length=30)

    @field_validator('p256dh')
    @classmethod
    def valid_public(cls, value):
        try:
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), decode_key(value))
        except Exception as exc:
            raise ValueError('推送加密公钥无效') from exc
        return value

    @field_validator('auth')
    @classmethod
    def valid_auth(cls, value):
        try:
            if len(decode_key(value)) != 16:
                raise ValueError()
        except Exception as exc:
            raise ValueError('推送授权信息无效') from exc
        return value


class Subscription(BaseModel):
    model_config = ConfigDict(extra='forbid')
    endpoint: str = Field(min_length=20, max_length=4096)
    keys: PushKeys
    expirationTime: float | None = Field(default=None, ge=0, allow_inf_nan=False)

    @field_validator('endpoint')
    @classmethod
    def trusted_endpoint(cls, value):
        try:
            url = urlsplit(value)
            host = (url.hostname or '').lower()
            allowed = (host == 'web.push.apple.com' or host.endswith('.push.apple.com')
                       or host == 'fcm.googleapis.com' or host == 'updates.push.services.mozilla.com')
            if not (url.scheme == 'https' and allowed and url.port in (None, 443)
                    and not url.username and not url.password and not url.fragment and len(url.path) > 3):
                raise ValueError()
        except ValueError as exc:
            raise ValueError('请使用浏览器提供的 Apple、Google 或 Mozilla 推送订阅') from exc
        return value


class SubscriptionId(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(pattern=r'^[a-f0-9]{64}$')


def config():
    return {'public_key': public_key()}


def subscription_status(subscription_id):
    with get_db() as conn:
        return {'active': conn.execute('SELECT 1 FROM webpush_subscriptions WHERE id=?', (subscription_id,)).fetchone() is not None}


def subscribe(subscription):
    value = subscription.model_dump(mode='json')
    sid = hashlib.sha256(value['endpoint'].encode()).hexdigest()
    at = iso(now_utc())
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        latest = conn.execute("SELECT started_at FROM strength_sessions WHERE status='completed' ORDER BY ended_at DESC LIMIT 1").fetchone()
        notify_from = max(latest[0], iso(now_utc() - timedelta(days=7))) if latest else at
        conn.execute('''INSERT INTO webpush_subscriptions (id,subscription_json,created_at,updated_at,notify_from)
                        VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET subscription_json=excluded.subscription_json,
                        updated_at=excluded.updated_at''', (sid, json.dumps(value), at, at, notify_from))
        conn.commit()
    queue_ready()
    return {'id': sid, 'active': True}


def unsubscribe(sid):
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute('DELETE FROM workout_push_deliveries WHERE subscription_id=?', (sid,))
        conn.execute('DELETE FROM observation_push_deliveries WHERE subscription_id=?', (sid,))
        conn.execute('DELETE FROM webpush_subscriptions WHERE id=?', (sid,))
        conn.commit()
    return {'active': False}


def ready(doc, job):
    if doc['status'] != 'completed' or not job or not job['payload_json']:
        return False
    if (doc['started_at'], doc['ended_at']) != (job['started_at'], job['ended_at']):
        return False
    if instant(doc['ended_at']) < now_utc() - timedelta(days=7):
        return False
    from .workout_physiology import _heart_summary
    payload = json.loads(job['payload_json'])
    heart, source, stats, _ = _heart_summary(payload, job['preferred_source_id'], instant(doc['started_at']), instant(doc['ended_at']))
    return bool(source and stats['sample_count'] and stats['minute_coverage_percent'] >= 90
                and stats['largest_gap_seconds'] <= 90 and source.get('latest_cloud_sample_at')
                and instant(source['latest_cloud_sample_at']) >= instant(doc['ended_at']))


def queue_ready():
    """Pure DB operation; registration and collection never send on an HTTP request."""
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        subscriptions = conn.execute('SELECT id,notify_from FROM webpush_subscriptions').fetchall()
        if not subscriptions:
            return
        rows = conn.execute("SELECT s.document_json,p.* FROM strength_sessions s JOIN strength_physiology p ON p.session_id=s.id WHERE s.status='completed' AND s.ended_at>=?", (iso(now_utc()-timedelta(days=7)),)).fetchall()
        for row in rows:
            doc = json.loads(row['document_json'])
            if not ready(doc, row):
                continue
            for sub in subscriptions:
                if doc['ended_at'] < sub['notify_from']:
                    continue
                conn.execute('''INSERT INTO workout_push_deliveries
                                (session_id,subscription_id,started_at,ended_at,next_attempt_at)
                                VALUES (?,?,?,?,?) ON CONFLICT(session_id,subscription_id) DO NOTHING''',
                             (doc['id'],sub['id'],doc['started_at'],doc['ended_at'],iso(now_utc())))
        conn.commit()


def _claim():
    now = iso(now_utc())
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        rows = conn.execute('''SELECT d.*,b.subscription_json,s.document_json,p.payload_json,p.preferred_source_id,
                              p.started_at AS current_start,p.ended_at AS current_end
                              FROM workout_push_deliveries d JOIN webpush_subscriptions b ON b.id=d.subscription_id
                              JOIN strength_sessions s ON s.id=d.session_id JOIN strength_physiology p ON p.session_id=s.id
                              WHERE d.delivered_at IS NULL AND d.next_attempt_at<=?
                              AND (d.lease_until IS NULL OR d.lease_until<=?) ORDER BY d.next_attempt_at LIMIT 20''', (now,now)).fetchall()
        for row in rows:
            doc=json.loads(row['document_json'])
            job=dict(row,started_at=row['current_start'],ended_at=row['current_end'])
            if (row['started_at'],row['ended_at'])!=(doc['started_at'],doc['ended_at']) or not ready(doc,job):
                conn.execute('DELETE FROM workout_push_deliveries WHERE session_id=? AND subscription_id=?', (row['session_id'],row['subscription_id']))
                continue
            token=str(uuid4())
            conn.execute("UPDATE workout_push_deliveries SET state='sending',lease_token=?,lease_until=?,attempts=attempts+1 WHERE session_id=? AND subscription_id=?", (token,iso(now_utc()+timedelta(minutes=2)),row['session_id'],row['subscription_id']))
            conn.commit()
            return dict(row,lease_token=token)
        conn.commit()
    return None


def _send(delivery):
    if "slot" in delivery:
        payload = {"kind": "observation", "slot": delivery["slot"], "date": delivery["report_date"],
                   "id": delivery["insight_id"]}
    else:
        payload = {'title': 'Health · 训练报告已更新', 'body': '训练时段的心率数据已获取，点此查看报告。',
                   'session_id': delivery['session_id']}
    try:
        vapid_key()
        webpush(subscription_info=json.loads(delivery['subscription_json']),data=json.dumps(payload,ensure_ascii=False),
                vapid_private_key=str(key_path()),vapid_claims={'sub':'https://health.frankandpatrick.com'},
                ttl=86400,timeout=10)
        return 'sent', None
    except WebPushException as error:
        status=getattr(error,'status_code',None)
        if status is None:
            response=getattr(error,'response',None)
            status=getattr(response,'status_code',None)
        retry_after = None
        if status in (429,503):
            value = getattr(error, 'retry_after', None)
            try:
                retry_after = max(0, int(value)) if str(value).isdigit() else max(0, int((parsedate_to_datetime(value)-now_utc()).total_seconds()))
            except (TypeError, ValueError, OverflowError):
                pass
        return ('gone' if status in (404,410) else 'retry'), retry_after
    except Exception:
        return 'retry', None  # Never log subscription URLs, keys, or notification health data.


def deliver_ready(limit=3):
    queue_ready()
    count=0
    for _ in range(limit):
        delivery=_claim()
        if not delivery:
            break
        result,retry_after=_send(delivery)
        if result=='gone':
            unsubscribe(delivery['subscription_id'])
            continue
        now=now_utc()
        delay=min(6*3600,60*5**min(delivery['attempts'],4))
        next_time=now+timedelta(seconds=max(delay,retry_after or 0))
        next_at=iso(next_time) if next_time < instant(delivery['ended_at'])+timedelta(days=7) else None
        with get_db() as conn:
            cursor=conn.execute('''UPDATE workout_push_deliveries SET state=?,delivered_at=?,next_attempt_at=?,lease_token=NULL,lease_until=NULL
                                   WHERE session_id=? AND subscription_id=? AND lease_token=?''',
                                ('sent' if result=='sent' else 'retry',iso(now) if result=='sent' else None,None if result=='sent' else next_at,delivery['session_id'],delivery['subscription_id'],delivery['lease_token']))
            conn.commit()
            count+=cursor.rowcount if result=='sent' else 0
    return count


def queue_observation(conn, insight_id, slot, report_date):
    """Write the outbox in the same transaction as the completed analysis."""
    if slot not in OBSERVATION_TITLES:
        return 0
    now = now_utc()
    cursor = conn.execute(
        """INSERT OR IGNORE INTO observation_push_deliveries
           (insight_id, subscription_id, slot, report_date, expires_at, next_attempt_at)
           SELECT ?, id, ?, ?, ?, ? FROM webpush_subscriptions""",
        (insight_id, slot, report_date, iso(now + timedelta(days=1)), iso(now)),
    )
    return cursor.rowcount


def _claim_observation():
    now = now_utc()
    with get_db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        row = conn.execute(
            """SELECT d.*, s.subscription_json
               FROM observation_push_deliveries d JOIN webpush_subscriptions s ON s.id = d.subscription_id
               WHERE d.next_attempt_at <= ? AND d.expires_at > ? AND d.delivered_at IS NULL
                 AND (d.lease_until IS NULL OR d.lease_until <= ?)
               ORDER BY d.next_attempt_at, d.insight_id LIMIT 1""",
            (iso(now), iso(now), iso(now)),
        ).fetchone()
        if row is None:
            return None
        token = str(uuid4())
        conn.execute(
            """UPDATE observation_push_deliveries
               SET attempts=attempts+1, lease_token=?, lease_until=?
               WHERE insight_id=? AND subscription_id=?""",
            (token, iso(now + timedelta(minutes=2)), row["insight_id"], row["subscription_id"]),
        )
        conn.commit()
        return dict(row, lease_token=token)


def deliver_observations(limit=3):
    count = 0
    for _ in range(limit):
        delivery = _claim_observation()
        if not delivery:
            break
        result, retry_after = _send(delivery)
        if result == "gone":
            unsubscribe(delivery["subscription_id"])
            continue
        now = now_utc()
        delay = min(3600, 60 * 5 ** min(delivery["attempts"], 3))
        next_at = iso(now + timedelta(seconds=max(delay, retry_after or 0)))
        with get_db() as conn:
            cursor = conn.execute(
                """UPDATE observation_push_deliveries
                   SET delivered_at=?, next_attempt_at=?, lease_token=NULL, lease_until=NULL
                   WHERE insight_id=? AND subscription_id=? AND lease_token=?""",
                (iso(now) if result == "sent" else None,
                 next_at if result != "sent" and next_at < delivery["expires_at"] else None,
                 delivery["insight_id"], delivery["subscription_id"], delivery["lease_token"]),
            )
            conn.commit()
            count += cursor.rowcount if result == "sent" else 0
    return count
