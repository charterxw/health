import asyncio
from datetime import datetime, timezone, timedelta
import unittest
from unittest.mock import patch, AsyncMock
from urllib.parse import urlparse, parse_qs
import httpx
from app import data_freshness as f, google_health as gh


class FreshnessTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026,11,17,5,0,tzinfo=timezone.utc)
        self.tokens=patch.object(gh,'_tokens',{})
        self.tokens.start();self.addCleanup(self.tokens.stop)

    def point(self, key, end, value=0):
        return {key:{'interval':{'startTime':'2026-11-17T04:50:00Z','endTime':end},
                     'count' if key=='steps' else 'kcal':value}}

    def test_uses_observed_end_not_retrieval_or_rollup_end(self):
        points=[self.point('steps','2026-11-17T04:53:00Z',5),self.point('steps','2026-11-17T04:57:00Z',0),
                {'endTime':'2026-11-17T05:00:00Z','steps':{'countSum':1000}}]
        self.assertEqual(f.latest_observation(points,'steps',self.now),'2026-11-17T04:57:00+00:00')
        self.assertIsNone(f.latest_observation([{'steps':{'interval':{'startTime':'2026-11-17T04:50:00Z','endTime':'2026-11-17T04:59:00Z'}}}],'steps',self.now))

    def test_zero_energy_is_a_real_record_future_and_invalid_are_ignored(self):
        self.assertEqual(f.latest_observation([self.point('activeEnergyBurned','2026-11-17T04:57:00Z',0)],'activeEnergyBurned',self.now),'2026-11-17T04:57:00+00:00')
        self.assertIsNone(f.latest_observation([self.point('steps','2026-11-17T05:01:00Z',1),self.point('steps','bad',1)],'steps',self.now))

    def test_prefers_air_tracker_and_never_persists_device_identifiers(self):
        device=f.tracker_summary([
            {'deviceType':'SCALE','lastSyncTime':'2026-11-17T04:59:00Z','deviceVersion':'Scale'},
            {'deviceType':'TRACKER','lastSyncTime':'2026-11-17T04:40:00Z','deviceVersion':'Fitbit Air','macAddress':'private','name':'private-id'},
            {'deviceType':'TRACKER','lastSyncTime':'2026-11-17T04:58:00Z','deviceVersion':'Other watch'}],self.now)
        self.assertEqual(device['device_name'],'Fitbit Air')
        self.assertNotIn('private',str(device))

    def test_existing_permissions_still_return_record_times_when_device_scope_missing(self):
        async def api(url,params=None,**kwargs):
            if url.endswith('/pairedDevices'):
                response=httpx.Response(403,json={'error':{'details':[{'reason':'MISSING_OAUTH_SCOPE'}]}},request=httpx.Request('GET',url))
                raise httpx.HTTPStatusError('denied',request=response.request,response=response)
            key='steps' if '/steps/' in url else 'activeEnergyBurned'
            return {'dataPoints':[self.point(key,'2026-11-17T04:57:00Z')]}
        with patch.object(gh,'_api_get',api):result=asyncio.run(f.freshness_snapshot(self.now))
        self.assertEqual(result['device']['status'],'permission_required')
        self.assertEqual(result['records']['activity']['observed_at'],'2026-11-17T04:57:00+00:00')

    def test_transient_failure_preserves_record_time_and_original_read_time(self):
        previous={'records':{'steps':{'observed_at':'2026-11-17T04:40:00Z','fetched_at':'2026-11-17T04:45:00Z'}},
                  'device':{'status':'permission_required','checked_at':'2026-11-17T04:50:00Z'}}
        with patch.object(gh,'_api_get',AsyncMock(side_effect=RuntimeError('offline'))) as api:
            result=asyncio.run(f.freshness_snapshot(self.now,previous))
        self.assertEqual(api.call_count,2)
        self.assertEqual(result['records']['steps']['observed_at'],'2026-11-17T04:40:00Z')
        self.assertEqual(result['records']['steps']['fetched_at'],'2026-11-17T04:45:00Z')
        self.assertEqual(result['records']['steps']['status'],'stale')

    def test_device_readonly_scope_is_incremental_and_optional(self):
        plain=parse_qs(urlparse(gh.get_auth_url('state')).query)
        extra=parse_qs(urlparse(gh.get_auth_url('state',device_sync=True)).query)
        self.assertNotIn(gh.DEVICE_SETTINGS_SCOPE,plain['scope'][0].split())
        self.assertIn(gh.DEVICE_SETTINGS_SCOPE,extra['scope'][0].split())
        self.assertEqual(extra['include_granted_scopes'],['false'])
        self.assertEqual(plain['scope'][0],gh.SCOPES)

    def test_collection_reader_preserves_health_points_and_paginates_devices(self):
        class Client:
            async def __aenter__(self):return self
            async def __aexit__(self,*_):pass
            async def get(self,url,params,headers):
                if url.endswith('/pairedDevices'):
                    body={'pairedDevices':[{'deviceVersion':'second'}]} if params.get('pageToken') else {'pairedDevices':[{'deviceVersion':'first'}],'nextPageToken':'next'}
                else:body={'dataPoints':[{'value':1}]}
                return httpx.Response(200,json=body,request=httpx.Request('GET',url))
        async def read():
            points=await gh._api_get('https://example.test/dataPoints')
            devices=await gh._api_get('https://example.test/pairedDevices',{'pageSize':100},paginate=True,collection='pairedDevices')
            return points,devices
        with patch.object(gh,'_get_token',AsyncMock(return_value='test-token')),patch.object(gh.httpx,'AsyncClient',lambda **_:Client()):
            points,devices=asyncio.run(read())
        self.assertEqual(points,{'dataPoints':[{'value':1}]})
        self.assertEqual([d['deviceVersion'] for d in devices['pairedDevices']],['first','second'])

    def test_known_device_scope_is_preserved_without_merging_foreign_scopes(self):
        gh._tokens['scopes']=[gh.DEVICE_SETTINGS_SCOPE,'openid','https://www.googleapis.com/auth/userinfo.email']
        url=parse_qs(urlparse(gh.get_auth_url('state')).query)
        self.assertEqual(set(url['scope'][0].split()),set(gh.SCOPES.split())|{gh.DEVICE_SETTINGS_SCOPE})
        self.assertEqual(url['include_granted_scopes'],['false'])

    def test_foreign_token_response_is_rejected_before_credentials_change(self):
        gh._tokens.update(access_token='old',refresh_token='refresh')
        before=dict(gh._tokens)
        with patch.object(gh,'_save_tokens') as save:
            with self.assertRaises(ValueError):gh.install_token({'access_token':'new','scope':gh.SCOPES+' openid'})
            save.assert_not_called()
        self.assertEqual(gh._tokens,before)

    def test_refresh_requests_only_previously_granted_health_scopes(self):
        gh._tokens.update(refresh_token='refresh',scopes=list(gh.HEALTH_SCOPES)+['openid'])
        requests=[]
        class Client:
            async def __aenter__(self):return self
            async def __aexit__(self,*_):pass
            async def post(self,url,data):
                requests.append(data)
                return httpx.Response(200,json={'access_token':'new','expires_in':3600,'scope':data['scope']},request=httpx.Request('POST',url))
        with patch.object(gh.httpx,'AsyncClient',lambda **_:Client()),patch.object(gh,'_save_tokens'):
            asyncio.run(gh._refresh_access_token())
        self.assertEqual(set(requests[0]['scope'].split()),gh.HEALTH_SCOPES)
        self.assertEqual(set(gh._tokens['scopes']),gh.HEALTH_SCOPES)
        self.assertEqual(gh._tokens['refresh_token'],'refresh')

    def test_disallowed_scopes_are_not_mislabeled_as_missing_device_permission(self):
        async def api(url,params=None,**kwargs):
            if url.endswith('/pairedDevices'):
                response=httpx.Response(403,json={'error':{'details':[{'reason':'DISALLOWED_OAUTH_SCOPES'}]}},request=httpx.Request('GET',url))
                raise httpx.HTTPStatusError('denied',request=response.request,response=response)
            return {'dataPoints':[]}
        with patch.object(gh,'_api_get',api):result=asyncio.run(f.freshness_snapshot(self.now))
        self.assertEqual(result['device']['status'],'unavailable')


if __name__=='__main__':unittest.main()
