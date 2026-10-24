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

  async function openPath(p, songPath) {
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
    const prevTitle = ed.chart.bx.name || '';
    ed.loadChart(chart, p);
    chartDir = await dirOf(p);
    setPref('lastDir', chartDir);
    await refreshSiblings();
    // 同じ曲名 (難易度の切り替えなど) なら、いま読んでいる曲をそのまま使う
    await autoAudio(songPath || (audio.music && audioPath && prevTitle === (chart.bx.name || '') ? audioPath : null));
    toast('開きました: ' + p.split(/[\\/]/).pop() + ' (ノーツ ' + chart.notes.length + ' 個)');
    fitView();
    return true;
  }

  async function openDialog() {
    if (!host) return;
    if (!(await confirmDiscard())) return;
    const p = await host.openDialog(chartDir || folders.charts || pref('lastDir', undefined));
    if (p) await openPath(p);
  }

  /// 保存。成功したら true
  async function save(forceAs) {
    if (!host) return false;
    if (ed.slideDraft) ed.finishSlide();
    let p = ed.filePath;
    if (!p || forceAs) {
      const base = (ed.filePath ? chartDir : null) || chartBaseDir();
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
    toast(r.unchanged ? '変更はありませんでした (保存済み)' : '保存しました' + (r.backup ? ' (前の中身はバックアップのフォルダに残しました)' : ''));
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
  // 曲フォルダ (Unity の Resources など) と、譜面と同じフォルダの曲を集める (フルパス)
  async function listAudioCandidates() {
    const out = [];
    const songDir = folders.songs;
    if (songDir) for (const f of await host.audioFiles(songDir, true)) out.push(f);
    if (chartDir) for (const f of await host.audioFiles(chartDir, false)) if (!out.includes(f)) out.push(f);
    return out;
  }
  function stemOf(p) { return p.split(/[\\/]/).pop().replace(/\.[^.]+$/, '').toLowerCase().trim(); }
  async function autoAudio(keep) {
    audioFilesInDir = await listAudioCandidates();
    let pick = keep || null;
    const remembered = ed.filePath ? audioMap()[ed.filePath] : null;
    if (!pick && remembered && await host.exists(remembered)) pick = remembered;
    if (!pick && audioFilesInDir.length) {
      const title = (ed.chart.bx.name || '').toLowerCase().trim();
      const base = ed.filePath ? ed.filePath.split(/[\\/]/).pop().replace(/\(..\)\.json$/i, '').replace(/\.json$/i, '').toLowerCase().trim() : '';
      const keys = [title, base].filter(k => k);
      pick = audioFilesInDir.find(f => keys.includes(stemOf(f)))
        || audioFilesInDir.find(f => { const s = stemOf(f); return keys.some(k => k.length >= 3 && s.length >= 3 && (s.includes(k) || k.includes(s))); })
        || null;
      // 名前で見つからないときは、譜面と同じフォルダに曲が 1 つだけならそれ (曲フォルダからは当てずっぽうで選ばない)
      if (!pick && chartDir) {
        const local = audioFilesInDir.filter(f => f.slice(0, chartDir.length) === chartDir && !/[\\/]/.test(f.slice(chartDir.length + 1)));
        if (local.length === 1) pick = local[0];
      }
    }
    if (pick) {
      if (pick !== audioPath || !audio.music) await loadAudio(pick);
      else { rememberAudio(); refreshAudioSelect(); }
    } else {
      audioPath = null; audio.music = null; refreshAudioSelect();
      if (audioFilesInDir.length) toast('曲が自動で見つかりませんでした。「曲の情報」の一覧から選んでください');
    }
  }
  /// 外から選んだ曲を、曲フォルダにコピーしてから読む (曲フォルダが決まっていて、まだその中に無いとき)
  /// 外から選んだ曲を、曲フォルダにコピーする (曲フォルダが決まっていて、まだその中に無いとき)。使うパスを返す (やめたら null)
  async function importSong(p) {
    const songDir = folders.songs;
    if (!autoImport || !songDir || !host.importAudio) return p;
    let r = await host.importAudio(p, songDir);
    if (r && r.conflict) {
      const name = r.path.split(/[\\/]/).pop();
      const c = await modal('同じ名前の曲があります', '<p>曲フォルダに「' + esc(name) + '」がすでにあり、中身が違います。</p>',
        [{ label: '別の名前でコピー', primary: true, value: 'rename' }, { label: '上書きする', danger: true, value: 'overwrite' },
          { label: 'コピーしないで使う', value: 'skip' }, { label: 'キャンセル', value: null }]);
      if (!c) return null;
      if (c === 'skip') return p;
      r = await host.importAudio(p, songDir, c);
    }
    if (!r || !r.ok) { toast('曲フォルダにコピーできませんでした: ' + (r && r.error || '')); return p; }
    if (r.copied) toast('曲フォルダにコピーしました: ' + r.path.split(/[\\/]/).pop());
    if (!audioFilesInDir.includes(r.path)) audioFilesInDir.push(r.path);
    return r.path;
  }

  // 曲名の比べ方: 全角半角・大文字小文字・空白や記号の違いは無視する
  function normName(s) {
    return String(s || '').normalize('NFKC').toLowerCase().replace(/\((bs|hd|ex|in)\)$/i, '')
      .replace(/[\s_\-‐－—~〜・.,!！?？'"’”()\[\]{}（）「」『』【】]/g, '');
  }
  function chartMatchesSong(name, base, songKey) {
    const a = normName(name), b = normName(base);
    return (a && a === songKey) || (b && b === songKey);
  }

  /// 曲を選んだとき: その曲の譜面を譜面のフォルダから探して開く (曲と譜面がずれないように)
  async function userPickSong(p0) {
    if (!host) return;
    const p = await importSong(p0);
    if (!p) return;
    const songKey = normName(stemOf(p));
    // 今の譜面がこの曲のものなら、曲だけ替える
    const curFileBase = ed.filePath ? ed.filePath.split(/[\\/]/).pop().replace(/\.json$/i, '') : '';
    if (chartMatchesSong(ed.chart.bx.name, curFileBase, songKey) || (ed.filePath && audioMap()[ed.filePath] === p)) { await loadAudio(p); return; }
    const dir = folders.charts || chartDir;
    let found = [];
    if (dir && host.chartIndex) {
      const idx = await host.chartIndex(dir);
      found = idx.filter(c => chartMatchesSong(c.name, c.base, songKey));
      if (!found.length) {
        found = idx.filter(c => { const n = normName(c.name) || normName(c.base); return songKey.length >= 3 && n.length >= 3 && (n.includes(songKey) || songKey.includes(n)); });
      }
    }
    if (found.length) {
      const cur = F.intValue(ed.chart.bx.difficulty);
      const pick = found.find(c => c.difficulty === cur) || found.find(c => c.difficulty === 2) || found[0];
      if (!(await confirmDiscard())) return;
      const m = audioMap(); m[pick.path] = p; setPref('audioFor', m);     // この譜面の曲として覚える
      await openPath(pick.path, p);
      return;
    }
    const r = await modal('この曲の譜面が見つかりません',
      '<p>「' + esc(stemOf(p)) + '」と同じ曲名の譜面が、譜面のフォルダにありません。</p>',
      [{ label: 'この曲で新しい譜面を作る', primary: true, value: 'new' }, { label: '今の譜面にこの曲を使う', value: 'use' }, { label: 'キャンセル', value: null }]);
    if (r === 'use') { await loadAudio(p); return; }
    if (r === 'new') {
      if (!(await confirmDiscard())) return;
      stop();
      const title = p.split(/[\\/]/).pop().replace(/\.[^.]+$/, '');
      const c = F.newChart(title, 120, F.intValue(ed.chart.bx.difficulty) === null ? 2 : F.intValue(ed.chart.bx.difficulty));
      ed.loadChart(c, null);
      ed.dirty = true;
      siblingExists = {};
      await loadAudio(p);
      updateTitle(); renderDiffs(); syncUI();
      toast('新しい譜面を作りました。BPM と offset を「曲の情報」「BPM・速さ」で入れてください');
    }
  }

  async function loadAudio(p) {
    stop();
    try {
      const buf = await host.readBinary(p);
      const dur = await audio.loadMusic(buf, p.split(/[\\/]/).pop());
      audioPath = p;
      rememberAudio();
      $('audioInfo').textContent = audio.musicName + ' (' + V.fmtTime(dur) + ')';
      $('audioInfo').title = p;
    } catch (e) {
      audioPath = null;
      audio.music = null;
      $('audioInfo').textContent = '曲を読み込めませんでした: ' + p.split(/[\\/]/).pop();
      toast('曲を読み込めませんでした (ogg / mp3 / wav に対応)');
    }
    refreshAudioSelect();
    needDraw = true;
  }
  function audioLabel(p) {
    for (const d of [folders.songs, chartDir]) {
      if (d && p.slice(0, d.length) === d && /[\\/]/.test(p.charAt(d.length))) return p.slice(d.length + 1);
    }
    return p.split(/[\\/]/).pop();
  }
  function refreshAudioSelect() {
    const sel = $('audioSel');
    sel.innerHTML = '';
    const list = audioFilesInDir.slice();
    if (audioPath && !list.includes(audioPath)) list.unshift(audioPath);
    const head = document.createElement('option');
    head.value = '';
    head.textContent = list.length ? '(曲を選ぶ)' : '(曲フォルダに曲がありません)';
    sel.appendChild(head);
    for (const p of list) {
      const o = document.createElement('option');
      o.value = p; o.textContent = audioLabel(p);
      if (p === audioPath) o.selected = true;
      sel.appendChild(o);
    }
    if (!audioPath) $('audioInfo').textContent = '曲が読み込まれていません (ノーツ音だけで再生します)';
  }

  // ------------------------------------------------------------ フォルダ (譜面 / 曲)
  const folders = { charts: pref('chartFolder', null), songs: pref('songFolder', null) };
  async function initFolders() {
    if (!host || !host.defaultFolders) return;
    if (!pref('foldersInit', false)) {
      const d = await host.defaultFolders();
      if (!folders.charts && d.charts) { folders.charts = d.charts; setPref('chartFolder', d.charts); }
      if (!folders.songs && d.songs) { folders.songs = d.songs; setPref('songFolder', d.songs); }
      setPref('foldersInit', true);
    }
    renderFolders();
    if (!audio.music) { audioFilesInDir = await listAudioCandidates(); refreshAudioSelect(); }
  }
  function renderFolders() {
    $('fCharts').textContent = folders.charts || '(決めていません)';
    $('fCharts').title = folders.charts || '';
    $('fSongs').textContent = folders.songs || '(決めていません)';
    $('fSongs').title = folders.songs || '';
    $('autoImport').checked = autoImport;
  }
  let autoImport = pref('autoImport', true);
  async function pickFolder(kind) {
    const title = kind === 'charts' ? '譜面 (JSON) を置くフォルダ' : '曲を置くフォルダ (Unity の Resources など)';
    const p = await host.folderDialog(title, folders[kind] || chartDir || undefined);
    if (!p) return;
    folders[kind] = p;
    setPref(kind === 'charts' ? 'chartFolder' : 'songFolder', p);
    renderFolders();
    if (kind === 'songs') { audioFilesInDir = await listAudioCandidates(); refreshAudioSelect(); }
  }
  function chartBaseDir() { return folders.charts || chartDir || pref('lastDir', ''); }

  // ------------------------------------------------------------ 再生
  let seeking = false;              // 再生中にホイールなどで動かしている途中 (少し止まってから、その位置から鳴らし直す)
  let seekTimer = null;
  function playingNow() { return audio.playing || seeking; }
  function startAudio() {
    audio.rate = Number($('rate').value) || 1;
    const startBeat = Math.max(-64, ed.viewBeat);      // 0 拍目より前 (前奏) からも流せる (プレビューの試聴など)
    ed.playStartBeat = startBeat;
    audio.play(ed.secOfBeat(startBeat), ed.offsetSec(), ed.keySounds());
  }
  function play() {
    if (playingNow()) return;
    // 置いている途中のスライドは、そのまま続けられるように残しておく (止めたあと続きの点を置ける)
    ed.ghost = null;
    ed.isPlaying = true;
    startAudio();
    $('btnPlay').textContent = '❚❚';
    $('btnPlay').classList.add('on');
  }
  function stop() {
    clearTimeout(seekTimer);
    const was = playingNow();
    seeking = false;
    audio.stop();
    ed.isPlaying = false;
    if (!was) return;
    $('btnPlay').textContent = '▶';
    $('btnPlay').classList.remove('on');
    needDraw = true;
    scheduleUI();
  }
  function togglePlay() { if (playingNow()) stop(); else play(); }
  /// 再生中に位置を動かす: 設定が「止める」なら止める。そうでなければ、動かし終わってから新しい位置で鳴らし直す
  function seekTo(beat) {
    if (!playingNow() || wheelStops) {
      if (playingNow()) stop();
      ed.viewBeat = beat;
      return;
    }
    ed.viewBeat = Math.max(0, beat);
    if (!seeking) { seeking = true; audio.stop(); }
    clearTimeout(seekTimer);
    seekTimer = setTimeout(() => { if (seeking) { seeking = false; startAudio(); } }, 110);
  }
  let wheelStops = pref('wheelStops', false);

  // ------------------------------------------------------------ 表示
  function fitView() {
    ed.viewBeat = 0;
    needDraw = true;
  }
  function scrollBy(beats) {
    seekTo(Math.max(-2, ed.viewBeat + beats));
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
  // 分割は iPad 版と同じく「1 拍を何分割するか」(1/4 = 1 拍を 4 分割)。一覧に無い数は入力欄で 1〜1024
  const SNAPS = [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 48, 64];
  function renderSnapList(d) {
    const sel = $('snap');
    const list = SNAPS.includes(d) ? SNAPS : SNAPS.concat([d]).sort((a, b) => a - b);
    sel.innerHTML = list.map(v => '<option value="' + v + '">1/' + v + '</option>').join('');
    sel.value = String(d);
    if (document.activeElement !== $('snapIn')) $('snapIn').value = d;
  }
  function setSnap(d, quiet) {
    d = Math.round(Number(d));
    if (!(d >= 1 && d <= 1024)) { toast('分割は 1〜1024 の整数で入れてください'); renderSnapList(ed.snapDen); return; }
    ed.snapDen = d;
    setPref('snapDen', d);
    renderSnapList(d);
    needDraw = true;
    if (!quiet) toast('分割を 1/' + d + ' にしました (1 拍を ' + d + ' 分割)');
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
    const wasPlaying = playingNow();
    seekTo(Math.max(0, ed.beatOfSec(Math.max(r.from, Math.min(r.to, s)))));
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
  /// その欄の数字を打っている途中か (打っている途中は一覧を作り直さない)
  function editingIn(box) { const a = document.activeElement; return !!a && a.tagName === 'INPUT' && box.contains(a); }
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
    // 中身が変わったときだけ作り直す (マウスを動かすたびに作り直すと、✕ を押している途中でボタンが入れ替わって押せないことがあった)
    const bpmSig = JSON.stringify(times);
    if (!editingIn(bl) && bl.dataset.sig !== bpmSig) {
      bl.dataset.sig = bpmSig;
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
        del.onclick = () => { del.blur(); ed.removeBPM(i); };
        bl.appendChild(row);
      });
    }
    const sl = $('spdList');
    const spdSig = JSON.stringify(ed.chart.speeds);
    if (!editingIn(sl) && sl.dataset.sig !== spdSig) {
      sl.dataset.sig = spdSig;
      sl.innerHTML = '';
      if (!ed.chart.speeds.length) sl.innerHTML = '<div class="empty">ソフランはありません</div>';
      ed.chart.speeds.forEach((t, i) => {
        const row = document.createElement('div');
        row.className = 'item';
        row.innerHTML = '<span class="at">' + Beat.label(t.beat) + '</span><input type="number" step="0.05" value="' + t.value + '"><button title="そこへ移動">→</button><button title="消す">✕</button>';
        const [inp, go, del] = [row.children[1], row.children[2], row.children[3]];
        inp.onchange = () => { const v = Number(inp.value); if (isFinite(v)) ed.addOrReplaceSpeed(t.beat, v); };
        go.onclick = () => { stop(); ed.viewBeat = Beat.val(t.beat); needDraw = true; };
        del.onclick = () => { del.blur(); ed.removeSpeed(i); };
        sl.appendChild(row);
      });
    }

    // 選択
    const sel = ed.selectedNotes();
    const nSl = sel.filter(F.isSlide).length;
    $('selCount').textContent = sel.length ? sel.length + ' 個を選択中' + (nSl ? ' (スライド/ホールド ' + nSl + ')' : '') : '選択なし (ノーツをクリック / ドラッグで囲む)';
    setVal('noteSpeed', sel.length ? ed.selectedSpeedText() : '');

    for (const b of document.querySelectorAll('.tool')) b.classList.toggle('active', b.dataset.tool === ed.tool);
    $('slideHead').checked = ed.slideWithHead;
    $('linkHead').checked = ed.linkHeadTap;
    $('segVertical').checked = ed.allowSegVertical;
    $('toolHint').textContent = TOOL_HINT[ed.tool] || '';
    renderDiffs();
    updateTitle();
  }

  const TOOL_HINT = {
    select: 'クリックで選択 / ドラッグで移動 / 空いた所をドラッグで囲んで選択。Ctrl / Shift で追加。',
    tap: 'クリックで白タップ (3 鍵)。Shift+クリックでスライド。ノーツを掴むと移動。右クリックで消す。',
    red: 'クリックで赤タップ (3 鍵)。',
    wipe: 'クリックでワイプ (7 鍵)。',
    slide: '始点 → 中継点を順にクリック (全部同じ鍵ならホールド)。始点から押したままドラッグでも置ける。Enter / 右クリックで完了。',
    modify: 'スライドを選んで、点をドラッグで動かす。空いた所をクリックで点を足す。',
    ease: 'スライドの帯 (点と点の間) をクリックして、曲がり方を選ぶ。',
    part: '始点の拍 → 終点の拍をクリックで part の区間。区間の中をクリックで消す。重なる区間は 1 つにまとまる。',
    range: '始点の拍 → 終点の拍をクリックで、その間のノーツを全部選ぶ (iPad の Time range)。そのあと Ctrl+C / Delete / ↑↓ など。',
    erase: 'クリックで消す。スライドは近い中継点から後ろを消す。',
  };

  // ------------------------------------------------------------ 入力欄
  function bindMeta() {
    $('mTitle').onchange = e => { ed.setMeta('name', e.target.value.trim()); refreshSiblings(); };
    $('mArtist').onchange = e => ed.setMeta('artist', e.target.value);
    $('mLevel').onchange = e => { const v = Number(e.target.value); if (isFinite(v)) ed.setMeta('LEVEL', v); };
    $('mOffset').onchange = e => { const v = Math.round(Number(e.target.value)); if (isFinite(v)) ed.setMeta('offset', v); };
    $('mPreview').onchange = e => { const t = e.target.value.trim(); ed.setMeta('preview', t === '' ? undefined : Number(t)); };
    // プレビュー: JSON の "preview" は「曲の何秒目から流すか」(Unity の preview.cs で music.time にそのまま入れている)。
    //   譜面の時刻 t の音 = 曲の t + offset/1000 秒目 なので、曲の秒 = 譜面の秒 + offset/1000
    $('pvHere').onclick = () => {
      const beat = playingNow() ? ed.beatOfSec(audio.chartTime(latencyMs / 1000)) : ed.viewBeat;
      const song = Math.max(0, ed.secOfBeat(Math.max(0, beat)) + ed.offsetSec());
      const v = Math.round(song * 1000) / 1000;
      ed.setMeta('preview', v);
      scheduleUI();
      toast('プレビューを 曲の ' + v + ' 秒目 にしました' + (F.intValue(ed.chart.bx.difficulty) === 2 ? '' : ' (ゲームでは EX の譜面の preview が使われます)'));
    };
    $('pvPlay').onclick = () => {
      if (!audio.music) { toast('曲が読み込まれていません'); return; }
      const p = F.doubleValue(ed.chart.bx.preview);
      const song = p === null ? 0 : p;
      stop();
      ed.viewBeat = ed.beatOfSec(song - ed.offsetSec());
      needDraw = true;
      play();
      toast('プレビューの位置 (曲の ' + song + ' 秒目) から流しています。Space で止める');
    };
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
    $('rate').onchange = () => { if (audio.playing) { audio.stop(); startAudio(); } };
    $('wheelStops').checked = wheelStops;
    $('wheelStops').onchange = e => { wheelStops = e.target.checked; setPref('wheelStops', wheelStops); };

    const snap = $('snap');
    renderSnapList(ed.snapDen);
    snap.onchange = () => setSnap(Number(snap.value));
    const snapIn = $('snapIn');
    snapIn.onchange = () => setSnap(snapIn.value);
    snapIn.onkeydown = e => { if (e.key === 'Enter') { setSnap(snapIn.value); snapIn.blur(); } };
    $('zoom').value = ed.ppb;
    $('zoom').oninput = e => setZoom(Number(e.target.value));

    $('btnPlay').onclick = togglePlay;
    $('btnTest').onclick = startTest;
    $('btnOpen').onclick = openDialog;
    $('btnSave').onclick = () => save();
    $('btnAudio').onclick = async () => {
      if (!host) return;
      const p = await host.audioDialog(folders.songs || chartDir || pref('lastDir', undefined));
      if (p) await userPickSong(p);
    };
    $('audioSel').onchange = async e => { if (e.target.value) await userPickSong(e.target.value); refreshAudioSelect(); };
    $('fChartsPick').onclick = () => pickFolder('charts');
    $('fSongsPick').onclick = () => pickFolder('songs');
    $('fChartsOpen').onclick = () => { if (folders.charts) host.openFolder(folders.charts); };
    $('fSongsOpen').onclick = () => { if (folders.songs) host.openFolder(folders.songs); };
    $('autoImport').onchange = e => { autoImport = e.target.checked; setPref('autoImport', autoImport); };
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
      ['Space', '再生 / 停止'], ['ホイール', 'スクロール (Shift で速く。再生中は再生したまま移動)'], ['Ctrl + ホイール', 'ズーム'], ['[  ]', '分割を粗く / 細かく'],
      ['Q / Esc', '選択ツール (置いている途中なら終わる)'], ['1〜9', 'タップ / 赤 / ワイプ / スライド (ホールド) / 中継点 / Ease / 消す / Part / 範囲選択'], ['P', 'テストプレイ (再生ラインから。D F J K で遊ぶ)'],
      ['Shift + クリック', '置くツールのままスライドを置く (Shift を離すと完了)'], ['Enter', 'スライドを完了'], ['右クリック', 'ノーツを消す (スライド作成中は完了)'],
      ['Ctrl+Z / Ctrl+Y', '元に戻す / やり直す'], ['Ctrl+C / X / V', 'コピー / 切り取り / 再生ラインに貼り付け'], ['Ctrl+A', '全部選ぶ'], ['Delete', '選択中を消す'],
      ['↑ ↓', '選択中を 1 分割ずつ動かす (選択なしならスクロール)'], ['← →', '選択中を横に動かす'], ['PageUp / PageDown', '1 小節ずつスクロール'], ['Home / End', '最初 / 最後のノーツへ'],
      ['M', '左右反転'], ['R', '白 ⇔ 赤タップ'], ['H', '始点 タップ / ワイプ / なし'], ['C', '曲線 (見た目)'], ['B', 'Curve bake'],
      ['Ctrl+S', '保存 (前の中身はバックアップのフォルダに残る)'], ['Ctrl+O / Ctrl+N', '開く / 新しい譜面'], ['F1', 'この一覧'],
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
    else if (/\.(ogg|mp3|wav|m4a|flac|aac|opus)$/i.test(p)) await userPickSong(p);
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
      const toolKeys = { '1': 'tap', '2': 'red', '3': 'wipe', '4': 'slide', '5': 'modify', '6': 'ease', '7': 'erase', '8': 'part', '9': 'range', 'q': 'select' };
      const lk = k.length === 1 ? k.toLowerCase() : k;
      if (toolKeys[lk]) ed.setTool(toolKeys[lk]);
      else switch (lk) {
        case ' ': togglePlay(); break;
        case 'Escape':
          if (ed.slideDraft) ed.finishSlide();
          else if (ed.partStart) { ed.partStart = null; ed.emit(); }
          else if (ed.rangeStart && !ed.rangeEnd) { ed.rangeStart = null; ed.emit(); }
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
        case '[': { const lower = SNAPS.filter(v => v < ed.snapDen); setSnap(lower.length ? lower[lower.length - 1] : SNAPS[0]); break; }
        case ']': { const upper = SNAPS.filter(v => v > ed.snapDen); setSnap(upper.length ? upper[0] : ed.snapDen); break; }
        case '+': case '=': case ';': setZoom(ed.ppb * 1.2); break;
        case '-': setZoom(ed.ppb / 1.2); break;
        case 'm': ed.flip(); break;
        case 'r': ed.toggleRed(); break;
        case 'h': ed.toggleSlideHead(); break;
        case 'c': ed.toggleCurve(); break;
        case 'b': ed.bakeCurve(); break;
        case 'F1': showHelp(); break;
        case 'p': startTest(); break;
        default: handled = false;
      }
    }
    if (handled) { e.preventDefault(); needDraw = true; }
  });

  window.addEventListener('resize', () => { needDraw = true; });

  // Shift: 押している間は、置くツールでもスライドを置く。離したら、Shift で置いていたスライドを完了
  function setShift(on) {
    if (ed.shiftHeld === on) return;
    ed.shiftHeld = on;
    if (!on && ed.slideDraft && ed.slideDraft.byShift && !(ed.drag && ed.drag.kind === 'place')) ed.finishSlide();
    if (lastMouse && geo) ed.updateGhost(lastMouse, geo);
  }
  window.addEventListener('keydown', e => { if (e.key === 'Shift') setShift(true); });
  window.addEventListener('keyup', e => { if (e.key === 'Shift') setShift(false); });
  window.addEventListener('blur', () => setShift(false));

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

  // ------------------------------------------------------------ テストプレイ
  const playScreen = new window.BXPlayScreen(audio);
  function startTest() {
    if (playScreen.isOpen) return;
    stop();
    if (ed.slideDraft) ed.finishSlide();
    ed.ghost = null;
    if (!ed.chart.notes.length) { toast('ノーツがありません'); return; }
    // 再生ラインの位置から (0 拍目より前なら最初から)
    const startSec = ed.secOfBeat(Math.max(0, ed.viewBeat));
    playScreen.onClose = () => { needDraw = true; };
    playScreen.open({ chart: ed.chart, startSec });
  }

  // ------------------------------------------------------------ ノーツ音の差し替え
  const SE_KINDS = [['tap', 'タップ'], ['wipe', 'ワイプ'], ['red', '赤']];
  function renderSERows() {
    const box = $('seRows');
    box.innerHTML = '';
    for (const [k, label] of SE_KINDS) {
      const p = pref('seFile.' + k, null);
      const row = document.createElement('div');
      row.className = 'serow';
      row.innerHTML = '<span>' + label + '</span><span class="sename"></span><button title="鳴らしてみる">▶</button><button>選ぶ…</button><button title="元の音に戻す">元に戻す</button>';
      row.children[1].textContent = p ? p.split(/[\\/]/).pop() : '(元の音)';
      row.children[1].title = p || '';
      row.children[2].onclick = () => audio.playNow(k);
      row.children[3].onclick = async () => {
        if (!host) return;
        const f = await host.audioDialog(p ? await dirOf(p) : undefined);
        if (f) await loadSE(k, f, true);
      };
      row.children[4].onclick = async () => { await audio.setSE(k, null); setPref('seFile.' + k, null); renderSERows(); toast(label + 'の音を元に戻しました'); };
      box.appendChild(row);
    }
  }
  async function loadSE(k, f, announce) {
    try {
      await audio.setSE(k, await host.readBinary(f));
      setPref('seFile.' + k, f);
      if (announce) { audio.playNow(k); toast('ノーツ音を変えました: ' + f.split(/[\\/]/).pop()); }
    } catch (e) {
      toast('音を読み込めませんでした: ' + f.split(/[\\/]/).pop() + ' (元の音を使います)');
      await audio.setSE(k, null);
      setPref('seFile.' + k, null);
    }
    renderSERows();
  }
  async function initSE() {
    renderSERows();
    if (!host) return;
    for (const [k] of SE_KINDS) { const f = pref('seFile.' + k, null); if (f) await loadSE(k, f, false); }
  }

  bindMeta();
  initSE();
  syncUI();
  initFolders();
  requestAnimationFrame(frame);
  window.__bx = { ed, audio, openPath, save };       // 動作確認用
})();
