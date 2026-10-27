// レーンの描画 (iPad 版 Renderers.swift の LaneRenderer をもとにした Canvas 版)
(function () {
  'use strict';
  const F = window.BXF, Beat = F.Beat, BX = F.BX, S = window.BXShapes;

  const C = {
    laneBg: 'rgba(14,16,22,0.96)',
    timePanel: 'rgba(88,88,66,0.55)',
    tap: ['#ffffff', '#99a3ad', '#fafcff', '#e6f2ff'],
    red: ['#ff4040', '#8f0d12', '#f24d4d', '#ff2626'],
    head: ['#a3e0ff', '#3385c7', '#d1f2ff', '#66ccff'],
    multi: ['#ff8fd9', '#b33385', '#ffd1f2', '#ff73cc'],
    sel: ['#ffa8a8', '#9e1a1f', '#ffd1d1', '#ff4d4d'],
    wipe: ['#f7fd4a', '#94964a', '#fffcc5', '#f2f240'],
    selWipe: ['#ff5c5c', '#944040', '#ffcccc', '#ff4d4d'],
    dot: ['rgba(234,251,255,0.86)', 'rgba(182,242,255,0.60)', 'rgba(243,252,254,0.94)'],
    selDot: ['rgba(255,240,240,0.86)', 'rgba(255,128,128,0.60)', 'rgba(255,230,230,0.94)'],
    ribbon: 'rgba(212,255,255,0.40)',
    selRibbon: 'rgba(255,199,199,0.40)',
  };
  const TAP_H = 11.5;

  function smallestPrime(d) {
    if (d < 4) return Math.max(d, 1);
    for (let p = 2; p * p <= d; p++) if (d % p === 0) return p;
    return d;
  }
  function lineStyle(rem, den) {
    if (rem === 0) return ['rgba(255,255,255,0.80)', 1.4];
    const rd = den / F.gcd(rem, den);
    if (rd === 2) return ['rgba(0,230,230,0.70)', 1.1];
    if (rd === 4) return ['rgba(217,77,217,0.60)', 1.0];
    if (rd === 3 || rd === 6 || rd === 12) return ['rgba(102,217,128,0.50)', 1.0];
    if (rd === 8) return ['rgba(255,255,255,0.30)', 0.8];
    return ['rgba(255,255,255,0.18)', 0.7];
  }

  /// 座標の変換。x255 = ノーツの横の位置 (0..255)、beat = 拍
  function makeGeo(W, H, ed) {
    const left = 58;
    const right = 170;
    const trackW = Math.max(220, Math.min(560, W - left - right - 20));
    const trackL = left + Math.max(10, (W - left - right - trackW) / 2);
    const playY = Math.round(H * 0.84);
    const ppb = ed.ppb;
    const vb = ed.viewBeat;
    return {
      W, H, trackL, trackW, playY, ppb,
      px: x => trackL + x / 255 * trackW,
      xOf: px => (px - trackL) / trackW * 255,
      py: b => playY - (b - vb) * ppb,
      beatOf: y => vb + (playY - y) / ppb,
    };
  }

  function rr(c, x, y, w, h, r) {
    c.beginPath();
    if (c.roundRect) c.roundRect(x, y, w, h, r);
    else c.rect(x, y, w, h);
  }

  function drawTap(c, cx, y, hw, tint, selected) {
    const col = selected ? C.sel : C[tint];
    const x = cx - hw, w = hw * 2, top = y - TAP_H / 2;
    rr(c, x, top, w, TAP_H, 3.2);
    c.lineWidth = 4; c.strokeStyle = hexA(col[3], 0.22); c.stroke();
    c.fillStyle = col[0]; c.fill();
    if (w > 8) {
      rr(c, x + 1.5, top + 1.5, w - 3, TAP_H - 3, 1.8); c.fillStyle = col[1]; c.fill();
      rr(c, x + 3, top + 3, w - 6, TAP_H - 6, 0.8); c.fillStyle = col[2]; c.fill();
    }
    if (selected && tint === 'red') { rr(c, x, top, w, TAP_H, 3.2); c.lineWidth = 1.5; c.strokeStyle = '#fff'; c.stroke(); }
  }
  function wipePath(c, xL, xR, yMid, h, t, delta) {
    const len = Math.sqrt(h * h + t * t);
    const tipDX = delta * len / h;
    const cornerDX = t + delta * (len - t) / h;
    const top = yMid - h + delta, bottom = yMid + h - delta;
    c.beginPath();
    c.moveTo(xL + tipDX, yMid);
    c.lineTo(xL + cornerDX, top);
    c.lineTo(xR - cornerDX, top);
    c.lineTo(xR - tipDX, yMid);
    c.lineTo(xR - cornerDX, bottom);
    c.lineTo(xL + cornerDX, bottom);
    c.closePath();
  }
  function drawWipe(c, xL, xR, yMid, selected) {
    const col = selected ? C.selWipe : C.wipe;
    const h = 6, cap = 4;
    const bx0 = xL + cap, bx1 = xR - cap, width = bx1 - bx0;
    if (width < 6) { rr(c, xL, yMid - h, Math.max(2, xR - xL), h * 2, 2); c.fillStyle = col[0]; c.fill(); return; }
    const t = Math.min(3.4, width / 2 - 1.5);
    wipePath(c, bx0, bx1, yMid, h, t, 0);
    c.lineWidth = 4; c.strokeStyle = hexA(col[3], 0.22); c.stroke();
    c.fillStyle = col[0]; c.fill();
    wipePath(c, bx0, bx1, yMid, h, t, 2); c.fillStyle = col[1]; c.fill();
    wipePath(c, bx0, bx1, yMid, h, t, 3.5); c.fillStyle = col[2]; c.fill();
    c.lineWidth = 1.6; c.strokeStyle = col[0];
    c.beginPath(); c.moveTo(xL + 3.2, yMid - 4.5); c.lineTo(xL + 0.8, yMid); c.lineTo(xL + 3.2, yMid + 4.5); c.stroke();
    c.beginPath(); c.moveTo(xR - 3.2, yMid - 4.5); c.lineTo(xR - 0.8, yMid); c.lineTo(xR - 3.2, yMid + 4.5); c.stroke();
  }
  function drawDot(c, x, y, selected, scale) {
    const col = selected ? C.selDot : C.dot;
    const s = scale || 0.8;
    const ring = (r1, r0, fill) => {
      c.beginPath(); c.arc(x, y, r1 * s, 0, Math.PI * 2);
      if (r0 > 0) c.arc(x, y, r0 * s, 0, Math.PI * 2, true);
      c.fillStyle = fill; c.fill('evenodd');
    };
    ring(11.4, 7.8, col[0]);
    ring(7.8, 4.5, col[1]);
    ring(4.5, 0, col[2]);
  }
  function hexA(hex, a) {
    const v = parseInt(hex.slice(1), 16);
    return 'rgba(' + ((v >> 16) & 255) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + a + ')';
  }

  /// ノーツを描く (iPad 版 drawNotes と同じ順番・色分け)
  function drawNotes(c, g, notes, selected, alpha) {
    const lo = g.beatOf(g.H) - 0.05, hi = g.beatOf(0) + 0.05;
    const dots = [], selDots = [];
    c.save();
    if (alpha !== undefined) c.globalAlpha = alpha;
    for (const n of notes) {
      if (!F.isSlide(n)) continue;
      const isSel = selected.has(n.id);
      const hw = n.w / 255 * g.trackW / 2;
      const sb = Beat.val(n.beat);
      const y0 = g.py(sb);
      if (y0 > -24 && y0 < g.H + 24) (isSel ? selDots : dots).push([g.px(n.x), y0]);
      let shape = [{ b: sb, x: n.x }];
      for (const s of n.segs) shape.push({ b: sb + Beat.val(s.beat), x: n.x + s.x });
      if ((F.isCurve(n) || F.hasEase(n)) && shape.length >= 2 && shape.every((p, i) => i === 0 || shape[i - 1].b <= p.b)) {
        shape = S.slideShape(shape.map(p => p.b), shape.map(p => p.x), F.eases(n), F.isCurve(n)).map(p => ({ b: p.x, x: p.y }));
      }
      c.fillStyle = isSel ? C.selRibbon : C.ribbon;
      const dummyA = F.isDummy(n) ? 0.35 : 1;
      const baseA = c.globalAlpha;
      c.globalAlpha = baseA * dummyA;
      for (let i = 1; i < shape.length; i++) {
        const a = shape[i - 1], b = shape[i];
        if (Math.max(a.b, b.b) < lo || Math.min(a.b, b.b) > hi) continue;
        let ta = 0, tb = 1;
        const db = b.b - a.b;
        if (db !== 0) {
          const t1 = (lo - a.b) / db, t2 = (hi - a.b) / db;
          ta = Math.max(0, Math.min(t1, t2)); tb = Math.min(1, Math.max(t1, t2));
        }
        if (tb < ta) continue;
        const pax = g.px(a.x + (b.x - a.x) * ta), pay = g.py(a.b + db * ta);
        const pbx = g.px(a.x + (b.x - a.x) * tb), pby = g.py(a.b + db * tb);
        c.beginPath();
        c.moveTo(pax - hw, pay); c.lineTo(pax + hw, pay); c.lineTo(pbx + hw, pby); c.lineTo(pbx - hw, pby);
        c.closePath(); c.fill();
      }
      c.globalAlpha = baseA;
      for (const s of n.segs) {
        const cy = g.py(sb + Beat.val(s.beat));
        if (cy > -24 && cy < g.H + 24) dots.push([g.px(n.x + s.x), cy]);
      }
    }
    const redKeys = new Set(), headKeys = new Set(), tapCount = {};
    for (const n of notes) {
      const b = Beat.val(n.beat);
      if (b < lo || b > hi) continue;
      const key = F.keyOf(n.beat, F.blockOfX(n.x));
      if (!F.isSlide(n) && n.type === 3) redKeys.add(key);
      if (F.isSlide(n)) headKeys.add(key);
    }
    for (const n of notes) {
      const b = Beat.val(n.beat);
      if (b < lo || b > hi) continue;
      const key = F.keyOf(n.beat, F.blockOfX(n.x));
      if (F.isSlide(n)) { if (F.headType(n) === 1 && !redKeys.has(key)) tapCount[key] = (tapCount[key] || 0) + 1; }
      else if (n.type === null || n.type === 1) tapCount[key] = (tapCount[key] || 0) + 1;
    }
    for (const n of notes) {
      const y = g.py(Beat.val(n.beat));
      if (y < -24 || y > g.H + 24) continue;
      const hw = n.w / 255 * g.trackW / 2;
      const cx = g.px(n.x);
      const isSel = selected.has(n.id);
      const kind = F.isSlide(n) ? F.headType(n) : (n.type === null ? 1 : n.type);
      if (kind === 0) continue;
      const key = F.keyOf(n.beat, F.blockOfX(n.x));
      if (F.isSlide(n) && kind === 1 && redKeys.has(key)) continue;
      const baseA = c.globalAlpha;
      if (F.isDummy(n)) c.globalAlpha = baseA * 0.4;
      if (kind === 4) drawWipe(c, cx - hw, cx + hw, y, isSel);
      else {
        let tint = F.isSlide(n) ? 'head' : (kind === 3 ? 'red' : 'tap');
        if (tint === 'tap' && headKeys.has(key)) tint = 'head';
        if (tint !== 'red' && (tapCount[key] || 0) >= 2) tint = 'multi';
        drawTap(c, cx, y, hw, tint, isSel);
      }
      c.globalAlpha = baseA;
    }
    for (const d of dots) drawDot(c, d[0], d[1], false);
    for (const d of selDots) drawDot(c, d[0], d[1], true);
    c.restore();
  }

  function draw(canvas, ed, extra) {
    const dpr = window.devicePixelRatio || 1;
    const W = canvas.clientWidth, H = canvas.clientHeight;
    if (canvas.width !== Math.round(W * dpr) || canvas.height !== Math.round(H * dpr)) {
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    }
    const c = canvas.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, W, H);
    const g = makeGeo(W, H, ed);
    const chart = ed.chart;

    // 背景
    c.fillStyle = '#07080c'; c.fillRect(0, 0, W, H);
    c.fillStyle = C.timePanel; c.fillRect(g.trackL - 50, 0, 50, H);
    c.fillStyle = C.laneBg; c.fillRect(g.trackL, 0, g.trackW, H);

    // part / 歌詞 (読むだけ。保存ではそのまま残る)
    drawParts(c, g, chart);

    // 縦の線: 3 鍵の境目 (太め) と 7 鍵の中心 (細い)
    for (let b = 0; b < 7; b++) {
      const x = g.px(F.centerX(b));
      c.strokeStyle = BX.tapBlocks.includes(b) ? 'rgba(120,200,255,0.10)' : 'rgba(255,255,255,0.05)';
      c.lineWidth = 1; c.beginPath(); c.moveTo(x, 0); c.lineTo(x, H); c.stroke();
    }
    for (let k = 0; k <= 3; k++) {
      const x = g.px(k * 85);
      c.strokeStyle = k === 0 || k === 3 ? 'rgba(255,255,255,0.55)' : 'rgba(255,255,255,0.22)';
      c.lineWidth = k === 0 || k === 3 ? 1.5 : 1; c.beginPath(); c.moveTo(x, 0); c.lineTo(x, H); c.stroke();
    }

    // 横の線 (拍の分割)
    const b0 = g.beatOf(H), b1 = g.beatOf(0);
    let d = Math.max(1, ed.snapDen);
    while (d > 1 && g.ppb / d < 6) d = d / smallestPrime(d);
    const t0 = Math.floor(b0 * d), t1 = Math.ceil(b1 * d);
    if (t1 >= t0 && t1 - t0 <= 1500) {
      for (let t = Math.max(0, t0); t <= t1; t++) {
        const y = Math.round(g.py(t / d)) + 0.5;
        const st = lineStyle(((t % d) + d) % d, d);
        c.strokeStyle = st[0]; c.lineWidth = st[1];
        c.beginPath(); c.moveTo(g.trackL, y); c.lineTo(g.trackL + g.trackW, y); c.stroke();
      }
    }
    // 拍の番号と時刻
    c.font = '600 15px "Segoe UI", system-ui, sans-serif';
    c.textBaseline = 'middle';
    let step = 1;
    while (g.ppb * step < 22) step *= 2;
    for (let b = Math.max(0, Math.floor(b0) - 1); b <= Math.ceil(b1); b++) {
      if (b % step) continue;
      const y = g.py(b + step / 2);
      c.fillStyle = b % 4 === 0 ? 'rgba(255,255,255,0.85)' : 'rgba(255,255,255,0.55)';
      c.fillText(String(b), g.trackL - 44, y);
    }

    // BPM 変化 / ソフラン (右側)
    c.font = '11px Consolas, monospace';
    chart.times.forEach((tp, i) => {
      const y = g.py(Beat.val(tp.beat));
      if (y < -20 || y > H + 20) return;
      if (i > 0) {
        c.setLineDash([6, 4]); c.strokeStyle = 'rgba(255,255,0,0.35)'; c.lineWidth = 1;
        c.beginPath(); c.moveTo(g.trackL, y); c.lineTo(g.trackL + g.trackW, y); c.stroke(); c.setLineDash([]);
      }
      c.fillStyle = 'rgba(255,230,0,0.9)';
      c.fillText('BPM ' + fmt(tp.bpm), g.trackL + g.trackW + 8, y - 8);
    });
    for (const sp of chart.speeds) {
      const y = g.py(Beat.val(sp.beat));
      if (y < -20 || y > H + 20) continue;
      c.setLineDash([2, 4]); c.strokeStyle = 'rgba(120,220,255,0.45)'; c.lineWidth = 1;
      c.beginPath(); c.moveTo(g.trackL, y); c.lineTo(g.trackL + g.trackW, y); c.stroke(); c.setLineDash([]);
      c.fillStyle = 'rgba(120,220,255,0.95)';
      c.fillText('×' + fmt(sp.value), g.trackL + g.trackW + 8, y + 8);
    }

    // 歌詞の始点 (置いている途中)
    if (ed.lyricsStart) {
      const y = g.py(Beat.val(ed.lyricsStart));
      c.fillStyle = 'rgba(178,255,115,0.95)';
      c.fillRect(g.trackL - 6, y - 1.5, g.trackW + 12, 3);
      c.font = 'bold 12px "Segoe UI", system-ui, sans-serif';
      c.fillText('歌詞 始点', g.trackL + 6, y - 8);
    }
    // Time range
    if (ed.rangeStart) {
      const y0 = g.py(Beat.val(ed.rangeStart));
      const y1 = ed.rangeEnd ? g.py(Beat.val(ed.rangeEnd)) : y0;
      c.fillStyle = 'rgba(255,165,0,0.14)';
      c.fillRect(g.trackL, Math.min(y0, y1), g.trackW, Math.max(2, Math.abs(y0 - y1)));
      c.fillStyle = 'rgba(255,165,0,0.9)';
      for (const y of [y0, y1]) c.fillRect(g.trackL, y - 1, g.trackW, 2);
    }
    // part の始点 (置いている途中)
    if (ed.partStart) {
      const y = g.py(Beat.val(ed.partStart));
      c.fillStyle = 'rgba(255,255,255,0.9)';
      c.fillRect(g.trackL - 6, y - 1.5, g.trackW + 12, 3);
      c.font = 'bold 12px "Segoe UI", system-ui, sans-serif';
      c.fillText('PART 始点', g.trackL + 6, y - 8);
    }
    drawNotes(c, g, chart.notes, ed.selected);
    drawMarks(c, g, chart.notes);

    // Slide modify: 選んでいるスライドの中継点に輪
    if (ed.tool === 'modify' && ed.modifyId) {
      const n = ed.note(ed.modifyId);
      if (n) {
        c.strokeStyle = 'rgba(0,230,230,0.9)'; c.lineWidth = 2;
        for (const s of n.segs) {
          const y = g.py(Beat.val(n.beat) + Beat.val(s.beat));
          if (y < -20 || y > H + 20) continue;
          c.beginPath(); c.arc(g.px(n.x + s.x), y, 11, 0, Math.PI * 2); c.stroke();
        }
      }
    }
    // スライドを置いている途中: 最後の点に印
    if (ed.slideDraft) {
      const last = ed.slideDraftLast();
      const y = g.py(Beat.val(last.beat));
      c.strokeStyle = 'rgba(255,170,60,0.95)'; c.lineWidth = 2;
      c.beginPath(); c.arc(g.px(last.x), y, 13, 0, Math.PI * 2); c.stroke();
    }

    // ゴースト (置く位置の見本)
    if (ed.ghost) {
      const gh = ed.ghost;
      const segs = gh.endBeat ? [{ beat: Beat.sub(gh.endBeat, gh.beat), x: gh.endX - gh.x }] : [];
      const type = gh.tool === 'wipe' ? 4 : (gh.tool === 'red' ? 3 : null);
      const n = { id: '_ghost', beat: gh.beat, x: gh.x, w: gh.w, type, segs, extra: {} };
      if (gh.noHead) n.extra[BX.headKey] = 0;
      drawNotes(c, g, [n], new Set(), 0.55);
    }

    // 範囲選択の四角
    if (ed.lasso) {
      const r = ed.lasso;
      c.fillStyle = 'rgba(255,140,60,0.12)'; c.strokeStyle = 'rgba(255,160,80,0.9)'; c.lineWidth = 1;
      c.fillRect(Math.min(r.x0, r.x1), Math.min(r.y0, r.y1), Math.abs(r.x1 - r.x0), Math.abs(r.y1 - r.y0));
      c.strokeRect(Math.min(r.x0, r.x1) + 0.5, Math.min(r.y0, r.y1) + 0.5, Math.abs(r.x1 - r.x0), Math.abs(r.y1 - r.y0));
    }

    // 再生ライン
    c.fillStyle = 'rgba(0,230,230,0.9)';
    c.fillRect(g.trackL - 6, g.playY - 1, g.trackW + 12, 2);
    c.font = '12px Consolas, monospace';
    c.fillStyle = 'rgba(0,230,230,0.95)';
    const sec = ed.secOfBeat(ed.viewBeat);
    c.fillText(Beat.label(ed.currentSnapBeat()), g.trackL + g.trackW + 8, g.playY + 12);
    c.fillText(fmtTime(sec), g.trackL + g.trackW + 8, g.playY + 27);

    if (extra && extra.hint) {
      c.fillStyle = 'rgba(255,255,255,0.55)';
      c.font = '15px "Segoe UI", system-ui, sans-serif';
      c.textAlign = 'center';
      c.fillText(extra.hint, g.trackL + g.trackW / 2, H * 0.4);
      c.textAlign = 'left';
    }
    return g;
  }

  function drawParts(c, g, chart) {
    const parts = Array.isArray(chart.bx.part) ? chart.bx.part : [];
    for (const p of parts) {
      const e = Array.isArray(p.parts) && p.parts[0];
      if (!e) continue;
      const s = Beat.val(F.beatOf(p)), en = Beat.val(F.beatOf(e));
      const y0 = g.py(s), y1 = g.py(en);
      if (y0 < 0 || y1 > g.H) {
        if (Math.max(y0, y1) < 0 || Math.min(y0, y1) > g.H) continue;
      }
      // iPad 版と同じく、区間はレーンの両端を太い白線に
      c.fillStyle = 'rgba(255,255,255,0.05)';
      c.fillRect(g.trackL, y1, g.trackW, y0 - y1);
      c.fillStyle = 'rgba(255,255,255,0.85)';
      c.fillRect(g.trackL - 4, y1, 4, y0 - y1);
      c.fillRect(g.trackL + g.trackW, y1, 4, y0 - y1);
      c.fillRect(g.trackL - 4, y0 - 1, 14, 2);
      c.fillRect(g.trackL - 4, y1 - 1, 14, 2);
      c.fillRect(g.trackL + g.trackW - 10, y0 - 1, 14, 2);
      c.fillRect(g.trackL + g.trackW - 10, y1 - 1, 14, 2);
      c.font = '900 11px "Segoe UI", system-ui, sans-serif';
      c.fillText('PART', g.trackL - 34, Math.min(g.H - 8, Math.max(12, y0 - 8)));
    }
    const lyrics = Array.isArray(chart.bx.lyrics) ? chart.bx.lyrics : [];
    c.font = 'bold 12px "Segoe UI", system-ui, sans-serif';
    for (const l of lyrics) {
      const e = Array.isArray(l.parts) && l.parts[0];
      if (!e) continue;
      const y0 = g.py(Beat.val(F.beatOf(l))), y1 = g.py(Beat.val(F.beatOf(e)));
      if (Math.max(y0, y1) < 0 || Math.min(y0, y1) > g.H) continue;
      c.fillStyle = 'rgba(178,255,115,0.5)';
      c.fillRect(g.trackL + g.trackW + 2, y1, 3, y0 - y1);
      c.fillStyle = 'rgba(178,255,115,0.95)';
      c.fillText('♪ ' + (l.text || ''), g.trackL + g.trackW + 8, y0 - 22);
    }
  }

  function drawMarks(c, g, notes) {
    const rows = {};
    c.font = 'bold 12px "Segoe UI", system-ui, sans-serif';
    for (const n of notes) {
      const y = g.py(Beat.val(n.beat));
      if (y < -24 || y > g.H + 24) continue;
      const k = F.keyOf(n.beat, F.blockOfX(n.x));
      const hw = n.w / 255 * g.trackW / 2;
      const cx = g.px(n.x);
      const sp = F.noteSpeed(n);
      if (sp !== null) {
        const r = rows[k + 's'] = (rows[k + 's'] || 0) + 1;
        c.fillStyle = sp > 1 ? '#ff73bf' : '#73d9ff';
        c.textAlign = 'right';
        c.fillText('×' + fmt(sp), cx + hw - 2, y - 13 - (r - 1) * 13);
        c.textAlign = 'left';
      }
      if (F.isDummy(n)) {
        const r = rows[k + 'd'] = (rows[k + 'd'] || 0) + 1;
        c.fillStyle = '#d9d9d9';
        c.fillText('D', cx - hw + 2, y - 13 - (r - 1) * 13);
      }
      const ap = F.atBeats(n, BX.appearKey).map(b => ({ b, show: true }));
      const va = F.atBeats(n, BX.vanishKey).map(b => ({ b, show: false }));
      const ev = ap.concat(va).sort((a, b) => Beat.cmp(a.b, b.b));
      if (ev.length) {
        const r = rows[k + 'a'] = (rows[k + 'a'] || 0) + 1;
        c.fillStyle = '#bfff8c';
        c.textAlign = 'right';
        c.fillText((F.isSlide(n) ? '[帯] ' : '') + ev.map(e => (e.show ? '出 ' : '消 ') + Beat.label(e.b)).join(' '), cx + hw - 2, y + 15 + (r - 1) * 13);
        c.textAlign = 'left';
      }
    }
  }

  function fmt(v) { return (Math.round(v * 1000) / 1000).toString(); }
  function fmtTime(s) {
    const neg = s < 0; s = Math.abs(s);
    const m = Math.floor(s / 60), r = s - m * 60;
    return (neg ? '-' : '') + m + ':' + (r < 10 ? '0' : '') + r.toFixed(3);
  }

  window.BXView = { draw, makeGeo, fmtTime, fmt };
})();
