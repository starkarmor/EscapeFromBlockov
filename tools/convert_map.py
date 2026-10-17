"""Ground Zero web export -> Roblox model (.rbxmx) for Rojo.

Layout, sizes and collision come 1:1 from data/ground_zero.json (tools/export_map.mjs) and the decoded level grid;
the look is restyled to docs/art-brief.md. 1 m = S studs.

  python3 tools/convert_map.py            -> src/world/GroundZero.rbxmx + src/shared/MapData.luau
"""
import json, sys as _sys
_sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from luastr import luastr
import math, sys, os, hashlib
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.dirname(ROOT)
S = 3.5  # studs per metre (docs/art-brief.md "Units")

d = json.load(open(os.path.join(ROOT, 'data/ground_zero.json')))
level = json.load(open(os.path.join(WEB, 'src/world/levels/ground_zero.json')))
sub = next(s for s in level['subScenes'] if s['id'] == 'Level_GroundZero_1')

# ---------------------------------------------------------------- palette (art brief roles)
P = {
    'meadow': (0x80, 0xDE, 0x25), 'meadow2': (0x68, 0xC9, 0x1F), 'forest': (0x2F, 0x9E, 0x3A), 'forest2': (0x3B, 0xB0, 0x44),
    'river': (0x13, 0xD5, 0xF4), 'river2': (0x07, 0x9B, 0xD7), 'sand': (0xDF, 0xC9, 0x88), 'sand2': (0xD0, 0xBA, 0x78),
    'log': (0x8A, 0x5A, 0x2B), 'bark': (0x5A, 0x3A, 0x1E), 'maple': (0xE8, 0x32, 0x2E), 'coral': (0xF3, 0x45, 0x43),
    'violet': (0x99, 0x38, 0xF2), 'gold': (0xFF, 0xD8, 0x3D), 'concrete': (0xB9, 0xBC, 0xC4), 'concrete2': (0xA4, 0xA8, 0xB2),
    'ink': (0x16, 0x15, 0x1D), 'white': (0xFF, 0xF8, 0xE9), 'asphalt': (0x6E, 0x72, 0x7C), 'mud': (0xB8, 0x8E, 0x55),
    'rock1': (0x9C, 0x9A, 0x94), 'rock2': (0x86, 0x84, 0x7E), 'rock3': (0x74, 0x72, 0x6C), 'rock4': (0x64, 0x62, 0x5D),
    'cap': (0x3A, 0x3C, 0x44), 'bush': (0x4C, 0xC2, 0x3A), 'bush2': (0x3E, 0xAE, 0x30),
}
# web stand-in colour -> (kind, art role). KIND_COLOUR in src/world/LevelMap.ts; rock bands; caps.
WEB_KIND = {
    '#7d776c': ('full', 'concrete'), '#8a8678': ('full', 'concrete2'), '#6f6a62': ('full', 'log'), '#857f72': ('full', 'concrete'), '#77736a': ('full', 'log'),
    '#8f979c': ('wall', 'concrete'), '#9a9c96': ('wall', 'concrete2'), '#7a6a52': ('wall', 'log'), '#8d8a80': ('wall', 'concrete'),
    '#6b6458': ('body', 'log'), '#7b6c58': ('body', 'mud'), '#5d6168': ('body', 'asphalt'), '#8a6b44': ('body', 'log'),
    '#4f6a39': ('fow', 'bush'), '#3f6a34': ('fow', 'bush2'), '#56743f': ('fow', 'bush'),
    '#a08a62': ('cover', 'sand2'), '#8a5a3a': ('cover', 'log'),
    '#5a554d': ('rock', 'rock1'), '#4c4842': ('rock', 'rock2'), '#403d38': ('rock', 'rock3'), '#36332f': ('rock', 'rock4'),
    '#17191b': ('cap', 'cap'),
}
# Block flags (src/utils/geometry.ts Block): body 1, bullet 2, sight 4, grenade 8, obstacle 16
KIND_CAT = {'full': 31, 'wall': 27, 'body': 1, 'fow': 4, 'cover': 27, 'rock': 31, 'cap': 0}

