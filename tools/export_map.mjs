// Deterministic Ground Zero export from the running web build (the port's layout authority).
// Loads a real raid, then dumps the built map: every visual mesh (box / cylinder / cone / sphere, world transform,
// colour), the collision boxes with their Block flags, interacts, spawners, exits, doors, covers, spawn points.
// Usage (from the web repo root): tools/pw1.sh --run node roblox/tools/export_map.mjs roblox/data/ground_zero.json
import { chromium } from '@playwright/test';
import fs from 'node:fs';
const BASE = process.env.BASE ?? 'http://127.0.0.1:5188';
const out = process.argv[2] ?? 'roblox/data/ground_zero.json';
const which = process.argv[3] ?? 'zone'; // 'cave': the Ground Zero cave sub-scene (B.caveMap())
const browser = await chromium.launch({ executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
try {
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 720 } })).newPage();
  page.on('pageerror', (e) => console.error('pageerror', String(e).slice(0, 300)));
  await page.goto(`${BASE}/`);
  await page.waitForFunction(() => !!window.__BLOCKOV__, null, { timeout: 120000 });
  await page.waitForFunction(() => (window.__THREE_GAME_DIAGNOSTICS__?.frame ?? 0) > 5);
  await page.waitForTimeout(1000);
  const data = await page.evaluate(async (which) => {
    const B = window.__BLOCKOV__;
    B.profile().flags['visited:Base'] = true;
    await B.deploy('entrance');
    B.step(5);
    const w = B.world();
    const m = which === 'cave' ? B.caveMap() : w.map;
    const r = (v, k = 3) => +(+v).toFixed(k);
    const meshes = [];
    const T = m.group.position.constructor; // THREE.Vector3
    const pos = new T(), scl = new T();
    const quat = new m.group.quaternion.constructor();
    const geoOf = (g) => {
      const p = g.parameters ?? {};
      switch (g.type) {
        case 'BoxGeometry': return { t: 'box', w: p.width, h: p.height, d: p.depth };
        case 'CylinderGeometry': return { t: p.radiusTop < 1e-3 ? 'cone' : 'cyl', rt: p.radiusTop, rb: p.radiusBottom, h: p.height, seg: p.radialSegments };
        case 'ConeGeometry': return { t: 'cone', rt: 0, rb: p.radius, h: p.height, seg: p.radialSegments };
        case 'SphereGeometry': return { t: 'sphere', r: p.radius };
        case 'PlaneGeometry': return { t: 'plane', w: p.width, h: p.height };
        case 'CircleGeometry': return { t: 'circle', r: p.radius };
        default: g.computeBoundingBox(); { const b = g.boundingBox; return { t: 'other', type: g.type, w: b.max.x - b.min.x, h: b.max.y - b.min.y, d: b.max.z - b.min.z, cx: (b.max.x + b.min.x) / 2, cy: (b.max.y + b.min.y) / 2, cz: (b.max.z + b.min.z) / 2 }; }
      }
    };
    const colOf = (mat) => {
      const M = Array.isArray(mat) ? mat[0] : mat;
      if (!M) return null;
      return { c: M.color ? '#' + M.color.getHexString() : null, e: M.emissive && M.emissive.getHex() ? '#' + M.emissive.getHexString() : null, ei: M.emissiveIntensity ?? 0, o: M.transparent ? r(M.opacity ?? 1, 2) : 1, tex: !!M.map, name: M.name || undefined };
    };
    const tmp = new (m.group.matrixWorld.constructor)();
    m.group.updateMatrixWorld(true);
    m.group.traverse((o) => {
      if (!o.isMesh || !o.visible) return;
      let vis = true;
      for (let p = o; p; p = p.parent) if (!p.visible) vis = false;
      if (!vis) return;
      const g = geoOf(o.geometry);
      const mat = colOf(o.material);
      const name = o.name || o.parent?.name || '';
      const push = (mw) => {
        mw.decompose(pos, quat, scl);
        meshes.push({ g, m: mat, n: name || undefined, p: [r(pos.x), r(pos.y), r(pos.z)], q: [r(quat.x, 5), r(quat.y, 5), r(quat.z, 5), r(quat.w, 5)], s: [r(scl.x), r(scl.y), r(scl.z)] });
      };
      if (o.isInstancedMesh) {
        for (let i = 0; i < o.count; i += 1) { o.getMatrixAt(i, tmp); tmp.premultiply(o.matrixWorld); push(tmp.clone()); }
      } else push(o.matrixWorld.clone());
    });
    const clean = (v, depth = 0) => {
      if (v == null || typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return typeof v === 'number' ? r(v) : v;
      if (depth > 6) return undefined;
      if (Array.isArray(v)) return v.map((x) => clean(x, depth + 1));
      if (typeof v === 'function' || v.isObject3D || v.isMaterial || v.isBufferGeometry) return undefined;
      if (v instanceof Map || v instanceof Set) return undefined;
      const o = {};
      for (const [k, x] of Object.entries(v)) { const c = clean(x, depth + 1); if (c !== undefined) o[k] = c; }
      return o;
    };
    return {
      id: m.id, name: m.name, bounds: clean(m.bounds), spawn: clean(m.spawn), randomSpawns: clean(m.randomSpawns), startSets: clean(m.startSets),
      boxes: clean(m.boxes), foliage: clean(m.foliage), shelters: clean(m.shelters),
      interacts: clean(m.interacts), spawners: clean(m.spawners), exits: clean(m.exits), exitCount: clean(m.exitCount), extractPads: clean(m.extractPads),
      doors: clean(m.doors), covers: clean(m.covers), regions: clean(m.regions), looseRows: clean(m.looseRows), looseSpots: clean(m.looseSpots),
      fishSpots: clean(m.fishSpots), breakableRows: clean(m.breakableRows), source: clean(m.source),
      lights: (m.lights ?? []).map((l) => ({ t: l.type, c: '#' + l.color.getHexString(), i: r(l.intensity), d: r(l.distance ?? 0), p: [r(l.position.x), r(l.position.y), r(l.position.z)] })),
      player: { x: r(w.player.pos.x), z: r(w.player.pos.z) },
      meshes,
    };
  }, which);
  fs.mkdirSync(out.replace(/\/[^/]+$/, ''), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(data));
  const kinds = {};
  for (const x of data.meshes) kinds[x.g.t] = (kinds[x.g.t] ?? 0) + 1;
  console.log(JSON.stringify({ out, map: data.id, meshes: data.meshes.length, kinds, boxes: data.boxes.length, interacts: data.interacts.length, spawners: data.spawners?.length, exits: data.exits?.length, player: data.player }));
} finally {
  await browser.close();
}
