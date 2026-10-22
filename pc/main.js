// BeatTriX Editor (PC 版) の本体 (Electron のメインプロセス)
//   ・ファイルの読み書きはここだけで行う (画面側からは preload.js 経由で呼ぶ)
//   ・保存: 前の中身を、アプリのフォルダ (ヘルプ → バックアップのフォルダ) に日時付きで残す (最新 300 個)。
//           譜面のフォルダ (Unity の ChartsRaw など) には何も増やさない
//           → 一時ファイルに書いてから置き換える → 読み直して中身が同じか確かめる
const { app, BrowserWindow, dialog, ipcMain, Menu, shell } = require('electron');
const path = require('path');
const fs = require('fs');

let win = null;
let dirty = false;
let forceClose = false;
let pendingOpen = null;

const AUDIO_EXT = ['.ogg', '.mp3', '.wav', '.m4a', '.flac', '.aac', '.opus'];

function argJson(argv) {
  for (const a of argv.slice(1)) {
    if (a && a.toLowerCase().endsWith('.json') && fs.existsSync(a)) return path.resolve(a);
  }
  return null;
}

function createWindow() {
  win = new BrowserWindow({
    width: 1440, height: 920, minWidth: 980, minHeight: 640,
    backgroundColor: '#0b0c10',
    title: 'BeatTriX Editor',
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.on('did-finish-load', () => {
    if (pendingOpen) { win.webContents.send('open-path', pendingOpen); pendingOpen = null; }
  });
  win.on('close', (e) => {
    if (!dirty || forceClose) return;
    e.preventDefault();
    const r = dialog.showMessageBoxSync(win, {
      type: 'warning',
      buttons: ['保存して閉じる', '保存しないで閉じる', 'キャンセル'],
      defaultId: 0, cancelId: 2,
      title: 'BeatTriX Editor',
      message: '保存していない変更があります。',
    });
    if (r === 0) win.webContents.send('menu', 'save-and-close');
    else if (r === 1) { forceClose = true; win.close(); }
  });
  buildMenu();
}

function send(cmd) { if (win) win.webContents.send('menu', cmd); }

function buildMenu() {
  const tpl = [
    {
      label: 'ファイル',
      submenu: [
        { label: '新しい譜面…', accelerator: 'CmdOrCtrl+N', click: () => send('new') },
        { label: '開く…', accelerator: 'CmdOrCtrl+O', click: () => send('open') },
        { type: 'separator' },
        { label: '保存', accelerator: 'CmdOrCtrl+S', click: () => send('save') },
        { label: '名前を付けて保存…', accelerator: 'CmdOrCtrl+Shift+S', click: () => send('save-as') },
        { type: 'separator' },
        { label: '曲のファイルを選ぶ…', click: () => send('pick-audio') },
        { label: '譜面のフォルダを開く', click: () => send('reveal') },
        { type: 'separator' },
        { label: '終了', role: 'quit' },
      ],
    },
    {
      label: '表示',
      submenu: [
        { label: '全画面', role: 'togglefullscreen' },
        { label: '開発者ツール', accelerator: 'F12', click: () => win && win.webContents.toggleDevTools() },
      ],
    },
    {
      label: 'ヘルプ',
      submenu: [
        { label: 'ショートカット一覧', accelerator: 'F1', click: () => send('help') },
        { label: 'バックアップのフォルダを開く', click: () => shell.openPath(backupDir()) },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(tpl));
}

function backupDir() {
  const d = path.join(app.getPath('userData'), 'backups');
  fs.mkdirSync(d, { recursive: true });
  return d;
}

function stamp() {
  const t = new Date();
  const p = (n, w) => String(n).padStart(w || 2, '0');
  return t.getFullYear() + p(t.getMonth() + 1) + p(t.getDate()) + '-' + p(t.getHours()) + p(t.getMinutes()) + p(t.getSeconds());
}

function keepBackup(filePath) {
  // アプリのフォルダに日時付きで (最新 300 個だけ残す)。譜面のフォルダには .bak を作らない
  const d = backupDir();
  const name = stamp() + '_' + path.basename(filePath);
  const dest = path.join(d, name);
  fs.copyFileSync(filePath, dest);
  const list = fs.readdirSync(d).filter(f => f.endsWith('.json')).sort();
  while (list.length > 300) {
    try { fs.unlinkSync(path.join(d, list.shift())); } catch (e) { break; }
  }
  return dest;
}

function writeSafely(filePath, text) {
  const data = Buffer.from(text, 'utf8');
  let backedUp = false;
  if (fs.existsSync(filePath)) {
    const old = fs.readFileSync(filePath);
    if (old.equals(data)) return { ok: true, unchanged: true };
    backedUp = keepBackup(filePath);
  }
  const tmp = filePath + '.tmp-' + process.pid;
  const fd = fs.openSync(tmp, 'w');
  try {
    fs.writeSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, filePath);
  const back = fs.readFileSync(filePath);
  if (!back.equals(data)) throw new Error('書いたあとに読み直した中身が一致しませんでした (' + filePath + ')');
  return { ok: true, backup: backedUp };
}

ipcMain.handle('dialog:open', async (_e, defaultDir) => {
  const r = await dialog.showOpenDialog(win, {
    title: '譜面 (JSON) を開く',
    defaultPath: defaultDir || undefined,
    properties: ['openFile'],
    filters: [{ name: '譜面 (JSON)', extensions: ['json'] }, { name: 'すべて', extensions: ['*'] }],
  });
  if (r.canceled || !r.filePaths.length) return null;
  return r.filePaths[0];
});

ipcMain.handle('dialog:save', async (_e, defaultPath) => {
  const r = await dialog.showSaveDialog(win, {
    title: '譜面を保存',
    defaultPath: defaultPath || undefined,
    filters: [{ name: '譜面 (JSON)', extensions: ['json'] }],
  });
  if (r.canceled || !r.filePath) return null;
  return r.filePath;
});

ipcMain.handle('dialog:audio', async (_e, defaultDir) => {
  const r = await dialog.showOpenDialog(win, {
    title: '曲のファイルを選ぶ',
    defaultPath: defaultDir || undefined,
    properties: ['openFile'],
    filters: [{ name: '音声', extensions: AUDIO_EXT.map(e => e.slice(1)) }, { name: 'すべて', extensions: ['*'] }],
  });
  if (r.canceled || !r.filePaths.length) return null;
  return r.filePaths[0];
});

ipcMain.handle('dialog:confirm', async (_e, opts) => {
  const r = await dialog.showMessageBox(win, {
    type: opts.type || 'question',
    buttons: opts.buttons || ['OK', 'キャンセル'],
    defaultId: 0, cancelId: (opts.buttons || ['OK', 'キャンセル']).length - 1,
    title: 'BeatTriX Editor',
    message: opts.message || '',
    detail: opts.detail || '',
  });
  return r.response;
});

ipcMain.handle('file:read-text', async (_e, p) => fs.readFileSync(p, 'utf8'));
ipcMain.handle('file:read-binary', async (_e, p) => {
  const b = fs.readFileSync(p);
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
});
ipcMain.handle('file:exists', async (_e, p) => fs.existsSync(p));
ipcMain.handle('file:save', async (_e, p, text) => {
  try {
    return writeSafely(p, text);
  } catch (err) {
    return { ok: false, error: String(err && err.message || err) };
  }
});
/// フォルダの中の曲 (下のフォルダも 4 段まで。最大 3000 個)。フルパスで返す
function listAudio(dir, depth) {
  const out = [];
  const walk = (d, lv) => {
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const e of ents) {
      if (out.length >= 3000) return;
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (lv < depth && !e.name.startsWith('.')) walk(p, lv + 1); }
      else if (AUDIO_EXT.includes(path.extname(e.name).toLowerCase())) out.push(p);
    }
  };
  if (dir) walk(dir, 0);
  return out.sort((a, b) => a.localeCompare(b));
}
ipcMain.handle('dir:audio-files', async (_e, dir, deep) => listAudio(dir, deep ? 4 : 0));

ipcMain.handle('dialog:folder', async (_e, title, defaultDir) => {
  const r = await dialog.showOpenDialog(win, {
    title: title || 'フォルダを選ぶ',
    defaultPath: defaultDir || undefined,
    properties: ['openDirectory', 'createDirectory'],
  });
  if (r.canceled || !r.filePaths.length) return null;
  return r.filePaths[0];
});

/// 初めて起動したときのフォルダの候補 (あるものだけ)
ipcMain.handle('app:default-folders', async () => {
  const root = path.join(app.getPath('home'), 'BeatTriX-shin-PlayFab(3k)', 'Assets');
  const charts = path.join(root, 'ChartsRaw');
  const songs = path.join(root, 'Resources');
  return { charts: fs.existsSync(charts) ? charts : null, songs: fs.existsSync(songs) ? songs : null };
});

function isInside(child, parent) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

/// 曲を曲フォルダにコピーする。
///   すでに曲フォルダの中 → そのまま / 同じ名前で同じ中身がある → それを使う /
///   同じ名前で中身が違う → mode が無ければ {conflict} を返す。'overwrite' で上書き、'rename' で「名前 (2).ogg」
ipcMain.handle('file:import-audio', async (_e, src, destDir, mode) => {
  try {
    if (isInside(src, destDir)) return { ok: true, path: src, already: true };
    fs.mkdirSync(destDir, { recursive: true });
    let dest = path.join(destDir, path.basename(src));
    if (fs.existsSync(dest)) {
      const a = fs.readFileSync(src), b = fs.readFileSync(dest);
      if (a.equals(b)) return { ok: true, path: dest, existed: true };
      if (!mode) return { ok: false, conflict: true, path: dest };
      if (mode === 'rename') {
        const ext = path.extname(src), stem = path.basename(src, ext);
        let i = 2;
        while (fs.existsSync(dest)) dest = path.join(destDir, stem + ' (' + (i++) + ')' + ext);
      }
    }
    const tmp = dest + '.tmp-' + process.pid;
    fs.copyFileSync(src, tmp);
    fs.renameSync(tmp, dest);
    return { ok: true, path: dest, copied: true };
  } catch (err) {
    return { ok: false, error: String(err && err.message || err) };
  }
});
/// 譜面のフォルダの譜面の一覧 (下のフォルダも 2 段まで): [{path, base, name, difficulty}]
ipcMain.handle('charts:index', async (_e, dir) => {
  const out = [];
  const walk = (d, lv) => {
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const e of ents) {
      if (out.length >= 3000) return;
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (lv < 2 && !e.name.startsWith('.')) walk(p, lv + 1); continue; }
      if (path.extname(e.name).toLowerCase() !== '.json') continue;
      let name = '', difficulty = null;
      try {
        const o = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
        if (!o || !Array.isArray(o.notes)) continue;
        name = typeof o.name === 'string' ? o.name : '';
        difficulty = typeof o.difficulty === 'number' ? o.difficulty : null;
      } catch (err) { continue; }
      out.push({ path: p, base: path.basename(e.name, path.extname(e.name)), name, difficulty });
    }
  };
  if (dir) walk(dir, 0);
  return out;
});
ipcMain.handle('path:inside', async (_e, child, parent) => !!(child && parent) && isInside(child, parent));
ipcMain.handle('path:info', async (_e, p) => ({ dir: path.dirname(p), base: path.basename(p), sep: path.sep }));
ipcMain.handle('path:join', async (_e, a, b) => path.join(a, b));
ipcMain.handle('shell:reveal', async (_e, p) => { if (p) shell.showItemInFolder(p); });
ipcMain.handle('shell:open-folder', async (_e, p) => { if (p) await shell.openPath(p); });
ipcMain.on('app:dirty', (_e, v) => { dirty = !!v; });
ipcMain.on('app:title', (_e, t) => { if (win) win.setTitle(t); });
ipcMain.on('app:close-now', () => { forceClose = true; if (win) win.close(); });

