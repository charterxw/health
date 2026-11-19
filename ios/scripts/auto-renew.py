#!/usr/bin/env python3
"""Best-effort Xcode renewal for one explicitly configured, paired iPhone.

Runs on the owner's Mac, in their logged-in user session. No Apple passwords,
certificate revocation, device uninstalls, or background app launches.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

LABEL = 'com.frankandpatrick.health.autorenew'
UTC = timezone.utc
BASE = Path.home() / 'Library/Application Support/HealthAutoRenew'
PLIST = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')


class RenewalError(Exception):
    pass


class Skip(Exception):
    pass


def instant():
    return datetime.now(UTC)


def timestamp(value):
    return value.isoformat()


def parse_time(value):
    result = datetime.fromisoformat(value)
    return result.replace(tzinfo=UTC) if result.tzinfo is None else result.astimezone(UTC)


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def write_json(path, value):
    private_dir(path.parent)
    temp = path.with_suffix('.tmp')
    with temp.open('w') as output:
        os.chmod(temp, 0o600)
        json.dump(value, output, indent=2, ensure_ascii=False)
    temp.replace(path)


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def tool(argv, timeout=30, log=None):
    """No shell interpolation; diagnostic output stays in private local logs."""
    try:
        if log:
            with log.open('wb') as output:
                result = subprocess.run(argv, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            if result.returncode:
                raise RenewalError(f'{Path(argv[0]).name} 失败；查看本机日志 {log}')
            return b''
        return subprocess.run(argv, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as error:
        raise RenewalError(f'{Path(argv[0]).name} 未完成，请检查 Xcode、设备连接和登录状态。') from error


def mac_required():
    if sys.platform != 'darwin':
        raise RenewalError('此任务需要在装有完整 Xcode 的 Mac 上运行。')


def validate_config(config):
    for key in ['project', 'team_id', 'device_udid', 'bundle_id']:
        if not isinstance(config.get(key), str) or not config[key].strip():
            raise RenewalError(f'缺少配置：{key}')
    if not re.fullmatch(r'[A-Z0-9]{10}', config['team_id']):
        raise RenewalError('Team ID 应为 Xcode 中原签名团队的 10 位标识。')
    if not re.fullmatch(r'[0-9A-Fa-f-]{16,64}', config['device_udid']):
        raise RenewalError('请填写 iPhone 的 UDID，不是设备名称。')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', config['bundle_id']):
        raise RenewalError('请填写原 App 的 Bundle Identifier。')
    if Path(config['project']).suffix != '.xcodeproj' or not Path(config['project']).is_dir():
        raise RenewalError('Xcode 项目路径不存在。')


def profile_identity(profile, bundle_id, team_id):
    entitlements = profile.get('Entitlements', {})
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    identifiers = {prefix + '.' + bundle_id for prefix in prefixes}
    return team_id in profile.get('TeamIdentifier', []) and entitlements.get('application-identifier') in identifiers


def validate_profile(profile, bundle_id, team_id, udid, now):
    if not profile_identity(profile, bundle_id, team_id):
        raise RenewalError(f'{bundle_id} 的描述文件不匹配原来的团队或精确 Bundle ID。')
    devices = {value.upper() for value in profile.get('ProvisionedDevices', [])}
    if udid.upper() not in devices:
        raise RenewalError('描述文件未包含指定 iPhone；请先在 Xcode 手动 Run 一次。')
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime):
        raise RenewalError('描述文件缺少有效的到期时间。')
    expiry = expiry.replace(tzinfo=UTC) if expiry.tzinfo is None else expiry.astimezone(UTC)
    if expiry <= now:
        raise RenewalError('构建包的描述文件已经过期，未安装。')
    return expiry


def certificate_expiry(app, work):
    prefix = str(work / 'certificate')
    tool(['/usr/bin/codesign', '--display', '--extract-certificates', prefix, str(app)])
    leaf = Path(prefix + '0')
    if not leaf.exists():
        raise RenewalError('无法读取实际签名证书，未安装。')
    result = tool(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', str(leaf), '-noout', '-enddate']).decode().strip()
    try:
        return datetime.strptime(result.split('=', 1)[1], '%b %d %H:%M:%S %Y %Z').replace(tzinfo=UTC)
    except (ValueError, IndexError) as error:
        raise RenewalError('无法确认签名证书到期时间，未安装。') from error


def check_bundle(app, config, now):
    expected = [config['bundle_id'], config['bundle_id'] + '.workout']
    extension = app / 'PlugIns/WorkoutWidget.appex'
    if not extension.is_dir():
        raise RenewalError('实况活动扩展缺失，未安装。')
    tool(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    expiries = []
    for target, bundle_id in zip([app, extension], expected):
        info = plistlib.loads((target / 'Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != bundle_id:
            raise RenewalError('构建产物的 Bundle ID 改变，未覆盖安装。')
        profile = plistlib.loads(tool(['/usr/bin/security', 'cms', '-D', '-i', str(target / 'embedded.mobileprovision')]))
        expiries.append(validate_profile(profile, bundle_id, config['team_id'], config['device_udid'], now))
        with tempfile.TemporaryDirectory(prefix='certificate-', dir=BASE) as work:
            expiries.append(certificate_expiry(target, Path(work)))
    return min(expiries)


def validate_extension(new_expiry, previous_expiry, now):
    if new_expiry < now + timedelta(hours=48):
        raise RenewalError('新包剩余有效期不足 48 小时；未安装，需要在 Xcode 检查签名。')
    if previous_expiry and new_expiry <= parse_time(previous_expiry) + timedelta(minutes=1):
        raise RenewalError('Xcode 仍复用原有效期，续签没有成功；未安装，需要在 Xcode 处理。')


def decode_profile(path):
    return plistlib.loads(tool(['/usr/bin/security', 'cms', '-D', '-i', str(path)]))


@contextmanager
def scoped_profiles(config, now):
    """Temporarily remove only exact app/extension matches; never wildcard profiles.

    Apple documents removing eligible cached profiles to request fresh automatic
    provisioning. Preserve originals and restore them on every exit, including
    failure. The installed phone profiles and certificates are never touched.
    """
    cache_dirs = [Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                  Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles']
    backup = BASE / 'profile-backups' / now.strftime('%Y%m%dT%H%M%S%fZ')
    moved = []
    try:
        for index, cache in enumerate(cache_dirs):
            for path in cache.glob('*.mobileprovision'):
                try:
                    profile = decode_profile(path)
                except (RenewalError, ValueError, plistlib.InvalidFileException):
                    continue
                if not any(profile_identity(profile, value, config['team_id']) for value in [config['bundle_id'], config['bundle_id'] + '.workout']):
                    continue
                private_dir(backup)
                saved = backup / f'{index}-{path.name}'
                shutil.copy2(path, saved)
                saved.chmod(0o600)
                moved.append((path, saved))
                path.unlink()
        yield
    finally:
        for path, saved in moved:
            # A new profile written under the same UUID takes precedence.
            if not path.exists():
                shutil.copy2(saved, path)


def device_ready(config, folder):
    target = folder / 'device.json'
    try:
        tool(['/usr/bin/xcrun', 'devicectl', 'device', 'info', 'details', '--device', config['device_udid'],
              '--json-output', str(target), '--timeout', '20'], timeout=25)
    except RenewalError as error:
        raise Skip('指定 iPhone 当前无法连接；手机回到可用 USB／无线配对连接后再试。') from error


def build_arguments(config):
    return ['/usr/bin/xcrun', 'xcodebuild', '-project', config['project'], '-scheme', 'Health',
            '-configuration', 'Debug', '-sdk', 'iphoneos', '-destination', 'id=' + config['device_udid'],
            '-derivedDataPath', str(BASE / 'DerivedData'), '-allowProvisioningUpdates',
            '-allowProvisioningDeviceRegistration', 'CODE_SIGN_STYLE=Automatic',
            'DEVELOPMENT_TEAM=' + config['team_id'], 'APP_BUNDLE_IDENTIFIER=' + config['bundle_id'],
            'build']


def due(state, now, force=False):
    if force:
        return True
    if state.get('installed_expiry') and parse_time(state['installed_expiry']) > now + timedelta(hours=72):
        return False
    return not state.get('last_attempt') or parse_time(state['last_attempt']) <= now - timedelta(hours=6)


def notify(message):
    script = 'on run argv\n display notification (item 1 of argv) with title "Health 自动续签"\nend run'
    try:
        subprocess.run(['/usr/bin/osascript', '-e', script, message], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def run_cycle(config, state, now, force=False):
    if not due(state, now, force):
        return '无需尝试：尚未进入到期前 72 小时，或距离上次尝试不足 6 小时。'
    tool(['/usr/bin/xcrun', '--find', 'devicectl'])
    tool(['/usr/bin/xcrun', 'xcodebuild', '-version'])
    with tempfile.TemporaryDirectory(prefix='device-', dir=BASE) as folder:
        device_ready(config, Path(folder))
    state['last_attempt'] = timestamp(now)
    write_json(BASE / 'state.json', state)
    with scoped_profiles(config, now):
        tool(build_arguments(config), timeout=900, log=BASE / 'build.log')
    app = BASE / 'DerivedData/Build/Products/Debug-iphoneos/Health.app'
    expiry = check_bundle(app, config, instant())
    validate_extension(expiry, state.get('installed_expiry'), instant())
    # This is the only installation command. No uninstall or app launch occurs.
    tool(['/usr/bin/xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['device_udid'],
          str(app), '--timeout', '120'], timeout=135, log=BASE / 'install.log')
    state.update(installed_expiry=timestamp(expiry), last_install=timestamp(instant()), outcome='installed',
                 message='安装命令成功，包的有效期已核对；未自动启动 App。')
    return f'安装命令成功；包的最早到期时间：{expiry.astimezone().isoformat()}'


def run(force=False):
    mac_required()
    private_dir(BASE)
    with (BASE / 'run.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('已有续签任务正在运行，稍后查看 status。')
            return
        state = read_json(BASE / 'state.json')
        now = instant()
        try:
            config = read_json(BASE / 'config.json')
            validate_config(config)
            message = run_cycle(config, state, now, force)
            print(message)
        except Skip as error:
            state.update(outcome='waiting_for_device', message=str(error))
            if state.get('installed_expiry') and parse_time(state['installed_expiry']) <= now+timedelta(hours=48):
                last=parse_time(state['last_notice']) if state.get('last_notice') else None
                if not last or now-last >= timedelta(hours=24):
                    notify('签名临近或已经到期，iPhone 当前无法连接；需要手机回到 Mac 可安装的连接。')
                    state['last_notice']=timestamp(now)
            print(error)
        except (RenewalError, OSError, ValueError, plistlib.InvalidFileException) as error:
            state.update(outcome='needs_attention', message=str(error))
            last = parse_time(state['last_notice']) if state.get('last_notice') else None
            if not last or now-last >= timedelta(hours=24):
                notify('自动续签未完成；请查看 HealthAutoRenew 状态，必要时在 Xcode 手动 Run。')
                state['last_notice'] = timestamp(now)
            print(error, file=sys.stderr)
            state['checked_at'] = timestamp(now)
            write_json(BASE / 'state.json', state)
            raise SystemExit(1)
        state['checked_at'] = timestamp(now)
        write_json(BASE / 'state.json', state)


def launch_agent(python, script):
    return {'Label': LABEL, 'ProgramArguments': [python, str(script), 'run'],
            'RunAtLoad': True, 'StartInterval': 1800,
            'ProcessType': 'Background',
            'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
            'StandardOutPath': str(BASE / 'agent.log'), 'StandardErrorPath': str(BASE / 'agent-error.log')}


def setup(args):
    mac_required()
    default_project = Path(__file__).resolve().parents[1] / 'Health.xcodeproj'
    project = args.project or (str(default_project) if default_project.is_dir() else input('原 Health.xcodeproj 的完整路径：').strip())
    config = {'project': str(Path(project).expanduser().resolve()),
              'team_id': args.team or input('原签名 Team ID（10 位）：').strip(),
              'device_udid': args.device or input('已配对 iPhone 的 UDID：').strip(),
              'bundle_id': args.bundle_id or input('原 App 的 Bundle Identifier：').strip()}
    validate_config(config)
    tool(['/usr/bin/xcrun', '--find', 'devicectl'])
    tool(['/usr/bin/xcrun', 'xcodebuild', '-version'])
    previous = read_json(BASE / 'config.json')
    if previous and previous != config:
        raise RenewalError('配置已存在且不同。请先停用任务，备份并移除本机 config.json 和 state.json 后再 setup。')
    write_json(BASE / 'config.json', config)
    script = BASE / 'auto-renew.py'
    if Path(__file__).resolve() != script:
        shutil.copy2(Path(__file__).resolve(), script)
    script.chmod(0o700)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with PLIST.open('wb') as output:
        plistlib.dump(launch_agent(sys.executable, script), output)
    PLIST.chmod(0o600)
    if not args.no_enable:
        subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}', str(PLIST)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tool(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(PLIST)])
    print('已配置。Mac 登录后每 30 分钟检查；实际签名尝试最多每 6 小时一次。')
    print('请首次运行 run --force，并检查 status。无需提供 Apple 密码给此脚本。')


def uninstall():
    mac_required()
    subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}', str(PLIST)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PLIST.unlink(missing_ok=True)
    print('已停用并移除定时任务；本地配置、日志和状态保留。')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    install = commands.add_parser('setup')
    install.add_argument('--project'); install.add_argument('--team'); install.add_argument('--device')
    install.add_argument('--bundle-id'); install.add_argument('--no-enable', action='store_true')
    renew = commands.add_parser('run'); renew.add_argument('--force', action='store_true')
    commands.add_parser('status'); commands.add_parser('uninstall')
    args = parser.parse_args()
    try:
        if args.command == 'setup': setup(args)
        elif args.command == 'run': run(args.force)
        elif args.command == 'uninstall': uninstall()
        else: print(json.dumps(read_json(BASE / 'state.json'), indent=2, ensure_ascii=False))
    except (RenewalError, OSError, ValueError) as error:
        parser.exit(2, str(error)+'\n')


if __name__ == '__main__':
    main()
