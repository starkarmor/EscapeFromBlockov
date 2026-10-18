"""Ground Zero cave sub-scene (web export data/gz_cave.json, tools/export_map.mjs ... cave) -> Roblox.
  src/world/GroundZeroCave.rbxmx: the drawn boxes (rock bands, caps, props) + invisible colliders from the decoded boxes
  (Block flags -> M1 / M27 / M31) + the floor; src/shared/CaveData.luau: bounds, spawn, interacts, spawners, the
  body-blocking boxes for the grid pathfinder (the web's NavGrid: the cave has no decoded navmesh).
  python3 tools/convert_cave.py"""
import json, os, hashlib
from xml.sax.saxutils import escape
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from luastr import luastr
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 3.5
d = json.load(open(os.path.join(ROOT, 'data/gz_cave.json')))

ROLE = {'#5a554d': (0x8A, 0x84, 0x7A), '#4c4842': (0x76, 0x70, 0x67), '#403d38': (0x64, 0x5F, 0x58), '#36332f': (0x54, 0x50, 0x4A),
        '#17191b': (0x3A, 0x3C, 0x44), '#5d6168': (0x6E, 0x72, 0x7C), '#7b6c58': (0xB8, 0x8E, 0x55), '#6b6458': (0x8A, 0x5A, 0x2B),
        '#8a6b44': (0x8A, 0x5A, 0x2B), '#8d8a80': (0xB9, 0xBC, 0xC4)}
ref = [0]
def c3(rgb): return '<Color3 name="Color"><R>%.4f</R><G>%.4f</G><B>%.4f</B></Color3>' % tuple(v / 255 for v in rgb)
def hexrgb(h): h = h.lstrip('#'); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def qmat(q):
    x, y, z, w = q
    return [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]
