// びーとり (BeatTriX) の譜面 JSON の読み書き。
// iPad 版 (BeatrixFormat.swift の parseBeatrix / beatrixData / BeatrixJSONWriter) をそのまま移したもの。
// 同じ譜面を iPad 版と PC 版で行き来しても、中身が変わらないようにしている (書き出しの並び・キーの順番・数の書き方も同じ)。
//
// エディタの中のノーツの持ち方も iPad 版と同じ:
//   { id, beat: {n, d}, x: 0..255 (中心), w: 幅, type: null(タップ) | 3(赤) | 4(ワイプ), segs: [{beat, x}] (スライドの経由点。相対), extra: {} }
//   extra のキーも iPad 版と同じ (bxHead / bxType / bxSpeed / bxDummy / bxCurve / bxEase / bxAppear / bxVanish / bxHeadOf)
(function (root) {
  'use strict';

  // ---------------------------------------------------------------- 拍 (分数)
  function gcd(a, b) {
    a = Math.abs(a); b = Math.abs(b);
    while (b) { const t = a % b; a = b; b = t; }
    return a === 0 ? 1 : a;
  }
  function B(n, d) {
    if (d === undefined) d = 1;
    if (d < 0) { n = -n; d = -d; }
    if (d === 0) d = 1;
    const g = gcd(n, d);
    return { n: n / g, d: d / g };
  }
  const Beat = {
    make: B,
    zero: B(0, 1),
    add(a, b) { return B(a.n * b.d + b.n * a.d, a.d * b.d); },
    sub(a, b) { return B(a.n * b.d - b.n * a.d, a.d * b.d); },
    cmp(a, b) { const l = a.n * b.d, r = b.n * a.d; return l < r ? -1 : l > r ? 1 : 0; },
    eq(a, b) { return a.n === b.n && a.d === b.d; },
    val(a) { return a.n / a.d; },
    key(a) { return a.n + '/' + a.d; },
    /// 1/den 拍にいちばん近い拍
    nearest(v, den) { return B(Math.round(v * den), den); },
    /// iPad 版の Beat.label (m:n/d)
    label(a) {
      const m = Math.floor(a.n / a.d);
      return m + ':' + (a.n - m * a.d) + '/' + a.d;
    },
  };

  // ---------------------------------------------------------------- 定数・小物
  const BX = {
    blockCount: 7,
    tapBlocks: [0, 3, 6],
    tapW: 77,
    sideW: 72,
    noteW: 85,
    headLPBMul: 2,
    headKey: 'bxHead', rawTypeKey: 'bxType', speedKey: 'bxSpeed', dummyKey: 'bxDummy',
    curveKey: 'bxCurve', easeKey: 'bxEase', appearKey: 'bxAppear', vanishKey: 'bxVanish', headLinkKey: 'bxHeadOf',
    difficulties: [
      { value: 0, abbr: 'BS', label: 'BASIC' },
      { value: 1, abbr: 'HD', label: 'HARD' },
      { value: 2, abbr: 'EX', label: 'EXTREME' },
      { value: 3, abbr: 'IN', label: 'INSANE' },
    ],
  };

  function intValue(v) {
    if (typeof v === 'number' && isFinite(v)) return Math.trunc(v);
    if (typeof v === 'string' && v.trim() !== '' && /^-?\d+$/.test(v.trim())) return parseInt(v.trim(), 10);
    return null;
  }
  function doubleValue(v) {
    if (typeof v === 'number' && isFinite(v)) return v;
    if (typeof v === 'string' && v.trim() !== '' && isFinite(Number(v.trim()))) return Number(v.trim());
    return null;
  }
  function centerX(b) {
    const bb = Math.max(0, Math.min(BX.blockCount - 1, b));
    return Math.round(255 * (3 + 2 * bb) / 18);
  }
  function blockOfX(px, tapOnly) {
    const list = tapOnly ? BX.tapBlocks : [0, 1, 2, 3, 4, 5, 6];
    let best = list[0], bestD = Infinity;
    for (const b of list) {
      const d = Math.abs(centerX(b) - px);
      if (d < bestD) { bestD = d; best = b; }
    }
    return best;
  }
  function isSlide(n) { return n.segs && n.segs.length > 0; }
  function isTapLike(n) { return !isSlide(n) && n.type !== 4; }
  function widthFor(n) { return isTapLike(n) ? BX.tapW : BX.sideW; }
  function headType(n) {
    const v = intValue(n.extra[BX.headKey]);
    if (v === 4) return 4;
    if (v === 0) return 0;
    return 1;
  }
  function lpbNum(b) {
    const g = gcd(b.n, b.d);
    const d = Math.max(1, b.d / g);
    const n = b.n / g;
    for (const c of [4, 8, 6, 12, 16, 24, 32, 48, 64, 96, 192]) {
      if (c % d === 0) return { lpb: c, num: n * (c / d) };
    }
    return { lpb: d, num: n };
  }
  function beatOf(dict) {
    const lpb = intValue(dict.LPB);
    const num = intValue(dict.num);
    return B(num === null ? 0 : num, Math.max(1, lpb === null ? 4 : lpb));
  }
  function keyOf(beat, block) { return Beat.key(beat) + '@' + block; }
  function clampBlock(v, dflt) {
    const b = intValue(v);
    return Math.max(0, Math.min(BX.blockCount - 1, b === null ? (dflt || 0) : b));
  }

  let idCounter = 0;
  function newId() { idCounter += 1; return 'n' + Date.now().toString(36) + '_' + idCounter; }
  function makeNote(beat, x, w, type, segs) {
    return { id: newId(), beat, x, w, type: type === undefined ? null : type, segs: segs || [], extra: {} };
  }
  function cloneNote(n) {
    return { id: n.id, beat: n.beat, x: n.x, w: n.w, type: n.type,
      segs: n.segs.map(s => ({ beat: s.beat, x: s.x })), extra: JSON.parse(JSON.stringify(n.extra)) };
  }

  // 出現 / 消えるの拍 ([[LPB, num], ...]。前の形式 [LPB, num] も読める)
  function atBeats(n, key) {
    const a = n.extra[key];
    if (!Array.isArray(a) || a.length === 0) return [];
    if (Array.isArray(a[0])) {
      const out = [];
      for (const p of a) {
        if (!Array.isArray(p) || p.length !== 2) continue;
        const l = intValue(p[0]), m = intValue(p[1]);
        if (l === null || m === null) continue;
        out.push(B(m, Math.max(1, l)));
      }
      return out.sort(Beat.cmp);
    }
    if (a.length === 2) {
      const l = intValue(a[0]), m = intValue(a[1]);
      if (l !== null && m !== null) return [B(m, Math.max(1, l))];
    }
    return [];
  }
  function setAtBeats(n, key, list) {
    if (list.length === 0) { delete n.extra[key]; return; }
    const uniq = [];
    for (const b of list.slice().sort(Beat.cmp)) if (!uniq.some(u => Beat.eq(u, b))) uniq.push(b);
    n.extra[key] = uniq.map(b => { const p = lpbNum(b); return [p.lpb, p.num]; });
  }
  /// 出現 / 消えるの拍を、ノーツと一緒にずらす (iPad 版の shiftAtBeats)
  function shiftAtBeats(n, orig, delta) {
    for (const key of [BX.appearKey, BX.vanishKey]) {
      const list = atBeats(orig, key);
      if (list.length === 0) continue;
      setAtBeats(n, key, list.map(b => Beat.add(b, delta)));
    }
  }
  function eases(n) {
    const raw = Array.isArray(n.extra[BX.easeKey]) ? n.extra[BX.easeKey].map(v => intValue(v)) : [];
    const out = new Array(n.segs.length).fill(0);
    for (let k = 0; k < Math.min(raw.length, out.length); k++) out[k] = (raw[k] === 1 || raw[k] === 2) ? raw[k] : 0;
    return out;
  }
  function hasEase(n) { return isSlide(n) && eases(n).some(e => e !== 0); }
  function isCurve(n) { return n.extra[BX.curveKey] === true; }
  function isDummy(n) { return n.extra[BX.dummyKey] === true; }
  function noteSpeed(n) { return doubleValue(n.extra[BX.speedKey]); }

  function splitName(name) {
    const t = (name || '').trim();
    const upper = t.toUpperCase();
    for (const d of BX.difficulties) {
      for (const suf of ['(' + d.abbr + ')', '（' + d.abbr + '）']) {
        if (upper.endsWith(suf)) return { title: t.slice(0, t.length - suf.length).trim(), diff: d.value };
      }
    }
    return { title: t, diff: null };
  }
  function safeFileName(s) {
    const r = (s || '').replace(/[\/\\:*?"<>|]/g, '_').trim();
    return r === '' ? 'chart' : r;
  }
  function lvRank(lv) {
    const v = Math.fround(lv);
    if (v >= 9) return '∞';
    if (v < 1.99) return 'F';
    if (v < 2.99) return 'E';
    if (v < 3.99) return 'D';
    if (v < 4.99) return 'C';
    if (v < 5.99) return 'B';
    if (v < 6.69) return 'A';
    if (v < 6.99) return 'A+';
    if (v < 7.69) return 'S';
    if (v < 7.99) return 'S+';
    if (v < 8.69) return 'X';
    if (v < 8.99) return 'X+';
    return 'Oops!';
  }

  // ---------------------------------------------------------------- 時間 (BPM 変化込み)
  function TimeMap(times) {
    let list = times.slice().sort((a, b) => Beat.cmp(a.beat, b.beat));
    if (list.length === 0) list = [{ beat: Beat.zero, bpm: 120 }];
    const bs = [], spb = [], secs = [];
    let t = 0;
    for (let i = 0; i < list.length; i++) {
      const b = Beat.val(list[i].beat);
      if (i > 0) t += (b - bs[i - 1]) * spb[i - 1];
      bs.push(b); spb.push(60 / Math.max(1, list[i].bpm)); secs.push(t);
    }
    return {
      sec(b) { let i = 0; while (i + 1 < bs.length && bs[i + 1] <= b) i++; return secs[i] + (b - bs[i]) * spb[i]; },
      beat(s) { let i = 0; while (i + 1 < secs.length && secs[i + 1] <= s) i++; return bs[i] + (s - secs[i]) / spb[i]; },
    };
  }

  // ---------------------------------------------------------------- 読み込み (parseBeatrix)
  function parse(text) {
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    const obj = JSON.parse(text);
    if (!obj || typeof obj !== 'object' || !Array.isArray(obj.notes)) throw new Error('びーとりの譜面 JSON ではありません (notes がありません)');
    const rawNotes = obj.notes;

    const bx = {};
    for (const k of Object.keys(obj)) {
      if (['notes', 'bpms', 'speeds', 'speeds_each', 'dummy', 'appear', 'disappear', 'curve', 'ease'].includes(k)) continue;
      bx[k] = obj[k];
    }
    const nameInfo = splitName(typeof obj.name === 'string' ? obj.name : '');
    bx.name = nameInfo.title;
    let diff = nameInfo.diff === null ? 2 : nameInfo.diff;
    const dv = intValue(obj.difficulty);
    if (dv !== null && dv >= 0 && dv <= 3) diff = dv;
    bx.difficulty = diff;

    let baseBPM = 120;
    const bv = doubleValue(obj.BPM);
    if (bv !== null && bv > 0) baseBPM = bv;
    const times = [{ beat: Beat.zero, bpm: baseBPM }];
    for (const e of Array.isArray(obj.bpms) ? obj.bpms : []) {
      const bpm = doubleValue(e.bpm);
      if (bpm === null || bpm <= 0) continue;
      const bt = beatOf(e);
      if (Beat.cmp(bt, Beat.zero) <= 0) times[0].bpm = bpm;
      else {
        const i = times.findIndex(t => Beat.eq(t.beat, bt));
        if (i >= 0) times[i].bpm = bpm; else times.push({ beat: bt, bpm });
      }
    }
    times.sort((a, b) => Beat.cmp(a.beat, b.beat));

    const speeds = [];
    for (const e of Array.isArray(obj.speeds) ? obj.speeds : []) {
      const sp = doubleValue(e.speed);
      if (sp === null) continue;
      speeds.push({ beat: beatOf(e), value: sp });
    }
    speeds.sort((a, b) => Beat.cmp(a.beat, b.beat));

    const notes = [];
    const slideAt = {};
    const singles = [];
    const noteRaw = [];
    rawNotes.forEach((e, ri) => {
      const bt = beatOf(e);
      const blk = clampBlock(e.block, 0);
      const t = intValue(e.type);
      const type = t === null ? 1 : t;
      const kids = Array.isArray(e.notes) ? e.notes : [];
      if (type === 2 && kids.length > 0) {
        const sx = centerX(blk);
        const segs = kids.map(k => ({ beat: Beat.sub(beatOf(k), bt), x: centerX(clampBlock(k.block, blk)) - sx }));
        const key = keyOf(bt, blk);
        if (slideAt[key] === undefined) slideAt[key] = notes.length;
        notes.push(makeNote(bt, sx, BX.sideW, null, segs));
        noteRaw.push(ri);
      } else {
        singles.push({ beat: bt, block: blk, type, raw: ri });
      }
    });
    for (const s of singles) {
      const n = makeNote(s.beat, centerX(s.block), s.type === 4 ? BX.sideW : BX.tapW, null);
      if (s.type === 3) n.type = 3;
      else if (s.type === 4) n.type = 4;
      else if (s.type === 1 || s.type === 2) n.type = null;
      else { n.type = null; n.extra[BX.rawTypeKey] = s.type; }
      notes.push(n);
      noteRaw.push(s.raw);
    }
    // 始点の表記 (LPB・num が 2 倍) から読んだタップ / ワイプは、そのスライドの始点として結び付ける
    notes.forEach((n, ni) => {
      if (isSlide(n) || !(n.type === null || n.type === 4) || ni >= noteRaw.length) return;
      const e = rawNotes[noteRaw[ni]];
      const p = lpbNum(n.beat);
      const lpb = intValue(e.LPB), num = intValue(e.num);
      if (lpb !== p.lpb * BX.headLPBMul || num !== p.num * BX.headLPBMul) return;
      const si = slideAt[keyOf(n.beat, blockOfX(n.x))];
      if (si !== undefined) n.extra[BX.headLinkKey] = notes[si].id;
    });
    for (const n of notes) if (isSlide(n)) n.extra[BX.headKey] = 0;

    // ノーツを指す項目の当て先
    const bodyKeys = new Set();
    for (const e of rawNotes) {
      const t = intValue(e.type);
      if ((t === null ? 1 : t) === 2 && Array.isArray(e.notes) && e.notes.length > 0) bodyKeys.add(keyOf(beatOf(e), clampBlock(e.block, 0)));
    }
    const rawToNote = {};
    noteRaw.forEach((ri, ni) => { rawToNote[ri] = ni; });
    const typed = {};
    const counter = {};
    rawNotes.forEach((e, ri) => {
      const t = intValue(e.type);
      const type = t === null ? 1 : t;
      const k = keyOf(beatOf(e), clampBlock(e.block, 0));
      const hasKids = Array.isArray(e.notes) && e.notes.length > 0;
      if ((type === 1 || type === 4) && bodyKeys.has(k)) return;
      if (type === 2 && !hasKids) return;
      const ck = k + '-' + type;
      const nth = counter[ck] || 0;
      counter[ck] = nth + 1;
      if (rawToNote[ri] !== undefined) typed[k + '#' + type + '#' + nth] = rawToNote[ri];
    });
    function targets(e) {
      const k = keyOf(beatOf(e), clampBlock(e.block, 0));
      const t = intValue(e.type);
      if (t !== null) {
        const nth = intValue(e.nth);
        const ni = typed[k + '#' + t + '#' + (nth === null ? 0 : nth)];
        return ni === undefined ? [] : [ni];
      }
      const out = [];
      notes.forEach((n, i) => { if (keyOf(n.beat, blockOfX(n.x)) === k) out.push(i); });
      return out;
    }
    for (const e of Array.isArray(obj.speeds_each) ? obj.speeds_each : []) {
      const sp = doubleValue(e.speed);
      if (sp === null) continue;
      for (const ni of targets(e)) notes[ni].extra[BX.speedKey] = sp;
    }
    for (const e of Array.isArray(obj.dummy) ? obj.dummy : []) for (const ni of targets(e)) notes[ni].extra[BX.dummyKey] = true;
    for (const e of Array.isArray(obj.ease) ? obj.ease : []) {
      const list = (Array.isArray(e.eases) ? e.eases : []).map(v => { const i = intValue(v); return i === null ? 0 : i; });
      for (const ni of targets(e)) if (isSlide(notes[ni])) notes[ni].extra[BX.easeKey] = list;
    }
    for (const e of Array.isArray(obj.curve) ? obj.curve : []) for (const ni of targets(e)) if (isSlide(notes[ni])) notes[ni].extra[BX.curveKey] = true;
    for (const [jsonKey, key] of [['appear', BX.appearKey], ['disappear', BX.vanishKey]]) {
      for (const e of Array.isArray(obj[jsonKey]) ? obj[jsonKey] : []) {
        const al = intValue(e.atLPB), an = intValue(e.atNum);
        const at = B(an === null ? 0 : an, Math.max(1, al === null ? 4 : al));
        for (const ni of targets(e)) setAtBeats(notes[ni], key, atBeats(notes[ni], key).concat([at]));
      }
    }
    return { bx, times, speeds, notes };
  }

  /// 新しい譜面
  function newChart(title, bpm, difficulty) {
    return {
      bx: { maxBlock: 7, LEVEL: 1.0, offset: 0, artist: '', preview: 0.0, name: title, difficulty },
      times: [{ beat: Beat.zero, bpm: Math.max(1, bpm) }],
      speeds: [],
      notes: [],
    };
  }

  // ---------------------------------------------------------------- 書き出し (beatrixData)
  function entries(chart) {
    const sorted = chart.notes.map((n, i) => ({ n, i })).sort((a, b) => {
      const c = Beat.cmp(a.n.beat, b.n.beat);
      if (c !== 0) return c;
      if (a.n.x !== b.n.x) return a.n.x < b.n.x ? -1 : 1;
      return a.i - b.i;
    }).map(o => o.n);
    const starts = {};
    for (const n of sorted) {
      if (!isSlide(n)) continue;
      const k = keyOf(n.beat, blockOfX(n.x));
      const h = headType(n);
      if (starts[k] !== undefined) {
        const old = starts[k];
        if (h === 4 || old === 4) starts[k] = 4;
        else if (h === 1 || old === 1) starts[k] = 1;
      } else starts[k] = h;
    }
    for (const n of sorted) {
      if (isSlide(n) || !(n.type === null || n.type === 4) || n.extra[BX.rawTypeKey] !== undefined) continue;
      const k = keyOf(n.beat, blockOfX(n.x));
      if (starts[k] === undefined) continue;
      if (n.type === 4) starts[k] = 4;
      else if (starts[k] === 0) starts[k] = 1;
    }
    for (const n of sorted) {
      if (isSlide(n) || n.type !== 3) continue;
      const k = keyOf(n.beat, blockOfX(n.x));
      if (starts[k] === 1) starts[k] = 0;
    }
    const bodiesAt = {};
    for (const n of sorted) {
      if (!isSlide(n)) continue;
      const k = keyOf(n.beat, blockOfX(n.x));
      (bodiesAt[k] = bodiesAt[k] || []).push(n);
    }
    const out = [];
    const headDone = new Set();
    for (const n of sorted) {
      const blk = blockOfX(n.x);
      const k = keyOf(n.beat, blk);
      const p = lpbNum(n.beat);
      if (isSlide(n)) {
        const kids = n.segs.map(s => {
          const q = lpbNum(Beat.add(n.beat, s.beat));
          return { LPB: q.lpb, num: q.num, block: blockOfX(n.x + s.x), type: 2, notes: [] };
        });
        out.push({ dict: { LPB: p.lpb, num: p.num, block: blk, type: 2, notes: kids }, source: n, bodies: [], isHead: false });
        const st = starts[k] === undefined ? 1 : starts[k];
        if (!headDone.has(k) && st !== 0) {
          headDone.add(k);
          out.push({ dict: { LPB: p.lpb * BX.headLPBMul, num: p.num * BX.headLPBMul, block: blk, type: st, notes: [] },
            source: null, bodies: bodiesAt[k] || [], isHead: true });
        }
      } else {
        const rawType = intValue(n.extra[BX.rawTypeKey]);
        if (rawType === null && (n.type === null || n.type === 4) && starts[k] !== undefined) continue;
        let t;
        if (rawType !== null) t = rawType;
        else if (n.type === 3) t = 3;
        else if (n.type === 4) t = 4;
        else t = 1;
        out.push({ dict: { LPB: p.lpb, num: p.num, block: blk, type: t, notes: [] }, source: n, bodies: [], isHead: false });
      }
    }
    return out;
  }

  function targetsOut(chart) {
    const out = [];
    const counter = {};
    for (const e of entries(chart)) {
      if (e.isHead || !e.source) continue;
      const n = e.source;
      const t = intValue(e.dict.type);
      const type = t === null ? 1 : t;
      const blk = intValue(e.dict.block) || 0;
      const ck = Beat.key(n.beat) + '-' + blk + '-' + type;
      const nth = counter[ck] || 0;
      counter[ck] = nth + 1;
      const p = lpbNum(n.beat);
      out.push({ ref: { LPB: p.lpb, num: p.num, block: blk, type, nth }, note: n });
    }
    return out;
  }

  function exportObject(chart) {
    const out = Object.assign({}, chart.bx);
    out.name = chart.bx.name || '';
    if (out.maxBlock === undefined) out.maxBlock = BX.blockCount;
    const dv = intValue(chart.bx.difficulty);
    out.difficulty = dv === null ? 2 : dv;
    if (out.LEVEL === undefined) out.LEVEL = 1.0;
    if (out.offset === undefined) out.offset = 0;

    const ts = chart.times.slice().sort((a, b) => Beat.cmp(a.beat, b.beat));
    out.BPM = ts.length ? ts[0].bpm : 120;
    out.bpms = ts.slice(1).map(t => { const p = lpbNum(t.beat); return { LPB: p.lpb, num: p.num, bpm: t.bpm }; });
    out.speeds = chart.speeds.slice().sort((a, b) => Beat.cmp(a.beat, b.beat))
      .map(e => { const p = lpbNum(e.beat); return { LPB: p.lpb, num: p.num, speed: e.value }; });
    const tg = targetsOut(chart);
    out.speeds_each = tg.filter(t => noteSpeed(t.note) !== null).map(t => Object.assign({}, t.ref, { speed: noteSpeed(t.note) }));
    out.dummy = tg.filter(t => isDummy(t.note)).map(t => t.ref);
    out.curve = tg.filter(t => isSlide(t.note) && isCurve(t.note)).map(t => t.ref);
    out.ease = tg.filter(t => hasEase(t.note)).map(t => Object.assign({}, t.ref, { eases: eases(t.note) }));
    function atList(key) {
      const list = [];
      for (const t of tg) {
        for (const at of atBeats(t.note, key)) {
          const q = lpbNum(at);
          list.push(Object.assign({}, t.ref, { atLPB: q.lpb, atNum: q.num }));
        }
      }
      return list;
    }
    out.appear = atList(BX.appearKey);
    out.disappear = atList(BX.vanishKey);
    if (out.lyrics === undefined) out.lyrics = [];
    out.notes = entries(chart).map(e => e.dict);
    return out;
  }

  // ---------------------------------------------------------------- JSON の書き方 (BeatrixJSONWriter)
  const topOrder = ['name', 'maxBlock', 'BPM', 'LEVEL', 'difficulty', 'artist', 'offset', 'preview', 'ver',
    'bpms', 'speeds', 'speeds_each', 'dummy', 'appear', 'disappear', 'curve', 'ease', 'part', 'lyrics', 'notes'];
  const innerOrder = ['LPB', 'num', 'block', 'type', 'nth', 'bpm', 'speed', 'atLPB', 'atNum', 'eases', 'text', 'notes', 'parts'];

  function orderedKeys(d, order) {
    const known = order.filter(k => d[k] !== undefined);
    const rest = Object.keys(d).filter(k => !order.includes(k) && d[k] !== undefined).sort();
    return known.concat(rest);
  }
  function numberText(v) {
    if (!isFinite(v)) return '0';
    if (v === Math.round(v) && Math.abs(v) < 1e15) return String(Math.round(v));
    // Swift の Double の表記に合わせる (いちばん短い形。とても小さい / 大きい数だけ 1e-05 の形)
    const a = Math.abs(v);
    if (a < 1e-4 || a >= 1e16) {
      const m = v.toExponential().split('e');
      const ex = parseInt(m[1], 10);
      const es = (ex < 0 ? '-' : '+') + (Math.abs(ex) < 10 ? '0' : '') + Math.abs(ex);
      return m[0] + 'e' + es;
    }
    return String(v);
  }
  function write(v, indent, order) {
    const pad = '  '.repeat(indent);
    const pad1 = '  '.repeat(indent + 1);
    if (v === null || v === undefined) return 'null';
    if (Array.isArray(v)) {
      if (v.length === 0) return '[]';
      return '[\n' + v.map(e => pad1 + write(e, indent + 1, innerOrder)).join(',\n') + '\n' + pad + ']';
    }
    if (typeof v === 'object') {
      const keys = orderedKeys(v, order);
      if (keys.length === 0) return '{}';
      return '{\n' + keys.map(k => pad1 + JSON.stringify(k) + ': ' + write(v[k], indent + 1, innerOrder)).join(',\n') + '\n' + pad + '}';
    }
    if (typeof v === 'string') return JSON.stringify(v);
    if (typeof v === 'boolean') return v ? 'true' : 'false';
    if (typeof v === 'number') return numberText(v);
    return JSON.stringify(String(v));
  }
  function stringify(chart) { return write(exportObject(chart), 0, topOrder) + '\n'; }

  // ---------------------------------------------------------------- ファイル名
  function diffInfo(v) { return BX.difficulties.find(d => d.value === v) || BX.difficulties[2]; }
  function fullName(chart) {
    const t = chart.bx.name ? chart.bx.name : 'chart';
    return t + '(' + diffInfo(intValue(chart.bx.difficulty)).abbr + ')';
  }
  function fileName(chart) { return safeFileName(fullName(chart)) + '.json'; }

  const api = {
    Beat, BX, gcd, intValue, doubleValue, centerX, blockOfX, isSlide, isTapLike, widthFor, headType, lpbNum, beatOf, keyOf,
    newId, makeNote, cloneNote, atBeats, setAtBeats, shiftAtBeats, eases, hasEase, isCurve, isDummy, noteSpeed,
    splitName, safeFileName, lvRank, TimeMap, parse, newChart, entries, exportObject, stringify, diffInfo, fullName, fileName,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.BXF = api;
})(typeof window !== 'undefined' ? window : globalThis);
