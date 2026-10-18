// Web camera probe: deploy, then for each player point and cursor NDC, step 120 frames and read the camera pose.
// Usage: tools/pw1.sh --run node roblox/tools/web_camprobe.mjs > out.json
import { chromium } from '@playwright/test';
const BASE = process.env.BASE ?? 'http://127.0.0.1:5188';
const browser = await chromium.launch({ executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
try {
  const page = await (await browser.newContext({ viewport: { width: 1684, height: 1080 } })).newPage();
  await page.goto(`${BASE}/`);
  await page.waitForFunction(() => !!window.__BLOCKOV__, null, { timeout: 120000 });
  await page.waitForFunction(() => (window.__THREE_GAME_DIAGNOSTICS__?.frame ?? 0) > 5);
  const res = await page.evaluate(async () => {
    const B = window.__BLOCKOV__;
    B.profile().flags['visited:Base'] = true;
    await B.deploy('entrance');
    for (let i = 0; i < 200 && !(B.world() && B.state() === 'zone'); i += 1) { B.step(5); await new Promise((r) => setTimeout(r, 50)); }
    const w = B.world();
    for (const e of w.enemies) { e.pos.x = 5000; e.pos.z = 5000; }
    const pts = [[126.72, 137.38], [82.6, 82.68], [-60.5, 129.1], [9.26, -28.45], [138.86, 6.1], [-6.0, 40.0]];
    const ndcs = [[0, 0], [0.5, -0.4], [-0.6, 0.5]];
    const out = [];
    for (const [x, z] of pts) {
      for (const [nx, ny] of ndcs) {
        w.player.pos.x = x; w.player.pos.z = z;
        if (w.player.vel) { w.player.vel.x = 0; w.player.vel.z = 0; }
        B.input.setCursorNdc(nx, ny);
        B.step(240);
        w.player.pos.x = x; w.player.pos.z = z;
        B.step(1);
        const c = B.camera;
        c.updateMatrixWorld();
        const d = c.getWorldDirection(new c.position.constructor());
        out.push({ x, z, nx, ny, cam: [c.position.x, c.position.y, c.position.z], dir: [d.x, d.y, d.z], fov: c.fov, aspect: c.aspect, px: w.player.pos.x, pz: w.player.pos.z });
      }
    }
    return out;
  });
  console.log(JSON.stringify(res));
} finally { await browser.close(); }
