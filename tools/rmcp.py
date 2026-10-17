"""Tiny stdio client for Roblox Studio's built-in MCP (macOS). Usage:
  python3 rmcp.py tools                      -> list tool schemas
  python3 rmcp.py call <tool> '<json args>'  -> call a tool, print text, save images to --img dir
"""
import json, subprocess, sys, threading, queue, time, base64, os
EXE = '/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP'
class C:
    def __init__(s, timeout=120):
        s.t=timeout; s.n=0; s.q=queue.Queue()
        s.p=subprocess.Popen([EXE],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        threading.Thread(target=s._r,daemon=True).start()
        threading.Thread(target=lambda:[None for _ in s.p.stderr],daemon=True).start()
    def _r(s):
        for l in s.p.stdout:
            try: s.q.put(json.loads(l))
            except Exception: pass
        s.q.put({'closed':1})
    def send(s,m): s.p.stdin.write(json.dumps(m)+'\n'); s.p.stdin.flush()
    def req(s,method,params=None):
        s.n+=1; i=s.n; s.send({'jsonrpc':'2.0','id':i,'method':method,'params':params or {}})
        end=time.time()+s.t
        while time.time()<end:
            try: m=s.q.get(timeout=end-time.time())
            except queue.Empty: break
            if 'closed' in m: raise RuntimeError('closed')
            if m.get('id')==i:
                if 'error' in m: raise RuntimeError(json.dumps(m['error']))
                return m.get('result',{})
        raise TimeoutError(method)
    def init(s):
        r=s.req('initialize',{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'claude-rmcp','version':'1'}})
        s.send({'jsonrpc':'2.0','method':'notifications/initialized'}); return r
def main():
    a=sys.argv[1:]; img=None
    if '--img' in a: k=a.index('--img'); img=a[k+1]; del a[k:k+2]
    c=C(); c.init()
    try:
        if a[0]=='tools':
            r=c.req('tools/list'); print(json.dumps(r.get('tools',[]),indent=1))
        else:
            args=json.loads(a[2]) if len(a)>2 else {}
            if len(a)>2 and a[2].startswith('@'): args=json.load(open(a[2][1:]))
            r=c.req('tools/call',{'name':a[1],'arguments':args})
            k=0
            for part in r.get('content',[]):
                if part.get('type')=='text': print(part['text'])
                elif part.get('type')=='image':
                    k+=1; path=(img or '/tmp/rmcp')+(f'_{k}' if k>1 else '')+'.png'
                    open(path,'wb').write(base64.b64decode(part['data'])); print('IMAGE ->',path)
            if r.get('isError'): sys.exit(2)
    finally:
        c.p.stdin.close()
        try: c.p.wait(3)
        except Exception: c.p.terminate()
if __name__ == "__main__":
    main()
