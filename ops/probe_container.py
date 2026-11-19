"""Run inside fitness-api; never print credentials or cookies."""
import json,os,urllib.request,urllib.error

def request(path,body=None,cookie=None):
    headers={'Content-Type':'application/json'}
    if cookie:headers['Cookie']=cookie
    req=urllib.request.Request('http://127.0.0.1:8000'+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
    try:response=urllib.request.urlopen(req,timeout=10)
    except urllib.error.HTTPError as error:response=error
    return response,json.loads(response.read())

response,data=request('/api/readyz')
if response.status!=200:
    print(json.dumps({'status':'not_ready','http_status':response.status}))
else:
    response,data=request('/api/auth/app-login',{'username':os.environ['DASHBOARD_USER'],'password':os.environ['DASHBOARD_PASS']})
    if response.status!=200:raise RuntimeError('Operational authentication failed')
    cookie=response.headers['Set-Cookie'].split(';')[0]
    try:
        response,data=request('/api/system/health',cookie=cookie)
        print(json.dumps(data))
    finally:request('/api/auth/logout',{},cookie)
