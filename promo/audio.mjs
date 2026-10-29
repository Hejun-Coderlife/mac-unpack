/* 介绍视频的配乐 + 音效，全部用程序算出来（没有现成素材，没有版权问题）
   风格：原声、不要电子味——毛毡钢琴的八分律动（按真实琴弦的泛音、走音和琴槌声来算）、拨弦竖琴琶音（Karplus-Strong 物理拨弦）、
        沙锤、轻柔的低鼓，最后过一个房间混响
   用法：node audio.mjs 时间线.json 输出.wav
   时间线.json = { end, drop（律动进来的时刻）, outro（鼓停、只留钢琴的时刻）, events:[{t,type}], duck:[[开始,结束,压到多少],...]（旁白时段，音乐压低） */
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const [, , IN, OUT] = process.argv;
const { end, events, duck = [], drop = 1.45, outro = end - 4, bed, nomusic } = JSON.parse(readFileSync(IN, 'utf8'));   // nomusic：只要音效（背景音乐用户自己在剪辑软件里加）
const SR = 48000, N = Math.ceil(end * SR);
const L = new Float32Array(N), R = new Float32Array(N);     // 干声
const VL = new Float32Array(N), VR = new Float32Array(N);   // 送混响的
let seed = 11;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1;
const hz = m => 440 * Math.pow(2, (m - 69) / 12);
// 写进干声，同时按比例送一份去混响
const add = (i, v, pan = 0, wet = 0.3) => {
  if (i < 0 || i >= N) return;
  const l = v * (1 - pan), r = v * (1 + pan);
  L[i] += l; R[i] += r; VL[i] += l * wet; VR[i] += r * wet;
};

// ---------------- 乐器 ----------------
// 毛毡钢琴：每个音两根弦（略微走音，产生钢琴特有的拍音），泛音带一点不谐和（弦有硬度），高泛音衰减快，盖了毛毡所以偏暗
function piano(t, m, vel, dur = 1.2, pan = 0) {
  const f0 = hz(m), i0 = Math.floor(t * SR), n = Math.floor((dur + 1.6) * SR);
  const B = 0.00035, parts = [];
  for (let h = 1; h <= 9; h++) {
    const amp = Math.pow(h, -1.9) * (h === 1 ? 1 : 0.8 + vel * 0.6);
    if (h * f0 > 9000) break;
    parts.push({ f: f0 * h * Math.sqrt(1 + B * h * h), amp, dec: 0.5 + 0.45 * h + m * 0.012 });
  }
  const pw = parts.map(() => [rnd() * 3, rnd() * 3]);
  for (let k = 0; k < n; k++) {
    const x = k / SR;
    const rel = x > dur ? Math.exp(-(x - dur) * 7) : 1;
    let v = 0;
    for (let p = 0; p < parts.length; p++) {
      const { f, amp, dec } = parts[p], e = Math.exp(-x * dec) * (0.75 + 0.25 * Math.exp(-x * dec * 4));
      v += amp * e * (Math.sin(2 * Math.PI * f * 0.9997 * x + pw[p][0]) + Math.sin(2 * Math.PI * f * 1.0003 * x + pw[p][1]));
    }
    v *= Math.min(1, x * 2000) * rel * vel * 0.5;
    add(i0 + k, v, pan, 0.35);
  }
  // 琴槌敲弦的那一下（很短的低沉噪声）
  let lp = 0;
  for (let k = 0; k < 0.012 * SR; k++) { lp += (rnd() - lp) * 0.25; add(i0 + k, lp * Math.exp(-k / SR * 400) * vel * 0.08, pan, 0.1); }
}
// 拨弦（Karplus-Strong）：一段噪声在延迟线里来回、每圈平均一次，就是一根被拨的弦，听起来像竖琴 / 尼龙弦
function pluck(t, m, vel, pan = 0, decay = 0.996, len = 1.8, bright = 0.5) {
  const f = hz(m), P = Math.max(2, Math.round(SR / f)), buf = new Float32Array(P);
  let lp = 0;
  for (let k = 0; k < P; k++) { lp += (rnd() - lp) * bright; buf[k] = lp; }
  const i0 = Math.floor(t * SR), n = Math.floor(len * SR);
  let idx = 0;
  for (let k = 0; k < n; k++) {
    const nx = (idx + 1) % P, v = buf[idx];
    buf[idx] = decay * 0.5 * (buf[idx] + buf[nx]);
    idx = nx;
    add(i0 + k, v * vel * Math.min(1, (n - k) / 2000), pan, 0.4);
  }
}
// 沙锤：带通的噪声，起得快收得快
function shaker(t, vel, pan = 0) {
  const i0 = Math.floor(t * SR), n = Math.floor(0.07 * SR); let a = 0, b = 0, prev = 0;
  for (let k = 0; k < n; k++) {
    const s = rnd(); a = 0.9 * (a + s - prev); prev = s; b += (a - b) * 0.55;   // 高通 + 轻微低通
    const x = k / SR, env = Math.min(1, x / 0.008) * Math.exp(-x * 55);
    add(i0 + k, b * env * vel, pan, 0.25);
  }
}
// 低鼓：像蒙了布的大鼓，闷、短，不是电子鼓那种「咚」
function lowDrum(t, vel) {
  const i0 = Math.floor(t * SR), n = Math.floor(0.45 * SR); let ph = 0, lp = 0;
  for (let k = 0; k < n; k++) {
    const x = k / SR, f = 52 + 30 * Math.exp(-x * 25);
    ph += 2 * Math.PI * f / SR; lp += (rnd() - lp) * 0.04;
    add(i0 + k, (Math.sin(ph) * Math.exp(-x * 7) + lp * 2.5 * Math.exp(-x * 30)) * vel, 0, 0.15);
  }
}
// 木质轻响（像指节敲木头）：极短、闷的拨弦
const wood = (t, vel, pan = 0) => pluck(t, 96, vel, pan, 0.9, 0.05, 0.8);

