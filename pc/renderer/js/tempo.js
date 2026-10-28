// BPM・offset の自動検出 (iPad 版 BeatrixTempoDetect.swift をそのまま移したもの)
//   1. 曲 (最大 6 分) を 1 本 (モノラル) にする
//   2. 音の立ち上がりの強さ (スペクトルフラックス。窓 512) を 128 サンプルごとに求める
//   3. BPM: いろいろな BPM の「拍の波」(と 2〜4 倍の波) を当てて、いちばん合うものを探す (0.25 刻み → 0.01 → 0.001)。倍・半分も候補に出す
//   4. offset: 選んだ BPM の拍の位置を、曲の最初の 30 秒で合わせる。0 拍目は「音が鳴り始めたところにいちばん近い拍」
//   5. BPM 変化: 15 秒ずつ見て、ずれていそうな所を知らせるだけ (自動では入れない)
// 重い計算は Web Worker の中で行う (画面が固まらないように)。このファイルは Worker でも画面側でも読む
(function (root) {
  'use strict';
  const FFT = 512, HOP = 128, MAX_SEC = 360;

  // ---- FFT (実数 512 点。基数 2) ----
  const fftTables = (() => {
    const n = FFT, cos = new Float64Array(n / 2), sin = new Float64Array(n / 2), rev = new Uint32Array(n);
    for (let i = 0; i < n / 2; i++) { cos[i] = Math.cos(2 * Math.PI * i / n); sin[i] = -Math.sin(2 * Math.PI * i / n); }
    const bits = Math.log2(n);
    for (let i = 0; i < n; i++) { let r = 0; for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b); rev[i] = r; }
    return { cos, sin, rev };
  })();
  function fftPower(input, re, im, out) {
    const n = FFT, { cos, sin, rev } = fftTables;
    for (let i = 0; i < n; i++) { re[rev[i]] = input[i]; im[rev[i]] = 0; }
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1, step = n / size;
      for (let i = 0; i < n; i += size) {
        for (let j = 0, k = 0; j < half; j++, k += step) {
          const a = i + j, b = a + half;
          const tr = re[b] * cos[k] - im[b] * sin[k];
          const ti = re[b] * sin[k] + im[b] * cos[k];
          re[b] = re[a] - tr; im[b] = im[a] - ti;
          re[a] += tr; im[a] += ti;
        }
      }
    }
    for (let k = 0; k < n / 2; k++) out[k] = re[k] * re[k] + im[k] * im[k];
  }

  function onsetStrength(x) {
    const n = FFT, half = n / 2;
    const frames = Math.floor((x.length - n) / HOP) + 1;
    if (frames <= 10) return { flux: new Float64Array(0), energy: new Float64Array(0) };
    const win = new Float64Array(n);
    for (let i = 0; i < n; i++) win[i] = 0.5 * (1 - Math.cos(2 * Math.PI * i / n));     // Hann
    const buf = new Float64Array(n), re = new Float64Array(n), im = new Float64Array(n), pw = new Float64Array(half);
    let prev = new Float64Array(half), cur = new Float64Array(half);
    const flux = new Float64Array(frames), energy = new Float64Array(frames);
    // vDSP の FFT (zrip) は値が 2 倍で出るので、その分をそろえる (対数で圧縮する前の大きさに効くため)
    const scale = 2;
    for (let f = 0; f < frames; f++) {
      const start = f * HOP;
      let e = 0;
      for (let i = 0; i < n; i++) { const v = x[start + i]; e += v * v; buf[i] = v * win[i]; }
      energy[f] = e;
      fftPower(buf, re, im, pw);
      let s = 0;
      for (let k = 1; k < half; k++) {
        const v = Math.log1p(10 * Math.sqrt(pw[k]) * scale);
        cur[k] = v;
        const d = v - prev[k];
        if (d > 0) s += d;
      }
      flux[f] = f === 0 ? 0 : s;
      const t = prev; prev = cur; cur = t;
    }
    return { flux, energy };
  }

  function postProcess(flux, frameRate) {
    const n = flux.length;
    const w = Math.max(1, Math.floor(0.1 * frameRate));
    const cum = new Float64Array(n + 1);
    for (let i = 0; i < n; i++) cum[i + 1] = cum[i] + flux[i];
    const out = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const a = Math.max(0, i - w), b = Math.min(n, i + w + 1);
      out[i] = Math.max(0, flux[i] - (cum[b] - cum[a]) / (b - a));
    }
    return out;
  }

  function beatPhasor(seg, s0, s1, frameRate, bpm, firstFrame) {
    const w = 2 * Math.PI * (bpm / 60) / frameRate;
    const cw = Math.cos(w), sw = -Math.sin(w);
    const p0 = -w * (firstFrame || 0);
    let zr = Math.cos(p0), zi = Math.sin(p0), ar = 0, ai = 0, k = 0;
    for (let i = s0; i < s1; i++) {
      const v = seg[i];
      ar += v * zr; ai += v * zi;
      const nr = zr * cw - zi * sw;
      zi = zr * sw + zi * cw; zr = nr;
      if (++k === 1024) { const mm = Math.sqrt(zr * zr + zi * zi); zr /= mm; zi /= mm; k = 0; }
    }
    return { re: ar, im: ai };
  }
  function beatMag(env, s0, s1, frameRate, bpm) {
    const c = beatPhasor(env, s0, s1, frameRate, bpm, 0);
    return Math.sqrt(c.re * c.re + c.im * c.im);
  }

  function snap(b) {
    const r1 = Math.round(b);
    if (Math.abs(b - r1) <= 0.05) return r1;
    const r2 = Math.round(b * 2) / 2;
    if (Math.abs(b - r2) <= 0.04) return r2;
    return Math.round(b * 100) / 100;
  }

  /// 本体 (Worker の中で呼ぶ)。mono = Float32Array、sr = サンプリング周波数
  function analyze(mono, sr, progress) {
    const limit = Math.floor(sr * MAX_SEC);
    if (mono.length > limit) mono = mono.subarray(0, limit);
    if (mono.length <= sr * 8) throw new Error('曲が短すぎて解析できません (8 秒以上必要です)');
    progress && progress(0.05);
    const { flux, energy } = onsetStrength(mono);
    const frameRate = sr / HOP;
    const shift = (FFT / 2) / sr;
    const env = postProcess(flux, frameRate);
    let maxE = 0;
    for (const e of energy) if (e > maxE) maxE = e;
    let startFrame = 0;
    if (maxE > 0) { const th = maxE * 0.001; for (let i = 0; i < energy.length; i++) if (energy[i] > th) { startFrame = i; break; } }
    const musicStart = startFrame / frameRate + shift;
    progress && progress(0.35);

    const coarseEnd = Math.min(env.length, startFrame + Math.floor(60 * frameRate));
    if (coarseEnd - startFrame <= 6 * frameRate) throw new Error('音の鳴っている部分が短すぎて解析できません');
    const step = 0.25, lo = 30, hi = 1680;
    const count = Math.floor((hi - lo) / step) + 1;
    const mag = new Float64Array(count);
    for (let i = 0; i < count; i++) {
      mag[i] = beatMag(env, startFrame, coarseEnd, frameRate, lo + i * step);
      if (progress && i % 400 === 0) progress(0.35 + 0.35 * i / count);
    }
    const m = bpm => {
      const i = Math.round((bpm - lo) / step);
      let best = 0;
      for (let j = i - 1; j <= i + 1; j++) if (j >= 0 && j < count) best = Math.max(best, mag[j]);
      return best;
    };
    const harm = b => m(b) + m(b * 2) + 0.5 * m(b * 3) + 0.5 * m(b * 4);
    let bestB = 120, bestS = -1;
    for (let b = 60; b <= 420; b += step) {
      const s = harm(b);
      const oct = Math.log2(b / 170);
      const w = Math.exp(-0.5 * (oct / 0.7) * (oct / 0.7));
      if (s * w > bestS) { bestS = s * w; bestB = b; }
    }

    const fineEnd = Math.min(env.length, startFrame + Math.floor(120 * frameRate));
    const fineHarm = b => beatMag(env, startFrame, fineEnd, frameRate, b) + beatMag(env, startFrame, fineEnd, frameRate, b * 2)
      + 0.5 * beatMag(env, startFrame, fineEnd, frameRate, b * 3) + 0.5 * beatMag(env, startFrame, fineEnd, frameRate, b * 4);
    let fineB = bestB, fineM = -1;
    for (let k = 0; k <= 120; k++) {
      const fb = bestB - 0.6 + k * 0.01;
      const v = fineHarm(fb);
      if (v > fineM) { fineM = v; fineB = fb; }
    }
    progress && progress(0.85);
    const center = fineB;
    for (let k = 0; k <= 24; k++) {
      const fb = center - 0.012 + k * 0.001;
      const v = fineHarm(fb);
      if (v > fineM) { fineM = v; fineB = fb; }
    }
    const cands = [snap(fineB)];
    for (const alt of [fineB * 2, fineB / 2]) if (alt >= 40 && alt <= 900) cands.push(snap(alt));
    const hint = changeHint(env, frameRate, shift, startFrame, fineB);
    progress && progress(1);
    return { rawBPM: fineB, candidates: cands, changeHint: hint, musicStart, env, frameRate, shift };
  }

  /// その BPM での 0 拍目の秒 (曲の頭から)
  function firstBeat(a, bpm) {
    const env = a.env, frameRate = a.frameRate, shift = a.shift, musicStart = a.musicStart;
    if (!(bpm > 0) || !env.length) return Math.max(0, musicStart);
    const period = 60 / bpm, periodF = period * frameRate;
    const startFrame = Math.max(0, Math.floor((musicStart - shift) * frameRate));
    const endFrame = Math.min(env.length, startFrame + Math.floor(30 * frameRate));
    if (endFrame <= startFrame + 4) return Math.max(0, musicStart);
    const sm = new Float64Array(env.length);
    const g = []; for (let d = -6; d <= 6; d++) g.push(Math.exp(-0.5 * d * d / 4));
    for (let i = startFrame; i < endFrame; i++) {
      let v = 0;
      for (let j = 0; j < g.length; j++) { const k = i + j - 6; if (k >= 0 && k < env.length) v += env[k] * g[j]; }
      sm[i] = v;
    }
    const smAt = f => { const i = Math.floor(f); if (i < 0 || i + 1 >= sm.length) return 0; const u = f - i; return sm[i] * (1 - u) + sm[i + 1] * u; };
    let phaseF = 0, bestComb = -1;
    for (let p = 0; p < periodF; p += 0.25) {
      let f = p + Math.ceil((startFrame - p) / periodF) * periodF, sum = 0;
      while (f < endFrame) { sum += smAt(f); f += periodF; }
      if (sum > bestComb) { bestComb = sum; phaseF = p; }
    }
    const devs = [];
    const win = Math.max(2, Math.floor(periodF * 0.15));
    let beatF = phaseF + Math.floor(startFrame / periodF) * periodF;
    while (beatF < endFrame) {
      const ci = Math.round(beatF);
      if (ci - win >= startFrame && ci + win < endFrame) {
        let bi = ci, bv = -1;
        for (let j = ci - win; j <= ci + win; j++) if (env[j] > bv) { bv = env[j]; bi = j; }
        if (bv > 0 && bi > 0 && bi < env.length - 1) {
          const a0 = env[bi - 1], b0 = env[bi], c0 = env[bi + 1];
          const den = a0 - 2 * b0 + c0;
          const off = den !== 0 ? Math.max(-0.5, Math.min(0.5, 0.5 * (a0 - c0) / den)) : 0;
          devs.push({ d: bi + off - beatF, s: bv });
        }
      }
      beatF += periodF;
    }
    if (devs.length >= 4) {
      const strong = devs.slice().sort((x, y) => y.s - x.s).slice(0, Math.max(2, Math.floor(devs.length / 2))).map(x => x.d).sort((x, y) => x - y);
      phaseF += strong[Math.floor(strong.length / 2)];
    }
    const seg = Array.from(env.subarray(startFrame, endFrame)).sort((x, y) => x - y);
    const p95 = seg[Math.min(seg.length - 1, Math.floor(seg.length * 0.95))];
    let onsetF = startFrame;
    for (let i = startFrame; i < endFrame; i++) if (env[i] > p95 * 0.3) { onsetF = i; break; }
    const k = Math.round((onsetF - phaseF) / periodF);
    let t = (phaseF + k * periodF) / frameRate + shift + 0.002;
    while (t < 0) t += period;
    return t;
  }

  /// JSON の offset (ms)。shiftBeats: 0 拍目を何拍ずらすか (+ で曲の後ろへ)
  function offsetRaw(a, bpm, shiftBeats) {
    const t = firstBeat(a, bpm) + (shiftBeats || 0) * 60 / bpm;
    return Math.round(t * 1000);
  }

  function changeHint(env, frameRate, shift, startFrame, bpm) {
    const winF = Math.floor(15 * frameRate), stepF = Math.floor(7.5 * frameRate);
    const flagged = [], flaggedBPM = [];
    for (let pos = startFrame; pos + winF <= env.length; pos += stepF) {
      const hm = x => beatMag(env, pos, pos + winF, frameRate, x) + beatMag(env, pos, pos + winF, frameRate, x * 2);
      const here = hm(bpm);
      let bestB = bpm, bestM = here;
      for (let b = bpm * 0.94; b <= bpm * 1.06; b += bpm * 0.002) { const v = hm(b); if (v > bestM) { bestM = v; bestB = b; } }
      if (Math.abs(bestB - bpm) / bpm > 0.01 && bestM > here * 1.3) { flagged.push(pos); flaggedBPM.push(bestB); }
      else { flagged.push(-1); flaggedBPM.push(0); }
    }
    for (let i = 1; i < flagged.length; i++) {
      if (flagged[i] >= 0 && flagged[i - 1] >= 0) {
        const sec = flagged[i - 1] / frameRate + shift;
        const mm = Math.floor(sec / 60), ss = Math.floor(sec) % 60;
        const nb = (flaggedBPM[i] + flaggedBPM[i - 1]) / 2;
        return mm + ':' + String(ss).padStart(2, '0') + ' あたりから BPM が変わっていそうです (約 ' + nb.toFixed(1) + ')。途中の BPM 変化は自動では入れないので、「BPM・速さ」タブで入れてください';
      }
    }
    return null;
  }

  const api = { analyze, firstBeat, offsetRaw, snap };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else if (typeof window === 'undefined' && typeof self !== 'undefined' && typeof importScripts === 'function') {
    // Worker の中
    self.onmessage = e => {
      try {
        const a = analyze(e.data.mono, e.data.sr, p => self.postMessage({ progress: p }));
        self.postMessage({ result: a }, [a.env.buffer]);
      } catch (err) {
        self.postMessage({ error: String(err && err.message || err) });
      }
    };
  } else root.BXTempo = api;
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : globalThis));