def c3(rgb):
    return '<Color3 name="Color"><R>%.4f</R><G>%.4f</G><B>%.4f</B></Color3>' % tuple(v / 255 for v in rgb)

def hexrgb(h):
    h = h.lstrip('#'); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def qmat(q):
    x, y, z, w = q
    return [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]

def cframe(p, R=None):
    R = R or [1, 0, 0, 0, 1, 0, 0, 0, 1]
    return ('<CoordinateFrame name="CFrame"><X>%.3f</X><Y>%.3f</Y><Z>%.3f</Z>' % p +
            ''.join('<R%d%d>%.5f</R%d%d>' % (i // 3, i % 3, R[i], i // 3, i % 3) for i in range(9)) + '</CoordinateFrame>')

ref = [0]
def part(name, cls, pos, size, rgb, R=None, collide=True, material='Plastic', variant='', transparency=0.0, attrs=None, shape=None, cast=True, query=True, touch=False, group='Default'):
    ref[0] += 1
    mat = {'Plastic': 256, 'SmoothPlastic': 272, 'Neon': 288, 'Glass': 1568, 'Wood': 512, 'Slate': 800, 'Concrete': 816}[material]
    a = ''
    if attrs:
        a = attrs_xml(attrs)
    shp = '<token name="shape">%d</token>' % shape if shape is not None else ''
    return ('<Item class="%s" referent="R%d"><Properties><string name="Name">%s</string><bool name="Anchored">true</bool>'
            '<bool name="CanCollide">%s</bool><bool name="CanQuery">%s</bool><bool name="CanTouch">%s</bool><bool name="CastShadow">%s</bool>'
            '%s%s<Vector3 name="size"><X>%.3f</X><Y>%.3f</Y><Z>%.3f</Z></Vector3><token name="Material">%d</token>'
            '<string name="MaterialVariantSerialized">%s</string><float name="Transparency">%.3f</float>'
            '<token name="TopSurface">0</token><token name="BottomSurface">0</token><string name="CollisionGroup">%s</string>%s%s</Properties></Item>') % (
        cls, ref[0], escape(name), str(collide).lower(), str(query).lower(), str(touch).lower(), str(cast).lower(),
        cframe(pos, R), c3(rgb), size[0], size[1], size[2], mat, variant, transparency, group, shp, a)

def attrs_xml(attrs):
    # Roblox attribute binary blob (AttributesSerialize): u32 count, then (string key, u8 type, value)
    import struct, base64
    b = struct.pack('<I', len(attrs))
    for k, v in attrs.items():
        kb = k.encode(); b += struct.pack('<I', len(kb)) + kb
        if isinstance(v, bool):
            b += bytes([0x03, 1 if v else 0])
        elif isinstance(v, (int, float)):
            b += bytes([0x06]) + struct.pack('<d', float(v))
        else:
            vb = str(v).encode(); b += bytes([0x02]) + struct.pack('<I', len(vb)) + vb
    return '<BinaryString name="AttributesSerialize">%s</BinaryString>' % base64.b64encode(b).decode()

def model(name, children, attrs=None):
    ref[0] += 1
    return ('<Item class="Model" referent="R%d"><Properties><string name="Name">%s</string>%s</Properties>%s</Item>' %
            (ref[0], escape(name), attrs_xml(attrs) if attrs else '', ''.join(children)))

def folder(name, children):
    ref[0] += 1
    return '<Item class="Folder" referent="R%d"><Properties><string name="Name">%s</string></Properties>%s</Item>' % (ref[0], escape(name), ''.join(children))

def sp(v):  # metres -> studs
    return v * S

# ---------------------------------------------------------------- ground from the decoded grid
def unrle(s, n):
    out = bytearray(n); o = 0; i = 0
    while i < len(s) and o < n:
        c = ord(s[i]); end = s.index('|', i + 1); ln = int(s[i + 1:end], 36)
        out[o:min(n, o + ln)] = bytes([c]) * (min(n, o + ln) - o); o += ln; i = end + 1
    return out

g = sub['grid']; W, H, cell = g['width'], g['height'], g['cell']; ox, oz = g['origin']
n = W * H
cls = [v - 48 for v in unrle(g['data'], n)]
splat = [255 if v == 46 else v - 48 for v in unrle(g['splat'], n)] if g.get('splat') else [255] * n
layers = g.get('splatLayers', [])
ROCK, FLOOR, WATER, LEDGE, PROP = 0, 1, 2, 3, 4
# ground class per coarse tile (K x K cells): majority of non-rock cells
K = 4  # 2 m tiles
TW, TH = (W + K - 1) // K, (H + K - 1) // K
def surface_of(i):
    k = cls[i]
    if k == WATER: return 'water'
    if k == ROCK: return 'rock'
    s = splat[i]
    name = layers[s] if s != 255 and s < len(layers) else ''
    if 'Asphalt' in name: return 'asphalt'
    if 'Mud' in name: return 'mud'
    return 'grass'
tiles = [None] * (TW * TH)
for ty in range(TH):
    for tx in range(TW):
        cnt = {}
        for y in range(ty * K, min(H, ty * K + K)):
            for x in range(tx * K, min(W, tx * K + K)):
                s = surface_of(y * W + x)
                cnt[s] = cnt.get(s, 0) + 1
        best = max(cnt.items(), key=lambda kv: kv[1])[0]
        if best == 'rock' and len(cnt) > 1:
            best = max(((k, v) for k, v in cnt.items() if k != 'rock'), key=lambda kv: kv[1])[0]
        tiles[ty * TW + tx] = best
# greedy rectangles per surface
used = [False] * (TW * TH)
rects = []
for ty in range(TH):
    for tx in range(TW):
        i = ty * TW + tx
        if used[i]: continue
        s = tiles[i]
        w = 1
        while tx + w < TW and not used[i + w] and tiles[i + w] == s: w += 1
        h = 1
        while ty + h < TH and all(not used[(ty + h) * TW + tx + k] and tiles[(ty + h) * TW + tx + k] == s for k in range(w)): h += 1
        for yy in range(ty, ty + h):
            for xx in range(tx, tx + w): used[yy * TW + xx] = True
        rects.append((s, tx, ty, w, h))
SURF = {'grass': ('meadow', 'meadow2'), 'mud': ('sand', 'sand2'), 'asphalt': ('asphalt', 'asphalt'), 'water': ('river', 'river2'), 'rock': ('rock3', 'rock3')}
ground = []
GROUND_T = 2.0  # studs thick, top at y = 0
for s, tx, ty, w, h in rects:
    x0 = ox + tx * K * cell; z0 = oz + ty * K * cell
    ww = min(w * K, W - tx * K) * cell; hh = min(h * K, H - ty * K) * cell
    cx, cz = x0 + ww / 2, z0 + hh / 2
    a, b = SURF[s]
    rgb = P[a] if ((tx + ty) % 2 == 0) else P[b]
    if s == 'water':
        ground.append(part('Water', 'Part', (sp(cx), -0.15 * S - GROUND_T / 2, sp(cz)), (sp(ww), GROUND_T, sp(hh)), P['river'],
                           material='SmoothPlastic', transparency=0.1, attrs={'Surface': 'water', 'Cat': 0}, cast=False, group='Ground'))
    else:
        ground.append(part('Ground', 'Part', (sp(cx), -GROUND_T / 2, sp(cz)), (sp(ww), GROUND_T, sp(hh)), rgb,
                           variant='CanuckStuds' if s in ('grass', 'mud') else '', attrs={'Surface': s, 'Cat': 0}, cast=False, group='Ground'))
# apron beyond the playable bounds
bx0, bx1, bz0, bz1 = ox, ox + W * cell, oz, oz + H * cell
ground.append(part('Apron', 'Part', (sp((bx0 + bx1) / 2), -GROUND_T / 2 - 0.2, sp((bz0 + bz1) / 2)), (sp(bx1 - bx0 + 300), GROUND_T, sp(bz1 - bz0 + 300)), P['forest'], collide=False, query=False, cast=False))


# ---------------------------------------------------------------- body colliders from the grid (LevelMap.ts "body colliders")
# rock cells: 6 m boxes (rcat flags; greedy per flag); water / ledge cells: 0.3 m, bodies only. Invisible.
rcat = [v - 48 for v in unrle(g['rcat'], n)] if g.get('rcat') else [31] * n
def greedy_cells(pred):
    seen = bytearray(n); out = []
    for z in range(H):
        row = z * W
        for x in range(W):
            i = row + x
            if seen[i] or not pred(i): continue
            k = pred(i)
            w = 1
            while x + w < W and not seen[i + w] and pred(i + w) == k: w += 1
            h = 1
            while z + h < H and all(not seen[(z + h) * W + x + j] and pred((z + h) * W + x + j) == k for j in range(w)): h += 1
            for zz in range(z, z + h):
                seen[zz * W + x: zz * W + x + w] = b'\x01' * w
            out.append((k, x, z, w, h))
    return out
colliders = []
def rock_key(i):
    return (rcat[i] or 31) if cls[i] == ROCK else 0
def low_key(i):
    return 1 if cls[i] in (WATER, LEDGE) else 0
for key_fn, height in ((rock_key, 6.0), (low_key, 0.3)):
    for k, x, z, w, h in greedy_cells(key_fn):
        cx = ox + (x + w / 2) * cell; cz = oz + (z + h / 2) * cell
        colliders.append(part('Block', 'Part', (sp(cx), sp(height) / 2, sp(cz)), (sp(w * cell), sp(height), sp(h * cell)), P['ink'],
                              collide=bool(k & 1), transparency=1, attrs={'Cat': k}, cast=False, group='M%d' % k))
# map edge walls
for cx, cz, ww, dd in ((bx0 - 2, (bz0 + bz1) / 2, 4, bz1 - bz0 + 8), (bx1 + 2, (bz0 + bz1) / 2, 4, bz1 - bz0 + 8),
                       ((bx0 + bx1) / 2, bz0 - 2, bx1 - bx0 + 8, 4), ((bx0 + bx1) / 2, bz1 + 2, bx1 - bx0 + 8, 4)):
    colliders.append(part('Edge', 'Part', (sp(cx), sp(3), sp(cz)), (sp(ww), sp(6), sp(dd)), P['ink'], transparency=1, attrs={'Cat': 31}, cast=False, group='M31'))

# ---------------------------------------------------------------- props from the web export
props, rocks, caps, bushes = [], [], [], []
counts = {}
for m in d['meshes']:
    t = m['g']['t']
    if t not in ('box', 'cyl'): continue
    col = (m['m'] or {}).get('c')
    kind, role = WEB_KIND.get(col, ('prop', None))
    q = m['q']; s = m['s']; p = m['p']; G = m['g']
    R = qmat(q)
    if t == 'box':
        size = (sp(G['w'] * s[0]), sp(G['h'] * s[1]), sp(G['d'] * s[2]))
    else:
        rr = max(G['rt'], G['rb'])
        size = (sp(G['h'] * s[1]), sp(2 * rr * s[0]), sp(2 * rr * s[2]))
        # Roblox cylinders run along X: rotate the local frame so X follows the web's Y axis
        R = [R[1], -R[0], R[2], R[4], -R[3], R[5], R[7], -R[6], R[8]]
    if min(size) < 0.05: continue
    if kind == 'prop':
        rgb = hexrgb(col) if col else P['white']
        emis = (m['m'] or {}).get('e')
        mat = 'Neon' if emis else 'Plastic'
        rgb = P['gold'] if col == '#e0b84c' else P['violet'] if col == '#46e08c' else P['maple'] if col in ('#c8322a', '#9c3b2a') else rgb
        cat = 31
    else:
        rgb = P[role]; mat = 'Plastic'; cat = KIND_CAT[kind]
    counts[kind] = counts.get(kind, 0) + 1
    pos = (sp(p[0]), sp(p[1]), sp(p[2]))
    hTop = p[1] + size[1] / S / 2; base = p[1] - size[1] / S / 2
    if kind == 'rock':
        cat = 31  # drawn; the grid rects collide
    if hTop <= 0.25 or base >= 1.0:
        cat &= ~1
    collide = bool(cat & 1) and kind != 'rock'
    a = {'Cat': cat, 'Kind': kind}
    pt = part(kind.capitalize(), 'Part', pos, size, rgb, R, collide=collide, material=mat, attrs=a,
              shape=2 if t == 'cyl' else None, query=cat != 0 and kind != 'rock', cast=kind not in ('cap',), group='M%d' % (cat if kind != 'rock' else 0))
    (rocks if kind == 'rock' else caps if kind == 'cap' else bushes if kind == 'fow' else props).append(pt)

# ---------------------------------------------------------------- toy pines (terrain trees)
trees = []
for m in d['meshes']:
    if m['g']['t'] != 'other': continue
    p = m['p']; sc = m['s'][1] * (m['g']['h'] / 4.65)
    x, z = sp(p[0]), sp(p[2])
    h = 4.65 * sc
    yaw = 2 * math.atan2(m['q'][1], m['q'][3])
    cy, sy = math.cos(yaw), math.sin(yaw)
    R = [cy, 0, sy, 0, 1, 0, -sy, 0, cy]
    hsh = int(hashlib.md5(('%.2f%.2f' % (x, z)).encode()).hexdigest()[:4], 16)
    green = P['forest'] if hsh % 2 else P['forest2']
    kids = [part('Trunk', 'Part', (x, sp(0.6 * sc), z), (sp(0.5 * sc), sp(1.2 * sc), sp(0.5 * sc)), P['bark'], R, attrs={'Cat': 27, 'Kind': 'tree'}, group='M27')]
    for k, (y0, w0, hh) in enumerate([(1.0, 2.8, 1.3), (2.1, 2.1, 1.2), (3.1, 1.3, 1.1)]):
        kids.append(part('Leaves', 'Part', (x, sp((y0 + hh / 2) * sc), z), (sp(w0 * sc), sp(hh * sc), sp(w0 * sc)), green, R,
                         collide=False, query=False, attrs={'Cat': 0, 'Kind': 'leaves'}, variant='CanuckStuds', group='M0'))
    trees.append(model('Pine', kids))

world = folder('GroundZero', [folder('Ground', ground), folder('Colliders', colliders), folder('Rocks', rocks), folder('Props', props), folder('Bushes', bushes), folder('Caps', caps), folder('Trees', trees)])
xml = '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" version="4">' + world + '</roblox>'
os.makedirs(os.path.join(ROOT, 'src/world'), exist_ok=True)
open(os.path.join(ROOT, 'src/world/GroundZero.rbxmx'), 'w').write(xml)

# ---------------------------------------------------------------- gameplay data module (metres; the game converts)
def lua(v, ind=0):
    if v is None: return 'nil'
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, (int, float)): return repr(round(v, 3)) if isinstance(v, float) else str(v)
    if isinstance(v, str): return luastr(v)
    if isinstance(v, list): return '{' + ', '.join(lua(x, ind) for x in v) + '}'
    if isinstance(v, dict):
        return '{' + ', '.join(('%s = %s' % (k, lua(x, ind)) if k.isidentifier() else '[%s] = %s' % (luastr(k), lua(x, ind))) for k, x in v.items()) + '}'
    return 'nil'
md = {k: d.get(k) for k in ('id', 'name', 'bounds', 'spawn', 'randomSpawns', 'startSets', 'interacts', 'spawners', 'exits', 'exitCount', 'extractPads', 'doors', 'covers', 'regions', 'looseRows', 'looseSpots', 'player')}
open(os.path.join(ROOT, 'src/shared/MapData.luau'), 'w').write(
    '-- Generated by tools/convert_map.py from the web build export. Metres, web frame (x, z). Do not edit.\n'
    '--!nocheck\nreturn ' + lua(md) + '\n')
print(json.dumps({'ground_rects': len(rects), 'props': counts, 'trees': len(trees), 'parts_total': ref[0], 'colliders': len(colliders),
                  'rbxmx_mb': round(len(xml) / 1e6, 1)}))
