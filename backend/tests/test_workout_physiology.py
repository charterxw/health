import asyncio
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch
from uuid import uuid4

import httpx
import jwt
from fastapi.testclient import TestClient

from app import database, google_health, strength_training as strength, workout_physiology as phys
from app.main import app

NOW = datetime(2026, 11, 1, 0, 10, 10, tzinfo=timezone.utc)
END = NOW - timedelta(seconds=10)
START = END - timedelta(minutes=10)


def raw(at, bpm=100, device='Air'):
    return {'heartRate': {'sampleTime': {'physicalTime': phys.iso(at)}, 'beatsPerMinute': str(bpm)},
            'dataSource': {'platform': 'FITBIT', 'recordingMethod': 'AUTOMATIC', 'device': {'displayName': device}}}


def covered(device='Air'):
    return [raw(START + timedelta(seconds=i), 100 + (i % 20), device) for i in range(0, 610, 10)]


class WorkoutPhysiologyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_path = database.DB_PATH
        database.DB_PATH = os.path.join(self.tmp.name, 'test.db')
        database.init_db()
        self.env = patch.dict(os.environ, {'JWT_SECRET': 'physiology-test-secret'})
        self.env.start()
        self.clock = patch.object(phys, 'now_utc', return_value=NOW)
        self.clock_mock = self.clock.start()
        self.auth = patch.object(google_health, 'is_authenticated', return_value=True)
        self.auth.start()
        self.hr = patch.object(google_health, 'get_heart_rate_window', new_callable=AsyncMock)
        self.heart = self.hr.start()
        self.heart.return_value = covered()
        self.activity_patch = patch.object(google_health, 'get_activity_window', new_callable=AsyncMock)
        self.activity = self.activity_patch.start()
        async def metrics(kind, *_):
            return [{'steps': {'countSum': '0'}}] if kind == 'steps' else [{'activeEnergyBurned': {'kcalSum': 17.5}}]
        self.activity.side_effect = metrics
        # No lifespan: tests must never start production jobs or use real APIs.
        self.client = TestClient(app)
        self.client.cookies.set('dashboard_session', jwt.encode({'sub': 'test', 'exp': datetime.now(timezone.utc) + timedelta(hours=1)}, 'physiology-test-secret', algorithm='HS256'))

    def tearDown(self):
        self.client.close()
        self.activity_patch.stop()
        self.hr.stop()
        self.auth.stop()
        self.clock.stop()
        self.env.stop()
        database.DB_PATH = self.old_path
        self.tmp.cleanup()

    def document(self, **changes):
        doc = {'id': str(uuid4()), 'title': '背部', 'started_at': phys.iso(START), 'ended_at': phys.iso(END),
               'status': 'completed', 'timezone': 'America/New_York', 'paused_seconds': 60, 'exercises': []}
        doc.update(changes)
        return doc

    def save(self, doc, version=0):
        return strength.save_session(strength.SaveSession(session=doc, expected_version=version))

    def collect(self):
        return asyncio.run(phys.process_due_jobs(limit=1))

    def job(self, doc):
        return phys._load(doc['id'])[1]

    def test_completion_and_job_commit_together_without_any_network_on_save(self):
        doc = self.document(status='active', ended_at=None)
        saved = self.save(doc)
        self.assertIsNone(self.job(doc))
        doc = saved['session']
        doc.update(status='completed', ended_at=phys.iso(END))
        saved = self.save(doc, 1)
        self.assertEqual(self.job(doc)['status'], 'queued')
        self.assertEqual(phys.get_report(doc['id'])['status'], 'pending')
        self.assertEqual(self.save(doc, 1)['version'], 2)
        self.heart.assert_not_called()
        self.activity.assert_not_called()

    def test_delayed_sync_fills_report_after_restart_without_changing_workout(self):
        doc = self.document()
        original = self.save(doc)
        self.heart.return_value = []
        self.assertEqual(self.collect(), 1)
        report = phys.get_report(doc['id'])
        self.assertEqual(report['status'], 'waiting_sync')
        self.assertIsNone(report['heart_rate']['summary']['mean_bpm'])
        self.assertEqual(report['metrics']['steps']['value'], 0)
        self.assertEqual(report['metrics']['active_energy']['value'], 17.5)
        database.init_db()  # Durable queue, not an in-memory task.
        phys.seed_recent_jobs()
        self.clock_mock.return_value = NOW + timedelta(seconds=61)
        self.heart.return_value = covered()
        self.assertEqual(self.collect(), 1)
        report = phys.get_report(doc['id'])
        self.assertEqual(report['status'], 'ready')
        self.assertEqual(report['heart_rate']['summary']['sample_count'], 60)
        self.assertEqual(report['heart_rate']['summary']['minute_coverage_percent'], 100)
        self.assertEqual(len(report['heart_rate']['chart']), 10)
        self.assertEqual(strength.get_session(doc['id']), original)
        self.assertEqual(self.heart.await_args.kwargs['data_source_family'], phys.WEARABLES)
        self.assertEqual(phys.instant(self.job(doc)['next_attempt_at']) - self.clock_mock.return_value, timedelta(hours=6))

    def test_physical_window_boundaries_cross_midnight_and_pauses_are_included(self):
        doc = self.document(started_at=phys.iso(START - timedelta(minutes=1)))
        self.save(doc)
        start = phys.instant(doc['started_at'])
        self.heart.return_value = [raw(start - timedelta(seconds=1), 200), raw(start, 80), raw(END - timedelta(seconds=1), 120), raw(END, 250)]
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertEqual(report['heart_rate']['summary']['mean_bpm'], 100)
        self.assertEqual(report['heart_rate']['summary']['sample_count'], 2)
        self.assertEqual(report['heart_rate']['summary']['window_minutes'], 11)
        self.assertEqual(report['heart_rate']['latest_cloud_sample_at'], phys.iso(END))
        self.assertEqual(self.activity.await_args.args[1:], (start, END))
        self.assertEqual(report['status'], 'partial')
        self.assertIsNone(report['heart_rate']['chart'][2]['mean_bpm'])

    def test_multiple_sources_require_selection_and_are_never_averaged_together(self):
        doc = self.document()
        self.save(doc)
        self.heart.return_value = covered() + [raw(START, 200, 'Watch')]
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertEqual(report['status'], 'needs_source')
        self.assertEqual(report['heart_rate']['summary']['sample_count'], 0)
        source = next(s for s in report['heart_rate']['sources'] if s['label'] == 'Watch')
        selected = phys.select_source(doc['id'], source['id'])
        self.assertEqual(selected['heart_rate']['summary']['mean_bpm'], 200)
        self.assertEqual(selected['heart_rate']['summary']['sample_count'], 1)
        self.assertEqual(self.job(doc)['preferred_source_id'], source['id'])
        with self.assertRaises(ValueError):
            phys.select_source(doc['id'], 'invented-source')

    def test_cache_is_preserved_on_failure_and_rate_limits_back_off(self):
        doc = self.document()
        self.save(doc)
        self.collect()
        before = phys.get_report(doc['id'])['heart_rate']
        self.clock_mock.return_value = NOW + timedelta(minutes=1)
        phys.request_refresh(doc['id'])
        request = httpx.Request('GET', 'https://health.googleapis.com/v4/test')
        self.heart.side_effect = httpx.HTTPStatusError('limited', request=request, response=httpx.Response(429, request=request))
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertEqual(report['heart_rate'], before)
        self.assertEqual(report['errors']['heart_rate'], 'rate_limited')
        self.assertEqual(phys.instant(report['next_attempt_at']) - self.clock_mock.return_value, timedelta(minutes=30))

    def test_lease_prevents_overlapping_workers_and_expires_after_crash(self):
        doc = self.document()
        self.save(doc)
        first = phys._claim_one(NOW)
        self.assertIsNone(phys._claim_one(NOW))
        second = phys._claim_one(NOW + timedelta(minutes=11))
        self.assertNotEqual(first['lease_token'], second['lease_token'])
        self.assertEqual(second['attempts'], 2)

    def test_late_inflight_response_cannot_attach_to_a_changed_window_or_discard(self):
        for discard in (False, True):
            doc = self.document()
            saved = self.save(doc)
            async def change_during_fetch(*args, **kwargs):
                changed = dict(saved['session'])
                changed.update(ended_at=phys.iso(END - timedelta(seconds=1)), **({'status': 'discarded'} if discard else {}))
                self.save(changed, 1)
                return covered()
            self.heart.side_effect = change_during_fetch
            self.assertEqual(self.collect(), 0)
            job = self.job(doc)
            self.assertIsNone(job['payload_json'])
            self.assertEqual(job['status'], 'inactive' if discard else 'queued')
            # Remove this fixture from subsequent claims.
            with database.get_db() as conn:
                conn.execute('UPDATE strength_physiology SET next_attempt_at=NULL WHERE session_id=?', (doc['id'],))
                conn.commit()

    def test_notes_and_idempotent_retry_do_not_reset_cached_data(self):
        doc = self.document()
        saved = self.save(doc)
        self.collect()
        job = self.job(doc)
        self.assertEqual(self.save(saved['session'], 0)['version'], 1)
        doc = saved['session']; doc['notes'] = 'good session'
        self.save(doc, 1)
        self.assertEqual(self.job(doc), job)

    def test_zero_length_or_oversized_workout_is_saved_without_an_invalid_api_call(self):
        for started in (END, END - timedelta(hours=25)):
            doc = self.document(started_at=phys.iso(started), paused_seconds=0)
            self.save(doc)
            self.assertEqual(phys.get_report(doc['id'])['status'], 'unsupported')
            self.assertEqual(self.collect(), 0)
        self.heart.assert_not_called()

    def test_startup_backfills_recent_completed_only_and_preserves_documents(self):
        doc = self.document()
        before = self.save(doc)
        old = self.document(started_at=phys.iso(START - timedelta(days=8)), ended_at=phys.iso(END - timedelta(days=8)))
        self.save(old)
        active = self.document(status='active', ended_at=None)
        self.save(active)
        with database.get_db() as conn:
            conn.execute('DELETE FROM strength_physiology')
            conn.commit()
        self.assertEqual(phys.seed_recent_jobs(), 1)
        self.assertIsNotNone(self.job(doc))
        self.assertIsNone(self.job(old))
        self.assertIsNone(self.job(active))
        self.assertEqual(strength.get_session(doc['id']), before)

    def test_retries_expire_after_seven_days_but_manual_history_refresh_still_works(self):
        doc = self.document()
        self.save(doc)
        self.heart.return_value = []
        self.clock_mock.return_value = END + timedelta(days=7)
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertEqual(report['status'], 'unavailable')
        self.assertIsNone(report['next_attempt_at'])
        self.clock_mock.return_value += timedelta(seconds=31)
        phys.request_refresh(doc['id'])
        self.heart.return_value = covered()
        self.assertEqual(self.collect(), 1)
        self.assertEqual(phys.get_report(doc['id'])['status'], 'ready')
        self.assertIsNone(phys.get_report(doc['id'])['next_attempt_at'])

    def test_manual_refresh_cooldown_does_not_duplicate_a_running_or_recent_request(self):
        doc = self.document()
        self.save(doc)
        self.collect()
        next_at = self.job(doc)['next_attempt_at']
        phys.request_refresh(doc['id'])
        self.assertEqual(self.job(doc)['next_attempt_at'], next_at)
        self.clock_mock.return_value += timedelta(seconds=31)
        phys.request_refresh(doc['id'])
        self.assertEqual(self.job(doc)['next_attempt_at'], phys.iso(self.clock_mock.return_value))
        phys._claim_one(self.clock_mock.return_value)
        lease = self.job(doc)['lease_token']
        phys.request_refresh(doc['id'])
        self.assertEqual(self.job(doc)['lease_token'], lease)

    def test_missing_and_zero_metrics_stay_distinct_and_daily_context_is_local_day(self):
        doc = self.document()
        self.save(doc)
        database.cache_health_metrics({'date': '2026-10-31', 'sleep_hours': 7.2, 'hrv': 41, 'resting_hr': 0})
        async def missing(kind, *_):
            return [{'steps': {}}] if kind == 'steps' else [{'activeEnergyBurned': {'kcalSum': 0}}]
        self.activity.side_effect = missing
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertIsNone(report['metrics']['steps']['value'])
        self.assertEqual(report['metrics']['active_energy']['value'], 0)
        self.assertEqual(report['daily_context']['date'], '2026-10-31')
        self.assertEqual(report['daily_context']['sleep_hours'], 7.2)
        self.assertIsNone(report['daily_context']['resting_hr'])

    def test_duplicate_invalid_and_conflicting_samples_do_not_pollute_statistics(self):
        doc = self.document()
        self.save(doc)
        self.heart.return_value = [raw(START, 80), raw(START, 80), raw(START + timedelta(seconds=10), 90),
                                   raw(START + timedelta(seconds=10), 150), raw(START + timedelta(seconds=20), 999), {'heartRate': {}}]
        self.collect()
        heart = phys.get_report(doc['id'])['heart_rate']
        self.assertEqual(heart['summary']['sample_count'], 1)
        self.assertEqual(heart['summary']['mean_bpm'], 80)
        self.assertEqual(heart['conflicting_timestamps'], 1)
        self.assertEqual(heart['invalid_count'], 2)

    def test_fractional_samples_are_ordered_by_physical_time(self):
        doc = self.document()
        self.save(doc)
        self.heart.return_value = [raw(START + timedelta(seconds=.5), 100), raw(START, 80), raw(START + timedelta(seconds=1), 120)]
        self.collect()
        stats = phys.get_report(doc['id'])['heart_rate']['summary']
        self.assertEqual(stats['first_sample_at'], phys.iso(START))
        self.assertEqual(stats['median_interval_seconds'], .5)

    def test_activity_rate_limit_also_backs_off_and_keeps_heart_data(self):
        doc = self.document()
        self.save(doc)
        request = httpx.Request('POST', 'https://health.googleapis.com/v4/test')
        self.activity.side_effect = httpx.HTTPStatusError('limited', request=request, response=httpx.Response(429, request=request))
        self.collect()
        report = phys.get_report(doc['id'])
        self.assertEqual(report['status'], 'ready')
        self.assertEqual(report['errors']['steps'], 'rate_limited')
        self.assertEqual(phys.instant(report['next_attempt_at']) - NOW, timedelta(minutes=30))

    def test_authenticated_routes_validate_state_missing_ids_and_source(self):
        doc = self.document()
        self.save(doc)
        url = f"/api/strength/sessions/{doc['id']}/physiology"
        self.assertEqual(self.client.get(url).json()['status'], 'pending')
        self.assertEqual(self.client.post(url + '/refresh').status_code, 200)
        self.assertEqual(self.client.put(url + '/source', json={'source_id': 'bogus'}).status_code, 422)
        self.assertEqual(self.client.get(f'/api/strength/sessions/{uuid4()}/physiology').status_code, 404)
        active = self.document(status='active', ended_at=None)
        self.save(active)
        self.assertEqual(self.client.post(f"/api/strength/sessions/{active['id']}/physiology/refresh").status_code, 422)
        self.client.cookies.clear()
        self.assertEqual(self.client.get(url).status_code, 401)
        self.assertEqual(self.client.post(url + '/refresh').status_code, 401)
        self.assertEqual(self.client.put(url + '/source', json={'source_id': 'bogus'}).status_code, 401)
        self.heart.assert_not_called()