def cframe(p, R=None):
    R = R or [1, 0, 0, 0, 1, 0, 0, 0, 1]
    return ('<CoordinateFrame name="CFrame"><X>%.3f</X><Y>%.3f</Y><Z>%.3f</Z>' % p + ''.join('<R%d%d>%.5f</R%d%d>' % (i // 3, i % 3, R[i], i // 3, i % 3) for i in range(9)) + '</CoordinateFrame>')
def attrs_xml(attrs):
    import struct, base64
    b = struct.pack('<I', len(attrs))
    for k, v in attrs.items():
        kb = k.encode(); b += struct.pack('<I', len(kb)) + kb
        if isinstance(v, bool): b += bytes([0x03, 1 if v else 0])
        elif isinstance(v, (int, float)): b += bytes([0x06]) + struct.pack('<d', float(v))
        else: vb = str(v).encode(); b += bytes([0x02]) + struct.pack('<I', len(vb)) + vb
    return '<BinaryString name="AttributesSerialize">%s</BinaryString>' % base64.b64encode(b).decode()
def part(name, pos, size, rgb, R=None, collide=True, material=256, transparency=0.0, attrs=None, cast=True, query=True, group='Default'):
    ref[0] += 1
    return ('<Item class="Part" referent="R%d"><Properties><string name="Name">%s</string><bool name="Anchored">true</bool>'
            '<bool name="CanCollide">%s</bool><bool name="CanQuery">%s</bool><bool name="CanTouch">false</bool><bool name="CastShadow">%s</bool>'
            '%s%s<Vector3 name="size"><X>%.3f</X><Y>%.3f</Y><Z>%.3f</Z></Vector3><token name="Material">%d</token>'
            '<float name="Transparency">%.3f</float><token name="TopSurface">0</token><token name="BottomSurface">0</token>'
            '<string name="CollisionGroup">%s</string>%s</Properties></Item>') % (
        ref[0], escape(name), str(collide).lower(), str(query).lower(), str(cast).lower(), cframe(pos, R), c3(rgb),
        size[0], size[1], size[2], material, transparency, group, attrs_xml(attrs) if attrs else '')
def folder(name, children):
    ref[0] += 1
    return '<Item class="Folder" referent="R%d"><Properties><string name="Name">%s</string></Properties>%s</Item>' % (ref[0], escape(name), ''.join(children))

drawn, cols = [], []
seen = set()
for m in d['meshes']:
    g = m['g']
    if g['t'] != 'box':
        continue
    key = (tuple(round(v, 3) for v in m['p']), tuple(round(v, 3) for v in m['s']), json.dumps(g, sort_keys=True))
    if key in seen:
        continue
    seen.add(key)
    col = (m['m'] or {}).get('c') or '#808080'
    rgb = ROLE.get(col, hexrgb(col))
    size = (g['w'] * m['s'][0] * S, g['h'] * m['s'][1] * S, g['d'] * m['s'][2] * S)
    if min(size) < 0.05:
        continue
    p = m['p']
    # a hashed epsilon per piece keeps coplanar faces from z-fighting (as the main map)
    kz = (int(hashlib.md5(('%.3f,%.3f,%.3f' % (p[0], p[1], p[2])).encode()).hexdigest()[:4], 16) % 8) + 1
    eps = 0.0044 * kz
    pos = (p[0] * S, p[1] * S + eps / 2, p[2] * S)
    drawn.append(part('Rock', pos, (size[0] + eps, size[1] + eps, size[2] + eps), rgb, qmat(m['q']), collide=False, query=False, attrs={'Cat': 0}, group='M0'))
# colliders: the decoded boxes with their Block flags (no cat = blocks everything)
for b in d['boxes']:
    if b.get('off'):
        continue
    cat = b.get('cat', 31)
    if not (cat & 1) and not (cat & 2) and not (cat & 4):
        continue
    w, dd = b['maxX'] - b['minX'], b['maxZ'] - b['minZ']
    h = b.get('h', 3)
    y0 = b.get('y0', 0)
    grp = 'M31' if cat & 6 == 6 and cat & 1 else ('M27' if cat & 2 else ('M1' if cat & 1 else 'M4'))
    cols.append(part('Block', ((b['minX'] + w / 2) * S, (y0 + h / 2) * S, (b['minZ'] + dd / 2) * S), (w * S, h * S, dd * S), (0x16, 0x15, 0x1D),
                     collide=bool(cat & 1), transparency=1, attrs={'Cat': cat}, cast=False, group=grp))
B = d['bounds']
cx, cz = (B['minX'] + B['maxX']) / 2, (B['minZ'] + B['maxZ']) / 2
floor = [part('Ground', (cx * S, -1.0, cz * S), ((B['maxX'] - B['minX']) * S, 2.0, (B['maxZ'] - B['minZ']) * S), (0x4A, 0x46, 0x40), material=800, attrs={'Surface': 'rock', 'Cat': 0}, cast=False, group='Ground'),
         part('Void', (cx * S, -1.4, cz * S), ((B['maxX'] - B['minX'] + 300) * S, 2.0, (B['maxZ'] - B['minZ'] + 300) * S), (0x08, 0x09, 0x0A), collide=False, query=False, cast=False)]
world = folder('GroundZeroCave', [folder('Ground', floor), folder('Rocks', drawn), folder('Colliders', cols)])
xml = '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" version="4">' + world + '</roblox>'
open(os.path.join(ROOT, 'src/world/GroundZeroCave.rbxmx'), 'w').write(xml)

def lua(v):
    if v is None: return 'nil'
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, (int, float)): return repr(round(v, 4)) if isinstance(v, float) else str(v)
    if isinstance(v, str): return luastr(v)
    if isinstance(v, list): return '{' + ', '.join(lua(x) for x in v) + '}'
    if isinstance(v, dict): return '{' + ', '.join(('%s = %s' % (k, lua(x)) if k.isidentifier() else '[%s] = %s' % (luastr(k), lua(x))) for k, x in v.items()) + '}'
    return 'nil'
# body-blocking boxes grown later by the grid (NavGrid: Block.body, doors passable)
body = [[round(b['minX'], 3), round(b['minZ'], 3), round(b['maxX'], 3), round(b['maxZ'], 3)] for b in d['boxes'] if not b.get('off') and (b.get('cat', 31) & 1)]
for it in d['interacts']:
    it['id'] = 'cave_' + it['id']  # unique beside the main map's interact ids
md = {'id': 'gz_cave', 'bounds': B, 'spawn': d['spawn'], 'interacts': d['interacts'], 'spawners': d['spawners'], 'body': body}
open(os.path.join(ROOT, 'src/shared/CaveData.luau'), 'w').write('--!nocheck\n-- GENERATED by tools/convert_cave.py from data/gz_cave.json. Do not edit.\nreturn ' + lua(md) + '\n')
print(json.dumps({'drawn': len(drawn), 'colliders': len(cols), 'body_boxes': len(body), 'rbxmx_kb': len(xml) // 1000}))
