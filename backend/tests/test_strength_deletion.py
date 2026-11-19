import json
import unittest
from unittest.mock import patch

import test_strength_training as fixtures
from app import database, strength_training as strength, workout_physiology as phys, openai_service
from app.training_observations import generate_training_observation


class StrengthDeletionTests(unittest.TestCase):
    setUp = fixtures.StrengthTests.setUp
    tearDown = fixtures.StrengthTests.tearDown
    document = fixtures.StrengthTests.document
    save = fixtures.StrengthTests.save

    def delete(self, doc, version=1):
        return self.client.delete(f"/api/strength/sessions/{doc['id']}?expected_version={version}")

    def test_deletion_removes_workout_and_physiology_and_is_retry_safe(self):
        doc = self.document(completed=True)
        self.save(doc)
        lease = phys._claim_one(phys.now_utc())
        self.assertIsNotNone(lease)
        deleted = self.delete(doc)
        self.assertEqual(deleted.status_code, 200, deleted.text)
        self.assertEqual(deleted.json()['version'], 2)
        self.assertEqual(self.delete(doc).json(), deleted.json())
        self.assertEqual(self.client.get('/api/strength/sessions').json(), [])
        self.assertEqual(self.client.get(f"/api/strength/sessions/{doc['id']}").status_code, 404)
        self.assertEqual(self.client.get(f"/api/strength/sessions/{doc['id']}/physiology").status_code, 404)
        self.assertEqual(strength.get_strength_workouts(), [])
        self.assertIsNone(phys._load(doc['id'])[1])
        # A collector response from before deletion cannot recreate its cache.
        with database.get_db() as conn:
            changed = conn.execute('UPDATE strength_physiology SET payload_json=? WHERE session_id=? AND lease_token=?', ('{}', doc['id'], lease['lease_token'])).rowcount
        self.assertEqual(changed, 0)
        database.init_db(); phys.seed_recent_jobs()
        self.assertEqual(self.client.get('/api/strength/session-deletions').json(), [deleted.json()])

    def test_old_or_new_versions_cannot_resurrect_a_deleted_id(self):
        doc = self.document(completed=True)
        self.save(doc); self.delete(doc)
        for version in (0, 1, 2, 99):
            response = self.save(doc, version)
            self.assertEqual(response.status_code, 410)
            self.assertEqual(response.json()['detail']['deleted']['id'], doc['id'])
        self.assertEqual(self.client.get('/api/strength/sessions').json(), [])

    def test_stale_delete_is_rejected_and_active_workout_is_preserved(self):
        doc = self.document(completed=True)
        self.save(doc)
        doc['notes'] = 'newer edit'; self.save(doc, 1)
        self.assertEqual(self.delete(doc).status_code, 409)
        self.assertEqual(self.client.get(f"/api/strength/sessions/{doc['id']}").json()['version'], 2)
        active = self.document()
        self.save(active)
        self.assertEqual(self.delete(active).status_code, 422)
        self.assertEqual(len(self.client.get('/api/strength/sessions').json()), 2)
        self.assertEqual(self.client.get('/api/strength/session-deletions').json(), [])

    def test_only_analyses_that_reference_deleted_evidence_are_invalidated(self):
        doc = self.document(completed=True)
        self.save(doc)
        with database.get_db() as conn:
            for table, column in [('training_analysis', 'summary'), ('ai_insights', 'content')]:
                if table == 'ai_insights':
                    conn.execute('INSERT INTO ai_insights (date,time_slot,title,content,input_json) VALUES (?,?,?,?,?)', ('2026-11-08','weekly','test','related', json.dumps({'localid': 'strength:' + doc['id']})))
                    conn.execute('INSERT INTO ai_insights (date,time_slot,title,content,input_json) VALUES (?,?,?,?,?)', ('2026-11-07','morning','sleep','unrelated','{}'))
                else:
                    conn.execute('INSERT INTO training_analysis (date,summary,input_json) VALUES (?,?,?)', ('2026-11-08','related', json.dumps({'session_id': 'strength:' + doc['id']})))
                    conn.execute('INSERT INTO training_analysis (date,summary,input_json) VALUES (?,?,?)', ('2026-11-07','unrelated','{}'))
            conn.commit()
        self.delete(doc)
        with database.get_db() as conn:
            self.assertEqual([r[0] for r in conn.execute('SELECT summary FROM training_analysis')], ['unrelated'])
            self.assertEqual([r[0] for r in conn.execute('SELECT content FROM ai_insights')], ['unrelated'])

    def test_late_generated_insight_cannot_save_deleted_evidence(self):
        doc = self.document(completed=True)
        self.save(doc); self.delete(doc)
        with self.assertRaises(openai_service.AIServiceError) as caught:
            openai_service._upsert_insight('2026-11-08','weekly','test','old result','observation',input_json=json.dumps({'session_id':'strength:'+doc['id']}))
        self.assertEqual(caught.exception.code, 'training_data_changed')
        with database.get_db() as conn:
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM ai_insights').fetchone()[0], 0)

    def test_late_training_analysis_cannot_save_after_its_evidence_is_deleted(self):
        doc = self.document(completed=True); self.save(doc)
        result = {'status': 'finding', 'summary': '', 'findings': [{'headline': '记录变化', 'body': '实验数据', 'evidence': ['本次记录'], 'confidence': 'medium'}], 'limitations': ''}
        def late_model(*args, **kwargs):
            self.delete(doc)
            return json.dumps(result)
        with patch.object(openai_service, '_require_ai_configured'), patch.object(openai_service, '_get_recent_metrics', return_value=[]), patch.object(openai_service, '_call_openai', side_effect=late_model), patch('app.workout_data.xunji_service.get_all_cached_workouts', return_value=[]):
            with self.assertRaises(openai_service.AIServiceError) as caught:
                generate_training_observation(notify=False)
        self.assertEqual(caught.exception.code, 'training_data_changed')
        with database.get_db() as conn:
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM training_analysis').fetchone()[0], 0)

    def test_delete_and_deletion_feed_require_login_and_validate_version(self):
        doc = self.document(completed=True); self.save(doc)
        self.assertEqual(self.client.delete(f"/api/strength/sessions/{doc['id']}").status_code, 422)
        self.client.cookies.clear()
        self.assertEqual(self.delete(doc).status_code, 401)
        self.assertEqual(self.client.get('/api/strength/session-deletions').status_code, 401)

    def test_post_delete_action_uses_same_version_check_and_idempotent_result(self):
        doc = self.document(completed=True); self.save(doc)
        url=f"/api/strength/sessions/{doc['id']}/delete"
        self.assertEqual(self.client.post(url,json={'expected_version':2}).status_code,409)
        deleted=self.client.post(url,json={'expected_version':1})
        self.assertEqual(deleted.status_code,200)
        self.assertEqual(self.client.post(url,json={'expected_version':1}).json(),deleted.json())
        self.assertEqual(self.client.get('/api/strength/sessions').json(),[])
        self.client.cookies.clear()
        self.assertEqual(self.client.post(url,json={'expected_version':1}).status_code,401)
