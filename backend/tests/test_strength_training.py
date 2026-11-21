import copy
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
from uuid import uuid4

from fastapi.testclient import TestClient

from app import database, security, strength_training as strength, workout_data
from app.main import app
from app.training_observations import normalized_workouts


class StrengthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_path = database.DB_PATH
        database.DB_PATH = os.path.join(self.tmp.name, 'test.db')
        database.init_db()
        self.env = patch.dict(os.environ, {'JWT_SECRET': 'strength-test-secret-with-32-plus-chars',
                                           'DASHBOARD_USER': 'test', 'DASHBOARD_PASS': 'test-password'})
        self.env.start()
        # Do not run the production lifespan, scheduler or external integrations.
        self.client = TestClient(app)
        # The app uses revocable server-side sessions; issue one for the test account.
        security.init_security()
        token, _ = security.issue_session('test')
        self.client.cookies.set('dashboard_session', token)

    def tearDown(self):
        self.client.close()
        self.env.stop()
        database.DB_PATH = self.old_path
        self.tmp.cleanup()

    def document(self, completed=False):
        now = datetime.now(timezone.utc)
        return {
            'id': str(uuid4()), 'title': '背·三角肌后束·二头',
            'started_at': (now - timedelta(minutes=10)).isoformat(),
            'ended_at': now.isoformat() if completed else None,
            'status': 'completed' if completed else 'active', 'timezone': 'America/New_York',
            'exercises': [{'id': str(uuid4()), 'exercise_id': 'wide-grip-pulldown',
                           'name': '宽距高位下拉', 'unit': 'lb', 'sets': [
                               {'id': str(uuid4()), 'weight': 100, 'reps': 8,
                                'completed_at': (now - timedelta(minutes=2)).isoformat() if completed else None},
                               {'id': str(uuid4()), 'weight': None, 'reps': None},
                           ]}],
        }

    def save(self, doc, version=0):
        return self.client.put('/api/strength/sessions/' + doc['id'], json={'session': doc, 'expected_version': version})

    def test_seed_matches_both_screenshots_and_survives_restart(self):
        data = self.client.get('/api/strength/catalog').json()
        self.assertEqual(len(data['exercises']), 24)
        exercises = {entry['id']: entry for entry in data['exercises']}
        self.assertIn('prone-leg-curl', exercises)
        self.assertNotIn('seated-leg-curl', exercises)
        self.assertNotIn('leg-press', exercises)
        self.assertTrue(all(entry['instructions'] and entry['primary_muscles'] for entry in exercises.values()))
        first, second = data['templates'][:2]
        self.assertEqual(first['template']['name'], '背·三角肌后束·二头')
        self.assertEqual([m['set_count'] for m in first['template']['exercises']], [3, 4, 4, 1, 3])
        self.assertEqual([m['set_count'] for m in second['template']['exercises']], [4, 4, 2, 4, 2])
        self.assertEqual(sum(m['set_count'] for m in first['template']['exercises']), 15)
        self.assertEqual(sum(m['set_count'] for m in second['template']['exercises']), 16)
        first['template']['exercises'][0]['set_count'] = 5
        saved = self.client.put('/api/strength/templates/' + first['template']['id'], json={'template': first['template'], 'expected_version': 1})
        self.assertEqual(saved.status_code, 200)
        database.init_db()
        current = self.client.get('/api/strength/catalog').json()['templates'][0]
        self.assertEqual(current['template']['exercises'][0]['set_count'], 5)
        self.assertEqual(current['version'], 2)

    def test_setup_note_is_saved_listed_trimmed_and_cleared(self):
        self.assertEqual(self.client.get('/api/strength/catalog').json()['setup_notes'], {})
        saved = self.client.put('/api/strength/exercises/wide-grip-pulldown/setup-note', json={'note': '  座椅第 4 档  '})
        self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(saved.json()['note'], '座椅第 4 档')
        self.assertEqual(self.client.get('/api/strength/catalog').json()['setup_notes'], {'wide-grip-pulldown': '座椅第 4 档'})
        database.init_db()
        self.assertEqual(self.client.get('/api/strength/catalog').json()['setup_notes'], {'wide-grip-pulldown': '座椅第 4 档'})
        self.assertEqual(self.client.put('/api/strength/exercises/wide-grip-pulldown/setup-note', json={'note': ''}).status_code, 200)
        self.assertEqual(self.client.get('/api/strength/catalog').json()['setup_notes'], {})
        self.assertEqual(self.client.put('/api/strength/exercises/not-an-exercise/setup-note', json={'note': 'x'}).status_code, 404)
        self.assertEqual(self.client.put('/api/strength/exercises/wide-grip-pulldown/setup-note', json={'note': 'x' * 201}).status_code, 422)
        self.assertEqual(self.client.put('/api/strength/exercises/wide-grip-pulldown/setup-note', json={'note': 'x', 'extra': 1}).status_code, 422)

    def test_session_retry_is_idempotent_and_stale_edit_is_rejected(self):
        doc = self.document()
        saved = self.save(doc)
        self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(saved.json()['version'], 1)
        self.assertEqual(self.save(doc).json()['version'], 1)
        doc['notes'] = 'another edit'
        self.assertEqual(self.save(doc).status_code, 409)
        reloaded = self.client.get('/api/strength/sessions/' + doc['id']).json()
        self.assertEqual(reloaded['session']['notes'], '')
        self.assertEqual(self.save(doc, 1).json()['version'], 2)

    def test_legacy_exercise_metadata_is_enriched_without_rewriting_saved_names(self):
        legacy = {'id': 'barbell-bench-press', 'name': '我的卧推', 'muscles': ['胸部'], 'equipment': '杠铃', 'load_mode': 'external'}
        with database.get_db() as conn:
            conn.execute('UPDATE strength_exercises SET document_json=? WHERE id=?', (strength.encode(legacy), legacy['id']))
            conn.commit()
        database.init_db()
        exercise = next(e for e in strength.catalog()['exercises'] if e['id'] == legacy['id'])
        self.assertEqual(exercise['name'], '我的卧推')
        self.assertTrue(exercise['instructions'])
        self.assertEqual(exercise['primary_muscles'], ['chest'])

    def test_catalogue_upgrade_preserves_saved_training_documents_and_versions(self):
        doc = self.document(completed=True)
        self.save(doc)
        legacy_ids = [entry.id for entry in strength.EXERCISES[:9]]
        with database.get_db() as conn:
            conn.execute('DELETE FROM strength_exercises WHERE id NOT IN (' + ','.join('?' for _ in legacy_ids) + ')', legacy_ids)
            conn.commit()
            before = tuple(conn.execute('SELECT document_json, version FROM strength_sessions WHERE id=?', (doc['id'],)).fetchone())
        database.init_db()
        with database.get_db() as conn:
            after = tuple(conn.execute('SELECT document_json, version FROM strength_sessions WHERE id=?', (doc['id'],)).fetchone())
            self.assertEqual(conn.execute('SELECT COUNT(*) FROM strength_exercises').fetchone()[0], 24)
        self.assertEqual(before, after)

    def test_progression_configuration_and_session_target_survive_round_trip(self):
        template = self.client.get('/api/strength/catalog').json()['templates'][0]
        template['template']['exercises'][0].update(progression='double', rep_min=8, rep_max=12, increment=5)
        response = self.client.put('/api/strength/templates/' + template['template']['id'], json={'template': template['template'], 'expected_version': 1})
        self.assertEqual(response.status_code, 200)
        doc = self.document()
        movement = doc['exercises'][0]
        movement.update(primary_muscles=['upper-back'], secondary_muscles=['biceps'], prescription={
            'policy': 'double', 'rep_min': 8, 'rep_max': 12, 'increment': 5, 'work_sets': 2,
            'weight': 105, 'reps': 8, 'action': 'increase', 'reason': '全部工作组达标，建议增加 5 磅。',
            'basis_date': '2026-11-01',
        })
        saved = self.save(doc)
        self.assertEqual(saved.status_code, 200, saved.text)
        reloaded = self.client.get('/api/strength/sessions/' + doc['id']).json()['session']['exercises'][0]
        self.assertEqual(reloaded['prescription'], movement['prescription'])
        self.assertEqual(reloaded['primary_muscles'], ['upper-back'])
        template['template']['exercises'][0]['rep_max'] = 6
        response = self.client.put('/api/strength/templates/' + template['template']['id'], json={'template': template['template'], 'expected_version': 2})
        self.assertEqual(response.status_code, 422)
        doc['exercises'][0]['prescription']['weight'] = float('inf')
        with self.assertRaises(ValueError):
            strength.Session.model_validate(doc)

    def test_completion_is_persisted_and_only_checked_sets_reach_analysis(self):
        doc = self.document(completed=True)
        doc['paused_seconds'] = 60
        self.assertEqual(self.save(doc).status_code, 200)
        database.init_db()
        reloaded = self.client.get('/api/strength/sessions').json()[0]['session']
        self.assertEqual(reloaded['id'], doc['id'])
        self.assertNotIn('started_at', reloaded['exercises'][0]['sets'][0])
        workouts = strength.get_strength_workouts()
        self.assertEqual(workouts[0]['duration_minutes'], 9)
        self.assertEqual(len(workouts[0]['movements'][0]['sets']), 1)
        normalized = normalized_workouts(workouts)[0]
        self.assertEqual(normalized['movements'][0]['sets'][0]['weight'], 100)
        self.assertTrue(normalized['session_id'].startswith('strength:'))

    def test_assistance_stays_separate_from_external_load(self):
        doc = self.document(completed=True)
        movement = doc['exercises'][0]
        movement.update(exercise_id='assisted-dip', name='双杠臂屈伸（辅助）', load_mode='assistance')
        self.assertEqual(self.save(doc).status_code, 200)
        movement = normalized_workouts(strength.get_strength_workouts())[0]['movements'][0]
        self.assertEqual(movement['sets'][0]['mode'], 'assistance')
        self.assertEqual(movement['recorded_peaks'], [])

    def test_empty_or_invalid_completed_set_cannot_be_saved(self):
        doc = self.document(completed=True)
        doc['exercises'][0]['sets'][0]['reps'] = None
        self.assertEqual(self.save(doc).status_code, 422)
        self.assertEqual(self.client.get('/api/strength/sessions').json(), [])
        doc['exercises'][0]['sets'][0]['reps'] = 8
        doc['exercises'][0]['sets'][1]['id'] = doc['exercises'][0]['sets'][0]['id']
        self.assertEqual(self.save(doc).status_code, 422)

    def test_only_one_active_session_and_next_can_start_after_finish(self):
        first, second = self.document(), self.document()
        response = self.save(first)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.save(second).status_code, 409)
        first = response.json()['session']
        first.update(status='completed', ended_at=datetime.now(timezone.utc).isoformat())
        self.assertEqual(self.save(first, 1).status_code, 200)
        self.assertEqual(self.save(second).status_code, 200)

    def test_template_changes_do_not_rewrite_existing_session(self):
        doc = self.document()
        self.save(doc)
        template = self.client.get('/api/strength/catalog').json()['templates'][0]
        template['template']['name'] = '改名后的模板'
        self.client.put('/api/strength/templates/' + template['template']['id'], json={'expected_version': template['version'], 'template': template['template']})
        self.assertEqual(self.client.get('/api/strength/sessions/' + doc['id']).json()['session']['title'], doc['title'])

    def test_discard_hides_session_but_keeps_a_recoverable_server_copy(self):
        doc = self.document()
        saved = self.save(doc).json()
        doc = saved['session']
        doc.update(status='discarded', ended_at=datetime.now(timezone.utc).isoformat())
        self.assertEqual(self.save(doc, 1).status_code, 200)
        self.assertEqual(self.client.get('/api/strength/sessions').json(), [])
        self.assertEqual(self.client.get('/api/strength/sessions/' + doc['id']).status_code, 200)

    def test_local_day_is_not_cut_off_at_utc_midnight(self):
        class Frozen(datetime):
            @classmethod
            def now(cls, tz=None):
                value = cls(2026, 11, 7, 12, tzinfo=timezone.utc)
                return value.astimezone(tz) if tz else value.replace(tzinfo=None)
        doc = self.document(completed=True)
        doc.update(started_at='2026-11-06T23:30:00Z', ended_at='2026-11-06T23:50:00Z', timezone='Pacific/Kiritimati')
        doc['exercises'][0]['sets'][0]['completed_at'] = '2026-11-06T23:40:00Z'
        with patch.object(strength, 'datetime', Frozen):
            strength.save_session(strength.SaveSession(expected_version=0, session=doc))
            self.assertEqual(strength.get_strength_workouts(1)[0]['datestr'], '2026-11-07')

    def test_custom_exercise_and_template_reference_are_validated(self):
        exercise = {'id': str(uuid4()), 'name': '自重深蹲', 'load_mode': 'bodyweight'}
        self.assertEqual(self.client.post('/api/strength/exercises', json=exercise).status_code, 200)
        template = {'id': str(uuid4()), 'name': '自定义', 'exercises': [{'exercise_id': exercise['id'], 'set_count': 2}]}
        self.assertEqual(self.client.put('/api/strength/templates/' + template['id'], json={'template': template, 'expected_version': 0}).status_code, 200)
        template['exercises'][0]['exercise_id'] = 'unknown'
        self.assertEqual(self.client.put('/api/strength/templates/' + template['id'], json={'template': template, 'expected_version': 1}).status_code, 422)

    def test_multiple_workouts_on_same_day_retain_distinct_ids(self):
        doc = self.document(completed=True)
        self.save(doc)
        imported = {'datestr': datetime.now().date().isoformat(), 'localid': doc['id'], 'movements': []}
        with patch.object(workout_data.xunji_service, 'get_all_cached_workouts', return_value=[imported]):
            records = workout_data.get_training_workouts()
        self.assertEqual(len(records), 2)
        self.assertEqual(len({r['localid'] for r in records}), 2)

    def test_new_routes_require_existing_dashboard_login(self):
        self.client.cookies.clear()
        self.assertEqual(self.client.get('/api/strength/catalog').status_code, 401)
        self.assertEqual(self.save(self.document()).status_code, 401)

    def test_guided_templates_seed_once_and_keep_old_templates_untouched(self):
        with database.get_db() as conn:
            conn.execute("DELETE FROM strength_templates WHERE id LIKE 'guided-%'")
            conn.commit()
            before = [tuple(r) for r in conn.execute('SELECT * FROM strength_templates')]
        database.init_db()
        database.init_db()
        with database.get_db() as conn:
            after = [tuple(r) for r in conn.execute("SELECT * FROM strength_templates WHERE id NOT LIKE 'guided-%'")]
        self.assertEqual(before, after)
        templates = strength.catalog()['templates']
        self.assertEqual(len(templates), 7)
        for record in templates[2:]:
            t = record['template']
            self.assertEqual(sum(m['set_count'] - m['warmup_count'] for m in t['exercises']), 12)
            self.assertEqual(sum(m['warmup_count'] for m in t['exercises']), 1)
            self.assertEqual((t['duration_min'], t['duration_max']), (30, 40))
        invalid = templates[2]['template']
        invalid['exercises'][0]['warmup_count'] = invalid['exercises'][0]['set_count']
        with self.assertRaises(ValueError):
            strength.Template.model_validate(invalid)

    def test_history_reads_all_local_and_cached_archive_without_mutating_records(self):
        doc = self.document(completed=True)
        self.assertEqual(self.save(doc).status_code, 200)
        active = self.document()
        self.assertEqual(self.save(active).status_code, 200)
        archive = {'datestr': '2020-01-01', 'localid': 'old', 'movements': [
            {'name': '宽距高位下拉', 'sets': [
                {'weight': 50, 'unit': 'kg', 'reps': 12, 'done': True},
                {'weight': 100, 'unit': 'lb', 'reps': 8, 'done': True},
                {'weight': 500, 'unit': 'kg', 'reps': 20, 'done': False},
            ]}]}
        with database.get_db() as conn:
            before = [tuple(r) for r in conn.execute('SELECT * FROM strength_sessions ORDER BY id')]
        with patch('app.exercise_history.xunji_service.get_all_cached_workouts', return_value=[archive, archive]) as cached:
            result = self.client.get('/api/strength/exercises/wide-grip-pulldown/history')
            cached.assert_called_once_with(days=None)
        self.assertEqual(result.status_code, 200)
        records = result.json()['records']
        self.assertEqual(len(records), 2)
        self.assertEqual({r['source'] for r in records}, {'local', 'archive'})
        imported = next(r for r in records if r['source'] == 'archive')
        self.assertEqual({m['unit'] for m in imported['session']['exercises']}, {'kg', 'lb'})
        self.assertEqual(sum(len(m['sets']) for m in imported['session']['exercises']), 2)
        with database.get_db() as conn:
            self.assertEqual(before, [tuple(r) for r in conn.execute('SELECT * FROM strength_sessions ORDER BY id')])
        self.assertEqual(self.client.get('/api/strength/exercises/unknown/history').status_code, 404)
        self.client.cookies.clear()
        self.assertEqual(self.client.get('/api/strength/exercises/wide-grip-pulldown/history').status_code, 401)

    def test_history_does_not_guess_ambiguous_archive_names(self):
        self.client.post('/api/strength/exercises', json={'id': 'custom-pulldown', 'name': '宽距高位下拉'})
        archive = {'datestr': '2020-01-01', 'movements': [{'name': '宽距高位下拉', 'sets': [{'weight': 100, 'unit': 'lb', 'reps': 8}]}]}
        with patch('app.exercise_history.xunji_service.get_all_cached_workouts', return_value=[archive]):
            result = self.client.get('/api/strength/exercises/wide-grip-pulldown/history').json()
        self.assertEqual(result['records'], [])


if __name__ == '__main__':
    unittest.main()
