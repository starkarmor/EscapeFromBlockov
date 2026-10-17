"""One persistent Studio MCP session: waits for Studio registration, then runs a JSON list of calls.
  python3 rmcp_session.py calls.json [--img prefix]
calls.json: [{"tool": "...", "args": {...}}, ...]; "{SID}" in any string arg becomes the studio id.
"""
import json, sys, time, base64, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rmcp import C
def main():
    calls = json.load(open(sys.argv[1]))
    img = sys.argv[sys.argv.index('--img') + 1] if '--img' in sys.argv else '/tmp/claude-501/cap'
    c = C(timeout=180); c.init()
    sid = None
    for _ in range(40):
        r = c.req('tools/call', {'name': 'list_roblox_studios', 'arguments': {}})
        try:
            st = json.loads(r['content'][0]['text']).get('studios', [])
        except Exception:
            st = []
        if st:
            sid = st[0].get('studio_id') or st[0].get('id')
            print('STUDIOS', json.dumps(st)[:300])
            break
        time.sleep(0.5)
    if not sid:
        print('NO STUDIO'); return
    k = 0
    for call in calls:
        args = json.loads(json.dumps(call.get('args', {})).replace('{SID}', sid))
        if 'studio_id' not in args: args['studio_id'] = sid
        r = c.req('tools/call', {'name': call['tool'], 'arguments': args})
        for part in r.get('content', []):
            if part.get('type') == 'text': print(part['text'][:4000])
            elif part.get('type') == 'image':
                k += 1; path = f'{img}_{k}.png'
                open(path, 'wb').write(base64.b64decode(part['data'])); print('IMAGE ->', path)
        if r.get('isError'): print('(error)')
    c.p.stdin.close()
main()