class WindowAPITests(unittest.IsolatedAsyncioTestCase):
    async def test_raw_heart_uses_physical_timestamps_and_wearable_filter(self):
        with patch.object(google_health, '_api_get', new_callable=AsyncMock, return_value={'dataPoints': []}) as fetch:
            await google_health.get_heart_rate_window(START, END, data_source_family=phys.WEARABLES)
            params = fetch.await_args.kwargs['params']
            self.assertEqual(params['dataSourceFamily'], phys.WEARABLES)
            self.assertIn('heart_rate.sample_time.physical_time >= "2026-11-01T00:00:00Z"', params['filter'])
            self.assertIn('< "2026-11-01T00:10:00Z"', params['filter'])
            self.assertTrue(fetch.await_args.kwargs['paginate'])

    async def test_activity_rollup_keeps_exact_range_instead_of_rounding_to_whole_minutes(self):
        with patch.object(google_health, '_api_post', new_callable=AsyncMock, return_value={'rollupDataPoints': []}) as fetch:
            end = START + timedelta(seconds=13)
            await google_health.get_activity_window('steps', START, end)
            body = fetch.await_args.args[1]
            self.assertEqual(body['range'], {'startTime': phys.iso(START), 'endTime': phys.iso(end)})
            self.assertEqual(body['windowSize'], '60s')
            self.assertEqual(body['dataSourceFamily'], phys.WEARABLES)
            with self.assertRaises(ValueError):
                await google_health.get_activity_window('hrv', START, END)
            with self.assertRaises(ValueError):
                await google_health.get_activity_window('steps', START.replace(tzinfo=None), END)

    async def test_simultaneous_requests_refresh_oauth_once_and_save_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'tokens.json')
            with patch.object(google_health, 'TOKEN_FILE', path), patch.object(google_health, '_tokens', {'access_token': 'expired-test', 'refresh_token': 'test-refresh', 'expires_at': 0}):
                google_health._save_tokens()
                async def refresh():
                    await asyncio.sleep(.01)
                    google_health._tokens.update(access_token='new-test', expires_at=datetime.now().timestamp() + 3600)
                    google_health._save_tokens()
                with patch.object(google_health, '_refresh_access_token', side_effect=refresh) as token:
                    values = await asyncio.gather(*(google_health._get_token() for _ in range(3)))
                self.assertEqual(values, ['new-test'] * 3)
                self.assertEqual(token.call_count, 1)
                with open(path) as file:
                    self.assertEqual(json.load(file)['access_token'], 'new-test')
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                self.assertEqual(os.listdir(tmp), ['tokens.json'])

    async def test_cancelling_a_refresh_waiter_cannot_leak_the_cross_loop_lock(self):
        with patch.object(google_health, '_load_tokens'), patch.object(google_health, '_tokens', {'access_token': 'expired-test', 'expires_at': 0}):
            google_health._refresh_lock.acquire()
            try:
                task = asyncio.create_task(google_health._get_token())
                await asyncio.sleep(.01)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            finally:
                google_health._refresh_lock.release()
            self.assertTrue(google_health._refresh_lock.acquire(blocking=False))
            google_health._refresh_lock.release()