// ---------------- 编曲：104 拍/分，Am(add9) – Fmaj7 – C – G ----------------
const BEAT = 60 / 104, E8 = BEAT / 2, S16 = BEAT / 4, BAR = BEAT * 4;
const PROG = [
  { bass: 45, arp: [57, 64, 71, 72, 76, 72, 71, 64] },   // Am(add9)
  { bass: 41, arp: [57, 60, 64, 65, 69, 65, 64, 60] },   // Fmaj7
  { bass: 48, arp: [55, 60, 64, 67, 72, 67, 64, 60] },   // C
  { bass: 43, arp: [55, 59, 62, 67, 71, 67, 62, 59] },   // G
];
if (nomusic) {
  // 不要背景音乐
} else if (bed) {
  // 垫底音乐用真实录音（bed = 音频文件路径，比如 Apple Loops 拼好的那段）：解码成 48k 立体声，循环铺满整片
  const pcm = execFileSync('ffmpeg', ['-v', 'error', '-i', bed, '-ac', '2', '-ar', String(SR), '-f', 'f32le', '-'], { maxBuffer: 1 << 30 });
  const frames = pcm.length / 8;
  for (let i = 0; i < N; i++) { const j = (i % frames) * 8; L[i] += pcm.readFloatLE(j) * 0.55; R[i] += pcm.readFloatLE(j + 4) * 0.55; }
} else {
// 开场：钢琴单音轻轻重复，像在等什么
  for (let t = 0.05, k = 0; t < drop - 0.05; t += E8, k++) piano(t, k % 4 === 3 ? 71 : 76, 0.32, E8 * 1.6, 0.15);
  piano(0.05, 45, 0.45, drop + 0.5);
  // 主体：钢琴八分律动 + 左手低音 + 竖琴琶音 + 沙锤 + 低鼓
  for (let t0 = drop, s = 0; t0 < outro - 1e-6; t0 += S16, s++) {
    const bar = Math.floor(s / 16), pos = s % 16, ch = PROG[bar % 4];
    if (pos === 0) { piano(t0, ch.bass - 12, 0.7, BAR * 0.95, -0.1); piano(t0, ch.bass, 0.5, BAR * 0.95, -0.1); }
    if (pos % 2 === 0) piano(t0, ch.arp[(pos / 2) % 8], pos % 8 === 0 ? 0.55 : 0.4, E8 * 1.4, 0.2);
    if (pos % 2 === 1 && bar % 2 === 1) pluck(t0, ch.arp[(pos + 3) % 8] + 12, 0.22, pos % 4 === 1 ? 0.5 : -0.5);
    shaker(t0, pos % 4 === 2 ? 0.16 : 0.08, pos % 2 ? 0.3 : -0.3);
    if (pos === 0 || pos === 10) lowDrum(t0, 0.5);
  }
  // 结尾：律动停，一个舒展开的 Am(add9) 琶音收住
  [45, 57, 64, 71, 72, 76].forEach((m, i) => piano(outro + 0.15 + i * 0.12, m, i ? 0.42 : 0.6, end - outro, (i - 2.5) * 0.12));
}

