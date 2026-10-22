// 画面 (renderer) から使える機能だけを渡す
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('bxHost', {
  openDialog: (dir) => ipcRenderer.invoke('dialog:open', dir),
  saveDialog: (p) => ipcRenderer.invoke('dialog:save', p),
  audioDialog: (dir) => ipcRenderer.invoke('dialog:audio', dir),
  confirm: (opts) => ipcRenderer.invoke('dialog:confirm', opts),
  readText: (p) => ipcRenderer.invoke('file:read-text', p),
  readBinary: (p) => ipcRenderer.invoke('file:read-binary', p),
  exists: (p) => ipcRenderer.invoke('file:exists', p),
  save: (p, text) => ipcRenderer.invoke('file:save', p, text),
  audioFiles: (dir, deep) => ipcRenderer.invoke('dir:audio-files', dir, deep),
  folderDialog: (title, dir) => ipcRenderer.invoke('dialog:folder', title, dir),
  defaultFolders: () => ipcRenderer.invoke('app:default-folders'),
  importAudio: (src, destDir, mode) => ipcRenderer.invoke('file:import-audio', src, destDir, mode),
  isInside: (child, parent) => ipcRenderer.invoke('path:inside', child, parent),
  pathInfo: (p) => ipcRenderer.invoke('path:info', p),
  join: (a, b) => ipcRenderer.invoke('path:join', a, b),
  reveal: (p) => ipcRenderer.invoke('shell:reveal', p),
  openFolder: (p) => ipcRenderer.invoke('shell:open-folder', p),
  setDirty: (v) => ipcRenderer.send('app:dirty', v),
  setTitle: (t) => ipcRenderer.send('app:title', t),
  closeNow: () => ipcRenderer.send('app:close-now'),
  pathOfFile: (f) => (webUtils && webUtils.getPathForFile ? webUtils.getPathForFile(f) : f.path),
  onMenu: (fn) => ipcRenderer.on('menu', (_e, cmd) => fn(cmd)),
  onOpenPath: (fn) => ipcRenderer.on('open-path', (_e, p) => fn(p)),
});
