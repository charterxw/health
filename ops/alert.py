"""Send deduplicated operational alerts using the existing private Telegram sink."""
import fcntl,hashlib,json,os,sys,time,urllib.request
from pathlib import Path

STATE=Path('/var/lib/health-ops')

def alert(kind,text):
    STATE.mkdir(mode=0o700,parents=True,exist_ok=True)
    os.umask(0o077)
    with (STATE/'alert.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        path=STATE/'alerts.json'
        cache=json.loads(path.read_text()) if path.exists() else {}
        key=hashlib.sha256(kind.encode()).hexdigest()
        if time.time()-cache.get(key,0)<3600:return False
        root=Path('/home/admin/health/secrets')
        token=(root/'telegram-bot-token').read_text().strip()
        chat=(root/'telegram-chat-id').read_text().strip()
        payload={'chat_id':chat,'text':'Health 服务告警\n'+text[:1500],
                 'protect_content':True,'link_preview_options':{'is_disabled':True}}
        req=urllib.request.Request('https://api.telegram.org/bot'+token+'/sendMessage',
            data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        try:
            result=json.load(urllib.request.urlopen(req,timeout=15))
            if not result.get('ok'):raise RuntimeError('Rejected')
        except Exception as error:
            raise RuntimeError('Operational alert delivery failed: '+type(error).__name__) from None
        cache[key]=time.time()
        temporary=path.with_suffix('.tmp');temporary.write_text(json.dumps(cache));os.replace(temporary,path)
        return True

if __name__=='__main__':
    unit=sys.argv[1] if len(sys.argv)>1 else 'health'
    alert(unit,'任务失败：'+unit+'。请检查该任务的 systemd 日志。')
