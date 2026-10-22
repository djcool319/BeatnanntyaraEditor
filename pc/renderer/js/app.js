// 画面のつなぎ込み (ファイル・再生・キー操作・右のパネル)
(function () {
  'use strict';
  const F = window.BXF, Beat = F.Beat, BX = F.BX, V = window.BXView;
  const host = window.bxHost || null;          // Electron の外 (ブラウザで開いたとき) は null
  const $ = id => document.getElementById(id);

  const ed = new window.BXEditor();
  const audio = new window.BXAudio();
  const lane = $('lane');
  const over = $('overview');

  let geo = null;
  let needDraw = true;
  let audioPath = null;
  let audioFilesInDir = [];
  let chartDir = null;
  let siblingExists = {};
  let lastMouse = null;

  function pref(key, dflt) { try { const v = localStorage.getItem('bx.' + key); return v === null ? dflt : JSON.parse(v); } catch (e) { return dflt; } }
  function setPref(key, v) { try { localStorage.setItem('bx.' + key, JSON.stringify(v)); } catch (e) { /* なくても動く */ } }

  audio.musicVolume = pref('volMusic', 0.8);
  audio.seVolume = pref('volSE', 0.8);
  audio.seOn = pref('seOn', true);
  let latencyMs = pref('latencyMs', 0);

  // ------------------------------------------------------------ トースト
  let toastTimer = null;
  function toast(s) {
    const t = $('toast');
    t.textContent = s;
    t.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
  }
  ed.onToast = toast;
  ed.onChange = () => { needDraw = true; scheduleUI(); };

  // ------------------------------------------------------------ ダイアログ
  function modal(title, bodyHTML, buttons, opts) {
    return new Promise(resolve => {
      $('modalTitle').textContent = title;
      $('modalBody').innerHTML = bodyHTML;
      const box = $('modalBtns');
      box.innerHTML = '';
      box.className = 'dialog-btns' + (opts && opts.column ? ' col' : '');
      const close = v => { $('modal').classList.add('hidden'); document.removeEventListener('keydown', onKey, true); resolve(v); };
      buttons.forEach((b, i) => {
        const el = document.createElement('button');
        el.textContent = b.label;
        if (b.primary) el.className = 'primary';
        if (b.danger) el.className = 'danger';
        el.onclick = () => close(b.value !== undefined ? b.value : i);
        box.appendChild(el);
      });
      const onKey = e => {
        if (e.key === 'Escape') { e.stopPropagation(); e.preventDefault(); close(null); }
        if (e.key === 'Enter' && opts && opts.enter !== undefined && e.target.tagName !== 'BUTTON') { e.stopPropagation(); e.preventDefault(); close(opts.enter); }
      };
      document.addEventListener('keydown', onKey, true);
      $('modal').classList.remove('hidden');
      const first = $('modalBody').querySelector('input');
      if (first) setTimeout(() => first.focus(), 30);
    });
  }
  function esc(s) { return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]); }

  // ------------------------------------------------------------ ファイル
  async function dirOf(p) { return host ? (await host.pathInfo(p)).dir : ''; }
  async function joinPath(a, b) { return host ? host.join(a, b) : b; }

  function updateTitle() {
    const name = ed.filePath ? ed.filePath.split(/[\\/]/).pop() : '新しい譜面 (まだ保存していません)';
    $('fileName').textContent = name;
    $('fileName').title = ed.filePath || '';
    if (host) {
      host.setTitle((ed.dirty ? '● ' : '') + name + ' — BeatTriX Editor');
      host.setDirty(ed.dirty);
    }
    $('dirtyMark').textContent = ed.dirty ? '● 保存していない変更があります' : '';
    $('btnSave').classList.toggle('dirty', ed.dirty);
  }

  async function confirmDiscard() {
    if (!ed.dirty) return true;
    const r = await modal('保存していない変更があります', '<p>今の譜面を保存しますか？</p>',
      [{ label: '保存する', primary: true, value: 'save' }, { label: '保存しない', danger: true, value: 'discard' }, { label: 'キャンセル', value: null }]);
    if (r === 'save') return await save();
    return r === 'discard';
  }

  async function openPath(p) {
    if (!host) return;
    stop();
    let chart;
    try {
      const text = await host.readText(p);
      chart = F.parse(text);
    } catch (e) {
      await modal('開けませんでした', '<p>' + esc(p) + '</p><p class="muted">' + esc(e.message || e) + '</p>', [{ label: 'OK', primary: true }]);
      return false;
    }
    const prevDir = chartDir;
    ed.loadChart(chart, p);
    chartDir = await dirOf(p);
    setPref('lastDir', chartDir);
    await refreshSiblings();
    if (chartDir !== prevDir || !audio.music) await autoAudio();
    else refreshAudioSelect();
    toast('開きました: ' + p.split(/[\\/]/).pop() + ' (ノーツ ' + chart.notes.length + ' 個)');
    fitView();
    return true;
  }

  async function openDialog() {
    if (!host) return;
    if (!(await confirmDiscard())) return;
    const p = await host.openDialog(chartDir || pref('lastDir', undefined));
    if (p) await openPath(p);
  }

  /// 保存。成功したら true
  async function save(forceAs) {
    if (!host) return false;
    if (ed.slideDraft) ed.finishSlide();
    let p = ed.filePath;
    if (!p || forceAs) {
      const base = chartDir || pref('lastDir', '');
      const def = base ? await joinPath(base, F.fileName(ed.chart)) : F.fileName(ed.chart);
      p = await host.saveDialog(def);
      if (!p) return false;
    }
    // 書き出した文字を読み直して、もう一度書き出しても同じになるか確かめる (壊れた中身を書かないため)
    let text;
    try {
      text = F.stringify(ed.chart);
      const again = F.stringify(F.parse(text));
      if (again !== text) throw new Error('書き出した JSON を読み直すと中身が変わります (保存を止めました)');
    } catch (e) {
      await modal('保存できませんでした', '<p class="muted">' + esc(e.message || e) + '</p><p>ファイルは書き換えていません。</p>', [{ label: 'OK', primary: true }]);
      return false;
    }
    const r = await host.save(p, text);
    if (!r || !r.ok) {
      await modal('保存できませんでした', '<p>' + esc(p) + '</p><p class="muted">' + esc(r && r.error || '') + '</p>', [{ label: 'OK', primary: true }]);
      return false;
    }
    ed.filePath = p;
    ed.dirty = false;
    chartDir = await dirOf(p);
    setPref('lastDir', chartDir);
    if (audioPath) rememberAudio();
    await refreshSiblings();
    updateTitle();
    toast(r.unchanged ? '変更はありませんでした (保存済み)' : '保存しました' + (r.backup ? ' (前の中身は .bak に残しました)' : ''));
    return true;
  }

  async function newChart() {
    if (!(await confirmDiscard())) return;
    const r = await modal('新しい譜面',
      '<label>曲名<input id="nTitle" type="text"></label>' +
      '<label>アーティスト<input id="nArtist" type="text"></label>' +
      '<label>BPM<input id="nBpm" type="number" value="120" step="0.01"></label>' +
      '<label>難易度<select id="nDiff">' + BX.difficulties.map(d => '<option value="' + d.value + '"' + (d.value === 2 ? ' selected' : '') + '>' + d.label + '</option>').join('') + '</select></label>' +
      '<p class="muted">曲のファイルは、保存したあと「曲の情報」で選べます (譜面と同じフォルダの曲は自動で読みます)。</p>',
      [{ label: '作る', primary: true, value: 'ok' }, { label: 'キャンセル', value: null }], { enter: 'ok' });
    if (r !== 'ok') return;
    stop();
    const title = $('nTitle') ? $('nTitle').value.trim() : '';
    const c = F.newChart(title, Number($('nBpm').value) || 120, Number($('nDiff').value));
    c.bx.artist = $('nArtist').value.trim();
    ed.loadChart(c, null);
    ed.dirty = true;
    siblingExists = {};
    updateTitle();
    renderDiffs();
    syncUI();
  }

  // 難易度ごとのファイル (iPad 版と同じく「曲名(XX).json」)
  async function siblingPath(d) {
    if (!chartDir) return null;
    const t = ed.chart.bx.name ? ed.chart.bx.name : 'chart';
    return joinPath(chartDir, F.safeFileName(t + '(' + F.diffInfo(d).abbr + ')') + '.json');
  }
  async function refreshSiblings() {
    siblingExists = {};
    if (host && chartDir) {
      for (const d of BX.difficulties) {
        const p = await siblingPath(d.value);
        siblingExists[d.value] = p ? await host.exists(p) : false;
      }
    }
    renderDiffs();
  }
  function renderDiffs() {
    const box = $('diffs');
    box.innerHTML = '';
    const cur = F.intValue(ed.chart.bx.difficulty);
    for (const d of BX.difficulties) {
      const b = document.createElement('button');
      b.className = 'diff ' + d.abbr.toLowerCase() + (d.value === cur ? ' current' : '') + (siblingExists[d.value] ? ' exists' : '');
      b.textContent = d.abbr;
      b.title = d.label + (siblingExists[d.value] ? ' (ファイルあり)' : ' (まだありません)');
      b.onclick = () => switchDifficulty(d.value);
      box.appendChild(b);
    }
  }
  async function switchDifficulty(d) {
    const cur = F.intValue(ed.chart.bx.difficulty);
    if (d === cur) return;
    if (!ed.filePath) {
      // まだ保存していない譜面: 難易度の札を変えるだけ
      ed.setMeta('difficulty', d);
      renderDiffs();
      return;
    }
    if (ed.dirty) {
      const r = await modal('難易度を切り替える前に', '<p>今の譜面を保存してから切り替えます。</p>',
        [{ label: '保存して切り替える', primary: true, value: 'ok' }, { label: 'キャンセル', value: null }], { enter: 'ok' });
      if (r !== 'ok' || !(await save())) return;
    }
    const p = await siblingPath(d);
    if (await host.exists(p)) { await openPath(p); return; }
    const r = await modal(F.diffInfo(d).label + ' の譜面はまだありません',
      '<p>' + esc(p.split(/[\\/]/).pop()) + ' を作ります。</p><p class="muted">曲の情報・BPM・ソフラン・part はそのまま引き継ぎます。</p>',
      [{ label: '空の譜面を作る', primary: true, value: 'empty' }, { label: '今のノーツをコピーして作る', value: 'copy' }, { label: 'キャンセル', value: null }]);
    if (!r) return;
    const c = JSON.parse(JSON.stringify(ed.chart));
    c.bx.difficulty = d;
    if (r === 'empty') c.notes = [];
    else c.notes.forEach(n => { n.id = F.newId(); });
    if (r === 'copy') {
      // 始点の結び付きを新しい id に付け直す
      const old = ed.chart.notes;
      const map = {};
      old.forEach((n, i) => { map[n.id] = c.notes[i].id; });
      c.notes.forEach(n => { const s = n.extra[BX.headLinkKey]; if (s) { if (map[s]) n.extra[BX.headLinkKey] = map[s]; else delete n.extra[BX.headLinkKey]; } });
    }
    ed.loadChart(c, p);
    ed.dirty = true;
    await save();
  }

  // ------------------------------------------------------------ 曲のファイル
  function audioMap() { return pref('audioFor', {}); }
  function rememberAudio() {
    if (!ed.filePath || !audioPath) return;
    const m = audioMap();
    m[ed.filePath] = audioPath;
    const keys = Object.keys(m);
    if (keys.length > 300) delete m[keys[0]];
    setPref('audioFor', m);
  }
  async function autoAudio() {
    audioFilesInDir = chartDir ? await host.audioFiles(chartDir) : [];
    let pick = null;
    const remembered = ed.filePath ? audioMap()[ed.filePath] : null;
    if (remembered && await host.exists(remembered)) pick = remembered;
    if (!pick && audioFilesInDir.length) {
      const title = (ed.chart.bx.name || '').toLowerCase();
      const base = ed.filePath ? ed.filePath.split(/[\\/]/).pop().replace(/\(..\)\.json$/i, '').replace(/\.json$/i, '').toLowerCase() : '';
      const byName = audioFilesInDir.find(f => { const s = f.toLowerCase().replace(/\.[^.]+$/, ''); return (title && s === title) || (base && s === base); })
        || audioFilesInDir.find(f => /\.ogg$/i.test(f)) || audioFilesInDir[0];
      pick = await joinPath(chartDir, byName);
    }
    if (pick) await loadAudio(pick);
    else { audioPath = null; audio.music = null; refreshAudioSelect(); }
  }
  async function loadAudio(p) {
    stop();
    try {
      const buf = await host.readBinary(p);
      const dur = await audio.loadMusic(buf, p.split(/[\\/]/).pop());
      audioPath = p;
      rememberAudio();
      $('audioInfo').textContent = audio.musicName + ' (' + V.fmtTime(dur) + ')';
    } catch (e) {
      audioPath = null;
      audio.music = null;
      $('audioInfo').textContent = '曲を読み込めませんでした: ' + p.split(/[\\/]/).pop();
      toast('曲を読み込めませんでした (ogg / mp3 / wav に対応)');
    }
    refreshAudioSelect();
    needDraw = true;
  }
  function refreshAudioSelect() {
    const sel = $('audioSel');
    sel.innerHTML = '';
    const cur = audioPath ? audioPath.split(/[\\/]/).pop() : null;
    const names = audioFilesInDir.slice();
    if (cur && !names.includes(cur)) names.unshift(cur);
    if (!names.length) sel.innerHTML = '<option value="">(フォルダに曲がありません)</option>';
    for (const n of names) {
      const o = document.createElement('option');
      o.value = n; o.textContent = n;
      if (n === cur) o.selected = true;
      sel.appendChild(o);
    }
    if (!audioPath) $('audioInfo').textContent = '曲が読み込まれていません (ノーツ音だけで再生します)';
  }

  // ------------------------------------------------------------ 再生
  function play() {
    if (audio.playing) return;
    if (ed.slideDraft) ed.finishSlide();
    ed.holdDraft = null;
    ed.ghost = null;
    ed.isPlaying = true;
    audio.rate = Number($('rate').value) || 1;
    const startBeat = Math.max(0, ed.viewBeat);
    ed.playStartBeat = startBeat;
    audio.play(ed.secOfBeat(startBeat), ed.offsetSec(), ed.keySounds());
    $('btnPlay').textContent = '❚❚';
    $('btnPlay').classList.add('on');
  }
  function stop() {
    if (!audio.playing) { ed.isPlaying = false; return; }
    audio.stop();
    ed.isPlaying = false;
    $('btnPlay').textContent = '▶';
    $('btnPlay').classList.remove('on');
    needDraw = true;
    scheduleUI();
  }
  function togglePlay() { if (audio.playing) stop(); else play(); }

  // ------------------------------------------------------------ 表示
  function fitView() {
    ed.viewBeat = 0;
    needDraw = true;
  }
  function scrollBy(beats) {
    ed.viewBeat = Math.max(-2, ed.viewBeat + beats);
    if (audio.playing) { stop(); }
    needDraw = true;
    scheduleUI();
    if (lastMouse && geo) ed.updateGhost(lastMouse, geo);
  }
  function setZoom(ppb, anchorY) {
    ppb = Math.max(40, Math.min(900, ppb));
    if (geo && anchorY !== undefined) {
      const b = geo.beatOf(anchorY);
      ed.ppb = ppb;
      // マウスの下の拍が動かないように
      ed.viewBeat = b - (geo.playY - anchorY) / ppb;
    } else ed.ppb = ppb;
    setPref('ppb', ed.ppb);
    $('zoom').value = ed.ppb;
    needDraw = true;
  }
  const SNAPS = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48];
  function setSnap(d) {
    ed.snapDen = d;
    setPref('snapDen', d);
    $('snap').value = String(d);
    needDraw = true;
    toast('分割: 1/' + (d * 4) + ' (1 拍を ' + d + ' 分割)');
  }

  function frame() {
    if (audio.playing) {
      const t = audio.chartTime(latencyMs / 1000);
      ed.viewBeat = Math.max(ed.playStartBeat || 0, ed.beatOfSec(t));
      needDraw = true;
      const end = Math.max(audio.duration() - ed.offsetSec(), ed.secOfBeat(ed.lastBeat()) + 2);
      if (t > end + 0.5) stop();
    }
    if (needDraw) {
      needDraw = false;
      geo = V.draw(lane, ed, { hint: ed.chart.notes.length || ed.filePath ? null : 'Ctrl+O で JSON を開く / JSON をここにドラッグ / Ctrl+N で新しい譜面' });
      drawOverview();
      $('clockTime').textContent = V.fmtTime(ed.secOfBeat(ed.viewBeat));
      $('clockBeat').textContent = Beat.label(ed.currentSnapBeat()) + '  (拍 ' + ed.viewBeat.toFixed(2) + ')';
    }
    requestAnimationFrame(frame);
  }

  function overviewRange() {
    const lastSec = Math.max(ed.secOfBeat(ed.lastBeat()) + 4, audio.music ? audio.duration() - ed.offsetSec() : 0, 30);
    return { from: Math.min(0, -ed.offsetSec()), to: lastSec };
  }
  function drawOverview() {
    const dpr = window.devicePixelRatio || 1;
    const W = over.clientWidth, H = over.clientHeight;
    if (over.width !== Math.round(W * dpr) || over.height !== Math.round(H * dpr)) { over.width = Math.round(W * dpr); over.height = Math.round(H * dpr); }
    const c = over.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, W, H);
    const r = overviewRange();
    const y = s => H - 6 - (s - r.from) / (r.to - r.from) * (H - 12);
    for (const n of ed.chart.notes) {
      const s = ed.secOfBeat(Beat.val(n.beat));
      const xx = 3 + n.x / 255 * (W - 6);
      c.fillStyle = F.isSlide(n) ? 'rgba(180,240,255,0.55)' : n.type === 3 ? 'rgba(255,90,90,0.8)' : n.type === 4 ? 'rgba(247,253,74,0.8)' : 'rgba(255,255,255,0.7)';
      c.fillRect(xx - 1.5, y(s), 3, 1.5);
    }
    // 見えている範囲
    if (geo) {
      const s0 = ed.secOfBeat(geo.beatOf(geo.H)), s1 = ed.secOfBeat(geo.beatOf(0));
      c.fillStyle = 'rgba(0,230,230,0.10)';
      c.fillRect(0, y(s1), W, y(s0) - y(s1));
    }
    c.fillStyle = 'rgba(0,230,230,0.95)';
    c.fillRect(0, y(ed.secOfBeat(ed.viewBeat)) - 1, W, 2);
  }
  function overviewSeek(ev) {
    const rect = over.getBoundingClientRect();
    const r = overviewRange();
    const H = rect.height;
    const s = r.from + (H - 6 - (ev.clientY - rect.top)) / (H - 12) * (r.to - r.from);
    const wasPlaying = audio.playing;
    if (wasPlaying) stop();
    ed.viewBeat = Math.max(0, ed.beatOfSec(Math.max(r.from, Math.min(r.to, s))));
    needDraw = true;
    scheduleUI();
    return wasPlaying;
  }

  // ------------------------------------------------------------ 右のパネル
  let uiPending = false;
  function scheduleUI() {
    if (uiPending) return;
    uiPending = true;
    requestAnimationFrame(() => { uiPending = false; syncUI(); });
  }
  function setVal(id, v) {
    const el = $(id);
    if (document.activeElement === el) return;
    el.value = v === undefined || v === null ? '' : v;
  }
  function syncUI() {
    const bx = ed.chart.bx;
    setVal('mTitle', bx.name || '');
    setVal('mArtist', bx.artist || '');
    const lv = F.doubleValue(bx.LEVEL);
    setVal('mLevel', lv === null ? 1 : lv);
    $('mRank').textContent = F.lvRank(lv === null ? 1 : lv);
    setVal('mOffset', F.intValue(bx.offset) === null ? 0 : F.intValue(bx.offset));
    setVal('mPreview', F.doubleValue(bx.preview) === null ? '' : F.doubleValue(bx.preview));
    setVal('mVer', F.intValue(bx.ver) === null ? '' : F.intValue(bx.ver));
    setVal('mMaxBlock', bx.maxBlock === undefined ? 7 : bx.maxBlock);

    const st = ed.stats();
    $('stats').innerHTML = [['白タップ', st.taps], ['赤タップ', st.reds], ['ワイプ', st.wipes], ['スライド/ホールド', st.slides], ['中継点', st.segs], ['合計 (エディタ内)', st.total]]
      .map(r => '<span>' + r[0] + '</span><b>' + r[1] + '</b>').join('');

    // BPM
    const times = ed.chart.times;
    setVal('bpmBase', times[0] ? times[0].bpm : 120);
    const bl = $('bpmList');
    if (!bl.contains(document.activeElement)) {
      bl.innerHTML = '';
      if (times.length <= 1) bl.innerHTML = '<div class="empty">途中の BPM 変化はありません</div>';
      times.forEach((t, i) => {
        if (i === 0) return;
        const row = document.createElement('div');
        row.className = 'item';
        row.innerHTML = '<span class="at">' + Beat.label(t.beat) + '</span><input type="number" step="0.01" min="1" value="' + t.bpm + '"><button title="そこへ移動">→</button><button title="消す">✕</button>';
        const [inp, go, del] = [row.children[1], row.children[2], row.children[3]];
        inp.onchange = () => { const v = Number(inp.value); if (v > 0) ed.addOrReplaceBPM(t.beat, v); };
        go.onclick = () => { stop(); ed.viewBeat = Beat.val(t.beat); needDraw = true; };
        del.onclick = () => ed.removeBPM(i);
        bl.appendChild(row);
      });
    }
    const sl = $('spdList');
    if (!sl.contains(document.activeElement)) {
      sl.innerHTML = '';
      if (!ed.chart.speeds.length) sl.innerHTML = '<div class="empty">ソフランはありません</div>';
      ed.chart.speeds.forEach((t, i) => {
        const row = document.createElement('div');
        row.className = 'item';
        row.innerHTML = '<span class="at">' + Beat.label(t.beat) + '</span><input type="number" step="0.05" value="' + t.value + '"><button title="そこへ移動">→</button><button title="消す">✕</button>';
        const [inp, go, del] = [row.children[1], row.children[2], row.children[3]];
        inp.onchange = () => { const v = Number(inp.value); if (isFinite(v)) ed.addOrReplaceSpeed(t.beat, v); };
        go.onclick = () => { stop(); ed.viewBeat = Beat.val(t.beat); needDraw = true; };
        del.onclick = () => ed.removeSpeed(i);
        sl.appendChild(row);
      });
    }

    // 選択
    const sel = ed.selectedNotes();
    const nSl = sel.filter(F.isSlide).length;
    $('selCount').textContent = sel.length ? sel.length + ' 個を選択中' + (nSl ? ' (スライド/ホールド ' + nSl + ')' : '') : '選択なし (ノーツをクリック / ドラッグで囲む)';
    setVal('noteSpeed', sel.length ? ed.selectedSpeedText() : '');

    for (const b of document.querySelectorAll('.tool')) b.classList.toggle('active', b.dataset.tool === ed.tool);
    $('holdHead').checked = ed.holdWithHead;
    $('slideHead').checked = ed.slideWithHead;
    $('linkHead').checked = ed.linkHeadTap;
    $('segVertical').checked = ed.allowSegVertical;
    $('toolHint').textContent = TOOL_HINT[ed.tool] || '';
    renderDiffs();
    updateTitle();
  }

  const TOOL_HINT = {
    select: 'クリックで選択 / ドラッグで移動 / 空いた所をドラッグで囲んで選択。Ctrl / Shift で追加。',
    tap: 'クリックで白タップ (3 鍵)。ノーツを掴むと移動。右クリックで消す。',
    red: 'クリックで赤タップ (3 鍵)。',
    wipe: 'クリックでワイプ (7 鍵)。',
    hold: '始点を押して終点までドラッグ。または 始点クリック → 終点クリック。',
    slide: '始点 → 中継点を順にクリック。Enter / 右クリックで完了。',
    modify: 'スライドを選んで、点をドラッグで動かす。空いた所をクリックで点を足す。',
    ease: 'スライドの帯 (点と点の間) をクリックして、曲がり方を選ぶ。',
    erase: 'クリックで消す。スライドは近い中継点から後ろを消す。',
  };

  // ------------------------------------------------------------ 入力欄
  function bindMeta() {
    $('mTitle').onchange = e => { ed.setMeta('name', e.target.value.trim()); refreshSiblings(); };
    $('mArtist').onchange = e => ed.setMeta('artist', e.target.value);
    $('mLevel').onchange = e => { const v = Number(e.target.value); if (isFinite(v)) ed.setMeta('LEVEL', v); };
    $('mOffset').onchange = e => { const v = Math.round(Number(e.target.value)); if (isFinite(v)) ed.setMeta('offset', v); };
    $('mPreview').onchange = e => { const t = e.target.value.trim(); ed.setMeta('preview', t === '' ? undefined : Number(t)); };
    $('mVer').onchange = e => { const t = e.target.value.trim(); ed.setMeta('ver', t === '' ? undefined : Math.round(Number(t))); };
    $('bpmBase').onchange = e => { const v = Number(e.target.value); if (v > 0) ed.setBaseBPM(v); };
    $('bpmAdd').onclick = () => {
      const v = Number($('bpmNew').value);
      if (!(v > 0)) { toast('BPM を入れてください'); return; }
      const b = ed.currentSnapBeat();
      if (Beat.val(b) <= 0) { ed.setBaseBPM(v); return; }
      ed.addOrReplaceBPM(b, v);
      toast(Beat.label(b) + ' に BPM ' + v + ' を入れました');
    };
    $('spdAdd').onclick = () => {
      const v = Number($('spdNew').value);
      if (!isFinite(v) || $('spdNew').value.trim() === '') { toast('速さを入れてください (例: 0.5 / 2)'); return; }
      const b = ed.currentSnapBeat();
      ed.addOrReplaceSpeed(b, v);
      toast(Beat.label(b) + ' にソフラン ×' + v + ' を入れました');
    };
    $('noteSpeedApply').onclick = () => ed.setNoteSpeed($('noteSpeed').value);
    $('noteSpeed').onkeydown = e => { if (e.key === 'Enter') ed.setNoteSpeed($('noteSpeed').value); };

    for (const b of document.querySelectorAll('[data-act]')) b.onclick = () => action(b.dataset.act);
    for (const b of document.querySelectorAll('.tool')) b.onclick = () => ed.setTool(b.dataset.tool);
    for (const t of document.querySelectorAll('.tab')) {
      t.onclick = () => {
        for (const x of document.querySelectorAll('.tab')) x.classList.toggle('active', x === t);
        for (const p of document.querySelectorAll('.pane')) p.classList.toggle('active', p.id === 'pane-' + t.dataset.tab);
      };
    }
    $('holdHead').onchange = e => ed.setPref('holdWithHead', e.target.checked);
    $('slideHead').onchange = e => ed.setPref('slideWithHead', e.target.checked);
    $('linkHead').onchange = e => ed.setPref('linkHeadTap', e.target.checked);
    $('segVertical').onchange = e => ed.setPref('allowSegVertical', e.target.checked);
    $('seOn').checked = audio.seOn;
    $('seOn').onchange = e => { audio.seOn = e.target.checked; setPref('seOn', audio.seOn); audio.applyVolumes(); };
    $('volMusic').value = audio.musicVolume;
    $('volMusic').oninput = e => { audio.musicVolume = Number(e.target.value); setPref('volMusic', audio.musicVolume); audio.applyVolumes(); };
    $('volSE').value = audio.seVolume;
    $('volSE').oninput = e => { audio.seVolume = Number(e.target.value); setPref('volSE', audio.seVolume); audio.applyVolumes(); };
    $('latency').value = latencyMs;
    $('latency').onchange = e => { latencyMs = Number(e.target.value) || 0; setPref('latencyMs', latencyMs); };
    $('rate').onchange = () => { if (audio.playing) { stop(); play(); } };

    const snap = $('snap');
    snap.innerHTML = SNAPS.map(d => '<option value="' + d + '">1/' + (d * 4) + '  (1 拍 ' + d + ' 分割)</option>').join('');
    snap.value = String(ed.snapDen);
    snap.onchange = () => setSnap(Number(snap.value));
    $('zoom').value = ed.ppb;
    $('zoom').oninput = e => setZoom(Number(e.target.value));

    $('btnPlay').onclick = togglePlay;
    $('btnOpen').onclick = openDialog;
    $('btnSave').onclick = () => save();
    $('btnAudio').onclick = async () => {
      if (!host) return;
      const p = await host.audioDialog(chartDir || pref('lastDir', undefined));
      if (p) await loadAudio(p);
    };
    $('audioSel').onchange = async e => { if (e.target.value && chartDir) await loadAudio(await joinPath(chartDir, e.target.value)); };
  }

  function action(a) {
    switch (a) {
      case 'flip': ed.flip(); break;
      case 'red': ed.toggleRed(); break;
      case 'head': ed.toggleSlideHead(); break;
      case 'dummy': ed.toggleDummy(); break;
      case 'curve': ed.toggleCurve(); break;
      case 'bake': ed.bakeCurve(); break;
      case 's2w': ed.slideToWipe(); break;
      case 'w2s': ed.wipeToSlide(); break;
      case 'appear': ed.setAppear('appear'); break;
      case 'vanish': ed.setAppear('vanish'); break;
      case 'clearHere': ed.setAppear('clearHere'); break;
      case 'clearAll': ed.setAppear('clear'); break;
      case 'copy': ed.copy(false); break;
      case 'cut': ed.copy(true); break;
      case 'paste': ed.paste(); break;
      case 'delete': ed.deleteSelected(); break;
    }
  }

  ed.onEasePick = async (id, seg) => {
    const r = await modal('この区間の曲がり方', '<p class="muted">見た目だけが変わります (判定の点の位置・時間はそのまま)</p>', [
      { label: 'まっすぐ', value: [0, false] },
      { label: 'Ease In (はじめゆっくり → あと速く)', value: [1, false] },
      { label: 'Ease Out (はじめ速く → あとゆっくり)', value: [2, false] },
      { label: 'このスライド全部 Ease In', value: [1, true] },
      { label: 'このスライド全部 Ease Out', value: [2, true] },
      { label: 'このスライド全部まっすぐ', danger: true, value: [0, true] },
      { label: 'キャンセル', value: null },
    ], { column: true });
    if (r) ed.setEase(id, seg, r[0], r[1]);
  };

  function showHelp() {
    const rows = [
      ['Space', '再生 / 停止'], ['ホイール', 'スクロール (Shift で速く)'], ['Ctrl + ホイール', 'ズーム'], ['[  ]', '分割を粗く / 細かく'],
      ['Q / Esc', '選択ツール (置いている途中なら終わる)'], ['1〜8', 'タップ / 赤 / ワイプ / ホールド / スライド / 中継点 / Ease / 消す'],
      ['Enter', 'スライドを完了'], ['右クリック', 'ノーツを消す (スライド作成中は完了)'],
      ['Ctrl+Z / Ctrl+Y', '元に戻す / やり直す'], ['Ctrl+C / X / V', 'コピー / 切り取り / 再生ラインに貼り付け'], ['Ctrl+A', '全部選ぶ'], ['Delete', '選択中を消す'],
      ['↑ ↓', '選択中を 1 分割ずつ動かす (選択なしならスクロール)'], ['← →', '選択中を横に動かす'], ['PageUp / PageDown', '1 小節ずつスクロール'], ['Home / End', '最初 / 最後のノーツへ'],
      ['M', '左右反転'], ['R', '白 ⇔ 赤タップ'], ['H', '始点 タップ / ワイプ / なし'], ['C', '曲線 (見た目)'], ['B', 'Curve bake'],
      ['Ctrl+S', '保存 (前の中身は .bak に残る)'], ['Ctrl+O / Ctrl+N', '開く / 新しい譜面'], ['F1', 'この一覧'],
    ];
    modal('ショートカット', '<div class="keys">' + rows.map(r => '<kbd>' + esc(r[0]) + '</kbd><span>' + esc(r[1]) + '</span>').join('') + '</div>', [{ label: '閉じる', primary: true }]);
  }

  // ------------------------------------------------------------ マウス
  function canvasPoint(e) {
    const r = lane.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }
  lane.addEventListener('contextmenu', e => e.preventDefault());
  lane.addEventListener('mousedown', e => {
    if (!geo) return;
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    if (e.button === 1) { e.preventDefault(); return; }
    const p = canvasPoint(e);
    ed.pointerDown(p, geo, { shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, button: e.button });
    needDraw = true;
  });
  window.addEventListener('mousemove', e => {
    if (!geo) return;
    const p = canvasPoint(e);
    const inside = p.x >= 0 && p.y >= 0 && p.x <= lane.clientWidth && p.y <= lane.clientHeight;
    lastMouse = inside ? p : null;
    if (ed.drag || inside) ed.pointerMove(p, geo, { shift: e.shiftKey, ctrl: e.ctrlKey });
    else ed.clearGhost();
  });
  window.addEventListener('mouseup', e => {
    if (!geo || !ed.drag) return;
    ed.pointerUp(canvasPoint(e), geo, { shift: e.shiftKey, ctrl: e.ctrlKey });
    needDraw = true;
  });
  lane.addEventListener('mouseleave', () => { if (!ed.drag) ed.clearGhost(); });
  lane.addEventListener('wheel', e => {
    e.preventDefault();
    const dy = e.deltaMode === 1 ? e.deltaY * 40 : e.deltaY;
    if (e.ctrlKey) { setZoom(ed.ppb * Math.pow(1.0015, -dy), canvasPoint(e).y); return; }
    scrollBy(-dy / ed.ppb * (e.shiftKey ? 4 : 1));
  }, { passive: false });
  let overDrag = false;
  over.addEventListener('mousedown', e => { overDrag = true; overviewSeek(e); });
  window.addEventListener('mousemove', e => { if (overDrag) overviewSeek(e); });
  window.addEventListener('mouseup', () => { overDrag = false; });

  // ドラッグ & ドロップで開く
  let dragDepth = 0;
  window.addEventListener('dragenter', e => { e.preventDefault(); dragDepth++; $('drop').classList.remove('hidden'); });
  window.addEventListener('dragleave', e => { e.preventDefault(); if (--dragDepth <= 0) { dragDepth = 0; $('drop').classList.add('hidden'); } });
  window.addEventListener('dragover', e => e.preventDefault());
  window.addEventListener('drop', async e => {
    e.preventDefault();
    dragDepth = 0;
    $('drop').classList.add('hidden');
    const f = e.dataTransfer.files && e.dataTransfer.files[0];
    if (!f || !host) return;
    const p = host.pathOfFile(f);
    if (/\.json$/i.test(p)) { if (await confirmDiscard()) await openPath(p); }
    else if (/\.(ogg|mp3|wav|m4a|flac|aac|opus)$/i.test(p)) await loadAudio(p);
    else toast('JSON (譜面) か 曲のファイルを落としてください');
  });

  // ------------------------------------------------------------ キー
  window.addEventListener('keydown', e => {
    if (!$('modal').classList.contains('hidden')) return;
    const tag = (e.target && e.target.tagName) || '';
    const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
    const ctrl = e.ctrlKey || e.metaKey;
    const k = e.key;
    if (ctrl && (k === 's' || k === 'S')) { e.preventDefault(); save(e.shiftKey); return; }
    if (ctrl && (k === 'o' || k === 'O')) { e.preventDefault(); openDialog(); return; }
    if (ctrl && (k === 'n' || k === 'N')) { e.preventDefault(); newChart(); return; }
    if (typing) { if (k === 'Escape') e.target.blur(); return; }
    let handled = true;
    if (ctrl) {
      switch (k.toLowerCase()) {
        case 'z': if (e.shiftKey) ed.redo(); else ed.undo(); break;
        case 'y': ed.redo(); break;
        case 'c': ed.copy(false); break;
        case 'x': ed.copy(true); break;
        case 'v': ed.paste(); break;
        case 'a': ed.selectAll(); break;
        default: handled = false;
      }
    } else {
      const toolKeys = { '1': 'tap', '2': 'red', '3': 'wipe', '4': 'hold', '5': 'slide', '6': 'modify', '7': 'ease', '8': 'erase', 'q': 'select' };
      const lk = k.length === 1 ? k.toLowerCase() : k;
      if (toolKeys[lk]) ed.setTool(toolKeys[lk]);
      else switch (lk) {
        case ' ': togglePlay(); break;
        case 'Escape':
          if (ed.slideDraft) ed.finishSlide();
          else if (ed.holdDraft) { ed.holdDraft = null; ed.ghost = null; ed.emit(); }
          else if (ed.tool !== 'select') ed.setTool('select');
          else ed.clearSelection();
          break;
        case 'Enter': ed.finishSlide(); break;
        case 'Delete': case 'Backspace': ed.deleteSelected(); break;
        case 'ArrowUp': if (ed.selected.size && !e.shiftKey) ed.nudge(1, 0); else scrollBy((e.shiftKey ? 4 : 1) / ed.snapDen); break;
        case 'ArrowDown': if (ed.selected.size && !e.shiftKey) ed.nudge(-1, 0); else scrollBy(-(e.shiftKey ? 4 : 1) / ed.snapDen); break;
        case 'ArrowLeft': ed.nudge(0, -1); break;
        case 'ArrowRight': ed.nudge(0, 1); break;
        case 'PageUp': scrollBy(4); break;
        case 'PageDown': scrollBy(-4); break;
        case 'Home': stop(); ed.viewBeat = 0; needDraw = true; break;
        case 'End': stop(); ed.viewBeat = ed.lastBeat(); needDraw = true; break;
        case '[': { const i = SNAPS.indexOf(ed.snapDen); setSnap(SNAPS[Math.max(0, (i < 0 ? 3 : i) - 1)]); break; }
        case ']': { const i = SNAPS.indexOf(ed.snapDen); setSnap(SNAPS[Math.min(SNAPS.length - 1, (i < 0 ? 3 : i) + 1)]); break; }
        case '+': case '=': case ';': setZoom(ed.ppb * 1.2); break;
        case '-': setZoom(ed.ppb / 1.2); break;
        case 'm': ed.flip(); break;
        case 'r': ed.toggleRed(); break;
        case 'h': ed.toggleSlideHead(); break;
        case 'c': ed.toggleCurve(); break;
        case 'b': ed.bakeCurve(); break;
        case 'F1': showHelp(); break;
        default: handled = false;
      }
    }
    if (handled) { e.preventDefault(); needDraw = true; }
  });

  window.addEventListener('resize', () => { needDraw = true; });

  // ------------------------------------------------------------ メニュー (Electron)
  if (host) {
    host.onMenu(async cmd => {
      if (cmd === 'new') newChart();
      else if (cmd === 'open') openDialog();
      else if (cmd === 'save') save();
      else if (cmd === 'save-as') save(true);
      else if (cmd === 'pick-audio') $('btnAudio').click();
      else if (cmd === 'reveal') { if (ed.filePath) host.reveal(ed.filePath); }
      else if (cmd === 'help') showHelp();
      else if (cmd === 'save-and-close') { if (await save()) host.closeNow(); }
    });
    host.onOpenPath(async p => { if (await confirmDiscard()) openPath(p); });
  }

  bindMeta();
  syncUI();
  requestAnimationFrame(frame);
  window.__bx = { ed, audio, openPath, save };       // 動作確認用
})();
