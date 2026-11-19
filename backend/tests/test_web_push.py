import base64
import json
import os
import unittest
from datetime import timedelta
from unittest.mock import patch, Mock
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import test_workout_physiology as fixtures
from app import database, observations, openai_service, web_push, workout_physiology as phys


def subscription(endpoint='https://web.push.apple.com/QH123456789'):
    public=ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)
    encode=lambda value:base64.urlsafe_b64encode(value).decode().rstrip('=')
    return {'endpoint':endpoint,'keys':{'p256dh':encode(public),'auth':encode(b'a'*16)},'expirationTime':None}


class WebPushTests(unittest.TestCase):
    setUp=fixtures.WorkoutPhysiologyTests.setUp
    tearDown=fixtures.WorkoutPhysiologyTests.tearDown
    document=fixtures.WorkoutPhysiologyTests.document
    save=fixtures.WorkoutPhysiologyTests.save
    collect=fixtures.WorkoutPhysiologyTests.collect

    def set_clock(self):
        return patch.object(web_push,'now_utc',return_value=fixtures.NOW)

    def enable(self):
        return web_push.subscribe(web_push.Subscription(**subscription()))

    def rows(self):
        with database.get_db() as conn:return [dict(r) for r in conn.execute('SELECT * FROM workout_push_deliveries')]

    def test_keys_persist_privately_and_authenticated_subscription_lifecycle(self):
        first=self.client.get('/api/webpush/config')
        self.assertEqual(first.status_code,200)
        self.assertEqual(len(web_push.decode_key(first.json()['public_key'])),65)
        self.assertEqual(os.stat(web_push.key_path()).st_mode&0o777,0o600)
        self.assertEqual(self.client.get('/api/webpush/config').json(),first.json())
        saved=self.client.post('/api/webpush/subscriptions',json=subscription())
        self.assertEqual(saved.status_code,200,saved.text)
        id=saved.json()['id']
        self.assertTrue(self.client.get('/api/webpush/subscription?id='+id).json()['active'])
        self.assertEqual(self.client.request('DELETE','/api/webpush/subscriptions',json={'id':id}).status_code,200)
        self.assertFalse(self.client.get('/api/webpush/subscription?id='+id).json()['active'])
        self.client.cookies.clear()
        self.assertEqual(self.client.get('/api/webpush/config').status_code,401)
        self.assertEqual(self.client.post('/api/webpush/subscriptions',json=subscription()).status_code,401)

    def test_private_or_untrusted_endpoints_and_bad_crypto_keys_are_rejected(self):
        for endpoint in ('http://web.push.apple.com/abcd','https://127.0.0.1/abcd','https://web.push.apple.com.evil.test/abcd','https://user@web.push.apple.com/abcd','https://web.push.apple.com:8443/abcd'):
            self.assertEqual(self.client.post('/api/webpush/subscriptions',json=subscription(endpoint)).status_code,422)
        bad=subscription();bad['keys']['auth']='!'*22
        self.assertEqual(self.client.post('/api/webpush/subscriptions',json=bad).status_code,422)

    def test_no_push_before_data_or_when_partial_then_one_notification_after_sync(self):
        with self.set_clock(),patch.object(web_push,'webpush') as send:
            doc=self.document();self.save(doc);self.enable()
            self.assertEqual(web_push.deliver_ready(),0)
            self.heart.return_value=[fixtures.raw(fixtures.START)]
            self.collect();self.assertEqual(web_push.deliver_ready(),0)
            self.clock_mock.return_value=fixtures.NOW+timedelta(seconds=61)
            self.heart.return_value=fixtures.covered();self.collect()
            self.assertEqual(web_push.deliver_ready(),1)
            self.assertEqual(web_push.deliver_ready(),0)
            send.assert_called_once()
            message=json.loads(send.call_args.kwargs['data'])
            self.assertEqual(message['session_id'],doc['id'])
            self.assertNotIn('bpm',message['body'])
            self.assertEqual(self.rows()[0]['state'],'sent')

    def test_observation_saved_once_and_sent_once_even_when_data_is_unchanged(self):
        date = "2026-11-09"
        context = {"period": {"start": date, "end": date}}
        report = {"status": "unchanged", "summary": "睡眠时长接近平时。", "findings": [], "limitations": ""}
        with self.set_clock(), patch.object(web_push, "webpush") as send, patch.object(
            openai_service, "_call_openai", return_value=json.dumps(report),
        ) as model, patch("app.notifications.notify_analysis") as fallback:
            self.enable()
            for _ in range(2):
                observations._save_report("morning", date, observations.MORNING_TITLE, context)
            self.assertEqual(web_push.deliver_observations(), 1)
            self.assertEqual(web_push.deliver_observations(), 0)
        model.assert_called_once()
        fallback.assert_not_called()
        send.assert_called_once()
        message = json.loads(send.call_args.kwargs["data"])
        self.assertEqual(message["kind"], "observation")
        self.assertEqual(message["slot"], "morning")
        self.assertEqual(set(message), {"kind", "slot", "date", "id"})

    def test_enabling_after_latest_report_is_ready_sends_latest_only(self):
        with self.set_clock(),patch.object(web_push,'webpush') as send:
            old=self.document(started_at=phys.iso(fixtures.START-timedelta(hours=2)),ended_at=phys.iso(fixtures.END-timedelta(hours=2)))
            self.save(old);self.collect()
            latest=self.document();self.save(latest);self.collect();self.enable()
            self.assertEqual(web_push.deliver_ready(),1)
            self.assertEqual(self.rows()[0]['session_id'],latest['id'])
            self.assertEqual(send.call_count,1)

    def test_delivery_failure_retries_without_refetching_google_data(self):
        with self.set_clock() as clock:
            doc=self.document();self.save(doc);self.collect();self.enable()
            with patch.object(web_push,'_send',return_value=('retry',None)):
                self.assertEqual(web_push.deliver_ready(),0)
            self.assertEqual(self.rows()[0]['state'],'retry')
            self.assertEqual(web_push.deliver_ready(limit=0),0)
            with patch.object(web_push,'_send',return_value=('sent',None)) as send:
                self.assertEqual(web_push.deliver_ready(),0)
                clock.return_value=fixtures.NOW+timedelta(seconds=61)
                self.assertEqual(web_push.deliver_ready(),1)
                send.assert_called_once()
            self.assertEqual(self.rows()[0]['attempts'],2)

    def test_expired_endpoint_is_removed_and_deleting_workout_cancels_pending_push(self):
        with self.set_clock(),patch.object(web_push,'_send',return_value=('gone',None)):
            doc=self.document();self.save(doc);self.collect();saved=self.enable()
            web_push.deliver_ready()
            self.assertFalse(web_push.subscription_status(saved['id'])['active'])
            self.assertEqual(self.rows(),[])
            self.enable()
            self.client.delete(f"/api/strength/sessions/{doc['id']}?expected_version=1")
            self.assertEqual(self.rows(),[])
            with patch.object(web_push,'_send') as send:
                self.assertEqual(web_push.deliver_ready(),0)
                send.assert_not_called()

    def test_lease_prevents_duplicate_workers_and_can_be_reclaimed_after_crash(self):
        with self.set_clock() as clock:
            self.save(self.document());self.collect();self.enable()
            first=web_push._claim();self.assertIsNotNone(first)
            self.assertIsNone(web_push._claim())
            clock.return_value=fixtures.NOW+timedelta(minutes=3)
            self.assertNotEqual(web_push._claim()['lease_token'],first['lease_token'])

    def test_real_encryption_and_vapid_signing_without_contacting_a_push_provider(self):
        with self.set_clock():
            self.save(self.document());self.collect();self.enable()
            response=Mock(status_code=201,text='',headers={})
            with patch('pywebpush.requests.post',return_value=response) as network:
                self.assertEqual(web_push.deliver_ready(),1)
            self.assertEqual(network.call_count,1)
            self.assertEqual(network.call_args.kwargs['headers']['content-encoding'],'aes128gcm')
            encrypted=network.call_args.kwargs['data']
            self.assertIsInstance(encrypted,bytes)
            self.assertNotIn(b'session_id',encrypted)
            self.assertTrue(network.call_args.kwargs['headers']['authorization'].startswith('vapid '))
