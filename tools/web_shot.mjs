// Web build reference shot at the raid entrance (or a given point), same viewport as the Studio capture.
// Usage: tools/pw1.sh --run node roblox/tools/web_shot.mjs out.png [x z]
import { chromium } from '@playwright/test';
const BASE = process.env.BASE ?? 'http://127.0.0.1:5188';
const out = process.argv[2] ?? '/tmp/claude-501/web.png';
const at = process.argv[3] ? [Number(process.argv[3]), Number(process.argv[4])] : null;
const browser = await chromium.launch({ executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
try {
  const page = await (await browser.newContext({ viewport: { width: 1684, height: 1080 } })).newPage();
  await page.goto(`${BASE}/`);
  await page.waitForFunction(() => !!window.__BLOCKOV__, null, { timeout: 120000 });
  await page.waitForFunction(() => (window.__THREE_GAME_DIAGNOSTICS__?.frame ?? 0) > 5);
  await page.evaluate(async (at) => {
    const B = window.__BLOCKOV__;
    B.profile().flags['visited:Base'] = true;
    await B.deploy('entrance');
    B.weather.force('Sunny');
    B.setClock(8);
    const w = B.world();
    if (at) { w.player.pos.x = at[0]; w.player.pos.z = at[1]; }
    for (const e of w.enemies) { e.pos.x = 5000; e.pos.z = 5000; }
    B.step(60);
    window.__THREE_GAME_TEST_HOOKS__.setState('active-play');
  }, at);
  await page.mouse.move(842, 540);
  await page.waitForTimeout(1500);
  await page.screenshot({ path: out });
  console.log('saved', out);
} finally { await browser.close(); }
