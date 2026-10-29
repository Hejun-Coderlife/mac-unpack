/* 逐帧录制 Unpack 介绍视频：无界面 Chrome 打开 index.html?rec=1，按 30 帧/秒调 PROMO.frame(t) 截图，配上 audio.mjs 合成的音乐音效，ffmpeg 合成 MP4
   用法：node record.mjs [输出.mp4]              （默认 ~/Desktop/Unpack介绍视频.mp4）
        node record.mjs --still 秒数 [秒数…]      （只截几张静帧到 /tmp/unpack_秒数.png，调画面用）
   （流程照搬 mac-recorder/promo/record.mjs，直接走 Chrome 调试协议，不用装任何 npm 包） */
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir, homedir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const still = args[0] === '--still' ? args.slice(1) : null;
const OUT = still ? null : (args[0] || join(homedir(), 'Desktop', 'Unpack介绍视频.mp4'));
const W = 1920, H = 1080, FPS = 30;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9336;
const DIR = join(tmpdir(), 'unpack-promo-frames');
rmSync(DIR, { recursive: true, force: true }); mkdirSync(DIR, { recursive: true });

const chrome = spawn(CHROME, ['--headless=new', `--remote-debugging-port=${PORT}`, `--window-size=${W},${H}`, '--hide-scrollbars',
  '--force-device-scale-factor=1', '--allow-file-access-from-files', '--enable-gpu', '--use-angle=metal', '--ignore-gpu-blocklist',
  `--user-data-dir=${join(tmpdir(), 'unpack-promo-chrome')}`,
  pathToFileURL(join(HERE, 'index.html')).href + '?rec=1'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const quit = () => new Promise(r => { chrome.once('exit', r); chrome.kill(); });
let ws;
for (let i = 0; i < 60 && !ws; i++) {
  await sleep(300);
  try { const pg = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find(t => t.type === 'page'); if (pg) ws = new WebSocket(pg.webSocketDebuggerUrl); } catch {}
}
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', e => { const m = JSON.parse(e.data); pending.get(m.id)?.(m); pending.delete(m.id); });
const send = (method, params) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = expr => send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }).then(m => {
  if (m.result?.exceptionDetails) throw new Error(JSON.stringify(m.result.exceptionDetails).slice(0, 500));
  return m.result?.result?.value;
});
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
for (let i = 0; !(await evaluate('!!window.PROMO && document.readyState === "complete"')); i++) {
  if (i > 100) { console.error('页面没加载出来（看看 index.html 有没有报错）'); await quit(); process.exit(1); }
  await sleep(200);
}
await evaluate('document.fonts.ready.then(() => Promise.all([...document.images].map(i => i.decode().catch(() => 0))))');
await sleep(800);   // 等贴图（图标）加载完

const shot = async (t, file) => {
  await evaluate(`PROMO.frame(${t.toFixed(4)}); new Promise(r => requestAnimationFrame(() => r(1)))`);
  const m = await send('Page.captureScreenshot', { format: file.endsWith('.png') ? 'png' : 'jpeg', quality: file.endsWith('.png') ? undefined : 95 });
  writeFileSync(file, Buffer.from(m.result.data, 'base64'));
};
if (still) {
  for (const s of still) await shot(+s, `/tmp/unpack_${s}.png`);
  ws.close(); await quit(); console.log('stills done'); process.exit(0);
}
const end = await evaluate('PROMO.END'), drop = await evaluate('PROMO.drop');
const n = Math.round(end * FPS), t0 = Date.now();
for (let i = 0; i < n; i++) {
  await shot(i / FPS, join(DIR, `f${String(i).padStart(5, '0')}.jpg`));
  if (i % 30 === 0) process.stdout.write(`\r帧 ${i}/${n}  ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}
const events = await evaluate('PROMO.events()'), voice = await evaluate('PROMO.hasVoice ? PROMO.voiceTrack() : []');
const outro = await evaluate('PROMO.scenes.E.start');
ws.close(); await quit();
if (!voice.length) console.log('\n（没有旁白：先跑 node voice.mjs 生成 voice/，这次先出无旁白版）');
const timeline = join(DIR, 'timeline.json'), music = join(DIR, 'music.wav');
// 垫底音乐：MUSIC=音频文件（比如 music-options/A-弦乐拨奏.mp3）；不给就用 music.mp3（选定的那段），都没有就用程序合成的
const bed = process.env.MUSIC || (existsSync(join(HERE, 'music.mp3')) ? join(HERE, 'music.mp3') : undefined);
// 默认不带背景音乐（用户自己在抖音 / 剪辑软件里加）；SYNTH_MUSIC=1 才用程序合成的配乐
const nomusic = !bed && !process.env.SYNTH_MUSIC;
writeFileSync(timeline, JSON.stringify({ end, events, drop, outro, bed, nomusic, duck: voice.map(v => [v.at, v.at + v.dur, .42]) }));
execFileSync('node', [join(HERE, 'audio.mjs'), timeline, music], { stdio: 'inherit' });
console.log('合成视频…');
// 旁白：每句一个 wav（输入从第 2 个起），按时间放好，和音乐混在一起再限幅
const vin = voice.flatMap(v => ['-i', join(HERE, 'voice', `${v.key}.wav`)]);
const filter = voice.map((v, i) => `[${2 + i}]volume=1.5,adelay=${Math.round(v.at * 1000)}:all=1[v${i}]`).join(';') + (voice.length ? ';' : '') +
  `[1]${voice.map((_, i) => `[v${i}]`).join('')}amix=inputs=${voice.length + 1}:normalize=0:duration=first,alimiter=limit=0.9:level=false[a]`;
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', join(DIR, 'f%05d.jpg'), '-i', music, ...vin,
  '-filter_complex', filter, '-map', '0:v', '-map', '[a]', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '16', '-preset', 'slow',
  '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', OUT], { stdio: 'inherit' });
rmSync(DIR, { recursive: true, force: true });
console.log('完成：', OUT);
