"""Local monitoring with delayed alerts; health data stays out of notifications."""
import datetime,json,os,shutil,subprocess,time
from pathlib import Path
from alert import alert

os.umask(0o077)
STATE=Path('/var/lib/health-ops');STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
issues=[]
try:
    probe=Path(__file__).with_name('probe_container.py').read_bytes()
    run=subprocess.run(['docker','exec','-i','fitness-api','python','-'],input=probe,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=40)
    if run.returncode:raise RuntimeError('probe_failed')
    app=json.loads(run.stdout)
    if app.get('status')=='not_ready':issues.append('backend_not_ready')
    for row in app.get('briefs',[]):
        if row.get('date')==datetime.datetime.now().date().isoformat() and row.get('status')=='error':
            issues.append('ai_brief_'+row['period']+'_failed')
    for source,data in app.get('sources',{}).items():
        if data.get('age_seconds',0)>86400:issues.append('source_'+source+'_stale')
except Exception as error:
    app={'status':'not_ready','error_type':type(error).__name__};issues.append('backend_probe_failed')
try:
    receipt=json.loads(Path('/var/lib/server-backup/health/last-success.json').read_text())
    completed=datetime.datetime.fromisoformat(receipt['completed_utc']).timestamp()
    if time.time()-completed>36*3600:issues.append('backup_older_than_36_hours')
    if not receipt.get('restore_verified'):issues.append('backup_restore_unverified')
except Exception:issues.append('backup_receipt_missing')
disk=shutil.disk_usage('/')
if disk.free<10*1024**3:issues.append('disk_free_below_10_gib')
state_file=STATE/'monitor.json'
previous=json.loads(state_file.read_text()) if state_file.exists() else {}
old=previous.get('first_seen',{})
first={issue:old.get(issue,time.time()) for issue in issues}
state={'checked_at':datetime.datetime.now().astimezone().isoformat(),'status':'degraded' if issues else 'ok',
       'issues':issues,'first_seen':first,'app':app,'disk_free_bytes':disk.free}
temporary=state_file.with_suffix('.tmp');temporary.write_text(json.dumps(state,indent=2));os.replace(temporary,state_file)
persisted=[issue for issue in issues if time.time()-first[issue]>=900]
if persisted:alert('health-monitor:'+','.join(sorted(persisted)), '以下检查持续异常超过 15 分钟：'+', '.join(persisted))
print(json.dumps({'status':state['status'],'issues':issues}))
