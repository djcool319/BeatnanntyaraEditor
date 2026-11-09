// 再生速度を変えても音程が変わらないように、曲を Rubber Band (vendor/rubberband-wasm.js の wasm) で時間だけ伸ばす。
//   iOS 版 RubberBandPCMSource.swift と同じやり方 (リアルタイムモード、頭の遅れを計算で消す)。
//   再生する位置から少しずつ伸ばして渡す (曲全体を待たないので、すぐ鳴る)。
//
// Worker として動かす (audio.js が使う):
//   → { type: 'load', key, sampleRate, channels: [Float32Array, ...] }   曲を渡す (曲を読んだとき 1 回)
//   → { type: 'start', job, key, rate, from, finer }                     from = 元の曲のフレーム。そこから伸ばし始める
//   → { type: 'more', job, frames }                                      伸ばした音を frames フレームぶん欲しい
//   ← { job, at, channels: [...], done }                                 at = 伸ばした音の何フレーム目からか
//   ← { job, error }
//   伸ばした音の n フレーム目 = 元の曲の from + n × rate フレーム目
// Worker は、このファイルの中身 (bxStretchModule) と wasm を Blob にして作る (file:// からは Worker のファイルを直接読めないため。audio.js の ensureWorker)
// Node でも使える (test/stretch.js で確かめる)
function bxStretchModule(root) {
  'use strict';

  function wasiImports(getMemory) {
    const view = () => new DataView(getMemory().buffer);
    const EBADF = 8;
    return {
      wasi_snapshot_preview1: {
        environ_get: () => 0,
        environ_sizes_get: (count, size) => { const v = view(); v.setUint32(count, 0, true); v.setUint32(size, 0, true); return 0; },
        clock_time_get: (_id, _prec, out) => {
          const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
          view().setBigUint64(out, BigInt(Math.round(now * 1e6)), true);
          return 0;
        },
        fd_close: () => 0,
        fd_fdstat_get: () => EBADF,
        fd_prestat_get: () => EBADF,
        fd_prestat_dir_name: () => EBADF,
        fd_read: () => EBADF,
        fd_seek: () => EBADF,
        fd_write: (_fd, iovs, n, written) => {
          const v = view();
          let total = 0;
          for (let i = 0; i < n; i++) total += v.getUint32(iovs + i * 8 + 4, true);
          v.setUint32(written, total, true);
          return 0;
        },
        proc_exit: (code) => { throw new Error('rubberband exit ' + code); },
      },
    };
  }

  function base64ToBytes(b64) {
    if (typeof atob === 'undefined') return new Uint8Array(Buffer.from(b64, 'base64'));
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  const OPT_REALTIME = 0x00000001;
  const OPT_THREADING_NEVER = 0x00010000;
  const OPT_ENGINE_FINER = 0x20000000;
  const BLOCK = 2048;

  /// 1 曲を、ある位置から伸ばしていく
  class Streamer {
    constructor(wasmBytes) {
      this.module = new WebAssembly.Module(wasmBytes);
      let inst = null;
      inst = new WebAssembly.Instance(this.module, wasiImports(() => inst.exports.memory));
      inst.exports._initialize();
      this.ex = inst.exports;
      this.st = 0;
      this.key = null;
    }
    /// 曲を渡す
    load(key, sampleRate, channels) {
      this.close();
      this.key = key;
      this.sampleRate = sampleRate;
      this.channels = channels;
    }
    close() {
      const ex = this.ex;
      if (this.st) { ex.rubberband_delete(this.st); this.st = 0; }
      if (this.ptrs) { for (const p of this.ptrs) ex.bx_free(p); this.ptrs = null; }
    }
    /// from (元の曲のフレーム) から、rate 倍の速さで伸ばし始める
    start(rate, from, finer) {
      this.close();
      const ex = this.ex;
      const nch = this.channels.length;
      this.nch = nch;
      this.rate = rate;
      this.st = ex.rubberband_new(this.sampleRate, nch, OPT_REALTIME | OPT_THREADING_NEVER | (finer ? OPT_ENGINE_FINER : 0), 1 / rate, 1.0);
      ex.rubberband_set_max_process_size(this.st, BLOCK);
      this.inArr = ex.bx_malloc(nch * 4);
      this.outArr = ex.bx_malloc(nch * 4);
      this.inBuf = []; this.outBuf = [];
      for (let c = 0; c < nch; c++) { this.inBuf.push(ex.bx_malloc(BLOCK * 4)); this.outBuf.push(ex.bx_malloc(BLOCK * 4)); }
      this.ptrs = [this.inArr, this.outArr, ...this.inBuf, ...this.outBuf];
      const u32 = new Uint32Array(ex.memory.buffer);
      for (let c = 0; c < nch; c++) { u32[(this.inArr >> 2) + c] = this.inBuf[c]; u32[(this.outArr >> 2) + c] = this.outBuf[c]; }
      this.queue = [];             // 取り出した出力 ([Float32Array, ...] の塊)
      this.queued = 0;
      this.made = 0;               // 渡した出力のフレーム数
      this.finished = false;
      this.sentFinal = false;
      // 頭の遅れを消す: 先に preferred_start_pad ぶん (from の直前の音) を入れて、start_delay ぶんの出力を捨てる
      const pad = ex.rubberband_get_preferred_start_pad(this.st);
      this.skip = ex.rubberband_get_start_delay(this.st);
      this.readPos = Math.round(from) - pad;
    }
    feed(n, final) {
      const ex = this.ex;
      const f32 = new Float32Array(ex.memory.buffer);
      const total = this.channels[0].length;
      for (let c = 0; c < this.nch; c++) {
        const dst = this.inBuf[c] >> 2;
        const src = this.channels[c];
        for (let i = 0; i < n; i++) {
          const k = this.readPos + i;
          f32[dst + i] = (k >= 0 && k < total) ? src[k] : 0;
        }
      }
      ex.rubberband_process(this.st, this.inArr, n, final ? 1 : 0);
      this.readPos += n;
    }
    drain() {
      const ex = this.ex;
      for (;;) {
        const av = ex.rubberband_available(this.st);
        if (av < 0) { this.finished = true; return; }
        if (av === 0) return;
        const got = ex.rubberband_retrieve(this.st, this.outArr, Math.min(av, BLOCK));
        if (got <= 0) return;
        const f32 = new Float32Array(ex.memory.buffer);
        let from = 0;
        if (this.skip > 0) { from = Math.min(this.skip, got); this.skip -= from; }
        if (from >= got) continue;
        const chunk = [];
        for (let c = 0; c < this.nch; c++) chunk.push(f32.slice((this.outBuf[c] >> 2) + from, (this.outBuf[c] >> 2) + got));
        this.queue.push(chunk);
        this.queued += got - from;
      }
    }
    /// 伸ばした音を frames フレームぶん返す ({ at, channels, done })
    more(frames) {
      const ex = this.ex;
      const total = this.channels[0].length;
      while (this.queued < frames && !this.finished) {
        if (this.readPos >= total) {
          if (!this.sentFinal) { this.feed(0, true); this.sentFinal = true; }
          this.drain();
          if (!this.finished && ex.rubberband_available(this.st) === 0) this.finished = true;
          continue;
        }
        let need = ex.rubberband_get_samples_required(this.st);
        if (need <= 0) need = BLOCK;
        const n = Math.min(BLOCK, need, total - this.readPos);
        this.feed(n, this.readPos + n >= total);
        if (this.readPos >= total) this.sentFinal = true;
        this.drain();
      }
      const len = Math.min(frames, this.queued);
      const out = [];
      for (let c = 0; c < this.nch; c++) out.push(new Float32Array(len));
      let w = 0;
      while (w < len) {
        const head = this.queue[0];
        const take = Math.min(head[0].length, len - w);
        for (let c = 0; c < this.nch; c++) out[c].set(head[c].subarray(0, take), w);
        if (take === head[0].length) this.queue.shift();
        else for (let c = 0; c < this.nch; c++) head[c] = head[c].subarray(take);
        w += take;
      }
      this.queued -= len;
      const at = this.made;
      this.made += len;
      return { at, channels: out, done: this.finished && this.queued === 0 };
    }
  }

  const api = { Streamer, base64ToBytes };
  root.BXStretch = api;

  // Worker として動いているとき (self.BX_RUBBERBAND_WASM = wasm の base64 は、Blob の頭に入っている)
  if (typeof importScripts === 'function' && typeof window === 'undefined' && root.BX_RUBBERBAND_WASM) {
    let s = null;
    let job = 0;
    self.onmessage = (e) => {
      const m = e.data;
      try {
        if (!s) s = new Streamer(base64ToBytes(self.BX_RUBBERBAND_WASM));
        if (m.type === 'load') { s.load(m.key, m.sampleRate, m.channels); return; }
        if (m.type === 'start') {
          if (s.key !== m.key) { self.postMessage({ job: m.job, error: 'no song' }); return; }
          job = m.job;
          s.start(m.rate, m.from, m.finer);
          return;
        }
        if (m.type === 'more') {
          if (m.job !== job || !s.st) return;
          const r = s.more(m.frames);
          self.postMessage({ job, at: r.at, channels: r.channels, done: r.done }, r.channels.map((a) => a.buffer));
        }
      } catch (err) {
        self.postMessage({ job: m.job, error: String(err && err.message || err) });
      }
    };
  }
}
bxStretchModule(typeof self !== 'undefined' ? self : globalThis);
if (typeof module !== 'undefined' && module.exports) module.exports = globalThis.BXStretch;
