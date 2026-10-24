// テストプレイの中身 (判定とノーツ生成)。iPad 版 BeatrixPlayCore.swift (= 本家 Unity の NotesGenerate.cs / keyjudge.cs) をそのまま移したもの
//   ノーツの種類: 1 = 白タップ / 2 = 始点タップ / 3 = 赤タップ / 4 = ワイプ / 5 = ホールド・スライドの判定点 (見えない)
//   ボタン: 0 = 左 (D) / 1 = 中央左 (F) / 2 = 中央右 (J) / 3 = 右 (K)
(function (root) {
  'use strict';
  const F = root.BXF || (typeof require !== 'undefined' ? require('./format.js') : null);
  const S = root.BXShapes || (typeof require !== 'undefined' ? require('./shapes.js') : null);
  const Beat = F.Beat, BX = F.BX;

  function visible(t, vis) {
    if (!vis || vis.length === 0) return true;
    for (const list of vis) {
      if (!list.length) return true;
      let v = !list[0].show;
      for (const e of list) { if (e.t > t) break; v = e.show; }
      if (v) return true;
    }
    return false;
  }

  const buttonZones = [[0, 1, 2], [1, 2, 3, 4], [2, 3, 4, 5], [4, 5, 6]];
  function sameZone(a, b) { return buttonZones.some(z => z.includes(a) && z.includes(b)); }
  function laneFrac(lane) { return (3 + 2 * lane) / 18; }

  /// 譜面 (エディタの chart) → プレイ用のデータ
  function makeChart(chart) {
    const tm = F.TimeMap(chart.times);
    const secB = b => tm.sec(Beat.val(b));
    const sec = d => secB(F.beatOf(d));
    const block = d => { const v = F.intValue(d.block); return Math.max(0, Math.min(6, v === null ? 0 : v)); };
    const kids = d => Array.isArray(d.notes) ? d.notes : [];
    const typeOf = d => { const v = F.intValue(d.type); return v === null ? 1 : v; };

    const entries = F.entries(chart);
    const raw = entries.map(e => e.dict);
    const out = { notes: [], holds: [], slides: [], sims: [], beats: [], parts: [], lyrics: [], endTime: 0, scroll: [] };

    const spOf = idx => {
      const e = entries[idx];
      if (e.isHead) { const b = e.bodies[0]; const v = b ? F.noteSpeed(b) : null; return v === null ? 1 : v; }
      const v = e.source ? F.noteSpeed(e.source) : null;
      return v === null ? 1 : v;
    };
    const dummyOf = idx => {
      const e = entries[idx];
      if (e.isHead) return e.bodies.length > 0 && e.bodies.every(F.isDummy);
      return e.source ? F.isDummy(e.source) : false;
    };
    const visList = n => {
      const ev = F.atBeats(n, BX.appearKey).map(b => ({ b, show: true })).concat(F.atBeats(n, BX.vanishKey).map(b => ({ b, show: false })));
      ev.sort((a, c) => Beat.eq(a.b, c.b) ? ((!a.show && c.show) ? -1 : (a.show === c.show ? 0 : 1)) : Beat.cmp(a.b, c.b));
      return ev.map(e => ({ t: secB(e.b), show: e.show }));
    };
    const visOf = idx => {
      const e = entries[idx];
      if (e.isHead) { const sets = e.bodies.map(visList); return sets.some(s => s.length === 0) ? [] : sets; }
      if (!e.source) return [];
      const l = visList(e.source);
      return l.length ? [l] : [];
    };

    // ソフラン
    const sps = [];
    for (const e of chart.speeds.slice().sort((a, b) => Beat.cmp(a.beat, b.beat))) {
      const t = secB(e.beat);
      if (sps.length && Math.abs(sps[sps.length - 1].t - t) < 1e-9) sps[sps.length - 1].speed = e.value;
      else sps.push({ t, speed: e.value });
    }
    if (sps.length) {
      let pos = sps[0].t;
      sps.forEach((p, i) => {
        if (i > 0) pos += (p.t - sps[i - 1].t) * sps[i - 1].speed;
        out.scroll.push({ t: p.t, pos, speed: p.speed });
      });
    }

    const holdStarts = new Set();
    for (const n of raw) if (typeOf(n) === 2 && kids(n).length) holdStarts.add(F.keyOf(F.beatOf(n), block(n)));

    raw.forEach((n, idx) => {
      const type = typeOf(n);
      if (type === 2) return;
      const blk = block(n);
      let tp = type;
      if (type === 1 && holdStarts.has(F.keyOf(F.beatOf(n), blk))) tp = 2;
      if (tp < 1 || tp > 4) tp = 1;
      out.notes.push(note(sec(n), blk, tp, spOf(idx), dummyOf(idx), visOf(idx)));
    });

    raw.forEach((n, idx) => {
      if (typeOf(n) !== 2 || !kids(n).length) return;
      const ks = kids(n);
      const blk = block(n);
      const isSlide = ks.some(k => block(k) !== blk);
      const dm = dummyOf(idx);
      if (!isSlide) {
        const startBeat = Beat.val(F.beatOf(n));
        const last = ks[ks.length - 1];
        const endBeat = Beat.val(F.beatOf(last));
        if (endBeat <= startBeat) return;
        out.holds.push({ t0: sec(n), t1: sec(last), lane: blk, sp: spOf(idx), dummy: dm, vis: visOf(idx) });
        let curLane = blk, curBeat = startBeat;
        for (const k of ks) {
          const eb = Beat.val(F.beatOf(k));
          out.notes.push(note(tm.sec(curBeat) + 0.02, curLane, 5, 1, dm, []));
          for (let j = 1; j < 100000; j++) {
            const b = curBeat + j * 0.5;
            if (b >= eb - 0.0001) break;
            out.notes.push(note(tm.sec(b) + 0.02, curLane, 5, 1, dm, []));
          }
          curLane = block(k);
          curBeat = eb;
        }
      } else {
        const pts = [{ t: sec(n), lane: blk }].concat(ks.map(k => ({ t: sec(k), lane: block(k) })));
        let draw = pts.map(p => ({ t: p.t, f: laneFrac(p.lane) }));
        const src = entries[idx].source;
        if (src && (F.isCurve(src) || F.hasEase(src))) {
          draw = S.slideShape(pts.map(p => p.t), pts.map(p => laneFrac(p.lane)), F.eases(src), F.isCurve(src)).map(p => ({ t: p.x, f: p.y }));
        }
        out.slides.push({ pts, draw, sp: spOf(idx), dummy: dm, vis: visOf(idx) });
        for (const p of pts) out.notes.push(note(p.t, p.lane, 5, 1, dm, []));
      }
    });

    out.notes.sort((a, b) => a.t - b.t);

    // ワイプ / 判定点の直後 0.16 秒以内のタップは GREAT / MISS を出さない
    for (let i = 0; i < out.notes.length; i++) {
      const ni = out.notes[i];
      if (ni.type !== 1 || ni.dummy) continue;
      for (let j = i - 1; j >= 0 && ni.t - out.notes[j].t <= 0.16; j--) {
        const o = out.notes[j];
        const gap = ni.t - o.t;
        if ((o.type === 4 || o.type === 5) && !o.dummy && gap > 0 && sameZone(ni.lane, o.lane)) { ni.suppressed = true; break; }
      }
    }

    markTateren(out.notes);

    const multi = {};
    out.notes.forEach((n, i) => {
      if (n.type !== 1 && n.type !== 2) return;
      const k = Math.round(n.t * 1000) + '-' + n.lane;
      (multi[k] = multi[k] || []).push(i);
    });
    for (const k in multi) if (multi[k].length >= 2) for (const i of multi[k]) out.notes[i].multi = true;

    const groups = {};
    out.notes.forEach((n, i) => {
      if (n.type === 5) return;
      const k = Math.round(n.t * 1000) + '|' + n.sp;
      (groups[k] = groups[k] || []).push(i);
    });
    for (const k in groups) {
      const idx = groups[k];
      if (idx.length < 2) continue;
      for (let a = 0; a < idx.length; a++) for (let b = a + 1; b < idx.length; b++) {
        const na = out.notes[idx[a]], nb = out.notes[idx[b]];
        if (Math.abs(na.lane - nb.lane) <= 1) continue;
        out.sims.push({ t: na.t, a: na.lane, b: nb.lane, sp: na.sp, ia: idx[a], ib: idx[b] });
      }
    }

    let end = out.notes.length ? out.notes[out.notes.length - 1].t : 0;
    for (const h of out.holds) end = Math.max(end, h.t1);
    for (const s of out.slides) end = Math.max(end, s.pts[s.pts.length - 1].t);
    out.endTime = end;
    for (let b = 0; b < 100000; b++) {
      const t = tm.sec(b);
      if (t > end + 4) break;
      out.beats.push(t);
    }
    for (const p of Array.isArray(chart.bx.part) ? chart.bx.part : []) {
      const e = Array.isArray(p.parts) && p.parts[0];
      if (!e) continue;
      const s0 = sec(p), s1 = sec(e);
      if (s0 < s1) out.parts.push({ start: s0, end: s1 });
    }
    for (const l of Array.isArray(chart.bx.lyrics) ? chart.bx.lyrics : []) {
      const e = Array.isArray(l.parts) && l.parts[0];
      if (!e) continue;
      const s0 = sec(l), s1 = sec(e);
      if (s0 < s1) out.lyrics.push({ start: s0, end: s1, text: typeof l.text === 'string' ? l.text : '' });
    }
    out.lyrics.sort((a, b) => a.start - b.start);
    out.pos = function (t) {
      const sc = this.scroll;
      if (!sc.length || t <= sc[0].t) return t;
      let lo = 0, hi = sc.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (sc[mid].t <= t) lo = mid; else hi = mid - 1; }
      return sc[lo].pos + (t - sc[lo].t) * sc[lo].speed;
    };
    return out;
  }

  function note(t, lane, type, sp, dummy, vis) {
    return { t, lane, type, sp: sp || 1, dummy: !!dummy, vis: vis || [], suppressed: false, tateren: false, lightTateren: false, multi: false, done: false, missed: false };
  }

  function markTateren(notes) {
    const gapSec = 60 / 200 / 4 + 0.002;
    const lightGap = 60 / 140 / 4 + 0.002;
    for (let lane = 0; lane < 7; lane++) {
      const idx = [];
      notes.forEach((n, i) => { if (n.lane === lane && n.type >= 1 && n.type <= 3 && !n.dummy) idx.push(i); });
      if (idx.length < 2) continue;
      idx.sort((a, b) => notes[a].t - notes[b].t);
      const times = [], groups = [];
      for (const i of idx) {
        if (times.length && notes[i].t - times[times.length - 1] <= 0.0005) { groups[groups.length - 1].push(i); continue; }
        times.push(notes[i].t); groups.push([i]);
      }
      const n = times.length;
      if (n < 2) continue;
      const linked = new Array(n - 1).fill(false);
      let a0 = 0;
      while (a0 < n - 1) {
        if (times[a0 + 1] - times[a0] > gapSec) { a0++; continue; }
        let b0 = a0, minGap = times[a0 + 1] - times[a0];
        while (b0 + 1 < n - 1 && times[b0 + 2] - times[b0 + 1] <= gapSec) { b0++; minGap = Math.min(minGap, times[b0 + 1] - times[b0]); }
        for (let k = a0; k <= b0; k++) linked[k] = true;
        const limit = minGap * 1.5 + 0.003;
        let k = a0 - 1;
        while (k >= 0 && times[k + 1] - times[k] <= limit) { linked[k] = true; k--; }
        k = b0 + 1;
        while (k < n - 1 && times[k + 1] - times[k] <= limit) { linked[k] = true; k++; }
        a0 = b0 + 1;
      }
      for (let k = 1; k < n; k++) if (linked[k - 1]) for (const i of groups[k]) notes[i].tateren = true;
      for (let k = 1; k < n; k++) if (!linked[k - 1] && times[k] - times[k - 1] <= lightGap) for (const i of groups[k]) if (!notes[i].tateren) notes[i].lightTateren = true;
    }
  }

  const tapZones = [[0, 1, 2], [3, 2, 1, 4], [3, 2, 4, 5], [6, 5, 4]];
  const holdZones = [[0, 1, 2], [1, 2, 3, 4], [2, 3, 4, 5], [4, 5, 6]];

  /// 判定の本体 (iPad 版 BxGame)。時刻はすべて譜面時刻 (秒)
  class Game {
    constructor(chart, startTime) {
      this.notes = chart.notes.map(n => Object.assign({}, n));
      for (const n of this.notes) if (n.t < startTime) n.done = true;
      this.first = 0;
      this.perfectPlus = 0; this.perfect = 0; this.great = 0; this.miss = 0;
      this.combo = 0; this.maxCombo = 0;
      this.lastJudge = null; this.lastJudgeAt = -Infinity; this.lastEarly = null;
      this.total = this.notes.filter(n => !n.dummy).length;
      this.lastLaneHit = new Array(7).fill(-999);
      this.lastAnyHit = -999;
      this.onSound = null;
      this.onJudge = null;
      this.advance();
    }
    advance() { while (this.first < this.notes.length && this.notes[this.first].done) this.first++; }
    get judged() { return this.perfectPlus + this.perfect + this.great + this.miss; }
    get score() {
      if (this.total <= 0) return 0;
      const got = 2 * (this.perfectPlus + this.perfect) + this.great;
      const full = (this.perfect === 0 && this.great === 0 && this.miss === 0) ? 1111111 : 1000000;
      return Math.floor(got / (2 * this.total) * full);
    }
    get achievableScore() {
      if (this.total <= 0) return 1111111;
      if (this.great === 0 && this.miss === 0) return this.perfect === 0 ? 1111111 : 1000000;
      const lost = this.great + 2 * this.miss;
      return Math.floor((2 * this.total - lost) / (2 * this.total) * 1000000);
    }
    static rank(s) {
      if (s >= 1111111) return 'AP+';
      if (s >= 1000000) return 'AP';
      if (s >= 990000) return 'SS';
      if (s >= 980000) return 'S';
      if (s >= 940000) return 'AA';
      if (s >= 900000) return 'A';
      if (s >= 820000) return 'B';
      if (s >= 750000) return 'C';
      return 'D';
    }
    get achievableRank() { return Game.rank(this.achievableScore); }
    get clearGauge() { return Math.max(0, Math.min(1, (this.achievableScore - 900000) / 100000)); }
    perfectWindow(n) { return n.type === 3 ? 0.075 : 0.06; }
    sound(type, t) { if (this.onSound) this.onSound(type, t); }

    press(zone, now) {
      if (zone < 0 || zone >= tapZones.length) return;
      const lanes = tapZones[zone];
      const notes = this.notes;
      const win = [];
      for (let j = this.first; j < notes.length; j++) {
        const n = notes[j];
        if (n.t - now > 0.15) break;
        if (!n.done && n.type >= 1 && n.type <= 3 && lanes.includes(n.lane) && now - n.t <= 0.15) win.push(j);
      }
      let bestDummy = -1, bestDummyLag = Infinity, bestRealLag = Infinity;
      for (const i of win) {
        const n = notes[i], a = Math.abs(now - n.t);
        if (n.dummy) { if (a <= 0.06 && a < bestDummyLag) { bestDummyLag = a; bestDummy = i; } }
        else {
          const range = n.tateren ? this.perfectWindow(n) : (n.type === 3 ? 0.075 : 0.13);
          if (a <= range && a < bestRealLag) bestRealLag = a;
        }
      }
      if (bestDummy >= 0 && bestDummyLag <= bestRealLag) {
        this.sound(notes[bestDummy].type, notes[bestDummy].t);
        notes[bestDummy].done = true;
        this.advance();
        return;
      }
      const cand = [];
      for (const i of win) {
        if (notes[i].dummy) continue;
        const a = Math.abs(now - notes[i].t);
        if (a <= (notes[i].type === 3 ? 0.075 : 0.13)) cand.push({ i, lag: a });
      }
      cand.sort((x, y) => {
        const px = x.lag <= this.perfectWindow(notes[x.i]), py = y.lag <= this.perfectWindow(notes[y.i]);
        if (px !== py) return px ? -1 : 1;
        if (px) { if (notes[x.i].t !== notes[y.i].t) return notes[x.i].t - notes[y.i].t; return x.i - y.i; }
        return x.lag !== y.lag ? x.lag - y.lag : x.i - y.i;
      });
      for (const c of cand) {
        const n = notes[c.i];
        const lag = now - n.t;
        if (n.tateren && c.lag > this.perfectWindow(n)) break;
        if (now - this.lastLaneHit[n.lane] < 0.1 && c.lag > this.perfectWindow(n)) break;
        const since = now - this.lastAnyHit;
        if (since >= -0.05 && since < 0.1 && (n.type === 1 || n.type === 2) && lag < -0.11) break;
        if (this.judgeTap(c.i, lag)) {
          if (n.tateren) this.lastLaneHit[n.lane] = now;
          this.lastAnyHit = now;
          return;
        }
      }
      for (const i of win) {
        const n = notes[i];
        if (!n.dummy) continue;
        if (Math.abs(now - n.t) <= (n.type === 3 ? 0.075 : 0.13)) {
          this.sound(n.type, n.t);
          n.done = true;
          this.advance();
          return;
        }
      }
    }

    hold(zone, now) {
      if (zone < 0 || zone >= holdZones.length) return;
      const lanes = holdZones[zone];
      const notes = this.notes;
      for (let i = this.first; i < notes.length; i++) {
        const n = notes[i];
        if (n.t - now > 0.12) break;
        if (n.done || !(n.type === 4 || n.type === 5) || !lanes.includes(n.lane) || Math.abs(now - n.t) > 0.12) continue;
        if (n.dummy) { if (n.type === 4) this.sound(4, n.t); n.done = true; continue; }
        if (n.type === 4) this.sound(4, n.t);
        this.record(i, 'pp', null);
        return;
      }
    }

    auto(now) {
      const notes = this.notes;
      for (let i = this.first; i < notes.length; i++) {
        const n = notes[i];
        if (n.t > now) break;
        if (!n.done && !n.dummy) {
          if (n.type <= 4) this.sound(n.type, n.t);
          this.record(i, 'pp', null);
        }
      }
      this.advance();
    }

    update(now) {
      const notes = this.notes;
      for (let i = this.first; i < notes.length; i++) {
        const n = notes[i];
        if (n.t > now) break;
        if (n.done) continue;
        const late = now - n.t;
        if ((n.type <= 3 && late > 0.09) || (n.type >= 4 && late > 0.12)) {
          if (n.dummy) n.done = true;
          else this.record(i, 'miss', null);
        }
      }
      this.advance();
    }

    judgeTap(i, lag) {
      const n = this.notes[i];
      const a = Math.abs(lag);
      if (n.type === 1) {
        const sup = n.suppressed || n.tateren;
        if (a <= 0.03 || (n.tateren && a <= 0.06)) { this.sound(1, n.t); this.record(i, 'pp', null); }
        else if (a <= 0.06) { this.sound(1, n.t); this.record(i, 'p', lag < 0); }
        else if (!sup && lag <= 0.09 && lag >= -0.11) { this.sound(1, n.t); this.record(i, 'g', lag < 0); }
        else if (!sup && a <= 0.13) this.record(i, 'miss', lag < 0);
        else return false;
      } else if (n.type === 2) {
        if (a <= 0.06) { this.sound(2, n.t); this.record(i, 'pp', null); }
        else if (!n.tateren && lag <= 0.09 && lag >= -0.11) { this.sound(2, n.t); this.record(i, 'g', lag < 0); }
        else if (!n.tateren && a <= 0.13) this.record(i, 'miss', lag < 0);
        else return false;
      } else if (n.type === 3) {
        if (a <= 0.075) { this.sound(3, n.t); this.record(i, 'pp', null); }
        else return false;
      } else return false;
      return true;
    }

    record(i, j, early) {
      const n = this.notes[i];
      n.done = true;
      if (j === 'miss' && early === null) n.missed = true;
      if (this.onJudge) this.onJudge(n.type, n.lane, j, early, n.t);
      if (j === 'pp') this.perfectPlus++;
      else if (j === 'p') this.perfect++;
      else if (j === 'g') this.great++;
      else this.miss++;
      if (j === 'miss') this.combo = 0;
      else { this.combo++; this.maxCombo = Math.max(this.maxCombo, this.combo); }
      this.lastJudge = j; this.lastEarly = early; this.lastJudgeAt = n.t;
      this.advance();
    }

    static laneHeld(lane, zones) {
      if (lane <= 2 && zones.has(0)) return true;
      if (lane >= 2 && lane <= 4 && (zones.has(1) || zones.has(2))) return true;
      if (lane >= 4 && zones.has(3)) return true;
      return false;
    }
  }

  const api = { makeChart, Game, visible, laneFrac, markTateren };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.BXPlay = api;
})(typeof window !== 'undefined' ? window : globalThis);
