// Rasterize the web item silhouettes (src/ui/icons.ts SHAPES, viewBox 32) to 64x64 alpha masks in a headless browser.
// Output: roblox/data/icon_masks.json {name: base64 of 64*64 alpha bytes}. Run through tools/pw1.sh --run node ...
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const src = fs.readFileSync(path.join(ROOT, 'src/ui/icons.ts'), 'utf8');
const block = src.slice(src.indexOf('const SHAPES'), src.indexOf('};', src.indexOf('const SHAPES')));
const shapes = {};
for (const m of block.matchAll(/^\s*(\w+):\s*'(.*)',\s*$/gm)) shapes[m[1]] = m[2];
// UI glyphs (viewBox 24): icons.ts GLYPHS (coin ...) and the inventory set (src/ui/invIcons.ts), stored as g_<name>
const glyphs = {};
const gsrc = src.slice(src.indexOf('const GLYPHS'), src.indexOf('};', src.indexOf('const GLYPHS')));
for (const m of gsrc.matchAll(/^\s*(\w+):\s*'(.*)',\s*$/gm)) glyphs[m[1]] = m[2];
const inv = fs.readFileSync(path.join(ROOT, 'src/ui/invIcons.ts'), 'utf8');
for (const m of inv.matchAll(/^\s*(\w+):\s*'(.*)',\s*$/gm)) glyphs[m[1]] = m[2];
// the HUD armor widget's helmet / vest (index.html #arm-head / #arm-body)
const html = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');
for (const id of ['arm-head', 'arm-body']) {
  const m = html.match(new RegExp(`id="${id}"><svg viewBox="0 0 24 24">(.*?)</svg>`));
  if (m) glyphs[id.replace('-', '_')] = m[1];
}
// the HUD status icons (src/systems/Hud.ts STATUS_ICON)
const hud = fs.readFileSync(path.join(ROOT, 'src/systems/Hud.ts'), 'utf8');
const sblock = hud.slice(hud.indexOf('export const STATUS_ICON'), hud.indexOf('};', hud.indexOf('export const STATUS_ICON')));
for (const m of sblock.matchAll(/^\s*(\w+):\s*'(.*)',\s*$/gm)) glyphs['st_' + m[1]] = m[2];
for (const [k, v] of Object.entries(glyphs)) shapes['g_' + k] = { body: v, vb: 24 };
const browser = await chromium.launch({ headless: true, executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium-1223/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' });
const page = await browser.newPage();
const out = await page.evaluate(async (shapes) => {
  const res = {};
  for (const [name, spec] of Object.entries(shapes)) {
    const body = typeof spec === 'string' ? spec : spec.body;
    const vb = typeof spec === 'string' ? 32 : spec.vb;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${vb} ${vb}" width="64" height="64" style="color:#fff;fill:#fff">${body.replaceAll('currentColor', '#fff')}</svg>`;
    const img = new Image();
    img.src = 'data:image/svg+xml;base64,' + btoa(svg);
    await img.decode();
    const c = document.createElement('canvas');
    c.width = 64; c.height = 64;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0, 64, 64);
    const d = g.getImageData(0, 0, 64, 64).data;
    // keep the alpha and the luminance (inner details drawn darker, e.g. fill="#00000055") as two bytes
    let s = '';
    for (let i = 0; i < d.length; i += 4) s += String.fromCharCode(d[i + 3]) + String.fromCharCode(d[i]);
    res[name] = btoa(s);
  }
  return res;
}, shapes);
await browser.close();
fs.writeFileSync(path.join(ROOT, 'roblox/data/icon_masks.json'), JSON.stringify(out));
console.log('shapes', Object.keys(out).length);
