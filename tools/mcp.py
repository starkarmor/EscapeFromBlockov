"""Scriptable Studio MCP session for tests: from mcp import Studio; s = Studio(); s.call(tool, **args) -> (texts, images)."""
import json, time, base64, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rmcp import C

class Studio:
    def __init__(self):
        self.c = C(timeout=180); self.c.init(); self.sid = None; self.k = 0
        for _ in range(40):
            r = self.c.req('tools/call', {'name': 'list_roblox_studios', 'arguments': {}})
            try: st = json.loads(r['content'][0]['text']).get('studios', [])
            except Exception: st = []
            if st: self.sid = st[0]['id']; break
            time.sleep(0.5)
        assert self.sid, 'no studio'
    def call(self, tool, img=None, **args):
        args.setdefault('studio_id', self.sid)
        r = self.c.req('tools/call', {'name': tool, 'arguments': args})
        texts, imgs = [], []
        for part in r.get('content', []):
            if part.get('type') == 'text': texts.append(part['text'])
            elif part.get('type') == 'image':
                self.k += 1; path = f"{img or '/tmp/claude-501/shot'}_{self.k}.png"
                open(path, 'wb').write(base64.b64decode(part['data'])); imgs.append(path)
        return '\n'.join(texts), imgs
    def lua(self, dm, code):
        return self.call('execute_luau', datamodel_type=dm, code=code)[0]
    def shot(self, name):
        return self.call('screen_capture', img=f'/tmp/claude-501/{name}', capture_id='ScreenCapture_' + name)[1]
    def keys(self, actions):
        return self.call('user_keyboard_input', datamodel_type='Client', actions=actions)[0]
    def mouse(self, actions):
        return self.call('user_mouse_input', datamodel_type='Client', actions=actions)[0]
    def console(self):
        t = self.call('get_console_output')[0]
        return '\n'.join(l for l in t.splitlines() if l.strip() and not any(x in l for x in ('UIBlox', 'Foundation', '203785492', 'CorePackages')))
    def close(self):
        self.c.p.stdin.close()
