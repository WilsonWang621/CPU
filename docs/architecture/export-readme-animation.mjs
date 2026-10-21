// Export the existing Archify motion scene; do not modify the validated HTML.
// Usage: ARCHIFY_CHROME=/path/to/chrome node docs/architecture/export-readme-animation.mjs
import { spawn, spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const chrome = process.env.ARCHIFY_CHROME;
if (!chrome) throw new Error('Set ARCHIFY_CHROME to a Chrome/Chromium executable.');
const htmlPath = join(directory, 'single-issue-overview.html');
const html = await readFile(htmlPath);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const delivery = JSON.parse(await readFile(join(directory, 'single-issue-overview.delivery.json'), 'utf8'));
if (delivery.status !== 'current' || delivery.artifact.sha256 !== sha256(html)) {
  throw new Error('Archify HTML differs from its delivery receipt; finalize it first.');
}
const work = await mkdtemp(join(tmpdir(), 'single-issue-animation-'));
const browser = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu',
  '--disable-dev-shm-usage', '--no-first-run', '--disable-background-timer-throttling',
  '--remote-debugging-pipe', `--user-data-dir=${join(work, 'profile')}`, 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let nextId = 0;
let buffered = '';
let stderr = '';
const pending = new Map();
browser.stderr.on('data', data => { stderr = (stderr + data).slice(-3000); });
const fail = error => { for (const p of pending.values()) p.reject(error); pending.clear(); };
browser.on('error', fail);
browser.on('exit', code => fail(new Error(`Chromium exited (${code}): ${stderr}`)));
browser.stdio[4].on('data', data => {
  buffered += data.toString();
  let end;
  while ((end = buffered.indexOf('\0')) !== -1) {
    const message = JSON.parse(buffered.slice(0, end));
    buffered = buffered.slice(end + 1);
    if (!message.id) continue;
    const p = pending.get(message.id);
    if (!p) continue;
    pending.delete(message.id);
    if (message.error) p.reject(new Error(JSON.stringify(message.error)));
    else p.resolve(message.result);
  }
});
function cdp(method, params = {}, sessionId) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    browser.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  });
}
const timeout = setTimeout(() => { fail(new Error('Animation export timed out')); browser.kill(); }, 60000);
try {
  const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  await cdp('Page.enable', {}, sessionId);
  await cdp('Page.navigate', { url: pathToFileURL(htmlPath).href }, sessionId);
  const evaluated = await cdp('Runtime.evaluate', {
    expression: `(async () => {
      if (document.readyState !== 'complete') await new Promise(r => window.addEventListener('load', r, { once: true }));
      await document.fonts.ready;
      document.documentElement.setAttribute('data-theme', 'light');
      const blob = await Archify.motion.recordWebm({ duration: 8000, fps: 12 });
      return await new Promise((resolve, reject) => {
        const reader = new FileReader(); reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error); reader.readAsDataURL(blob);
      });
    })()`, awaitPromise: true, returnByValue: true,
  }, sessionId);
  if (evaluated.exceptionDetails) throw new Error(JSON.stringify(evaluated.exceptionDetails));
  const webm = join(work, 'overview.webm');
  await writeFile(webm, Buffer.from(evaluated.result.value.split(',')[1], 'base64'));
  const output = join(directory, 'single-issue-overview.gif');
  const filter = 'fps=10,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle';
  const conversion = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', webm,
    '-filter_complex', filter, '-loop', '0', output], { encoding: 'utf8' });
  if (conversion.status !== 0) throw new Error(conversion.stderr || 'ffmpeg conversion failed');
  const gif = await readFile(output);
  await writeFile(join(directory, 'single-issue-overview.gif.receipt.json'), JSON.stringify({
    source: 'single-issue-overview.html', source_sha256: sha256(html),
    export: 'Archify.motion.recordWebm', duration_ms: 8000, capture_fps: 12,
    gif_fps: 10, gif_loop: 0, gif_sha256: sha256(gif), gif_bytes: gif.length,
    note: '连接方向动画；不是 CPU 周期仿真。GIF 不保留交互。',
  }, null, 2) + '\n');
  console.log(JSON.stringify({ output, bytes: gif.length, sourceUnchanged: true }));
} finally {
  clearTimeout(timeout);
  browser.kill();
  await new Promise(resolve => browser.exitCode !== null ? resolve() : browser.once('exit', resolve));
  await rm(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
}
