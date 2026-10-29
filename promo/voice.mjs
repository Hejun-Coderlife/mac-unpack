/* 旁白：每句合成一个 wav，量出时长，写 voice/voice.js（网页按时长排每段画面、出字幕）
   用法：node voice.mjs                 微软云希（男声）（uvx edge-tts，要联网；连不上会自动走本机代理 7897 重试）
        ONLY=c,d node voice.mjs         只重做某几句
        ENGINE=say node voice.mjs       用 macOS 自带语音（Tingting，机器人味重，只在 edge 用不了时临时顶一下）
   （照搬 mac-recorder/promo/voice.mjs 的做法）
   scene = 哪一段画面说；at = 从该段开头第几秒开始说；spoken = 实际念的（和字幕不一样时才写） */
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIR = join(HERE, 'voice');
const EDGE = process.env.ENGINE !== 'say';
const VOICE = process.env.VOICE || (EDGE ? 'zh-CN-YunxiNeural' : 'Tingting');   // 男声云希（用户要男声；云扬 YunyangNeural 偏新闻播音腔）
const RATE = process.env.RATE || (EDGE ? '+4%' : '190');

export const LINES = [
  { key: 'a', scene: 'V', at: .3, text: '我自己做了个 Mac 解压软件，压缩包拖进来，就解开。' },
  { key: 'b', scene: 'T', at: .2, text: 'zip、7z、rar，分卷包、加密包，都能解。', spoken: 'zip、七z、rar，分卷包、加密包，都能解。' },
  { key: 'c', scene: 'P', at: .3, text: '加密包？存过的密码，它会自动帮你试。' },
  { key: 'd', scene: 'G', at: .25, text: 'Windows 打包的中文乱码，也能自动修好。' },
  { key: 'e', scene: 'L', at: .25, text: '解完放回原处，多余的垃圾文件，顺手清掉。' },
  { key: 'f', scene: 'E', at: .45, text: 'Unpack。Mac 上解压，就该这么简单。' },
];

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const ONLY = process.env.ONLY?.split(',');
  let old = [];
  if (ONLY && existsSync(join(DIR, 'voice.js'))) { globalThis.window = {}; await import(join(DIR, 'voice.js') + `?${Date.now()}`); old = window.VOICE; }
  else { rmSync(DIR, { recursive: true, force: true }); mkdirSync(DIR, { recursive: true }); }
  const out = [];
  for (const l of LINES) {
    const prev = old.find(o => o.key === l.key);
    if (ONLY && !ONLY.includes(l.key) && prev) { out.push({ ...prev, scene: l.scene, at: l.at, text: l.text }); console.log(l.key, '沿用'); continue; }
    const raw = join(DIR, `${l.key}.${EDGE ? 'mp3' : 'aiff'}`), wav = join(DIR, `${l.key}.wav`);
    if (EDGE) {
      for (let i = 0; ; i++) {
        try {
          execFileSync('uvx', ['edge-tts', '--voice', VOICE, `--rate=${RATE}`, '--text', l.spoken || l.text, '--write-media', raw,
            ...(i ? ['--proxy', 'http://127.0.0.1:7897'] : [])], { stdio: ['ignore', 'ignore', 'pipe'] });
          break;
        } catch (e) {
          if (i === 3) throw e;
          console.log(`  ${l.key} 连接失败，重试（${i + 1}）…`);
          execFileSync('sleep', ['2']);
        }
      }
    } else execFileSync('say', ['-v', VOICE, '-r', RATE, '-o', raw, l.spoken || l.text]);
    // 转 48k 立体声，去掉首尾静音，时长才准
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', raw, '-af',
      'silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse',
      '-ar', '48000', '-ac', '2', wav]);
    rmSync(raw);
    const dur = +execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', wav]).toString().trim();
    out.push({ key: l.key, scene: l.scene, at: l.at, text: l.text, dur: +dur.toFixed(3) });
    console.log(l.key, dur.toFixed(2) + 's', l.text);
  }
  writeFileSync(join(DIR, 'voice.js'), `// voice.mjs 生成（${VOICE}，语速 ${RATE}）\nwindow.VOICE = ${JSON.stringify(out, null, 1)};\n`);
  console.log('写好了 voice/voice.js，接着跑 node record.mjs 出片');
}
