"""Install host-side monitoring, daily backups and guarded SSH settings as root."""
import argparse,json,os,shutil,subprocess
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--source',required=True);parser.add_argument('--backup',required=True)
args=parser.parse_args();source=Path(args.source).resolve();backup=Path(args.backup).resolve()/'host-config'
if os.geteuid()!=0:raise SystemExit('Run with sudo')
os.umask(0o077);backup.mkdir(parents=True,exist_ok=True,mode=0o700)

def preserve(path):
    path=Path(path)
    if path.exists():
        target=backup/path.relative_to('/')
        if not target.exists():target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,target)

def write(path,text,mode=0o644):
    path=Path(path);preserve(path);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(text);path.chmod(mode)

ops=Path('/usr/local/lib/health-ops');ops.mkdir(mode=0o700,parents=True,exist_ok=True)
for name in ['probe_container.py','monitor.py','alert.py']:
    write(ops/name,(source/'ops'/name).read_text(),0o700)
Path('/var/lib/health-ops').mkdir(mode=0o700,parents=True,exist_ok=True)
common='''User=root
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/lib/health-ops
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
MemoryMax=128M
'''
write('/etc/systemd/system/health-monitor.service','''[Unit]
Description=Health application and verified-backup monitoring
After=docker.service network-online.target
Wants=network-online.target
OnFailure=health-ops-alert@monitor.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/health-ops/monitor.py
TimeoutStartSec=90
'''+common)
write('/etc/systemd/system/health-monitor.timer','''[Unit]
Description=Check Health every five minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=15s
Unit=health-monitor.service
[Install]
WantedBy=timers.target
''')
write('/etc/systemd/system/health-ops-alert@.service','''[Unit]
Description=Private Health operational alert for %i
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/health-ops/alert.py %i
TimeoutStartSec=30
'''+common)
write('/etc/systemd/system/server-backup@health.service.d/alert.conf','''[Unit]
OnFailure=health-ops-alert@backup-health.service
''')
write('/etc/systemd/system/server-backup@health.timer.d/schedule.conf','''[Timer]
OnCalendar=
OnCalendar=*-*-* 03:10:00 America/New_York
Persistent=true
''')
profile_path=Path('/etc/server-backup/profiles/health.json');preserve(profile_path)
profile=json.loads(profile_path.read_text());profile['calendar']='*-*-* 03:10:00 America/New_York';profile['local_keep']=14
extra=['/usr/local/lib/health-ops','/etc/systemd/system/health-monitor.service',
       '/etc/systemd/system/health-monitor.timer','/etc/systemd/system/health-ops-alert@.service',
       '/etc/systemd/system/server-backup@health.service.d','/etc/systemd/system/server-backup@health.timer.d']
for item in extra:
    if item not in profile['sources']['backup-runtime']:profile['sources']['backup-runtime'].append(item)
profile_path.write_text(json.dumps(profile,indent=2)+'\n');profile_path.chmod(0o600)
write('/etc/ssh/sshd_config.d/20-health-hardening.conf','''# Keep the owner's password access until a personal SSH key has been provisioned.
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:30
PerSourceMaxStartups 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
''',0o600)
write('/etc/fail2ban/jail.d/health-sshd.local','''[sshd]
enabled = true
backend = systemd
banaction = nftables-multiport
maxretry = 5
findtime = 10m
bantime = 15m
# Cloudflare Access already authenticates this connector; do not lock out all tunnel users together.
ignoreip = 127.0.0.1/8 ::1 172.17.0.3/32
''',0o600)
subprocess.run(['/usr/sbin/sshd','-t'],check=True)
subprocess.run(['fail2ban-client','-t'],check=True)
boot=Path('/boot/firmware/cmdline.txt');preserve(boot)
tokens=boot.read_text().strip().split()
for token in ['cgroup_enable=memory','cgroup_memory=1','swapaccount=1']:
    if token not in tokens:tokens.append(token)
boot.write_text(' '.join(tokens)+'\n')
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','reload','ssh'],check=True)
subprocess.run(['systemctl','enable','--now','fail2ban'],check=True)
subprocess.run(['systemctl','restart','fail2ban'],check=True)
subprocess.run(['systemctl','enable','--now','health-monitor.timer','server-backup@health.timer'],check=True)
subprocess.run(['systemctl','restart','server-backup@health.timer'],check=True)
print(json.dumps({'installed':True,'ssh_password_access':'preserved','backup':'daily 03:10 America/New_York',
                  'monitor':'every 5 minutes','memory_controller':'reboot required'}))
