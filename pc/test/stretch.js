// 音程を変えずに遅くする (renderer/js/stretch.js + vendor/rubberband-wasm.js) の確認
//   ・伸ばした長さが 1/速度 倍か ・音の高さ (440Hz) が変わらないか ・クリックの位置が 1/速度 倍の時刻にあるか
'use strict';
const fs = require('fs');
const path = require('path');
const { Streamer, base64ToBytes } = require('../renderer/js/stretch.js');
const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'vendor', 'rubberband-wasm.js'), 'utf8');
const b64 = src.match(/BX_RUBBERBAND_WASM = '([^']+)'/)[1];
const s = new Streamer(base64ToBytes(b64));
const sr = 44100, sec = 4;
const a = new Float32Array(sr * sec), b = new Float32Array(sr * sec);
for (let i = 0; i < a.length; i++) a[i] = b[i] = 0.3 * Math.sin(2 * Math.PI * 440 * i / sr);
for (let t = 0.25; t < sec; t += 0.5) { const k = Math.round(t * sr); for (let j = 0; j < 30; j++) { a[k + j] += 0.9 * (1 - j / 30); b[k + j] += 0.9 * (1 - j / 30); } }
s.load(1, sr, [a, b]);
let ok = true;
for (const [rate, from] of [[0.5, 0], [0.75, 1.1], [0.25, 2]]) {
  s.start(rate, from * sr, true);
  const parts = []; let n = 0;
  for (;;) { const r = s.more(sr / 2); parts.push(r.channels[0]); n += r.channels[0].length; if (r.done || r.channels[0].length === 0) break; }
  const o = new Float32Array(n); let w = 0; for (const p of parts) { o.set(p, w); w += p.length; }
  const lenOk = Math.abs(n / sr - (sec - from) / rate) < 0.5;
  const s0 = Math.round(((Math.ceil((from - 0.25) / 0.5) * 0.5 + 0.25) - from + 0.1) / rate * sr);
  let zc = 0; for (let i = s0 + 1; i < s0 + sr * 0.08; i++) if (o[i - 1] < 0 && o[i] >= 0) zc++;
  const freq = zc / 0.08;
  let click = -1; for (let i = 1; i < o.length; i++) if (Math.abs(o[i]) > 0.75) { click = i / sr; break; }
  const expect = (Math.ceil((from - 0.25) / 0.5) * 0.5 + 0.25 - from) / rate;
  const good = lenOk && Math.abs(freq - 440) < 30 && Math.abs(click - expect) < 0.03;
  console.log((good ? 'OK ' : 'NG ') + 'x' + rate + ' 長さ ' + (n / sr).toFixed(2) + 's / 高さ ' + freq.toFixed(0) + 'Hz / クリック ' + click.toFixed(3) + 's (目安 ' + expect.toFixed(3) + 's)');
  ok = ok && good;
}
if (!ok) { console.error('音程を変えずに遅くする処理がおかしい'); process.exit(1); }