// 旁白时段音乐压低（音效在后面加，不受影响）
const duckAt = x => { let g = 1; for (const [a, b, lv = .45] of duck) { const k = Math.min(1, Math.max(0, Math.min((x - a + .25) / .25, (b + .35 - x) / .35))); g = Math.min(g, 1 - (1 - lv) * k); } return g; };
for (let i = 0; i < N; i++) { const g = duckAt(i / SR); L[i] *= g; R[i] *= g; VL[i] *= g; VR[i] *= g; }

// ---------------- 音效（都用原声的质感）----------------
const sfx = {
  riser(t) {   // 炸开前：沙锤越摇越密越响
    for (let k = 0; k < 14; k++) { const x = k / 14; shaker(t + 0.5 * (1 - Math.pow(1 - x, 1.6)), 0.08 + 0.3 * x, k % 2 ? .3 : -.3); }
  },
  boom(t) { lowDrum(t, 1.1); piano(t, 21, 1, 2.2); piano(t, 33, 0.9, 2.2); piano(t, 40, 0.7, 2.2); },   // 炸开：钢琴最低音区重重一按
  whoosh(t) {  // 空气划过
    const i0 = Math.floor(t * SR), n = Math.floor(.45 * SR); let lp = 0;
    for (let k = 0; k < n; k++) { const x = k / n, a = .02 + .25 * Math.sin(Math.PI * x); lp += (rnd() - lp) * a; add(i0 + k, lp * Math.sin(Math.PI * x) * .16, (x - .5) * .9, 0.3); }
  },
  swipe(t) { sfx.whoosh(t - .1); },
  pop(t) { pluck(t, 84, 0.4, 0, 0.993, 0.9, 0.7); },     // 砖被拉开：竖琴「叮」
  tick(t) { wood(t, 0.35, (rnd()) * .3); },
  ok(t) { piano(t, 88, 0.35, 0.5, .2); piano(t + .08, 93, 0.3, 0.6, -.2); },
  chime(t) { [81, 84, 88, 93].forEach((m, i) => pluck(t + i * .07, m, 0.3, (i - 1.5) * .25, 0.995, 2.5, 0.6)); },
};
// 用真实音乐垫底时，只留不带音高的音效（风声、轻敲、低鼓），合成的钢琴、拨弦音效会和真乐器打架、显出电子味
const KEEP = new Set(['whoosh', 'swipe', 'tick', 'riser']);
for (const e of events) {
  if (!bed && !nomusic) sfx[e.type]?.(e.t);
  else if (KEEP.has(e.type)) sfx[e.type](e.t);
  else if (e.type === 'boom') lowDrum(e.t, 0.9);
}

// ---------------- 房间混响（Schroeder：4 个梳状 + 2 个全通），只处理送过来的那份 ----------------
function reverb(x) {
  const out = new Float32Array(N);
  for (const [d, fb] of [[1687, .82], [1601, .83], [2053, .81], [2251, .80]]) {
    const buf = new Float32Array(d); let i = 0, lp = 0;
    for (let k = 0; k < N; k++) { const y = buf[i]; lp += (y - lp) * 0.45; buf[i] = x[k] + lp * fb; i = (i + 1) % d; out[k] += y * 0.25; }
  }
  for (const d of [541, 241]) {
    const buf = new Float32Array(d); let i = 0;
    for (let k = 0; k < N; k++) { const b = buf[i], y = -out[k] * 0.5 + b; buf[i] = out[k] + b * 0.5; out[k] = y; i = (i + 1) % d; }
  }
  return out;
}
const RL = reverb(VL), RR = reverb(VR);
for (let i = 0; i < N; i++) { L[i] += RL[i] * 0.9; R[i] += RR[i] * 0.9; }

// ---------------- 收尾：柔和限幅、归一、尾部淡出 ----------------
const fade = Math.floor(1.0 * SR);
let peak = 0;
for (let i = 0; i < N; i++) { L[i] = Math.tanh(L[i] * 1.1); R[i] = Math.tanh(R[i] * 1.1); peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i])); }
const g = nomusic ? 0.5 : .89 / peak;   // 只有音效时不放大到满，免得盖过旁白
const buf = Buffer.alloc(44 + N * 4);
buf.write('RIFF', 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write('WAVEfmt ', 8);
buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22); buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28);
buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write('data', 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  const f = i > N - fade ? (N - i) / fade : 1;
  buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i] * g * f)) * 32767), 44 + i * 4);
  buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i] * g * f)) * 32767), 46 + i * 4);
}
writeFileSync(OUT, buf);
console.log('配乐+音效：', OUT, `${end.toFixed(1)}s, ${events.length} 个音效`);