// 動作確認 (CI 用): 画面を出さずに起動して、譜面の読み書きと保存の仕組みを試し、結果をファイルに書いて終わる
//   BeatTriXEditor.exe --smoke <結果を書くファイル>
function smokeTest() {
  const outIdx = process.argv.indexOf('--smoke') + 1;
  const outPath = process.argv[outIdx] && !process.argv[outIdx].startsWith('--') ? process.argv[outIdx] : path.join(app.getPath('temp'), 'bx-smoke.txt');
  const log = [];
  const finish = (ok) => {
    log.push(ok ? 'SMOKE OK' : 'SMOKE FAILED');
    try { fs.writeFileSync(outPath, log.join('\n') + '\n'); } catch (e) { /* 書けなくても終わる */ }
    app.exit(ok ? 0 : 1);
  };
  setTimeout(() => { log.push('timeout'); finish(false); }, 60000);
  try {
    // 保存の仕組み: 書く → 書き換える (控えができる / .bak は作らない) → 中身が同じなら書かない
    const dir = fs.mkdtempSync(path.join(app.getPath('temp'), 'bx-smoke-'));
    const f = path.join(dir, 'test(EX).json');
    writeSafely(f, '{"a": 1}\n');
    const r2 = writeSafely(f, '{"a": 2}\n');
    const r3 = writeSafely(f, '{"a": 2}\n');
    const bak = fs.readFileSync(r2.backup, 'utf8');
    const okSave = typeof r2.backup === 'string' && !fs.existsSync(f + '.bak') && r3.unchanged === true && bak === '{"a": 1}\n' && fs.readFileSync(f, 'utf8') === '{"a": 2}\n';
    log.push('save/backup: ' + (okSave ? 'ok' : 'NG'));
    if (!okSave) { finish(false); return; }
  } catch (e) {
    log.push('save error: ' + e.message);
    finish(false);
    return;
  }
  win = new BrowserWindow({ show: false, webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false } });
  win.webContents.on('console-message', (_e, level, message) => { if (level >= 2) log.push('console: ' + message); });
  win.webContents.on('did-finish-load', async () => {
    try {
      const res = await win.webContents.executeJavaScript(`(() => {
        const F = window.BXF, B = F.Beat.make;
        const c = F.newChart('smoke', 180, 2);
        const s = F.makeNote(B(1), F.centerX(1), 72, null, [{ beat: B(1, 2), x: F.centerX(4) - F.centerX(1) }, { beat: B(1), x: F.centerX(6) - F.centerX(1) }]);
        s.extra.bxHead = 0; s.extra.bxCurve = true; s.extra.bxEase = [1, 2];
        const h = F.makeNote(B(1), F.centerX(1), 77, null); h.extra.bxHeadOf = s.id;
        c.notes.push(s, h, F.makeNote(B(2), F.centerX(3), 77, 3), F.makeNote(B(3), F.centerX(5), 72, 4));
        const a = F.stringify(c), b = F.stringify(F.parse(a));
        return JSON.stringify({ same: a === b, notes: JSON.parse(a).notes.length, ui: typeof window.__bx === 'object', audio: typeof window.BXAudio === 'function' });
      })()`);
      log.push('renderer: ' + res);
      const o = JSON.parse(res);
      finish(o.same && o.notes === 4 && o.ui && o.audio);
    } catch (e) {
      log.push('renderer error: ' + e.message);
      finish(false);
    }
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

const single = process.argv.includes('--smoke') ? true : app.requestSingleInstanceLock();
if (!single) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const p = argJson(argv);
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
      if (p) win.webContents.send('open-path', p);
    }
  });
  app.whenReady().then(() => {
    if (process.argv.includes('--smoke')) { smokeTest(); return; }
    pendingOpen = argJson(process.argv);
    createWindow();
  });
  app.on('window-all-closed', () => app.quit());
}
