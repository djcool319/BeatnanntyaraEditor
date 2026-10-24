// テストプレイの画面 (iPad 版 BeatrixPlayView.swift の PC 版)。
// 奥から手前へノーツが流れてくる、本家と同じ見た目 (遠近の付いた 3 鍵のレーン + マゼンタの判定ライン)。
// 操作: D = 左 / F = 中央左 / J = 中央右 / K = 右 (本家の button.cs と同じ)。押した瞬間 → タップ・始点・赤、押している間 → ワイプ・ホールド・スライド
// Esc / Space でポーズ。判定は playcore.js (本家の keyjudge.cs と同じ)
(function () {
  'use strict';
  const P = window.BXPlay, F = window.BXF;

  const COUNT_IN = 2.0;
  const BASE_DEPTH_SPEED = 2.3;
  const TAP_W = 0.3027, SIDE_W = 0.2825, TAP_D = 0.04, WIPE_D = 0.034;
  const KEYS = { KeyD: 0, KeyF: 1, KeyJ: 2, KeyK: 3 };
  const DIFF_COLORS = ['#2978ff', '#ffa814', '#e61f29', '#9938eb'];
  const FONT = '"Segoe UI Black", "Arial Rounded MT Bold", "Yu Gothic UI", "Segoe UI", sans-serif';

  function pref(key, dflt) { try { const v = localStorage.getItem('bx.play.' + key); return v === null ? dflt : JSON.parse(v); } catch (e) { return dflt; } }
  function setPref(key, v) { try { localStorage.setItem('bx.play.' + key, JSON.stringify(v)); } catch (e) { /* なくても動く */ } }

  class PlayScreen {
    constructor(audio) {
      this.audio = audio;
      this.root = document.getElementById('play');
      this.canvas = document.getElementById('playCanvas');
      this.ctx = this.canvas.getContext('2d');
      this.pauseEl = document.getElementById('playPause');
      this.resultEl = document.getElementById('playResult');
      this.settings = {
        speed: pref('speed', 1.0),
        judgeAtEdge: pref('judgeAtEdge', true),
        adjMs: pref('adjMs', -30),
        auto: pref('auto', false),
        se: pref('se', true),
      };
      this.open_ = false;
      this.held = new Map();       // キー / ポインタ → ボタン
      this.effects = [];
      this.pendingWipeFx = [];
      this.judgeImgs = {};
      this.bgCache = null;
      this.onClose = () => {};
      this.bindInput();
      this.bindPanels();
    }

    // ------------------------------------------------------------ 開く / 閉じる
    open(opts) {
      this.chart = P.makeChart(opts.chart);
      this.title = opts.chart.bx.name || '';
      this.artist = opts.chart.bx.artist || '';
      const dv = F.intValue(opts.chart.bx.difficulty);
      this.diff = dv === null ? 2 : dv;
      const lv = F.doubleValue(opts.chart.bx.LEVEL);
      this.level = lv === null ? 1 : lv;
      const off = F.intValue(opts.chart.bx.offset);
      this.offsetRaw = off === null ? 0 : off;
      this.startAt = Math.max(0, opts.startSec);
      this.firstTime = this.startAt - COUNT_IN;
      this.open_ = true;
      this.prevSeOn = this.audio.seOn;              // プレイ中のノーツ音は、プレイの設定 (ポーズ画面) で決める
      this.audio.seOn = true;
      this.audio.applyVolumes();
      this.root.classList.remove('hidden');
      this.resize();
      this.retry();
      const loop = () => { if (!this.open_) return; this.frame(); this.raf = requestAnimationFrame(loop); };
      this.raf = requestAnimationFrame(loop);
    }
    close() {
      this.open_ = false;
      cancelAnimationFrame(this.raf);
      this.audio.stop();
      this.held.clear();
      this.audio.seOn = this.prevSeOn;
      this.audio.applyVolumes();
      this.root.classList.add('hidden');
      this.pauseEl.classList.add('hidden');
      this.resultEl.classList.add('hidden');
      this.onClose();
    }
    get isOpen() { return this.open_; }

    offsetSec() { return this.offsetRaw / 1000 + this.settings.adjMs / 1000; }
    begin(t) {
      this.audio.rate = 1;
      this.audio.play(t, this.offsetSec(), []);
      this.running = true;
      this.pauseEl.classList.add('hidden');
    }
    retry() {
      this.game = new P.Game(this.chart, this.firstTime);
      this.attachSounds();
      this.held.clear();
      this.effects = [];
      this.pendingWipeFx = [];
      this.resultShown = false;
      this.resultEl.classList.add('hidden');
      this.viewTime = this.firstTime;
      this.begin(this.firstTime);
    }
    pause() {
      if (!this.running) return;
      this.pausedT = this.now();
      this.running = false;
      this.audio.stop();
      this.held.clear();
      this.pendingWipeFx = [];
      this.syncPausePanel();
      this.pauseEl.classList.remove('hidden');
    }
    resume() {
      if (this.running || !this.open_) return;
      this.begin(this.pausedT);
    }
    now(perf) { return this.audio.chartTimeAtPerf(perf === undefined ? performance.now() : perf); }

    attachSounds() {
      const a = this.audio;
      this.game.onSound = (type, t) => {
        if (!this.settings.se) return;
        const kind = type === 3 ? 'red' : (type === 4 ? 'wipe' : 'tap');
        // ワイプは、本家と同じくノーツが判定ラインに来た瞬間に鳴らす。オートは全部ノーツの時刻ぴったり
        if (type === 4 || this.settings.auto) a.playAt(kind, t); else a.playNow(kind);
      };
      this.game.onJudge = (type, lane, j, early, t) => {
        if (type === 4 && j !== 'miss') { this.pendingWipeFx.push({ t, lane, j }); return; }
        this.spawnEffect(type, lane, j, early);
      };
    }

    // ------------------------------------------------------------ 入力
    bindInput() {
      window.addEventListener('keydown', e => {
        if (!this.open_) return;
        const typing = e.target && e.target.tagName === 'INPUT' && (e.target.type === 'number' || e.target.type === 'text');
        if (typing && e.code !== 'Escape') return;
        if (e.target && e.target.blur && e.target !== document.body) e.target.blur();
        e.preventDefault();
        e.stopImmediatePropagation();
        if (e.code === 'Escape' || e.code === 'Space') {
          if (!this.resultShown) { if (this.running) this.pause(); else this.resume(); }
          else this.close();
          return;
        }
        if (e.code === 'Enter' && (this.resultShown || !this.running)) { this.retry(); return; }
        const z = KEYS[e.code];
        if (z === undefined || e.repeat || !this.running) return;
        this.held.set('k' + e.code, z);
        if (!this.settings.auto) this.game.press(z, this.now(e.timeStamp));
      }, true);
      window.addEventListener('keyup', e => {
        if (!this.open_) return;
        e.stopImmediatePropagation();
        this.held.delete('k' + e.code);
      }, true);
      window.addEventListener('blur', () => this.held.clear());
      this.canvas.addEventListener('pointerdown', e => {
        if (!this.running) return;
        const p = this.point(e);
        if (p.x > this.W - this.W * 0.09 && p.y < this.H * 0.13) { this.pause(); return; }   // 右上の II
        const z = this.zoneAt(p.x);
        this.held.set('p' + e.pointerId, z);
        if (!this.settings.auto) this.game.press(z, this.now(e.timeStamp));
        this.canvas.setPointerCapture(e.pointerId);
      });
      this.canvas.addEventListener('pointermove', e => { if (this.held.has('p' + e.pointerId)) this.held.set('p' + e.pointerId, this.zoneAt(this.point(e).x)); });
      const up = e => this.held.delete('p' + e.pointerId);
      this.canvas.addEventListener('pointerup', up);
      this.canvas.addEventListener('pointercancel', up);
      window.addEventListener('resize', () => { if (this.open_) this.resize(); });
    }
    point(e) { const r = this.canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }
    zoneAt(x) {
      const g = this.geo();
      const f = (x - (g.midX - g.halfJ)) / (2 * g.halfJ);
      if (f < 1 / 3) return 0;
      if (f < 0.5) return 1;
      if (f < 2 / 3) return 2;
      return 3;
    }

    bindPanels() {
      const $ = id => document.getElementById(id);
      $('ppResume').onclick = () => this.resume();
      $('ppRetry').onclick = () => this.retry();
      $('ppQuit').onclick = () => this.close();
      $('prRetry').onclick = () => this.retry();
      $('prQuit').onclick = () => this.close();
      $('ppSpeed').oninput = e => { this.settings.speed = Number(e.target.value); setPref('speed', this.settings.speed); this.syncPausePanel(); };
      $('ppEdge').onchange = e => { this.settings.judgeAtEdge = e.target.value === '1'; setPref('judgeAtEdge', this.settings.judgeAtEdge); };
      $('ppAdj').onchange = e => { const v = Math.max(-200, Math.min(200, Math.round(Number(e.target.value) || 0))); this.settings.adjMs = v; setPref('adjMs', v); this.syncPausePanel(); };
      $('ppAuto').onchange = e => { this.settings.auto = e.target.checked; setPref('auto', this.settings.auto); };
      $('ppSE').onchange = e => { this.settings.se = e.target.checked; setPref('se', this.settings.se); };
    }
    syncPausePanel() {
      const $ = id => document.getElementById(id);
      $('ppSpeed').value = this.settings.speed;
      $('ppSpeedV').textContent = '×' + this.settings.speed.toFixed(1);
      $('ppEdge').value = this.settings.judgeAtEdge ? '1' : '0';
      $('ppAdj').value = this.settings.adjMs;
      $('ppAuto').checked = this.settings.auto;
      $('ppSE').checked = this.settings.se;
    }

    // ------------------------------------------------------------ 遠近
    resize() {
      const dpr = window.devicePixelRatio || 1;
      this.W = this.canvas.clientWidth; this.H = this.canvas.clientHeight;
      this.canvas.width = Math.round(this.W * dpr); this.canvas.height = Math.round(this.H * dpr);
      this.dpr = dpr;
      this.bgCache = null;
      this.judgeImgs = {};
    }
    geo() {
      const W = this.W, H = this.H;
      const judgeY = H * 0.80;
      const halfJ = Math.min(W * 0.4625, H * 0.62);
      const vanishY = judgeY - H * 1.24;
      const midX = W / 2;
      const s = d => 1 / (1 + Math.max(d, -0.85));
      return {
        midX, judgeY, vanishY, halfJ,
        y: d => vanishY + (judgeY - vanishY) * s(d),
        x: (f, d) => midX + (f - 0.5) * 2 * halfJ * s(d),
        depthAtY: yy => 1 / Math.max((yy - vanishY) / (judgeY - vanishY), 0.01) - 1,
      };
    }
    depth(t, sp) {
      const speed = BASE_DEPTH_SPEED * Math.min(Math.max(this.settings.speed, 0.5), 2.0);
      return (this.chart.pos(t) - this.nowPos) * speed * (sp || 1) + (this.settings.judgeAtEdge ? TAP_D / 2 : 0);
    }

    // ------------------------------------------------------------ 毎フレーム
    frame() {
      if (this.running) {
        const t = this.now();
        const zones = this.zones();
        if (this.settings.auto) this.game.auto(t);
        else for (const z of zones) this.game.hold(z, t);
        this.game.update(t);
        if (this.pendingWipeFx.length) {
          const due = this.pendingWipeFx.filter(e => e.t <= t);
          if (due.length) {
            this.pendingWipeFx = this.pendingWipeFx.filter(e => e.t > t);
            for (const e of due) this.spawnEffect(4, e.lane, e.j, null);
          }
        }
        this.viewTime = t;
        if (!this.resultShown && t > this.chart.endTime + 1.5) this.showResult();
      }
      this.draw();
    }
    zones() {
      if (this.settings.auto) return new Set([0, 1, 2, 3]);
      return new Set(this.held.values());
    }

    showResult() {
      this.resultShown = true;
      const g = this.game, sc = g.score;
      const $ = id => document.getElementById(id);
      $('prScore').textContent = String(sc).padStart(7, '0');
      $('prRank').textContent = P.Game.rank(sc);
      $('prClear').textContent = sc >= 900000 ? 'CLEAR' : 'FAILED';
      $('prClear').className = sc >= 900000 ? 'clear' : 'failed';
      $('prPP').textContent = g.perfectPlus; $('prP').textContent = g.perfect; $('prG').textContent = g.great; $('prM').textContent = g.miss;
      $('prCombo').textContent = g.maxCombo + ' / ' + g.total;
      this.resultEl.classList.remove('hidden');
    }

    holdActive(h, t, zones) { return t >= h.t0 && t <= h.t1 && P.Game.laneHeld(h.lane, zones); }
    slideActive(s, t, zones) {
      if (!zones.size) return false;
      const f = s.pts[0], l = s.pts[s.pts.length - 1];
      if (t < f.t || t > l.t) return false;
      for (let k = 0; k < s.pts.length - 1; k++) {
        const a = s.pts[k], b = s.pts[k + 1];
        if (t < a.t || t > b.t) continue;
        const u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0;
        if (P.Game.laneHeld(Math.round(a.lane + (b.lane - a.lane) * u), zones)) return true;
      }
      return false;
    }

    // ------------------------------------------------------------ 描画
    drawBackground() {
      // 背景・床・レーンの線・判定ラインは、画面の大きさが変わったときだけ作る
      const c = document.createElement('canvas');
      c.width = this.canvas.width; c.height = this.canvas.height;
      const x = c.getContext('2d');
      x.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      const W = this.W, H = this.H, g = this.geo(), r = this.depthRange(g);
      const grad = x.createLinearGradient(0, 0, 0, H);
      grad.addColorStop(0, 'rgb(32,33,42)'); grad.addColorStop(1, 'rgb(19,20,27)');
      x.fillStyle = grad; x.fillRect(0, 0, W, H);
      // 網目 (決まった乱数)
      let seed = 0x9E3779B9 >>> 0;
      const rnd = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
      const cols = 7, rows = 5, pts = [];
      for (let j = 0; j <= rows; j++) {
        const row = [];
        for (let i = 0; i <= cols; i++) {
          row.push({ x: (i + (i === 0 || i === cols ? 0 : rnd() * 0.7 - 0.35)) * W / cols, y: (j + (j === 0 || j === rows ? 0 : rnd() * 0.7 - 0.35)) * H / rows });
        }
        pts.push(row);
      }
      x.strokeStyle = 'rgba(255,255,255,0.075)'; x.lineWidth = 1.2; x.beginPath();
      for (let j = 0; j <= rows; j++) for (let i = 0; i <= cols; i++) {
        const p = pts[j][i];
        if (i < cols) { x.moveTo(p.x, p.y); x.lineTo(pts[j][i + 1].x, pts[j][i + 1].y); }
        if (j < rows) { x.moveTo(p.x, p.y); x.lineTo(pts[j + 1][i].x, pts[j + 1][i].y); }
        if (i < cols && j < rows) {
          const a = (i + j) % 2 === 0 ? p : pts[j][i + 1], b = (i + j) % 2 === 0 ? pts[j + 1][i + 1] : pts[j + 1][i];
          x.moveTo(a.x, a.y); x.lineTo(b.x, b.y);
        }
      }
      x.stroke();
      x.strokeStyle = 'rgba(255,255,255,0.045)'; x.lineWidth = H * 0.025;
      x.beginPath(); x.arc(W / 2, H * 0.4, H * 0.5, 0, Math.PI * 2); x.stroke();
      // 床
      x.fillStyle = 'rgba(14,14,17,0.93)';
      this.quad(x, g, 0, 1, r.bot, r.top); x.fill();
      x.strokeStyle = 'rgba(255,255,255,0.3)'; x.lineWidth = 1.4; x.beginPath();
      for (const f of [1 / 3, 2 / 3]) { x.moveTo(g.x(f, r.bot), g.y(r.bot)); x.lineTo(g.x(f, r.top), g.y(r.top)); }
      x.stroke();
      this.bgCache = c;
    }
    depthRange(g) { return { bot: Math.max(-0.8, g.depthAtY(this.H)), top: g.depthAtY(0) + 0.05 }; }
    quad(x, g, f0, f1, d0, d1) {
      x.beginPath();
      x.moveTo(g.x(f0, d0), g.y(d0)); x.lineTo(g.x(f1, d0), g.y(d0));
      x.lineTo(g.x(f1, d1), g.y(d1)); x.lineTo(g.x(f0, d1), g.y(d1)); x.closePath();
    }
    addQuad(p, g, f0, f1, d0, d1) {
      p.moveTo(g.x(f0, d0), g.y(d0)); p.lineTo(g.x(f1, d0), g.y(d0));
      p.lineTo(g.x(f1, d1), g.y(d1)); p.lineTo(g.x(f0, d1), g.y(d1)); p.closePath();
    }

    draw() {
      const c = this.ctx, g = this.geo(), W = this.W, H = this.H;
      if (!this.bgCache) this.drawBackground();
      c.setTransform(1, 0, 0, 1, 0, 0);
      c.drawImage(this.bgCache, 0, 0);
      c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      const vt = this.viewTime;
      this.nowPos = this.chart.pos(vt);
      const r = this.depthRange(g);
      const zones = this.zones();
      const touched = new Set(this.held.values());

      // part
      let inPart = false;
      const pFill = new Path2D(), pEdge = new Path2D();
      for (const p of this.chart.parts) {
        if (vt >= p.start && vt < p.end) inPart = true;
        const d0 = Math.max(this.depth(p.start), r.bot), d1 = Math.min(this.depth(p.end), r.top);
        if (d1 <= d0) continue;
        this.addQuad(pFill, g, 0, 1, d0, d1);
        this.addQuad(pEdge, g, -0.012, 0, d0, d1);
        this.addQuad(pEdge, g, 1, 1.012, d0, d1);
      }
      c.fillStyle = 'rgba(255,255,255,0.05)'; c.fill(pFill);
      c.fillStyle = 'rgb(237,237,237)'; c.fill(pEdge);
      // レーンの両端
      c.strokeStyle = inPart ? '#fff' : 'rgb(217,217,217)'; c.lineWidth = inPart ? 4 : 2.5;
      c.beginPath();
      for (const f of [0, 1]) { c.moveTo(g.x(f, r.bot), g.y(r.bot)); c.lineTo(g.x(f, r.top), g.y(r.top)); }
      c.stroke();
      // 1 拍ごとの線
      c.strokeStyle = 'rgba(255,255,255,0.13)'; c.lineWidth = 1.4; c.beginPath();
      for (const t of this.chart.beats) {
        const d = this.depth(t);
        if (d < r.bot || d > r.top) continue;
        c.moveTo(g.x(0, d), g.y(d)); c.lineTo(g.x(1, d), g.y(d));
      }
      c.stroke();
      // 押しているボタンの光
      const zp = new Path2D();
      if (touched.has(0)) this.addQuad(zp, g, 0, 1 / 3, r.bot, r.top);
      if (touched.has(1) || touched.has(2)) this.addQuad(zp, g, 1 / 3, 2 / 3, r.bot, r.top);
      if (touched.has(3)) this.addQuad(zp, g, 2 / 3, 1, r.bot, r.top);
      c.fillStyle = 'rgba(255,255,255,0.06)'; c.fill(zp);

      // ホールド / スライドの帯
      const idle = new Path2D(), active = new Path2D();
      const hw = SIDE_W / 2;
      for (const h of this.chart.holds) {
        if (!P.visible(vt, h.vis)) continue;
        const d0 = Math.max(this.depth(h.t0, h.sp), 0), d1 = Math.min(this.depth(h.t1, h.sp), r.top);
        if (d1 <= d0) continue;
        const f = P.laneFrac(h.lane);
        this.addQuad(this.holdActive(h, vt, zones) ? active : idle, g, f - hw, f + hw, d0, d1);
      }
      for (const s of this.chart.slides) {
        const fp = s.pts[0], lp = s.pts[s.pts.length - 1];
        if (lp.t < vt || !P.visible(vt, s.vis)) continue;
        if (this.depth(fp.t, s.sp) > r.top && this.depth(lp.t, s.sp) > r.top) continue;
        const path = this.slideActive(s, vt, zones) ? active : idle;
        const dp = s.draw;
        for (let k = 0; k < dp.length - 1; k++) {
          const a = dp[k], b = dp[k + 1];
          if (b.t <= a.t || b.t < vt) continue;
          const ta = Math.max(a.t, vt), tb = b.t;
          if (tb <= ta) continue;
          const cuts = [ta];
          for (const sc of this.chart.scroll) if (sc.t > ta && sc.t < tb) cuts.push(sc.t);
          cuts.push(tb);
          for (let ci = 0; ci < cuts.length - 1; ci++) {
            let t0 = cuts[ci], t1 = cuts[ci + 1];
            let d0 = this.depth(t0, s.sp), d1 = this.depth(t1, s.sp);
            if (d0 > r.top && d1 > r.top) continue;
            if (d1 > r.top && d1 !== d0) { const u = (r.top - d0) / (d1 - d0); t1 = t0 + (t1 - t0) * u; d1 = r.top; }
            else if (d0 > r.top && d1 !== d0) { const u = (r.top - d0) / (d1 - d0); t0 = t0 + (t1 - t0) * u; d0 = r.top; }
            const fa = a.f + (b.f - a.f) * (t0 - a.t) / (b.t - a.t);
            const fb = a.f + (b.f - a.f) * (t1 - a.t) / (b.t - a.t);
            path.moveTo(g.x(fa - hw, d0), g.y(d0)); path.lineTo(g.x(fa + hw, d0), g.y(d0));
            path.lineTo(g.x(fb + hw, d1), g.y(d1)); path.lineTo(g.x(fb - hw, d1), g.y(d1)); path.closePath();
          }
        }
      }
      c.fillStyle = 'rgba(92,107,189,0.9)'; c.fill(idle);
      c.fillStyle = 'rgb(120,148,255)'; c.fill(active);

      // 同時押しの線
      const gn = this.game.notes;
      const noteVisible = i => { const n = gn[i]; if (!n || !P.visible(vt, n.vis)) return false; return !n.done || (n.type === 4 && vt < n.t); };
      c.strokeStyle = 'rgba(217,217,217,0.75)'; c.lineWidth = 2; c.beginPath();
      for (const sim of this.chart.sims) {
        if (!noteVisible(sim.ia) || !noteVisible(sim.ib)) continue;
        const d = this.depth(sim.t, sim.sp);
        if (d < -0.02 || d > r.top) continue;
        c.moveTo(g.x(P.laneFrac(sim.a), d), g.y(d)); c.lineTo(g.x(P.laneFrac(sim.b), d), g.y(d));
      }
      c.stroke();

      this.drawNotes(c, g, r, vt);

      // 判定ライン
      c.fillStyle = 'rgb(237,18,237)';
      this.quad(c, g, -0.005, 1.005, -0.007, 0.007); c.fill();

      this.drawEffects(c);
      this.drawHUD(c, g, vt);
    }

    drawNotes(c, g, r, vt) {
      const notes = this.game.notes;
      const tLo = vt - 2;
      let lo = 0, hi = notes.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (notes[mid].t < tLo) lo = mid + 1; else hi = mid; }
      const L = {};
      for (const k of ['tap', 'head', 'multi', 'red', 'wipe']) L[k] = { p: new Path2D(), s: new Path2D() };
      for (let i = lo; i < notes.length; i++) {
        const n = notes[i];
        if (n.type === 5) continue;
        if (n.done && !n.missed && !(n.type === 4 && vt < n.t)) continue;
        if (!P.visible(vt, n.vis)) continue;
        const d = this.depth(n.t, n.sp);
        if (d > r.top + 0.1 || d < r.bot - 0.1) continue;
        const f = P.laneFrac(n.lane);
        let key, w = TAP_W, dd = TAP_D;
        if (n.multi && (n.type === 1 || n.type === 2)) { key = 'multi'; w = n.type === 2 ? SIDE_W : TAP_W; }
        else if (n.type === 2) { key = 'head'; w = SIDE_W; }
        else if (n.type === 3) key = 'red';
        else if (n.type === 4) { key = 'wipe'; w = SIDE_W; dd = WIPE_D; }
        else key = 'tap';
        this.addPill(L[key], g, f - w / 2, f + w / 2, d - dd / 2, d + dd / 2, n.dummy);
      }
      const colors = {
        tap: ['rgb(184,186,199)', '#fff'], head: ['rgb(89,153,217)', 'rgb(140,204,255)'],
        multi: ['rgb(191,77,153)', 'rgb(255,143,217)'], red: ['rgb(153,20,36)', 'rgb(237,51,69)'],
        wipe: ['rgb(184,173,31)', 'rgb(242,237,61)'],
      };
      for (const k of ['tap', 'head', 'multi', 'red', 'wipe']) {
        c.fillStyle = colors[k][0]; c.fill(L[k].s);
        c.fillStyle = colors[k][1]; c.fill(L[k].p);
      }
      // ダミーは薄く (上から暗い色を重ねる)
      if (this.dummyPath) { c.fillStyle = 'rgba(14,14,17,0.55)'; c.fill(this.dummyPath); this.dummyPath = null; }
    }
    addPill(layer, g, f0, f1, d0, d1, dummy) {
      const yb = g.y(d0), yt = g.y(d1), hh = yb - yt;
      if (hh < 0.5) return;
      const dm = (d0 + d1) / 2;
      const xl = g.x(f0, dm), xr = g.x(f1, dm), ww = xr - xl;
      if (ww < 1) return;
      const pill = (p, h) => {
        const ch = Math.min(h / 2, ww / 2), cw = Math.min(h * 0.8, ww / 2);
        p.roundRect(xl, yt, ww, h, [{ x: cw, y: ch }]);
      };
      pill(layer.s, hh);
      pill(layer.p, hh * 0.8);
      if (dummy) { if (!this.dummyPath) this.dummyPath = new Path2D(); pill(this.dummyPath, hh); }
    }

    // ------------------------------------------------------------ エフェクト
    spawnEffect(type, lane, j, early) {
      const cyan = [31, 245, 245];
      let col;
      if (j === 'pp' || j === 'p') col = type === 3 ? [255, 64, 89] : (type === 4 ? [255, 245, 128] : cyan);
      else if (j === 'g') col = [255, 140, 217];
      else { if (early !== true) return; col = [153, 153, 153]; }
      const g = this.geo(), third = g.halfJ * 2 / 3;
      const fx = { t0: performance.now(), x: g.x(P.laneFrac(lane), 0), y: g.judgeY, col };
      if (type === 4 && j !== 'miss') Object.assign(fx, { w: third * 1.4, h: third * 0.4, s0: 0.9, s1: 1.1, dur: 250, stops: [0, 0.45, 1], a: [0.85, 0.5, 0] });
      else if (type === 5) Object.assign(fx, { w: third * 0.3, h: third * 0.3, s0: 0.9, s1: 1.05, dur: 200, stops: [0, 1], a: [0.7, 0], white: true });
      else Object.assign(fx, { w: third * 0.6, h: third * 0.6, s0: 0.85, s1: 1.1, dur: j === 'miss' ? 180 : 250, stops: [0, 0.4, 1], a: [0.8, 0.55, 0] });
      this.effects.push(fx);
    }
    drawEffects(c) {
      const now = performance.now();
      this.effects = this.effects.filter(e => now - e.t0 < e.dur);
      for (const e of this.effects) {
        const u = (now - e.t0) / e.dur;
        const ease = 1 - (1 - u) * (1 - u);
        const sc = e.s0 + (e.s1 - e.s0) * ease;
        c.save();
        c.globalAlpha = 1 - ease;
        c.translate(e.x, e.y);
        c.scale(sc * e.w / 2, sc * e.h / 2);
        const grd = c.createRadialGradient(0, 0, 0, 0, 0, 1);
        const [r0, g0, b0] = e.col;
        e.stops.forEach((s, i) => {
          const white = i === 0 || e.white;
          grd.addColorStop(s, white ? 'rgba(255,255,255,' + e.a[i] + ')' : 'rgba(' + r0 + ',' + g0 + ',' + b0 + ',' + e.a[i] + ')');
        });
        c.fillStyle = grd;
        c.beginPath(); c.arc(0, 0, 1, 0, Math.PI * 2); c.fill();
        c.restore();
      }
    }

    // ------------------------------------------------------------ 文字・ゲージ
    judgeImage(j) {
      if (this.judgeImgs[j]) return this.judgeImgs[j];
      const H = this.H, dpr = this.dpr;
      const spec = {
        pp: ['PERFECT!!', ['rgb(153,240,255)', 'rgb(242,247,255)', 'rgb(237,173,242)'], 'rgb(107,117,143)'],
        p: ['PERFECT!', ['rgb(191,230,255)', 'rgb(242,242,250)', 'rgb(224,199,242)'], 'rgb(107,117,143)'],
        g: ['GREAT', ['rgb(255,217,115)', 'rgb(255,242,217)', 'rgb(255,158,209)'], 'rgb(140,107,102)'],
        miss: ['MISS', ['rgb(184,184,184)', 'rgb(184,184,184)'], 'rgb(92,92,92)'],
      }[j];
      const size = H * 0.105;
      const font = '900 ' + size + 'px ' + FONT;
      const m = document.createElement('canvas').getContext('2d');
      m.font = font;
      const tw = m.measureText(spec[0]).width + size * 0.03 * spec[0].length;
      const depth = Math.max(2, Math.round(H * 0.006));
      const cw = Math.ceil(tw + depth + 8), ch = Math.ceil(size * 1.3 + depth + 4);
      const cv = document.createElement('canvas');
      cv.width = cw * dpr; cv.height = ch * dpr;
      const x = cv.getContext('2d');
      x.scale(dpr, dpr);
      x.font = font; x.textBaseline = 'top';
      if ('letterSpacing' in x) x.letterSpacing = (H * 0.003) + 'px';
      x.fillStyle = spec[2];
      for (let k = depth; k >= 1; k--) x.fillText(spec[0], 4 + k * 0.5, 2 + k);
      const grad = x.createLinearGradient(0, 0, cw, 0);
      spec[1].forEach((col, i) => grad.addColorStop(spec[1].length === 3 ? i / 2 : i, col));
      x.fillStyle = grad;
      x.fillText(spec[0], 4, 2);
      this.judgeImgs[j] = { cv, w: cw, h: ch };
      return this.judgeImgs[j];
    }
    outlined(c, text, x, y, fill, stroke, width, align) {
      c.textAlign = align || 'left';
      c.lineJoin = 'round';
      c.strokeStyle = stroke; c.lineWidth = width; c.strokeText(text, x, y);
      c.fillStyle = fill; c.fillText(text, x, y);
      c.textAlign = 'left';
    }
    poly(c, pts, fill) {
      c.beginPath(); c.moveTo(pts[0][0], pts[0][1]);
      for (const p of pts.slice(1)) c.lineTo(p[0], p[1]);
      c.closePath(); c.fillStyle = fill; c.fill();
    }
    drawHUD(c, g, vt) {
      const W = this.W, H = this.H, u = H / 1440, game = this.game;
      c.textBaseline = 'middle';
      // 歌詞
      let lyric = '';
      for (const l of this.chart.lyrics) if (l.start <= vt && vt < l.end) lyric = l.text;
      if (lyric) {
        c.font = '600 15px "Yu Gothic UI", "Segoe UI", sans-serif';
        c.save(); c.shadowColor = '#000'; c.shadowBlur = 6;
        c.fillStyle = 'rgba(255,255,255,0.92)'; c.textAlign = 'center';
        c.fillText(lyric, g.midX, g.judgeY - 26, g.halfJ * 2); c.restore(); c.textAlign = 'left';
      }
      // 左上の帯
      this.poly(c, [[0, 40 * u], [615 * u, 40 * u], [560 * u, 90 * u], [0, 90 * u]], 'rgb(232,232,232)');
      c.font = '900 ' + 44 * u + 'px ' + FONT;
      this.outlined(c, 'SCORE ' + game.score, 12 * u, 66 * u, 'rgb(115,115,115)', '#fff', 4 * u * 2);
      this.poly(c, [[0, 90 * u], [560 * u, 90 * u], [425 * u, 225 * u], [0, 225 * u]], 'rgba(40,40,40,0.94)');
      c.font = '900 ' + 50 * u + 'px ' + FONT; c.fillStyle = '#fff';
      c.fillText(this.title, 16 * u, 134 * u, 470 * u);
      c.font = '500 ' + 25 * u + 'px "Yu Gothic UI", "Segoe UI", sans-serif'; c.fillStyle = 'rgba(255,255,255,0.9)';
      c.fillText(this.artist, 16 * u, 188 * u, 400 * u);
      const dInfo = F.diffInfo(this.diff);
      const dText = dInfo.label + ' Lv.' + F.lvRank(this.level);
      c.font = '900 ' + 31 * u + 'px ' + FONT;
      const dw = c.measureText(dText).width;
      const tagR = Math.max(330 * u, 16 * u + dw + 50 * u);
      this.poly(c, [[0, 225 * u], [tagR, 225 * u], [tagR - 65 * u, 272 * u], [0, 272 * u]], DIFF_COLORS[this.diff] || DIFF_COLORS[2]);
      c.fillStyle = '#fff'; c.fillText(dText, 16 * u, 249 * u);
      // ゲージ (到達可能なスコア) とランク
      const gr = { x: 20 * u, y: 276 * u, w: 46 * u, h: 634 * u };
      c.fillStyle = 'rgb(77,77,77)'; c.fillRect(gr.x, gr.y, gr.w, gr.h);
      const fh = gr.h * game.clearGauge;
      c.fillStyle = 'rgb(158,235,153)'; c.fillRect(gr.x, gr.y + gr.h - fh, gr.w, fh);
      c.font = '900 ' + 24 * u + 'px "Yu Gothic UI", "Segoe UI", sans-serif';
      c.save(); c.shadowColor = 'rgba(0,0,0,0.9)'; c.shadowBlur = 4; c.fillStyle = '#fff'; c.textAlign = 'center';
      c.fillText('到達可能', 183 * u, 304 * u); c.restore(); c.textAlign = 'left';
      const rc = { x: 183 * u, y: 368 * u }, rh = 72 * u;
      const rank = game.achievableRank;
      this.poly(c, [[rc.x, rc.y - rh], [rc.x + rh, rc.y], [rc.x, rc.y + rh], [rc.x - rh, rc.y]], 'rgba(31,31,31,0.85)');
      if (rank === 'SS' || rank === 'S') {
        c.strokeStyle = 'rgb(255,209,77)'; c.lineWidth = Math.max(1.5, 4 * u); c.stroke();
      }
      const rcol = rank === 'AP+' || rank === 'AP' ? 'rgb(128,255,255)' : (rank === 'SS' || rank === 'S') ? 'rgb(255,217,89)' : (rank === 'AA' || rank === 'A') ? 'rgb(255,153,191)' : 'rgb(235,235,235)';
      c.font = '900 ' + (rank.length >= 3 ? 50 : 66) * u + 'px ' + FONT;
      this.outlined(c, rank, rc.x, rc.y + 2 * u, rcol, 'rgb(20,20,20)', 3 * u * 2, 'center');
      // 右上の II
      c.fillStyle = 'rgba(33,33,33,0.85)';
      c.beginPath(); c.roundRect(W - 160 * u, 0, 150 * u, 160 * u, 10 * u); c.fill();
      c.fillStyle = '#fff';
      c.fillRect(W - 85 * u - 13 * u - 32 * u, 36 * u, 32 * u, 88 * u);
      c.fillRect(W - 85 * u + 13 * u, 36 * u, 32 * u, 88 * u);

      // コンボ
      if (game.combo > 0) {
        c.font = '900 ' + H * 0.14 + 'px ' + FONT;
        c.fillStyle = 'rgba(120,120,120,0.92)'; c.textAlign = 'center';
        c.fillText(String(game.combo), W / 2, H * 0.57); c.textAlign = 'left';
      }
      // 判定の文字
      if (game.lastJudge && vt - game.lastJudgeAt < 0.6) {
        const im = this.judgeImage(game.lastJudge);
        c.drawImage(im.cv, W / 2 - im.w / 2, H * 0.71 - im.h / 2, im.w, im.h);
        if (game.lastEarly !== null && (game.lastJudge === 'p' || game.lastJudge === 'g')) {
          c.font = '900 ' + H * 0.026 + 'px ' + FONT; c.textAlign = 'center';
          c.fillStyle = game.lastEarly ? 'rgb(115,191,255)' : 'rgb(255,140,115)';
          c.fillText(game.lastEarly ? 'FAST' : 'SLOW', W / 2, H * 0.8025); c.textAlign = 'left';
        }
      }
      // カウント
      if (vt < this.startAt && this.running) {
        c.font = 'bold 56px ' + FONT; c.fillStyle = '#fff'; c.textAlign = 'center';
        c.fillText(String(Math.ceil(this.startAt - vt)), W / 2, H * 0.22 + 35); c.textAlign = 'left';
      }
      if (this.settings.auto) {
        c.font = '900 ' + 30 * u + 'px ' + FONT; c.textAlign = 'right';
        this.outlined(c, 'AUTO', W - 180 * u, 80 * u, 'rgb(128,255,255)', 'rgb(20,20,20)', 6 * u, 'right');
      }
      // キーの案内 (判定ラインの下)
      c.font = '700 ' + Math.max(11, 26 * u) + 'px Consolas, monospace'; c.textAlign = 'center';
      const keys = ['D', 'F', 'J', 'K'], fr = [1 / 6, 5 / 12, 7 / 12, 5 / 6];
      const held = new Set(this.held.values());
      for (let k = 0; k < 4; k++) {
        c.fillStyle = held.has(k) ? 'rgba(255,255,255,0.9)' : 'rgba(255,255,255,0.28)';
        c.fillText(keys[k], g.x(fr[k], -0.08), g.y(-0.08));
      }
      c.textAlign = 'left';
    }
  }

  window.BXPlayScreen = PlayScreen;
})();
