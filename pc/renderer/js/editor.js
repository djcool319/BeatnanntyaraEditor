// エディタの状態と編集操作 (iPad 版 EditorState / EditorState+Tools / EditorState+Beatrix の PC 版)
(function () {
  'use strict';
  const F = window.BXF, Beat = F.Beat, BX = F.BX, S = window.BXShapes;

  function loadPref(key, dflt) {
    try { const v = localStorage.getItem('bx.' + key); return v === null ? dflt : JSON.parse(v); } catch (e) { return dflt; }
  }
  function savePref(key, v) { try { localStorage.setItem('bx.' + key, JSON.stringify(v)); } catch (e) { /* なくても動く */ } }

  const TOOLS = ['select', 'tap', 'red', 'wipe', 'slide', 'modify', 'ease', 'erase'];   // ホールドは「全部同じ鍵のスライド」

  class Editor {
    constructor() {
      this.chart = F.newChart('', 120, 2);
      this.filePath = null;          // 開いている JSON のパス (新規なら null)
      this.dirty = false;
      this.selected = new Set();
      this.tool = 'select';
      this.slideWithHead = loadPref('slideWithHead', true);
      this.linkHeadTap = loadPref('linkHeadTap', false);   // iPad 版と同じく初期値はオフ
      this.allowSegVertical = loadPref('allowSegVertical', true);
      this.snapDen = loadPref('snapDen', 4);
      this.ppb = loadPref('ppb', 160);   // 1 拍の高さ (px)
      this.viewBeat = 0;                 // 再生ライン (シアンの横線) の拍
      this.undoStack = [];
      this.redoStack = [];
      this.clip = [];
      this.slideDraft = null;            // {noteId, beat, x, w}
      this.modifyId = null;              // Slide modify で選んでいるスライド
      this.ghost = null;
      this.drag = null;                  // マウス操作の途中の状態
      this.lasso = null;                 // 範囲選択の四角 {x0,y0,x1,y1}
      this.isPlaying = false;
      this.onChange = () => {};
      this.onToast = () => {};
      this.rebuildTime();
    }

    // ------------------------------------------------------------ 共通
    toast(s) { this.onToast(s); }
    emit() { this.onChange(); }
    rebuildTime() { this.timeMap = F.TimeMap(this.chart.times); }
    setPref(key, v) { this[key] = v; savePref(key, v); this.emit(); }

    loadChart(chart, filePath) {
      this.chart = chart;
      this.filePath = filePath || null;
      this.selected = new Set();
      this.undoStack = [];
      this.redoStack = [];
      this.slideDraft = null;
      this.modifyId = null;
      this.ghost = null;
      this.drag = null;
      this.viewBeat = 0;
      this.dirty = false;
      this.normalize();
      this.rebuildTime();
      this.emit();
    }

    snapshot() {
      return JSON.stringify({ bx: this.chart.bx, times: this.chart.times, speeds: this.chart.speeds, notes: this.chart.notes });
    }
    restore(s) {
      const o = JSON.parse(s);
      this.chart.bx = o.bx; this.chart.times = o.times; this.chart.speeds = o.speeds; this.chart.notes = o.notes;
      this.changed();
    }
    pushUndo() {
      this.undoStack.push(this.snapshot());
      if (this.undoStack.length > 300) this.undoStack.shift();
      this.redoStack = [];
    }
    dropLastUndo() { this.undoStack.pop(); }
    undo() {
      if (this.isPlaying) return;
      if (!this.undoStack.length) { this.toast('これ以上戻せません'); return; }
      this.redoStack.push(this.snapshot());
      this.slideDraft = null;
      this.restore(this.undoStack.pop());
    }
    redo() {
      if (this.isPlaying) return;
      if (!this.redoStack.length) { this.toast('やり直せる操作がありません'); return; }
      this.undoStack.push(this.snapshot());
      this.restore(this.redoStack.pop());
    }

    /// 譜面が変わったあと: 位置を鍵の中心にそろえ、消えたノーツを選択から外し、時間を作り直す
    changed() {
      this.normalize();
      const ids = new Set(this.chart.notes.map(n => n.id));
      for (const id of Array.from(this.selected)) if (!ids.has(id)) this.selected.delete(id);
      if (this.modifyId && !ids.has(this.modifyId)) this.modifyId = null;
      this.rebuildTime();
      this.dirty = true;
      this.emit();
    }

    /// iPad 版 Beatrix.normalized と同じ (位置を 7 鍵の中心に、幅をそろえる)
    normalize() {
      for (const n of this.chart.notes) {
        const nx = F.centerX(F.blockOfX(n.x));
        if (F.isSlide(n)) {
          for (const s of n.segs) s.x = F.centerX(F.blockOfX(n.x + s.x)) - nx;
          n.type = null;
        }
        n.x = nx;
        n.w = F.widthFor(n);
      }
    }

    guardPlaying() {
      if (this.isPlaying) { this.toast('再生中は編集できません。止めてから操作してください'); return true; }
      return false;
    }

    note(id) { return this.chart.notes.find(n => n.id === id); }
    selectedNotes() { return this.chart.notes.filter(n => this.selected.has(n.id)); }
    linkedSlide(n) {
      const sid = n.extra[BX.headLinkKey];
      if (!sid) return null;
      const s = this.note(sid);
      return s && F.isSlide(s) ? s : null;
    }

    setTool(t) {
      if (!TOOLS.includes(t)) return;
      if (this.slideDraft) this.finishSlide();
      this.ghost = null;
      if (t !== 'modify') this.modifyId = null;
      this.tool = t;
      this.emit();
    }

    snapBeat(v) { return Beat.nearest(Math.max(0, v), this.snapDen); }
    tapOnlyTool() { return this.tool === 'tap' || this.tool === 'red'; }
    snapX(x255) {
      const tapOnly = this.tapOnlyTool();
      return { x: F.centerX(F.blockOfX(x255, tapOnly)), w: tapOnly ? BX.tapW : BX.sideW };
    }
    currentSnapBeat() { return this.snapBeat(this.viewBeat); }

    // ------------------------------------------------------------ 当たり判定
    noteHit(n, p, g) {
      const y0 = g.py(Beat.val(n.beat));
      const cx = g.px(n.x);
      const hw = n.w / 255 * g.trackW / 2;
      if (Math.abs(p.y - y0) <= 10 && Math.abs(p.x - cx) <= hw + 4) return true;
      if (F.isSlide(n)) {
        const pts = [{ x: cx, y: y0 }];
        for (const s of n.segs) pts.push({ x: g.px(n.x + s.x), y: g.py(Beat.val(n.beat) + Beat.val(s.beat)) });
        for (let k = 0; k < pts.length - 1; k++) {
          const a = pts[k], b = pts[k + 1];
          const poly = [{ x: a.x - hw, y: a.y }, { x: a.x + hw, y: a.y }, { x: b.x + hw, y: b.y }, { x: b.x - hw, y: b.y }];
          if (pointInPolygon(p, poly)) return true;
        }
        for (const q of pts) if (Math.hypot(q.x - p.x, q.y - p.y) < 12) return true;
      }
      return false;
    }
    /// 上に描いてあるものを優先 (タップは帯より手前)
    hitNote(p, g) {
      const notes = this.chart.notes;
      for (let i = notes.length - 1; i >= 0; i--) {
        const n = notes[i];
        if (F.isSlide(n)) continue;
        if (this.noteHit(n, p, g)) return n;
      }
      for (let i = notes.length - 1; i >= 0; i--) {
        const n = notes[i];
        if (F.isSlide(n) && this.noteHit(n, p, g)) return n;
      }
      return null;
    }
    hitSegAny(p, g) {
      const reach = 16;
      let best = null, bestScore = Infinity;
      for (const n of this.chart.notes) {
        if (!F.isSlide(n)) continue;
        const bonus = n.id === this.modifyId ? 3 : 0;
        n.segs.forEach((s, j) => {
          const qy = g.py(Beat.val(n.beat) + Beat.val(s.beat));
          if (Math.abs(qy - p.y) > reach) return;
          const d = Math.hypot(g.px(n.x + s.x) - p.x, qy - p.y);
          if (d >= reach) return;
          if (d - bonus < bestScore) { bestScore = d - bonus; best = { note: n, j }; }
        });
      }
      return best;
    }

    // ------------------------------------------------------------ マウス
    /// p = キャンバス上の座標、g = 座標変換、mods = {shift, ctrl, button}
    pointerDown(p, g, mods) {
      this.drag = null;
      if (mods.button === 2) { this.rightClick(p, g); return; }
      if (this.isPlaying) { this.toast('再生中は編集できません。止めてから操作してください'); return; }
      const t = this.tool;
      if (t === 'erase') {
        const n = this.hitNote(p, g);
        if (n) this.removeAt(n, p, g);
        return;
      }
      if (t === 'ease') { this.easePick(p, g); return; }
      if (t === 'modify') {
        const h = this.hitSegAny(p, g);
        if (h) {
          if (this.modifyId !== h.note.id) { this.modifyId = h.note.id; this.selected = new Set([h.note.id]); }
          const s = h.note.segs[h.j];
          this.drag = { kind: 'seg', id: h.note.id, j: h.j, orig: { beat: s.beat, x: s.x }, start: p, pushed: false,
            grab: { x: g.px(h.note.x + s.x) - p.x, y: g.py(Beat.val(h.note.beat) + Beat.val(s.beat)) - p.y } };
          this.emit();
        } else {
          this.modifyTap(p, g);
        }
        return;
      }
      const placing = ['tap', 'red', 'wipe', 'slide'].includes(t);
      // 置くツールで Shift を押しながらクリック: スライドを置く (Shift を離すと完了。前のエディターと同じ癖)
      if (placing && mods.shift && !mods.ctrl && !this.slideDraft) {
        if (this.selected.size) this.selected = new Set();
        const b = this.snapBeat(g.beatOf(p.y));
        const q = { x: F.centerX(F.blockOfX(g.xOf(p.x))), w: BX.sideW };
        this.slideDraft = { noteId: F.newId(), beat: b, x: q.x, w: q.w, pressed: true, byShift: true };
        this.drag = { kind: 'place', start: p };
        this.emit();
        return;
      }
      if (this.slideDraft && (t === 'slide' || this.slideDraft.byShift)) {
        this.drag = { kind: 'place', start: p };
        return;
      }
      const hit = this.hitNote(p, g);
      if (hit) {
        const linked = this.linkHeadTap ? this.linkedSlide(hit) : null;
        if (mods.ctrl || mods.shift) {
          if (this.selected.has(hit.id)) {
            this.selected.delete(hit.id);
            if (linked) this.selected.delete(linked.id);
            this.emit();
            return;
          }
          this.selected.add(hit.id);
          if (linked) this.selected.add(linked.id);
        } else if (!this.selected.has(hit.id)) {
          this.selected = new Set([hit.id]);
          if (linked) this.selected.add(linked.id);
        }
        this.drag = { kind: 'pendingMove', start: p, id: hit.id, wasSelected: true, mods };
        this.emit();
        return;
      }
      if (t === 'select' || mods.ctrl || (mods.shift && !placing)) {
        if (!(mods.shift || mods.ctrl)) this.selected = new Set();
        this.drag = { kind: 'lasso', start: p, base: new Set(this.selected) };
        this.lasso = { x0: p.x, y0: p.y, x1: p.x, y1: p.y };
        this.emit();
        return;
      }
      if (placing) {
        if (this.selected.size) { this.selected = new Set(); }
        this.drag = { kind: 'place', start: p };
        if (t === 'slide') {
          // 押した所が始点。そのまま後ろの拍までドラッグして離すと、そこが 1 つ目の中継点 (同じ鍵ならホールド)
          const b = this.snapBeat(g.beatOf(p.y));
          const q = this.snapX(g.xOf(p.x));
          this.slideDraft = { noteId: F.newId(), beat: b, x: q.x, w: q.w, pressed: true };
        }
        this.emit();
      }
    }

    pointerMove(p, g, mods) {
      const d = this.drag;
      if (!d) { this.updateGhost(p, g); return; }
      const moved = Math.hypot(p.x - d.start.x, p.y - d.start.y) > 5;
      if (d.kind === 'pendingMove' && moved) this.beginMove(d, g);
      if (d.kind === 'moving') this.applyMove(p, g);
      else if (d.kind === 'lasso') {
        this.lasso.x1 = p.x; this.lasso.y1 = p.y;
        this.selectInRect(g, d.base);
      } else if (d.kind === 'seg') {
        if (moved || d.pushed) this.dragSeg(p, g);
      } else if (d.kind === 'place') {
        this.updateGhost(p, g);
      }
    }

    pointerUp(p, g, mods) {
      const d = this.drag;
      this.drag = null;
      if (!d) return;
      const moved = Math.hypot(p.x - d.start.x, p.y - d.start.y) > 5;
      if (d.kind === 'moving') { this.finishMove(); return; }
      if (d.kind === 'pendingMove') {
        // 動かさずに離した: 修飾キーなしなら、そのノーツ (と結び付いたスライド) だけを選ぶ
        if (!(d.mods.ctrl || d.mods.shift)) {
          const n = this.note(d.id);
          if (n) {
            this.selected = new Set([n.id]);
            const linked = this.linkHeadTap ? this.linkedSlide(n) : null;
            if (linked) this.selected.add(linked.id);
          }
        }
        this.emit();
        return;
      }
      if (d.kind === 'lasso') { this.lasso = null; this.emit(); return; }
      if (d.kind === 'seg') { if (d.pushed) this.changed(); else this.emit(); return; }
      if (d.kind === 'place') {
        this.place(p, g, moved);
        if (this.slideDraft && this.slideDraft.byShift && !this.shiftHeld && !this.slideDraft.pressed) this.finishSlide();
      }
    }

    rightClick(p, g) {
      if (this.isPlaying) return;
      if (this.slideDraft) { this.finishSlide(); return; }
      const n = this.hitNote(p, g);
      if (n) this.removeAt(n, p, g);
    }

    updateGhost(p, g) {
      const t = this.tool;
      if (!['tap', 'red', 'wipe', 'slide'].includes(t) || this.isPlaying || p === null || this.drag && this.drag.kind !== 'place') {
        if (this.ghost) { this.ghost = null; this.emit(); }
        return;
      }
      const b = this.snapBeat(g.beatOf(p.y));
      const slideMode = this.slideDraft || this.shiftHeld;     // Shift の間はスライドの見本
      const q = slideMode ? { x: F.centerX(F.blockOfX(g.xOf(p.x))), w: BX.sideW } : this.snapX(g.xOf(p.x));
      let gh;
      if (this.slideDraft) {
        const last = this.slideDraftLast();
        gh = Beat.cmp(b, last.beat) < 0 ? null : { tool: t, beat: last.beat, x: last.x, w: BX.sideW, endBeat: b, endX: q.x };
      } else if (slideMode) {
        gh = { tool: 'slide', beat: b, x: q.x, w: q.w, noHead: !this.slideWithHead };
      } else {
        gh = { tool: t, beat: b, x: q.x, w: q.w, noHead: t === 'slide' ? !this.slideWithHead : false };
      }
      this.ghost = gh;
      this.emit();
    }
    clearGhost() { if (this.ghost) { this.ghost = null; this.emit(); } }

    // ------------------------------------------------------------ 置く
    place(p, g, moved) {
      const t = this.tool;
      const b = this.snapBeat(g.beatOf(p.y));
      const slideMode = !!this.slideDraft;
      const q = slideMode ? { x: F.centerX(F.blockOfX(g.xOf(p.x))), w: BX.sideW } : this.snapX(g.xOf(p.x));
      if (!slideMode && (t === 'tap' || t === 'red' || t === 'wipe')) {
        const n = F.makeNote(b, q.x, q.w, t === 'wipe' ? 4 : (t === 'red' ? 3 : null));
        this.addNote(n);
        return;
      }
      if (slideMode) {
        const d = this.slideDraft;
        if (d.pressed) {
          // 始点を押して離したところ
          d.pressed = false;
          if (!moved || Beat.cmp(b, d.beat) <= 0) {
            this.toast(d.byShift ? '始点を置きました。Shift を押したまま中継点をクリック (離すと完了)' : '始点を置きました。続けて中継点をクリック (同じ鍵ならホールド。Enter / 右クリックで完了)');
            this.updateGhost(p, g);
            return;
          }
          this.appendDraftSeg(b, q.x);       // ドラッグで置いた 1 つ目の中継点
          this.toast('続けて中継点をクリック (Enter / 右クリックで完了)');
          return;
        }
        const last = this.slideDraftLast();
        if (Beat.cmp(b, last.beat) < 0) { this.finishSlide(); return; }
        this.appendDraftSeg(b, q.x);
      }
    }

    addNote(n) {
      if (Beat.val(n.beat) < 0) return;
      for (const e of this.chart.notes) {
        if (Beat.eq(e.beat, n.beat) && e.x === n.x && e.w === n.w && e.type === n.type && !F.isSlide(e) && !F.isSlide(n)) return;
      }
      this.pushUndo();
      this.chart.notes.push(n);
      this.changed();
    }

    slideDraftNote() { return this.slideDraft ? this.note(this.slideDraft.noteId) : null; }
    slideDraftLast() {
      const d = this.slideDraft;
      const n = this.slideDraftNote();
      if (n && n.segs.length) {
        const s = n.segs[n.segs.length - 1];
        return { beat: Beat.add(n.beat, s.beat), x: n.x + s.x };
      }
      return { beat: n ? n.beat : d.beat, x: n ? n.x : d.x };
    }
    appendDraftSeg(b, x) {
      const d = this.slideDraft;
      const last = this.slideDraftLast();
      if (Beat.eq(b, last.beat) && x === last.x) { this.toast('直前の点と同じ位置です'); return; }
      const n = this.slideDraftNote();
      this.pushUndo();
      if (n) {
        n.segs.push({ beat: Beat.sub(b, n.beat), x: x - n.x });
      } else {
        const m = F.makeNote(d.beat, d.x, d.w, null, [{ beat: Beat.sub(b, d.beat), x: x - d.x }]);
        m.id = d.noteId;
        m.extra[BX.headKey] = 0;
        this.chart.notes.push(m);
        if (this.slideWithHead) {
          // 始点にもうタップがあれば、それを始点にする (同じ所にタップを 2 つ置かない)
          const key = F.keyOf(d.beat, F.blockOfX(d.x));
          const old = this.chart.notes.find(e => !F.isSlide(e) && e.type === null && !e.extra[BX.headLinkKey] && F.keyOf(e.beat, F.blockOfX(e.x)) === key);
          if (old) old.extra[BX.headLinkKey] = m.id;
          else {
            const h = F.makeNote(d.beat, d.x, BX.tapW, null);
            h.extra[BX.headLinkKey] = m.id;
            this.chart.notes.push(h);
          }
        }
      }
      this.changed();
    }
    finishSlide() {
      if (!this.slideDraft) return;
      const n = this.slideDraftNote();
      this.slideDraft = null;
      this.ghost = null;
      this.toast(n ? 'スライドを作りました (中継点 ' + n.segs.length + ' 個)' : '中継点が無いので、始点を取り消しました');
      this.emit();
    }

    // ------------------------------------------------------------ 動かす
    beginMove(d, g) {
      const targets = this.chart.notes.filter(n => this.selected.has(n.id)).map(n => ({ n, orig: F.cloneNote(n) }));
      if (!targets.length) { this.drag = null; return; }
      const touched = targets.find(t => t.n.id === d.id) || targets[0];
      let minBeat = targets[0].orig.beat, left = 255, right = 0;
      for (const t of targets) {
        const o = t.orig;
        if (Beat.cmp(o.beat, minBeat) < 0) minBeat = o.beat;
        let mnx = o.x, mxx = o.x;
        for (const s of o.segs) {
          const sb = Beat.add(o.beat, s.beat);
          if (Beat.cmp(sb, minBeat) < 0) minBeat = sb;
          mnx = Math.min(mnx, o.x + s.x); mxx = Math.max(mxx, o.x + s.x);
        }
        left = Math.min(left, mnx - o.w / 2);
        right = Math.max(right, mxx + o.w / 2);
      }
      this.pushUndo();
      this.drag = { kind: 'moving', start: d.start, targets, anchor: touched.orig.beat, minBeat, left, right,
        tapLike: targets.some(t => F.isTapLike(t.orig)), lastDelta: Beat.zero, lastDX: 0 };
    }
    applyMove(p, g) {
      const d = this.drag;
      const rawBeats = (d.start.y - p.y) / this.ppb;
      let delta = Beat.sub(this.snapBeat(Beat.val(d.anchor) + rawBeats), d.anchor);
      if (Beat.cmp(d.minBeat, Beat.zero) >= 0 && Beat.cmp(Beat.add(d.minBeat, delta), Beat.zero) < 0) delta = Beat.sub(Beat.zero, d.minBeat);
      const rawX = g.xOf(p.x) - g.xOf(d.start.x);
      const step = d.tapLike ? 85 : 255 / 9;
      let dx = Math.round(Math.round(rawX / step) * step);
      dx = Math.max(Math.min(0, Math.ceil(-d.left)), Math.min(Math.max(0, Math.floor(255 - d.right)), dx));
      if (Beat.eq(delta, d.lastDelta) && dx === d.lastDX) return;
      d.lastDelta = delta; d.lastDX = dx;
      for (const t of d.targets) {
        t.n.beat = Beat.add(t.orig.beat, delta);
        t.n.x = t.orig.x + dx;
        F.shiftAtBeats(t.n, t.orig, delta);
      }
      this.emit();
    }
    finishMove() {
      const d = this.drag;
      this.drag = null;
      if (d && d.kind === 'moving' && Beat.eq(d.lastDelta, Beat.zero) && d.lastDX === 0) { this.dropLastUndo(); this.emit(); return; }
      this.changed();
    }
    /// キーボードで選択中のノーツを動かす (上下 = 1 スナップ、左右 = 1 鍵 / タップは 3 鍵)
    nudge(dBeatSteps, dLane) {
      if (this.guardPlaying()) return;
      const sel = this.selectedNotes();
      if (!sel.length) return;
      const delta = Beat.make(dBeatSteps, this.snapDen);
      const tapLike = sel.some(n => F.isTapLike(n));
      const dx = Math.round(dLane * (tapLike ? 85 : 255 / 9));
      let minBeat = Infinity, left = 255, right = 0;
      for (const n of sel) {
        minBeat = Math.min(minBeat, Beat.val(n.beat));
        let mnx = n.x, mxx = n.x;
        for (const s of n.segs) { minBeat = Math.min(minBeat, Beat.val(n.beat) + Beat.val(s.beat)); mnx = Math.min(mnx, n.x + s.x); mxx = Math.max(mxx, n.x + s.x); }
        left = Math.min(left, mnx - n.w / 2); right = Math.max(right, mxx + n.w / 2);
      }
      if (minBeat + Beat.val(delta) < -1e-9) return;
      if (left + dx < -1 || right + dx > 256) return;
      this.pushUndo();
      for (const n of sel) {
        const orig = F.cloneNote(n);
        n.beat = Beat.add(n.beat, delta);
        n.x += dx;
        F.shiftAtBeats(n, orig, delta);
      }
      this.changed();
    }

    selectInRect(g, base) {
      const r = this.lasso;
      const x0 = Math.min(r.x0, r.x1), x1 = Math.max(r.x0, r.x1), y0 = Math.min(r.y0, r.y1), y1 = Math.max(r.y0, r.y1);
      const inside = (x, y) => x >= x0 && x <= x1 && y >= y0 && y <= y1;
      const sel = new Set(base);
      for (const n of this.chart.notes) {
        const b0 = Beat.val(n.beat);
        let hit = inside(g.px(n.x), g.py(b0));
        if (!hit && F.isSlide(n)) hit = n.segs.some(s => inside(g.px(n.x + s.x), g.py(b0 + Beat.val(s.beat))));
        if (hit) {
          sel.add(n.id);
          const linked = this.linkHeadTap ? this.linkedSlide(n) : null;
          if (linked) sel.add(linked.id);
        }
      }
      this.selected = sel;
      this.emit();
    }

    // ------------------------------------------------------------ Slide modify
    modifyTap(p, g) {
      const cur = this.modifyId ? this.note(this.modifyId) : null;
      if (cur && this.noteHit(cur, p, g)) { this.modifyId = null; this.selected.delete(cur.id); this.emit(); return; }
      for (let i = this.chart.notes.length - 1; i >= 0; i--) {
        const n = this.chart.notes[i];
        if (F.isSlide(n) && n.id !== this.modifyId && this.noteHit(n, p, g)) {
          this.modifyId = n.id; this.selected = new Set([n.id]); this.emit(); return;
        }
      }
      if (!cur) { this.toast('中継点を足すスライドを先にクリックしてください'); return; }
      const b = this.snapBeat(g.beatOf(p.y));
      const lastBeat = cur.segs.length ? Beat.add(cur.beat, cur.segs[cur.segs.length - 1].beat) : cur.beat;
      if (Beat.cmp(b, lastBeat) < 0) { this.modifyId = null; this.selected.delete(cur.id); this.emit(); return; }
      const q = F.centerX(F.blockOfX(g.xOf(p.x)));
      let same = Beat.eq(b, cur.beat) && q === cur.x;
      for (const s of cur.segs) if (Beat.eq(Beat.add(cur.beat, s.beat), b) && cur.x + s.x === q) same = true;
      if (same) { this.toast('その位置には、すでに点があります'); return; }
      this.pushUndo();
      cur.segs.push({ beat: Beat.sub(b, cur.beat), x: q - cur.x });
      this.changed();
    }
    dragSeg(p, g) {
      const d = this.drag;
      const n = this.note(d.id);
      if (!n || d.j >= n.segs.length) { this.drag = null; return; }
      const cur = n.segs[d.j];
      let segBeat = d.orig.beat;
      if (this.allowSegVertical) {
        let b = this.snapBeat(g.beatOf(p.y + d.grab.y));
        const myBeat = Beat.add(n.beat, d.orig.beat);
        const prevBeat = d.j === 0 ? n.beat : Beat.add(n.beat, n.segs[d.j - 1].beat);
        if (Beat.cmp(prevBeat, myBeat) <= 0 && Beat.cmp(b, prevBeat) < 0) b = prevBeat;
        if (d.j + 1 < n.segs.length) {
          const nextBeat = Beat.add(n.beat, n.segs[d.j + 1].beat);
          if (Beat.cmp(nextBeat, myBeat) >= 0 && Beat.cmp(b, nextBeat) > 0) b = nextBeat;
        }
        segBeat = Beat.sub(b, n.beat);
      }
      const x = F.centerX(F.blockOfX(g.xOf(p.x + d.grab.x))) - n.x;
      if (Beat.eq(segBeat, cur.beat) && x === cur.x) return;
      if (!d.pushed) { this.pushUndo(); d.pushed = true; }
      n.segs[d.j] = { beat: segBeat, x };
      this.emit();
    }

    // ------------------------------------------------------------ 消す
    removeAt(n, p, g) {
      if (this.guardPlaying()) return;
      if (!F.isSlide(n)) {
        this.pushUndo();
        this.chart.notes = this.chart.notes.filter(m => m !== n);
        this.changed();
        return;
      }
      const hw = n.w / 255 * g.trackW / 2;
      const pts = [{ x: g.px(n.x), y: g.py(Beat.val(n.beat)) }];
      for (const s of n.segs) pts.push({ x: g.px(n.x + s.x), y: g.py(Beat.val(n.beat) + Beat.val(s.beat)) });
      let bestK = 0, bestScore = Infinity;
      pts.forEach((q, k) => {
        const dx = Math.max(0, Math.abs(q.x - p.x) - hw), dy = q.y - p.y;
        const score = Math.hypot(dx, dy) + 0.001 * Math.hypot(q.x - p.x, dy);
        if (score < bestScore) { bestScore = score; bestK = k; }
      });
      this.pushUndo();
      if (bestK <= 1) {
        this.chart.notes = this.chart.notes.filter(m => m !== n);
        this.changed();
        return;
      }
      const removed = n.segs.length - (bestK - 1);
      n.segs.splice(bestK - 1);
      this.changed();
      this.toast('中継点 #' + bestK + ' 以降 (' + removed + ' 個) を消しました');
    }
    deleteSelected() {
      if (this.guardPlaying()) return;
      if (!this.selected.size) return;
      this.pushUndo();
      const n0 = this.chart.notes.length;
      this.chart.notes = this.chart.notes.filter(n => !this.selected.has(n.id));
      this.selected = new Set();
      this.changed();
      this.toast((n0 - this.chart.notes.length) + ' 個消しました');
    }

    // ------------------------------------------------------------ 選択の操作
    selectAll() { this.selected = new Set(this.chart.notes.map(n => n.id)); this.emit(); }
    clearSelection() { this.selected = new Set(); this.modifyId = null; this.emit(); }

    copy(cut) {
      const sel = this.selectedNotes();
      if (!sel.length) { this.toast('コピーするノーツが選択されていません'); return; }
      let base = sel[0].beat;
      for (const n of sel) if (Beat.cmp(n.beat, base) < 0) base = n.beat;
      this.clip = sel.map(n => {
        const m = F.cloneNote(n);
        m.beat = Beat.sub(n.beat, base);
        F.shiftAtBeats(m, n, Beat.sub(Beat.zero, base));
        return m;
      });
      if (cut) { this.deleteSelected(); this.toast(this.clip.length + ' 個切り取りました'); }
      else this.toast(this.clip.length + ' 個コピーしました');
    }
    paste() {
      if (this.guardPlaying()) return;
      if (!this.clip.length) { this.toast('コピーされたノーツがありません'); return; }
      const base = this.currentSnapBeat();
      this.pushUndo();
      const newID = {};
      for (const n of this.clip) newID[n.id] = F.newId();
      const pasted = new Set();
      for (const n of this.clip) {
        const m = F.cloneNote(n);
        m.beat = Beat.add(base, n.beat);
        F.shiftAtBeats(m, n, base);
        m.id = newID[n.id];
        const sid = n.extra[BX.headLinkKey];
        if (sid) { if (newID[sid]) m.extra[BX.headLinkKey] = newID[sid]; else delete m.extra[BX.headLinkKey]; }
        pasted.add(m.id);
        this.chart.notes.push(m);
      }
      this.selected = pasted;
      this.changed();
      this.toast(this.clip.length + ' 個貼り付けました (再生ラインの位置)');
    }
    flip() {
      if (this.guardPlaying()) return;
      let sel = this.selectedNotes();
      if (!sel.length) { sel = this.chart.notes; this.toast('選択が無いので、全部のノーツを左右反転しました'); }
      if (!sel.length) return;
      this.pushUndo();
      for (const n of sel) { n.x = 254 - n.x; for (const s of n.segs) s.x = -s.x; }
      this.changed();
    }
    slideToWipe() {
      if (this.guardPlaying()) return;
      const slides = this.selectedNotes().filter(F.isSlide);
      if (!slides.length) { this.toast('選択中のノーツにスライドがありません'); return; }
      this.pushUndo();
      const created = [];
      for (const n of slides) {
        created.push(F.makeNote(n.beat, n.x, n.w, 4));
        for (const s of n.segs) created.push(F.makeNote(Beat.add(n.beat, s.beat), Math.max(0, Math.min(255, n.x + s.x)), n.w, 4));
      }
      const rm = new Set(slides.map(n => n.id));
      this.chart.notes = this.chart.notes.filter(n => !rm.has(n.id)).concat(created);
      for (const n of created) this.selected.add(n.id);
      this.changed();
      this.toast(slides.length + ' 本のスライドをワイプにしました');
    }
    wipeToSlide() {
      if (this.guardPlaying()) return;
      const wipes = this.selectedNotes().filter(n => n.type === 4 && !F.isSlide(n));
      if (wipes.length < 2) { this.toast('選択中のワイプが 2 個以上いります'); return; }
      const sorted = wipes.slice().sort((a, b) => Beat.cmp(a.beat, b.beat));
      const first = sorted[0];
      const segs = sorted.slice(1).map(n => ({ beat: Beat.sub(n.beat, first.beat), x: n.x - first.x }));
      this.pushUndo();
      const slide = F.makeNote(first.beat, first.x, first.w, null, segs);
      const rm = new Set(wipes.map(n => n.id));
      this.chart.notes = this.chart.notes.filter(n => !rm.has(n.id));
      this.chart.notes.push(slide);
      this.selected.add(slide.id);
      this.changed();
      this.toast('ワイプ ' + wipes.length + ' 個を 1 本のスライドにしました');
    }
    toggleSlideHead() {
      if (this.guardPlaying()) return;
      const sl = this.selectedNotes().filter(F.isSlide);
      if (!sl.length) { this.toast('先にスライド / ホールドを選択してください'); return; }
      const h = F.headType(sl[0]);
      const next = h === 1 ? 4 : (h === 4 ? 0 : 1);
      this.pushUndo();
      for (const n of sl) { if (next === 1) delete n.extra[BX.headKey]; else n.extra[BX.headKey] = next; }
      this.changed();
      this.toast('始点を「' + (next === 1 ? 'タップ' : next === 4 ? 'ワイプ' : 'なし') + '」にしました (' + sl.length + ' 本)');
    }
    toggleRed() {
      if (this.guardPlaying()) return;
      const taps = this.selectedNotes().filter(F.isTapLike);
      if (!taps.length) { this.toast('先にタップを選択してください'); return; }
      const toRed = taps.some(n => n.type !== 3);
      this.pushUndo();
      for (const n of taps) { n.type = toRed ? 3 : null; delete n.extra[BX.rawTypeKey]; }
      this.changed();
      this.toast(toRed ? '赤タップにしました (' + taps.length + ' 個)' : '白タップにしました (' + taps.length + ' 個)');
    }
    toggleFlag(key, onlySlides, onName, offName) {
      if (this.guardPlaying()) return;
      const sel = this.selectedNotes().filter(n => !onlySlides || F.isSlide(n));
      if (!sel.length) { this.toast(onlySlides ? '先にスライドを選択してください' : '先にノーツを選択してください'); return; }
      const on = sel.some(n => n.extra[key] !== true);
      this.pushUndo();
      for (const n of sel) { if (on) n.extra[key] = true; else delete n.extra[key]; }
      this.changed();
      this.toast((on ? onName : offName) + ' (' + sel.length + ' 個)');
    }
    toggleDummy() { this.toggleFlag(BX.dummyKey, false, 'ダミーにしました (判定なし)', 'ダミーを解除しました'); }
    toggleCurve() { this.toggleFlag(BX.curveKey, true, '曲線スライドにしました (見た目だけ)', '曲線を解除しました'); }
    setNoteSpeed(text) {
      if (this.guardPlaying()) return;
      const sel = this.selectedNotes();
      if (!sel.length) { this.toast('先にノーツを選択してください'); return; }
      const t = String(text).trim().replace(/[×x]/g, '');
      let v = null;
      if (t !== '') {
        const d = Number(t);
        if (!isFinite(d) || d === 0 || Math.abs(d) > 100) { this.toast('速さは 0 以外の数で入れてください (例: 2 / 0.5 / 1.25)'); return; }
        v = Math.abs(d - 1) < 1e-9 ? null : d;
      }
      this.pushUndo();
      for (const n of sel) { if (v === null) delete n.extra[BX.speedKey]; else n.extra[BX.speedKey] = v; }
      this.changed();
      this.toast(v === null ? 'ノーツの速さを解除しました' : 'ノーツの速さを ×' + v + ' にしました (' + sel.length + ' 個)');
    }
    selectedSpeedText() {
      const sel = this.selectedNotes();
      const set = new Set(sel.map(n => { const v = F.noteSpeed(n); return v === null ? 1 : v; }));
      return set.size === 1 ? String(Array.from(set)[0]) : '';
    }
    /// 出現 / 消える: 再生ラインの拍で (iPad 版 setAppear)
    setAppear(action) {
      if (this.guardPlaying()) return;
      const sel = this.selectedNotes();
      if (!sel.length) { this.toast('先にノーツを選択してください'); return; }
      const at = this.currentSnapBeat();
      this.pushUndo();
      for (const n of sel) {
        let ap = F.atBeats(n, BX.appearKey), va = F.atBeats(n, BX.vanishKey);
        if (action === 'appear') { va = va.filter(b => !Beat.eq(b, at)); if (!ap.some(b => Beat.eq(b, at))) ap.push(at); }
        else if (action === 'vanish') { ap = ap.filter(b => !Beat.eq(b, at)); if (!va.some(b => Beat.eq(b, at))) va.push(at); }
        else if (action === 'clearHere') { ap = ap.filter(b => !Beat.eq(b, at)); va = va.filter(b => !Beat.eq(b, at)); }
        else { ap = []; va = []; }
        F.setAtBeats(n, BX.appearKey, ap);
        F.setAtBeats(n, BX.vanishKey, va);
      }
      this.changed();
      const msg = { appear: 'で出現するようにしました', vanish: 'で消えるようにしました', clearHere: 'の出現 / 消えるを外しました', clear: '' }[action];
      this.toast(action === 'clear' ? '出現 / 消えるを全部外しました' : Beat.label(at) + ' ' + msg + ' (' + sel.length + ' 個)');
    }

    // ------------------------------------------------------------ Ease
    easePick(p, g) {
      const tb = g.beatOf(p.y);
      let best = null;
      for (const n of this.chart.notes) {
        if (!F.isSlide(n)) continue;
        const hw = n.w / 255 * g.trackW / 2;
        const bs = [Beat.val(n.beat)], xs = [n.x];
        for (const s of n.segs) { bs.push(Beat.val(n.beat) + Beat.val(s.beat)); xs.push(n.x + s.x); }
        const es = F.eases(n);
        for (let k = 0; k < bs.length - 1; k++) {
          const lo = Math.min(bs[k], bs[k + 1]), hi = Math.max(bs[k], bs[k + 1]);
          if (hi - lo <= 1e-9 || tb < lo || tb > hi) continue;
          const u = (tb - bs[k]) / (bs[k + 1] - bs[k]);
          const x = xs[k] + (xs[k + 1] - xs[k]) * S.easeFraction(es[k], u);
          const d = Math.abs(g.px(x) - p.x);
          if (d > hw + 10) continue;
          if (!best || d < best.d) best = { id: n.id, seg: k, d };
        }
      }
      if (!best) { this.toast('スライドの帯 (点と点の間) をクリックしてください'); return; }
      this.selected = new Set([best.id]);
      this.emit();
      this.onEasePick(best.id, best.seg);
    }
    setEase(id, seg, e, all) {
      const n = this.note(id);
      if (!n || !F.isSlide(n)) return;
      let es = F.eases(n);
      if (all) es = es.map(() => e); else if (seg < es.length) es[seg] = e;
      this.pushUndo();
      if (es.some(v => v !== 0)) n.extra[BX.easeKey] = es; else delete n.extra[BX.easeKey];
      this.changed();
      const name = ['まっすぐ', 'Ease In', 'Ease Out'][e];
      this.toast(all ? 'このスライドの全区間を「' + name + '」にしました' : '区間 ' + (seg + 1) + ' を「' + name + '」にしました');
    }

    // ------------------------------------------------------------ Curve bake
    bakeCurve() {
      if (this.guardPlaying()) return;
      const sl = this.selectedNotes().filter(F.isSlide);
      if (!sl.length) { this.toast('先にスライドを選択してください'); return; }
      const out = [];
      for (const n of sl) { const segs = bakedSegs(n); if (segs) out.push({ n, segs }); }
      if (!out.length) { this.toast('曲線にできるスライドがありません (中継点が 2 個以上いります)'); return; }
      this.pushUndo();
      for (const o of out) { o.n.segs = o.segs; o.n.extra[BX.curveKey] = true; }
      this.changed();
      this.toast('曲線に作り直しました (' + out.length + ' 本。判定点が変わります。Ctrl+Z で戻せます)');
    }

    // ------------------------------------------------------------ BPM / ソフラン / 曲の情報
    setMeta(key, value) {
      if (this.chart.bx[key] === value) return;
      this.pushUndo();
      if (value === undefined) delete this.chart.bx[key]; else this.chart.bx[key] = value;
      this.dirty = true;
      this.emit();
    }
    setBaseBPM(v) {
      if (!(v > 0)) return;
      this.pushUndo();
      this.chart.times.sort((a, b) => Beat.cmp(a.beat, b.beat));
      this.chart.times[0].bpm = v;
      this.changed();
    }
    addOrReplaceBPM(beat, bpm) {
      if (!(bpm > 0) || Beat.val(beat) < 0) return;
      this.pushUndo();
      const i = this.chart.times.findIndex(t => Beat.eq(t.beat, beat));
      if (i >= 0) this.chart.times[i].bpm = bpm; else this.chart.times.push({ beat, bpm });
      this.chart.times.sort((a, b) => Beat.cmp(a.beat, b.beat));
      this.changed();
    }
    removeBPM(i) {
      if (i <= 0 || i >= this.chart.times.length) return;
      this.pushUndo();
      this.chart.times.splice(i, 1);
      this.changed();
    }
    addOrReplaceSpeed(beat, value) {
      if (!isFinite(value)) return;
      this.pushUndo();
      const i = this.chart.speeds.findIndex(t => Beat.eq(t.beat, beat));
      if (i >= 0) this.chart.speeds[i].value = value; else this.chart.speeds.push({ beat, value });
      this.chart.speeds.sort((a, b) => Beat.cmp(a.beat, b.beat));
      this.changed();
    }
    removeSpeed(i) {
      if (i < 0 || i >= this.chart.speeds.length) return;
      this.pushUndo();
      this.chart.speeds.splice(i, 1);
      this.changed();
    }

    // ------------------------------------------------------------ 時間
    secOfBeat(b) { return this.timeMap.sec(b); }
    beatOfSec(s) { return this.timeMap.beat(s); }
    offsetSec() { const v = F.intValue(this.chart.bx.offset); return (v === null ? 0 : v) / 1000; }
    lastBeat() {
      let m = 0;
      for (const n of this.chart.notes) {
        m = Math.max(m, Beat.val(n.beat));
        for (const s of n.segs) m = Math.max(m, Beat.val(n.beat) + Beat.val(s.beat));
      }
      return m;
    }

    /// 再生中に鳴らすノーツ音 (iPad 版 rebuildKeyTimes と同じ。譜面の秒、同じ時刻の同じ音は 1 つ)
    keySounds() {
      const out = [];
      for (const n of this.chart.notes) {
        let kind;
        if (F.isSlide(n)) {
          const h = F.headType(n);
          if (h === 0) continue;
          kind = h === 4 ? 'wipe' : 'tap';
        } else if (n.type === 3) kind = 'red';
        else if (n.type === 4) kind = 'wipe';
        else kind = 'tap';
        out.push({ t: this.timeMap.sec(Beat.val(n.beat)), k: kind });
      }
      out.sort((a, b) => a.t - b.t);
      const res = [];
      let i = 0;
      while (i < out.length) {
        let j = i;
        const seen = [];
        while (j < out.length && out[j].t - out[i].t < 0.001) {
          if (!seen.includes(out[j].k)) { seen.push(out[j].k); res.push({ t: out[i].t, k: out[j].k }); }
          j++;
        }
        i = j;
      }
      return res;
    }

    stats() {
      let taps = 0, reds = 0, wipes = 0, slides = 0, segs = 0;
      for (const n of this.chart.notes) {
        if (F.isSlide(n)) { slides++; segs += n.segs.length; }
        else if (n.type === 3) reds++;
        else if (n.type === 4) wipes++;
        else taps++;
      }
      return { taps, reds, wipes, slides, segs, total: this.chart.notes.length };
    }
  }

  function pointInPolygon(p, poly) {
    let inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const a = poly[i], b = poly[j];
      if ((a.y > p.y) !== (b.y > p.y)) {
        const t = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
        if (p.x < t) inside = !inside;
      }
    }
    return inside;
  }

  // iPad 版 Beatrix.bSplineSamples / EditorState.bakedSegs
  function bSplineSamples(ts, vs, perSpan) {
    perSpan = perSpan || 48;
    const n = ts.length;
    const pt = [ts[0], ts[0]].concat(ts, [ts[n - 1], ts[n - 1]]);
    const pv = [vs[0], vs[0]].concat(vs, [vs[n - 1], vs[n - 1]]);
    const out = [];
    for (let i = 0; i < pt.length - 3; i++) {
      for (let j = 0; j < perSpan; j++) {
        const u = j / perSpan, u2 = u * u, u3 = u2 * u;
        const b0 = (1 - u) * (1 - u) * (1 - u) / 6;
        const b1 = (3 * u3 - 6 * u2 + 4) / 6;
        const b2 = (-3 * u3 + 3 * u2 + 3 * u + 1) / 6;
        const b3 = u3 / 6;
        out.push({ t: b0 * pt[i] + b1 * pt[i + 1] + b2 * pt[i + 2] + b3 * pt[i + 3],
          v: b0 * pv[i] + b1 * pv[i + 1] + b2 * pv[i + 2] + b3 * pv[i + 3] });
      }
    }
    out.push({ t: ts[n - 1], v: vs[n - 1] });
    out[0] = { t: ts[0], v: vs[0] };
    return out;
  }
  function bakedSegs(n) {
    const beats = [n.beat], lanes = [F.blockOfX(n.x)];
    for (const sg of n.segs) { beats.push(Beat.add(n.beat, sg.beat)); lanes.push(F.blockOfX(n.x + sg.x)); }
    if (beats.length < 3) return null;
    for (let k = 1; k < beats.length; k++) if (Beat.cmp(beats[k - 1], beats[k]) > 0) return null;
    const xs = beats.map(Beat.val);
    const pieces = [[0]];
    for (let k = 1; k < beats.length; k++) {
      if (Beat.eq(beats[k], beats[k - 1])) pieces.push([k]); else pieces[pieces.length - 1].push(k);
    }
    const out = [];
    const addOriginal = k => { if (k > 0) out.push({ beat: n.segs[k - 1].beat, x: n.segs[k - 1].x }); };
    let changed = false;
    pieces.forEach((piece, pi) => {
      if (pi > 0) addOriginal(piece[0]);
      if (piece.length < 3) { for (const k of piece.slice(1)) addOriginal(k); return; }
      const samples = bSplineSamples(piece.map(k => xs[k]), piece.map(k => lanes[k]));
      const valueAt = t => {
        let j = 1;
        while (j < samples.length - 1 && samples[j].t < t) j++;
        const p = samples[j - 1], q = samples[j];
        const h = q.t - p.t;
        return h <= 1e-12 ? q.v : p.v + (q.v - p.v) * Math.min(1, Math.max(0, (t - p.t) / h));
      };
      const endBeat = beats[piece[piece.length - 1]];
      let lastBeat = beats[piece[0]], lastLane = lanes[piece[0]];
      for (let j = 1; j < samples.length; j++) {
        const t1 = samples[j - 1].t, v1 = samples[j - 1].v, t2 = samples[j].t, v2 = samples[j].v;
        const lo = Math.ceil(Math.min(v1, v2)), hi = Math.floor(Math.max(v1, v2));
        if (lo > hi) continue;
        const order = [];
        for (let L = lo; L <= hi; L++) order.push(L);
        if (v2 < v1) order.reverse();
        for (const L of order) {
          if (L === v1) continue;
          const target = t1 + (t2 - t1) * (L - v1) / (v2 - v1);
          if (L === lastLane && target - Beat.val(lastBeat) < 1 / 32) continue;
          let put = null, bestErr = Infinity;
          for (const den of [16, 32, 48, 64, 96, 192, 384]) {
            const c = Beat.nearest(target, den);
            if (!(Beat.cmp(lastBeat, c) < 0 && Beat.cmp(c, endBeat) < 0)) continue;
            const err = Math.abs(valueAt(Beat.val(c)) - L);
            if (err < bestErr) { bestErr = err; put = c; }
            if (err <= 0.15) break;
          }
          if (put) {
            out.push({ beat: Beat.sub(put, n.beat), x: F.centerX(L) - n.x });
            lastBeat = put; lastLane = L; changed = true;
          }
        }
      }
      addOriginal(piece[piece.length - 1]);
    });
    if (!changed && out.length === n.segs.length) return null;
    return out;
  }

  window.BXEditor = Editor;
  window.BXTools = TOOLS;
})();
