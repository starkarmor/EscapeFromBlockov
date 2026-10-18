"""Items, gun feel and Ground Zero loot -> Luau (src/shared/gen/*). Generated from the web build's decoded data:
src/game/gz/gz_items.json, gz_gunfeel.json, gz_loot.json, gz_melee.json. Only items reachable at Ground Zero
(loot tables, enemy drops, the starting kit) are emitted.

  python3 tools/gen_items.py
"""
import json, sys as _sys
_sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from luastr import luastr
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.dirname(ROOT)
GZ = os.path.join(WEB, 'src/game/gz')
OUT = os.path.join(ROOT, 'src/shared/gen')
os.makedirs(OUT, exist_ok=True)

items = {x['id']: x for x in json.load(open(os.path.join(GZ, 'gz_items.json')))}
feel = json.load(open(os.path.join(GZ, 'gz_gunfeel.json')))['guns']
loot = json.load(open(os.path.join(GZ, 'gz_loot.json')))
melee_path = os.path.join(GZ, 'gz_melee.json')
melee = json.load(open(melee_path)) if os.path.exists(melee_path) else {}

def lua(v):
    if v is None: return 'nil'
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, int): return str(v)
    if isinstance(v, float): return repr(round(v, 6))
    if isinstance(v, str): return luastr(v)
    if isinstance(v, list): return '{' + ','.join(lua(x) for x in v) + '}'
    if isinstance(v, dict):
        return '{' + ','.join(('%s=%s' % (k, lua(x)) if k.isidentifier() else '[%s]=%s' % (luastr(k), lua(x))) for k, x in v.items()) + '}'
    return 'nil'

# the Ground Zero map's container tables (the exported interacts carry their table ids)
md = json.load(open(os.path.join(ROOT, 'data/ground_zero.json')))
cave_path = os.path.join(ROOT, 'data/gz_cave.json')
cave_interacts = json.load(open(cave_path))['interacts'] if os.path.exists(cave_path) else []
used_tables = sorted({i.get('table') for i in md['interacts'] + cave_interacts if i.get('kind') == 'container' and i.get('table')})
tables = {}
need = set()
for t in used_tables:
    row = loot['tables'].get(t)
    if not row:
        # the box's own decoded table missing: fall back to its container type
        continue
    tables[t] = row
# the cave's own tables and blueprint items (src/world/gz/cave_spawns.json): inline pools become named pools
cave_spawns_path = os.path.join(WEB, 'src/world/gz/cave_spawns.json')
cave_pools = {}
if os.path.exists(cave_spawns_path):
    cs = json.load(open(cave_spawns_path))
    for x in cs.get('items', []):
        items.setdefault(x['id'], x)
    for tname, row in cs.get('tables', {}).items():
        row = dict(row)
        if isinstance(row.get('pool'), list):
            pid = 'cave_' + tname
            cave_pools[pid] = [[e['id'], e['w']] for e in row['pool'] if e.get('id')]
            row['pool'] = pid if cave_pools[pid] else None
        tables[tname] = row
pools = dict(cave_pools)
for row in list(tables.values()) + list(loot['types'].values()):
    pid = row.get('pool')
    if pid and pid in loot['pools']:
        pools[pid] = loot['pools'][pid]
    for f in row.get('fixed', []):
        need.add(f['id'])
for p in pools.values():
    for iid, _ in p:
        need.add(iid)
# Ground Zero's loose item spawners (data.ts LOOSE_SPAWNERS: draws at distinct points, leftover probability = nothing)
for g in loot.get('loose', []):
    for iid, _ in g['pool']:
        need.add(iid)
bodies = {}
for k in ('scrapper', 'scav', 'brute', 'scrapper_rifle', 'contractor', 'boss', 'wolf', 'bloater', 'drone', 'stormling'):
    if k in loot['bodies']:
        bodies[k] = loot['bodies'][k]
# giant / operator bodies come straight from their presets' drops (gz_presets.json; pool rows [id, weight, typeID])
presets = json.load(open(os.path.join(GZ, 'gz_presets.json')))['presets']
for k, pname in (('giant', 'EnemyPreset_Melee_UltraMan'), ('operator', 'EnemyPreset_USEC_HiddenWareHouse')):
    pr = presets.get(pname)
    if not pr: continue
    drops = []
    for d in pr.get('drops', []):
        pool = [[r[0], r[1]] for r in d.get('pool', []) if r[0] and r[0] in items]
        if not pool: continue
        row = {'chance': d.get('chance', 1), 'count': d.get('count', [1, 1]), 'pool': pool}
        if d.get('fromPool') is False: row['each'] = True
        if d.get('role') in ('weapon', 'gun', 'melee'): row['weapon'] = True
        drops.append(row)
    bodies[k] = {'src': pname, 'cash': [pr.get('hasCashChance', 0), 100, 400] if k == 'operator' else [0, 0, 0], 'drops': drops}
