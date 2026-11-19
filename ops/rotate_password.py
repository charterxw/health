"""Rotate the configured Health password without logging either password."""
import datetime,getpass,json,os,pathlib,re,shutil,subprocess,sys,tempfile,urllib.request,urllib.error

ROOT=pathlib.Path('/home/admin/health')
if sys.stdin.isatty():new_password=getpass.getpass('New Health password: ')
else:
    print('READY_FOR_NEW_PASSWORD',flush=True)
    new_password=sys.stdin.readline().rstrip('\r\n')
if len(new_password)<16 or not re.fullmatch(r'[A-Za-z0-9_-]+',new_password):
    raise SystemExit('Expected a password of at least 16 letters, digits, underscores or hyphens')
os.umask(0o077)
backup=ROOT/'backups'/('password-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
backup.mkdir(mode=0o700)
env_path=ROOT/'.env';shutil.copy2(env_path,backup/'.env')
def runtime_env():
    item=json.loads(subprocess.check_output(['docker','inspect','fitness-api']))[0]
    return dict(value.split('=',1) for value in item['Config']['Env'])
old=runtime_env();account=old['DASHBOARD_USER'];old_password=old['DASHBOARD_PASS']
def request(path,body=None,cookie=None):
    headers={'Content-Type':'application/json'}
    if cookie:headers['Cookie']=cookie
    req=urllib.request.Request('http://127.0.0.1:9999'+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
    try:response=urllib.request.urlopen(req,timeout=15)
    except urllib.error.HTTPError as error:response=error
    response.read();return response.status,response.headers
status,headers=request('/api/auth/app-login',{'username':account,'password':old_password})
assert status==200,'Could not establish the pre-change verification session'
old_cookie=headers['Set-Cookie'].split(';')[0]
text=env_path.read_text()
pattern=r'(?m)^\s*(?:export\s+)?DASHBOARD_PASS\s*=.*$'
assert len(re.findall(pattern,text))==1,'Expected exactly one configured password'
updated=re.sub(pattern,'DASHBOARD_PASS='+json.dumps(new_password),text)
fd,temporary=tempfile.mkstemp(prefix='.health-password-',dir=ROOT)
with os.fdopen(fd,'w') as handle:handle.write(updated);handle.flush();os.fsync(handle.fileno())
os.chmod(temporary,0o600);os.replace(temporary,env_path)
compose=['docker','compose','--project-directory',str(ROOT),'up','-d','--no-build','--force-recreate','--wait','--wait-timeout','150','backend','frontend']
try:
    with (backup/'restart.log').open('w') as log:
        subprocess.run(compose,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
    assert runtime_env()['DASHBOARD_PASS']==new_password,'Requested credential was not applied'
    # Delete obsolete fingerprints as well as rejecting them during verification.
    cleanup="from app.security import credential_version; from app.database import get_db; c=get_db(); db=c.__enter__(); db.execute('DELETE FROM dashboard_sessions WHERE credential_version<>?',(credential_version(),)); db.commit(); c.__exit__(None,None,None)"
    subprocess.run(['docker','exec','fitness-api','python','-c',cleanup],check=True)
    old_login,_=request('/api/auth/app-login',{'username':account,'password':old_password})
    old_session,_=request('/api/home',cookie=old_cookie)
    new_login,headers=request('/api/auth/app-login',{'username':account,'password':new_password})
    assert new_login==200 and old_login==401 and old_session==401,'Credential rotation verification failed'
    cookie=headers['Set-Cookie'].split(';')[0]
    try:
        home,_=request('/api/home',cookie=cookie);assert home==200
    finally:request('/api/auth/logout',{},cookie)
except Exception:
    shutil.copy2(backup/'.env',env_path)
    with (backup/'rollback.log').open('w') as log:
        subprocess.run(compose,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=180)
    raise
result={'account':account,'password_changed':True,'new_password_login':new_login,
        'old_password_login':old_login,'old_session':old_session,'authenticated_home':home,
        'backup_directory':str(backup)}
(backup/'verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result),flush=True)
