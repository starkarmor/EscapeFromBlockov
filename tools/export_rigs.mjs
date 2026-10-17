// Character rigs from the running web build: the player beaver and each Ground Zero enemy kind.
// Each visible box mesh -> {bone index (or -1 = rig root), local CFrame relative to that bone at the bind pose, size, colour}.
// Usage (web repo root): tools/pw1.sh --run node roblox/tools/export_rigs.mjs roblox/data/rigs.json
import { chromium } from '@playwright/test';
import fs from 'node:fs';
const BASE = process.env.BASE ?? 'http://127.0.0.1:5188';
const out = process.argv[2] ?? 'roblox/data/rigs.json';
const KINDS = (process.env.KINDS ?? 'scrapper,scav,brute,scrapper_rifle,wolf').split(',');
const browser = await chromium.launch({ channel: 'chromium' });
try {
  const page = await (await browser.newContext({ viewport: { width: 800, height: 600 } })).newPage();
  page.on('pageerror', (e) => console.error('pageerror', String(e).slice(0, 300)));
  await page.goto(`${BASE}/`);
  await page.waitForFunction(() => !!window.__BLOCKOV__, null, { timeout: 120000 });
  await page.waitForFunction(() => (window.__THREE_GAME_DIAGNOSTICS__?.frame ?? 0) > 5);
  const data = await page.evaluate(async (KINDS) => {
    const B = window.__BLOCKOV__;
    B.profile().flags['visited:Base'] = true;
    await B.deploy('entrance');
    B.step(2);
    const w = B.world();
    const r = (v, k = 4) => +(+v).toFixed(k);
    const dumpRig = (rig, name) => {
      const g = rig.group;
      // reset to the bind pose at the origin, facing +z
      g.position.set(0, 0, 0);
      g.rotation.set(0, 0, 0);
      g.updateMatrixWorld(true);
      const inv = g.matrixWorld.clone().invert();
      const parts = [];
      const V = g.position.constructor;
      const Q = g.quaternion.constructor;
      const p = new V(), s = new V(), q = new Q();
      g.traverse((o) => {
        if (!o.isMesh) return;
        let vis = o.visible;
        for (let a = o.parent; a && a !== g; a = a.parent) if (!a.visible) vis = false;
        const mat = Array.isArray(o.material) ? o.material[0] : o.material;
        if (!vis || (mat && mat.visible === false) || (mat && mat.opacity === 0)) return;
        let bone = null;
        for (let a = o.parent; a; a = a.parent) if (a.userData && a.userData.bone !== undefined) { bone = a; break; }
        const geo = o.geometry; geo.computeBoundingBox();
        const bb = geo.boundingBox;
        const size = [bb.max.x - bb.min.x, bb.max.y - bb.min.y, bb.max.z - bb.min.z];
        const centre = new V((bb.max.x + bb.min.x) / 2, (bb.max.y + bb.min.y) / 2, (bb.max.z + bb.min.z) / 2);
        // model-space matrix of the mesh (centre offset applied), then relative to its bone
        const m = o.matrixWorld.clone().premultiply(inv);
        const cm = new (m.constructor)().makeTranslation(centre.x, centre.y, centre.z);
        m.multiply(cm);
        const rel = bone ? bone.matrixWorld.clone().premultiply(inv).invert().multiply(m) : m;
        rel.decompose(p, q, s);
        parts.push({
          bone: bone ? bone.userData.bone : -1, name: o.name || o.parent?.name || undefined,
          geo: geo.type, size: size.map((x, i) => r(x * [s.x, s.y, s.z][i])),
          p: [r(p.x), r(p.y), r(p.z)], q: [r(q.x, 5), r(q.y, 5), r(q.z, 5), r(q.w, 5)],
          c: mat?.color ? '#' + mat.color.getHexString() : '#ffffff', o: mat?.transparent ? r(mat.opacity, 2) : 1,
          weapon: o === rig.weapon || undefined, head: o === rig.head || undefined,
        });
      });
      // the root scale (enemy kinds scale the skeleton root)
      let rootScale = 1;
      g.traverse((o) => { if (o.userData && o.userData.bone === 0 && o.parent) rootScale = o.parent.scale.x; });
      return { name, parts, rootScale: r(rootScale), skeletal: !!rig.anim };
    };
    const rigs = { player: dumpRig(w.player.rig, 'beaver') };
    const p = w.player;
    for (const k of KINDS) {
      try {
        w.spawnEnemy(k, p.pos.x + 3, p.pos.z + 3, [{ x: p.pos.x + 3, z: p.pos.z + 3 }]);
        const e = w.enemies[w.enemies.length - 1];
        rigs[k] = { ...dumpRig(e.rig, e.def?.name ?? k), def: JSON.parse(JSON.stringify(e.def ?? {}, (key, v) => (typeof v === 'function' || (v && v.isObject3D) ? undefined : v))) };
      } catch (err) { rigs[k] = { error: String(err) }; }
    }
    return rigs;
  }, KINDS);
  fs.writeFileSync(out, JSON.stringify(data));
  console.log(JSON.stringify(Object.fromEntries(Object.entries(data).map(([k, v]) => [k, v.error ?? `${v.parts.length} parts, scale ${v.rootScale}, skeletal ${v.skeletal}`]))));
} finally {
  await browser.close();
}