for k in bodies:
    for d in bodies[k]['drops']:
        for iid, _ in d.get('pool', []):
            need.add(iid)
# every hotbar throwable (gz_throw.json rows by item key) and the enemy-only guns
throw_rows = json.load(open(os.path.join(GZ, 'gz_throw.json')))
for iid, it in items.items():
    if it.get('kind') == 'throwable' and it.get('key') in throw_rows['skills']:
        need.add(iid)
need |= {'tt33', 'ammo_s_rusty', 'stick', 'bandage', 'aspirin', 'carrot', 'cocoa', 'pm', 'toz66'}
# ammo for every gun we ship
for iid in list(need):
    f = items.get(iid, {}).get('fire')
    if f and f.get('ammo'):
        need.add(f['ammo'])

KEEP = ('id', 'name', 'kind', 'cat', 'weight', 'value', 'maxStack', 'q', 'color', 'desc', 'typeID')
out_items = {}
for iid in sorted(need):
    it = items.get(iid)
    if not it: continue
    row = {k: it[k] for k in KEEP if k in it}
    for sub in ('fire', 'ammo', 'use', 'melee', 'gear'):
        if sub in it: row[sub] = it[sub]
    out_items[iid] = row
guns = {iid: feel[iid] for iid in out_items if iid in feel}
for gid in ('egun_spider', 'egun_storm', 'egun_ring'):
    if gid in feel: guns[gid] = feel[gid]
throw = {iid: throw_rows['skills'][it['key']] for iid, it in items.items() if iid in out_items and it.get('kind') == 'throwable' and it.get('key') in throw_rows['skills']}

L = ['-- Generated by tools/gen_items.py from src/game/gz (gz_items, gz_gunfeel, gz_loot). Do not edit.', '--!nocheck', 'local M = {}']
L.append('M.items = ' + lua(out_items))
L.append('M.gunFeel = ' + lua(guns))
L.append('M.tables = ' + lua(tables))
L.append('M.types = ' + lua(loot['types']))
L.append('M.pools = ' + lua(pools))
L.append('M.bodies = ' + lua(bodies))
L.append('M.throw = ' + lua(throw))
L.append('M.loose = ' + lua(loot.get('loose', [])))
# gz_holdpose.json muzzle: the gun agent's Muzzle socket (agent frame on the hand socket: x right, y up, z forward)
hold = json.load(open(os.path.join(GZ, 'gz_holdpose.json')))
ENEMY_GUN_KEYS = {'egun_spider': 'Item_EnemyGun_Spider_Rifle', 'egun_storm': 'Item_EGun_AR_Storm_NoGraphic', 'egun_ring': 'Item_EGun_Magic_Ring_Mushroom'}
muzzle = {}
for gid in list(guns):
    key = ENEMY_GUN_KEYS.get(gid) or items.get(gid, {}).get('key')
    if key and key in hold['muzzle']:
        muzzle[gid] = hold['muzzle'][key]
L.append('M.muzzle = ' + lua(muzzle))
L.append('M.holdModels = ' + lua(hold['models']))
L.append('M.throwPhysics = ' + lua(throw_rows['physics']))
# gun attachments (src/game/data.ts GUN_SLOTS / PARTS / partFits; gunFeel part mods: [field, type 0 add / 100 pct / else
# mul, value]) for the guns and parts we ship
attach = json.load(open(os.path.join(GZ, 'gz_attach.json')))
feel_parts = json.load(open(os.path.join(GZ, 'gz_gunfeel.json')))['parts']
L.append('M.gunSlots = ' + lua({g: attach['slots'][g] for g in out_items if g in attach['slots']}))
L.append('M.parts = ' + lua({pid: attach['parts'][pid]['tags'] for pid in out_items if pid in attach['parts']}))
L.append('M.feelParts = ' + lua({pid: feel_parts[pid] for pid in out_items if pid in feel_parts}))
L.append('M.partMods = ' + lua({pid: attach['parts'][pid]['mods'] for pid in out_items if pid in attach['parts']}))
# Inventory.Sort metadata (src/game/inventory.ts sortMeta): Item.order and first tag per typeID, Tag.priority
inv = json.load(open(os.path.join(GZ, 'gz_inventory.json')))
sort_rows = {}
for iid, it in out_items.items():
    t = it.get('typeID')
    m = inv['items'].get(str(t)) if t is not None else None
    sort_rows[iid] = [m[0] if m else 0, m[1] if m else None]
L.append('M.sortMeta = ' + lua(sort_rows))
L.append('M.tagPriority = ' + lua({k: v for k, v in inv['tags'].items() if v}))
L.append('M.basePocketSlots = 10')
L.append('return M')
open(os.path.join(OUT, 'Items.luau'), 'w').write('\n'.join(L) + '\n')
print(json.dumps({'throw': sorted(throw), 'bodies': sorted(bodies), 'items': len(out_items), 'guns': sorted(guns), 'tables': len(tables), 'missing_tables': len(used_tables) - len(tables), 'pools': len(pools)}))
