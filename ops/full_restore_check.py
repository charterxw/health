"""Download, authenticate and boot a full backup in isolated containers."""
import hashlib,http.client,json,os,pathlib,shutil,sqlite3,subprocess,time
ROOT=pathlib.Path('/home/admin/health');TAG=(ROOT/'CURRENT_RELEASE').read_text().strip()
BACKUP=pathlib.Path((ROOT/'HARDENING_BACKUP').read_text().strip())
PROFILE=json.loads(pathlib.Path('/etc/server-backup/profiles/health.json').read_text())
RECEIPT=json.loads(pathlib.Path('/var/lib/server-backup/health/last-success.json').read_text())
SNAPSHOT=pathlib.Path('/var/lib/server-backup/health/snapshots')/RECEIPT['snapshot']
assert RECEIPT['download_verified'] and RECEIPT['restore_verified']
manifest=json.loads((SNAPSHOT/'manifest.json').read_text())
assert manifest['config_sha256']==hashlib.sha256(pathlib.Path('/etc/server-backup/profiles/health.json').read_bytes()).hexdigest()
CHECK=BACKUP/'full-restore-check';CHECK.mkdir(mode=0o700,exist_ok=True)
os.umask(0o077)
for kind in ['app','data']:
    name=kind+'.tar.zst.age';target=CHECK/name
    subprocess.run(['rclone','--config','/etc/server-backup/rclone.conf','copyto',RECEIPT['remote']+'/'+name,str(target),'--quiet'],check=True)
    expected=next(a['sha256'] for a in manifest['archives'] if a['name']==name)
    assert hashlib.sha256(target.read_bytes()).hexdigest()==expected
    destination=CHECK/kind;destination.mkdir(mode=0o700,exist_ok=True)
    age=subprocess.Popen(['age','-d','-i',PROFILE['encryption']['identity_file'],str(target)],stdout=subprocess.PIPE)
    zstd=subprocess.Popen(['zstd','-d','-q'],stdin=age.stdout,stdout=subprocess.PIPE);age.stdout.close()
    tar=subprocess.Popen(['tar','-xpf','-','-C',str(destination)],stdin=zstd.stdout);zstd.stdout.close()
    assert tar.wait()==0 and zstd.wait()==0 and age.wait()==0
source=CHECK/'app/home/admin/health'
data=CHECK/'data/var/lib/docker/volumes/health_fitness-data/_data'
assert (source/'backend/app/security.py').is_file() and (source/'backend/requirements.txt').is_file()
assert 'FROM local/' not in (source/'backend/Dockerfile').read_text()
assert 'FROM local/' not in (source/'frontend/Dockerfile').read_text()
for file in (ROOT/'backend/app').rglob('*.py'):
    restored=source/'backend/app'/file.relative_to(ROOT/'backend/app')
    assert hashlib.sha256(file.read_bytes()).digest()==hashlib.sha256(restored.read_bytes()).digest()
for file in (ROOT/'frontend/src').rglob('*'):
    if file.is_file():
        restored=source/'frontend/src'/file.relative_to(ROOT/'frontend/src')
        assert hashlib.sha256(file.read_bytes()).digest()==hashlib.sha256(restored.read_bytes()).digest()
with sqlite3.connect(data/'fitness.db') as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    protected={name:db.execute('SELECT count(*) FROM '+name).fetchone()[0] for name in ['strength_sessions','strength_templates','home_goals','home_feedback','home_rounds']}
network='health-full-restore-check';api_name='health-full-restore-api';ui_name='health-full-restore-ui'
def run(args):return subprocess.check_output(args,text=True).strip()
if subprocess.run(['docker','network','inspect',network],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:
    run(['docker','network','create',network])
shared=['--network',network,'--read-only','--cap-drop','ALL','--security-opt','no-new-privileges:true',
        '--tmpfs','/tmp:rw,noexec,nosuid,size=64m,mode=1777','--label','io.codex.health-hardening='+TAG]
try:
    run(['docker','run','-d','--name',api_name,*shared,'--network-alias','backend','--env-file',str(source/'.env'),
         '-e','TZ=America/New_York','-e','ENABLE_BACKGROUND_JOBS=false','-e','TELEGRAM_NOTIFICATIONS_ENABLED=false',
         '-e','MEDIA_AI_SOCKET=','-e','DB_PATH=/data/fitness.db','-e','TOKEN_FILE=/data/tokens.json',
         '-e','CHATGPT_CREDENTIALS_FILE=/run/secrets/oauth/chatgpt-oauth.json',
         '-v',str(data)+':/data','-v',str(source/'runtime-secrets/oauth')+':/run/secrets/oauth:ro',
         '-p','127.0.0.1::8000','local/health-backend:'+TAG])
    run(['docker','run','-d','--name',ui_name,*shared,'-p','127.0.0.1::8080','local/health-frontend:'+((source/'FRONTEND_RELEASE').read_text().strip() if (source/'FRONTEND_RELEASE').exists() else TAG)])
    def port(name,number):return int(json.loads(run(['docker','inspect',name]))[0]['NetworkSettings']['Ports'][str(number)+'/tcp'][0]['HostPort'])
    api=port(api_name,8000);ui=port(ui_name,8080)
    def request(port,path,body=None,cookie=None):
        c=http.client.HTTPConnection('127.0.0.1',port,timeout=15);headers={'Content-Type':'application/json'}
        if cookie:headers['Cookie']=cookie
        c.request('GET' if body is None else 'POST',path,None if body is None else json.dumps(body),headers)
        r=c.getresponse();raw=r.read();headers={k.lower():v for k,v in r.getheaders()};status=r.status;c.close()
        return status,headers,raw
    for _ in range(45):
        try:
            if request(api,'/api/readyz')[0]==200:break
        except OSError:pass
        time.sleep(1)
    else:raise RuntimeError('Restored backend not ready')
    env=dict(value.split('=',1) for value in json.loads(run(['docker','inspect',api_name]))[0]['Config']['Env'])
    status,headers,_=request(ui,'/api/auth/app-login',{'username':env['DASHBOARD_USER'],'password':env['DASHBOARD_PASS']});assert status==200
    cookie=headers['set-cookie'].split(';')[0]
    checks={path:request(ui,path,cookie=cookie)[0] for path in ['/api/home','/api/strength/catalog','/api/strength/sessions']}
    assert all(value==200 for value in checks.values())
    assert request(ui,'/api/auth/logout',{},cookie)[0]==200
    assert request(ui,'/api/home',cookie=cookie)[0]==401
    with sqlite3.connect(data/'fitness.db') as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert all(db.execute('SELECT count(*) FROM '+name).fetchone()[0]>=count for name,count in protected.items())
    result={'snapshot':RECEIPT['snapshot'],'downloaded_archives':['app','data'],'archive_hashes':'verified',
            'age_decryption':'verified','canonical_source':'matches production','isolated_startup':'passed',
            'authenticated_routes':checks,'logout_revocation':True,'database_integrity':'ok','training_records_preserved':True}
    (BACKUP/'full-restore-validation.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
finally:
    for name in [ui_name,api_name]:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['docker','network','rm',network],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if 'result' in locals():
    # Retain encrypted downloads and validation evidence; remove temporary plaintext secrets.
    for name in ['app','data']:shutil.rmtree(CHECK/name)
