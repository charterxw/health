#!/usr/bin/env python3
"""Decision, safety, and mocked pipeline checks; no Apple account/device needed."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('renew', Path(__file__).with_name('auto-renew.py'))
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.base = self.root / 'private'
        renew.private_dir(self.base)
        self.base_patch = patch.object(renew, 'BASE', self.base)
        self.base_patch.start()
        self.now = datetime(2026, 11, 16, 12, tzinfo=timezone.utc)
        self.project = self.root / 'My Project/Health.xcodeproj'
        self.project.mkdir(parents=True)
        self.config = {'project': str(self.project), 'team_id': 'ABCDE12345',
                       'device_udid': '00008110-0011223344556677', 'bundle_id': 'com.example.health'}

    def tearDown(self):
        self.base_patch.stop()
        self.temp.cleanup()

    def profile(self, bundle='com.example.health', team='ABCDE12345', days=7):
        return {'TeamIdentifier': [team], 'ApplicationIdentifierPrefix': [team],
                'Entitlements': {'application-identifier': team + '.' + bundle},
                'ProvisionedDevices': [self.config['device_udid']], 'ExpirationDate': self.now + timedelta(days=days)}

    def test_schedule_uses_actual_expiry_and_limits_retries(self):
        self.assertFalse(renew.due({'installed_expiry': renew.timestamp(self.now + timedelta(days=5))}, self.now))
        self.assertTrue(renew.due({'installed_expiry': renew.timestamp(self.now + timedelta(days=2))}, self.now))
        state = {'last_attempt': renew.timestamp(self.now-timedelta(hours=1))}
        self.assertFalse(renew.due(state, self.now))
        self.assertTrue(renew.due(state, self.now, force=True))

    def test_old_profile_and_short_lifetime_are_not_success(self):
        previous = renew.timestamp(self.now + timedelta(days=3))
        for expiry in [self.now + timedelta(hours=12), self.now + timedelta(days=3)]:
            with self.assertRaises(renew.RenewalError):
                renew.validate_extension(expiry, previous, self.now)
        renew.validate_extension(self.now + timedelta(days=7), previous, self.now)

    def test_profile_checks_team_exact_bundle_device_and_expiry(self):
        good = self.profile()
        self.assertEqual(renew.validate_profile(good, self.config['bundle_id'], self.config['team_id'], self.config['device_udid'], self.now), self.now+timedelta(days=7))
        invalid = [self.profile(team='OTHER12345'), self.profile(bundle='com.example.other'), self.profile(days=-1), {**good, 'ProvisionedDevices': ['a-different-device']}]
        for value in invalid:
            with self.assertRaises(renew.RenewalError):
                renew.validate_profile(value, self.config['bundle_id'], self.config['team_id'], self.config['device_udid'], self.now)
        self.assertFalse(renew.profile_identity(self.profile(bundle='*'), self.config['bundle_id'], self.config['team_id']))

    def test_profile_cache_is_scoped_backed_up_and_restored_on_failure(self):
        cache = self.root / 'Library/MobileDevice/Provisioning Profiles'
        cache.mkdir(parents=True)
        files = {name: cache / (name+'.mobileprovision') for name in ['main','extension','other','wildcard','team']}
        profiles = {'main': self.profile(), 'extension': self.profile(bundle='com.example.health.workout'),
                    'other': self.profile(bundle='com.example.other'), 'wildcard': self.profile(bundle='*'),
                    'team': self.profile(team='OTHER12345')}
        for name, path in files.items(): path.write_text(name)
        with patch.object(renew.Path, 'home', return_value=self.root), patch.object(renew, 'decode_profile', side_effect=lambda p: profiles[p.stem]):
            with self.assertRaisesRegex(RuntimeError, 'build failed'):
                with renew.scoped_profiles(self.config, self.now):
                    self.assertFalse(files['main'].exists())
                    self.assertFalse(files['extension'].exists())
                    for name in ['other','wildcard','team']:self.assertTrue(files[name].exists())
                    raise RuntimeError('build failed')
        for name,path in files.items():self.assertEqual(path.read_text(), name)
        self.assertEqual(len(list((self.base/'profile-backups').rglob('*.mobileprovision'))),2)

    def test_restore_never_overwrites_new_profile(self):
        cache = self.root / 'Library/MobileDevice/Provisioning Profiles'
        cache.mkdir(parents=True)
        original = cache/'main.mobileprovision';original.write_text('old')
        with patch.object(renew.Path, 'home', return_value=self.root), patch.object(renew, 'decode_profile', return_value=self.profile()):
            with renew.scoped_profiles(self.config,self.now):original.write_text('new')
        self.assertEqual(original.read_text(),'new')

    def test_device_unavailable_does_not_build_install_or_start_retry_cooldown(self):
        state = {}
        with patch.object(renew, 'tool', return_value=b'') as tool, patch.object(renew, 'device_ready', side_effect=renew.Skip('offline')):
            with self.assertRaises(renew.Skip):renew.run_cycle(self.config,state,self.now)
        self.assertNotIn('last_attempt',state)
        self.assertFalse(any('install' in call.args[0] for call in tool.call_args_list))

    def test_failed_install_does_not_advance_recorded_expiry(self):
        state = {'installed_expiry': renew.timestamp(self.now+timedelta(days=2))}
        old = state['installed_expiry']
        def command(argv, **kwargs):
            if 'install' in argv:raise renew.RenewalError('phone disconnected')
            return b''
        with patch.object(renew, 'tool', side_effect=command), patch.object(renew, 'device_ready'), patch.object(renew, 'check_bundle', return_value=self.now+timedelta(days=7)), patch.object(renew, 'instant', return_value=self.now):
            with self.assertRaisesRegex(renew.RenewalError,'disconnected'):renew.run_cycle(self.config,state,self.now)
        self.assertEqual(state['installed_expiry'],old)
        self.assertNotIn('last_install',state)

    def test_only_verified_package_can_reach_install(self):
        state = {'installed_expiry': renew.timestamp(self.now+timedelta(days=2))}
        with patch.object(renew, 'tool', return_value=b'') as tool, patch.object(renew, 'device_ready'), patch.object(renew, 'check_bundle', return_value=self.now+timedelta(days=2)), patch.object(renew, 'instant', return_value=self.now):
            with self.assertRaises(renew.RenewalError):renew.run_cycle(self.config,state,self.now)
        self.assertFalse(any('install' in call.args[0] for call in tool.call_args_list))

    def test_success_records_expiry_after_install_and_never_launches(self):
        state={}
        with patch.object(renew,'tool',return_value=b'') as tool, patch.object(renew,'device_ready'), patch.object(renew,'check_bundle',return_value=self.now+timedelta(days=7)), patch.object(renew,'instant',return_value=self.now):
            renew.run_cycle(self.config,state,self.now)
        self.assertEqual(state['installed_expiry'],renew.timestamp(self.now+timedelta(days=7)))
        commands=[call.args[0] for call in tool.call_args_list]
        self.assertEqual(sum('install' in argv for argv in commands),1)
        self.assertFalse(any('uninstall' in argv or 'launch' in argv or 'revoke' in argv for argv in commands))
        self.assertEqual((self.base/'state.json').stat().st_mode&0o777,0o600)

    def test_extension_and_real_signing_certificate_can_shorten_effective_lifetime(self):
        app=self.root/'Health.app';extension=app/'PlugIns/WorkoutWidget.appex';extension.mkdir(parents=True)
        for target,bundle in [(app,self.config['bundle_id']),(extension,self.config['bundle_id']+'.workout')]:
            (target/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle}))
        def command(argv,**kwargs):
            if argv[0]=='/usr/bin/security':
                bundle=self.config['bundle_id']+('.workout' if 'WorkoutWidget.appex' in argv[-1] else '')
                value=self.profile(bundle=bundle)
                value['ExpirationDate']=value['ExpirationDate'].replace(tzinfo=None)
                return plistlib.dumps(value)
            return b''
        with patch.object(renew,'tool',side_effect=command), patch.object(renew,'certificate_expiry',side_effect=[self.now+timedelta(days=7),self.now+timedelta(days=4)]):
            self.assertEqual(renew.check_bundle(app,self.config,self.now),self.now+timedelta(days=4))
        (extension/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.different.workout'}))
        with patch.object(renew,'tool',side_effect=command),patch.object(renew,'certificate_expiry',return_value=self.now+timedelta(days=7)):
            with self.assertRaisesRegex(renew.RenewalError,'Bundle ID'):renew.check_bundle(app,self.config,self.now)

    def test_moved_project_is_recorded_as_failure_and_notified(self):
        renew.write_json(self.base/'config.json',{**self.config,'project':str(self.root/'missing.xcodeproj')})
        with patch.object(renew,'mac_required'),patch.object(renew,'notify') as notice:
            with self.assertRaises(SystemExit) as result:renew.run()
        self.assertEqual(result.exception.code,1)
        self.assertEqual(renew.read_json(self.base/'state.json')['outcome'],'needs_attention')
        notice.assert_called_once()

    def test_expiring_offline_phone_notifies_once_per_day(self):
        renew.write_json(self.base/'config.json',self.config)
        renew.write_json(self.base/'state.json',{'installed_expiry':renew.timestamp(self.now+timedelta(hours=24))})
        with patch.object(renew,'mac_required'),patch.object(renew,'tool',return_value=b''),patch.object(renew,'device_ready',side_effect=renew.Skip('offline')),patch.object(renew,'instant',return_value=self.now),patch.object(renew,'notify') as notice:
            renew.run();renew.run()
        notice.assert_called_once()
        self.assertEqual(renew.read_json(self.base/'state.json')['outcome'],'waiting_for_device')

    def test_paths_with_spaces_remain_single_arguments_and_agent_is_user_scoped(self):
        args=renew.build_arguments(self.config)
        self.assertEqual(args[args.index('-project')+1],str(self.project))
        self.assertIn('APP_BUNDLE_IDENTIFIER=com.example.health',args)
        agent=renew.launch_agent('/usr/bin/python3',self.root/'space dir/auto-renew.py')
        self.assertEqual(agent['StartInterval'],1800)
        self.assertEqual(agent['ProgramArguments'][1],str(self.root/'space dir/auto-renew.py'))
        self.assertNotIn('KeepAlive',agent)
        self.assertNotIn('UserName',agent)


if __name__=='__main__':unittest.main()
