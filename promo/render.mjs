// 逐帧渲染 index.html → 视频（无声）+ 导出音效提示表 cues.json
// 用法：node render.mjs [--portrait] <out.mp4> [fps]    或  node render.mjs --stills 3,15,23 <dir>
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const { chromium } = createRequire(import.meta.url)('playwright'); // 全局安装时配合 NODE_PATH
const here = path.dirname(fileURLToPath(import.meta.url));
const ffmpeg = process.env.FFMPEG || 'ffmpeg';
const argv = process.argv.slice(2);
const portrait = argv.includes('--portrait');
const args = argv.filter(a => a !== '--portrait');

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: portrait ? { width: 1080, height: 1920 } : { width: 1920, height: 1080 } });
// 字体请求交给 Node 去取：在走 HTTPS 代理的环境里无头 Chromium 可能不认代理证书，
// 取不到时 Google Fonts 会静默回退成系统字体。（有代理时用 NODE_USE_ENV_PROXY=1 运行）
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36';
const fontFailures = [];
await page.route(/^https:\/\/fonts\.(googleapis|gstatic)\.com\//, async route => {
  try {
    const r = await fetch(route.request().url(), { headers: { 'user-agent': UA } });
    await route.fulfill({ status: r.status, headers: { 'content-type': r.headers.get('content-type') || '', 'access-control-allow-origin': '*' }, body: Buffer.from(await r.arrayBuffer()) });
  } catch (e) { fontFailures.push(route.request().url()); await route.abort(); }
});
await page.goto('file://' + path.join(here, 'index.html') + (portrait ? '?portrait' : ''));
await page.evaluate(() => window.ready);
if (fontFailures.length) throw new Error(`字体下载失败 ${fontFailures.length} 个：${fontFailures[0]}`);
const fontsOk = await page.evaluate(() => [...document.fonts].filter(f => f.status === 'loaded').map(f => f.family));
if (!new Set(fontsOk).has('Noto Serif SC')) throw new Error('字体没加载上：' + [...new Set(fontsOk)].join(', '));
const meta = await page.evaluate(() => ({ dur: window.DUR, cues: window.CUES, marks: window.MARKS }));
writeFileSync(path.join(here, 'cues.json'), JSON.stringify(meta, null, 1));

if (args[0] === '--stills') {
  for (const t of args[1].split(',').map(Number)) {
    await page.evaluate(t => window.seek(t), t);
    await page.screenshot({ path: path.join(args[2], `still-${t}.png`) });
  }
} else {
  const out = args[0], fps = Number(args[1] || 30);
  const n = Math.round(meta.dur * fps);
  const ff = spawn(ffmpeg, ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.seek(t), i / fps);
    const buf = await page.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 150 === 0) console.log(`frame ${i}/${n}`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
await browser.close();
