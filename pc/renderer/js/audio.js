// 再生: 曲とノーツ音を、同じ AudioContext の時間軸に予約して鳴らす (サンプル単位でぴったり合う)
//   再生速度が 1 以外のときは、曲を Rubber Band (js/stretch.js の Worker) で時間だけ伸ばして鳴らす (音程は変わらない)。
//   再生する位置から少しずつ伸ばしてもらい、伸ばした塊を同じ時間軸に隙間なく並べて予約する
(function () {
  'use strict';

  function decodePCM(ctx, b64) {
    const bin = atob(b64);
    const frames = Math.floor(bin.length / 4);
    const buf = ctx.createBuffer(2, Math.max(1, frames), 44100);
    const l = buf.getChannelData(0), r = buf.getChannelData(1);
    for (let i = 0; i < frames; i++) {
      const o = i * 4;
      let a = bin.charCodeAt(o) | (bin.charCodeAt(o + 1) << 8);
      let b = bin.charCodeAt(o + 2) | (bin.charCodeAt(o + 3) << 8);
      if (a >= 32768) a -= 65536;
      if (b >= 32768) b -= 65536;
      l[i] = a / 32768; r[i] = b / 32768;
    }
    return buf;
  }

  class BXAudio {
    constructor() {
      this.ctx = null;
      this.music = null;          // AudioBuffer
      this.musicName = '';
      this.src = null;
      this.playing = false;
      this.events = [];
      this.nextEvent = 0;
      this.voices = [];
      this.musicVolume = 0.8;
      this.seVolume = 0.8;
      this.seOn = true;
      this.rate = 1;
      this.keepPitch = true;      // 速度を変えても音程を変えない (Rubber Band)
      this.stretchBroken = false; // Rubber Band が動かなかった (このときは音程ごと変わる昔の鳴らし方)
      this.worker = null;
      this.workerSong = null;     // Worker に渡してある曲
      this.songId = 0;
      this.job = 0;
      this.stream = null;         // 伸ばして鳴らしている途中の情報
      this.streamSrcs = [];
    }
    ensure() {
      if (this.ctx) return this.ctx;
      this.ctx = new AudioContext({ latencyHint: 'interactive' });
      this.musicGain = this.ctx.createGain();
      this.seGain = this.ctx.createGain();
      this.musicGain.connect(this.ctx.destination);
      this.seGain.connect(this.ctx.destination);
      this.applyVolumes();
      const d = window.BX_SOUND_DATA || {};
      this.se = {};
      this.seDefault = {};
      for (const k of ['tap', 'wipe', 'red']) if (d[k]) { this.seDefault[k] = decodePCM(this.ctx, d[k]); this.se[k] = this.seDefault[k]; }
      return this.ctx;
    }
    /// ノーツ音を差し替える (arrayBuffer = 音のファイルの中身。null で元の音に戻す)
    async setSE(kind, arrayBuffer) {
      const ctx = this.ensure();
      if (!arrayBuffer) { this.se[kind] = this.seDefault[kind]; return true; }
      this.se[kind] = await ctx.decodeAudioData(arrayBuffer);
      return true;
    }
    applyVolumes() {
      if (!this.ctx) return;
      this.musicGain.gain.value = this.musicVolume;
      this.seGain.gain.value = this.seOn ? this.seVolume : 0;
    }
    async loadMusic(arrayBuffer, name) {
      const ctx = this.ensure();
      this.music = await ctx.decodeAudioData(arrayBuffer);
      this.musicName = name || '';
      this.songId++;
      return this.music.duration;
    }
    duration() { return this.music ? this.music.duration : 0; }

    /// chartSec から再生。offsetSec = 0 拍目が曲の何秒目か。events = [{t: 譜面の秒, k: 'tap'|'wipe'|'red'}] (t の小さい順)
    play(chartSec, offsetSec, events) {
      const ctx = this.ensure();
      if (ctx.state === 'suspended') ctx.resume();
      this.stop();
      const rate = this.rate;
      const stretch = rate !== 1 && this.keepPitch && !this.stretchBroken && this.music && this.ensureWorker();
      // 伸ばすときは、最初の塊ができるまで少し待つ。時刻はサンプルの境目にそろえる (塊を隙間なく並べるため)
      const sr = ctx.sampleRate;
      this.startCtx = Math.ceil((ctx.currentTime + (stretch ? 0.2 : 0.08)) * sr) / sr;
      this.chart0 = chartSec;
      this.offset = offsetSec;
      if (this.music) {
        const pos = chartSec + offsetSec;
        if (pos < this.music.duration) {
          if (stretch) this.startStream(pos);
          else this.startPlain(this.startCtx);
        }
      }
      this.events = events || [];
      let i = 0;
      while (i < this.events.length && this.events[i].t < chartSec - 0.0005) i++;
      this.nextEvent = i;
      this.playing = true;
      this.pump();
      this.timer = setInterval(() => this.pump(), 40);
    }
    /// 曲の、ctx の時刻 at に聞こえるべき位置 (秒)
    songPosAt(at) { return this.chart0 + this.offset + (at - this.startCtx) * this.rate; }
    /// 速度を変えるだけの鳴らし方 (速度 1、または Rubber Band が使えないとき。速度を変えると音程も変わる)
    startPlain(at) {
      const ctx = this.ctx;
      const rate = this.rate;
      const pos = this.songPosAt(at);
      if (pos >= this.music.duration) return;
      const s = ctx.createBufferSource();
      s.buffer = this.music;
      s.playbackRate.value = rate;
      s.connect(this.musicGain);
      if (pos >= 0) s.start(at, pos);
      else s.start(at + (-pos) / rate, 0);
      this.src = s;
    }
    ensureWorker() {
      if (this.worker) return true;
      try {
        // stretch.js の中身と wasm (vendor/rubberband-wasm.js) を 1 つの Blob にして Worker を作る
        if (typeof window.bxStretchModule !== 'function' || !window.BX_RUBBERBAND_WASM) throw new Error('stretch.js / rubberband-wasm.js が読めていない');
        const src = 'self.BX_RUBBERBAND_WASM=' + JSON.stringify(window.BX_RUBBERBAND_WASM) + ';\n' +
          '(' + window.bxStretchModule.toString() + ')(self);\n';
        const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        this.worker = new Worker(url);
        URL.revokeObjectURL(url);
      } catch (err) {
        console.warn('Rubber Band の Worker を作れませんでした', err);
        this.stretchBroken = true;
        return false;
      }
      this.worker.onmessage = (e) => this.onStretched(e.data);
      this.worker.onerror = (e) => { console.warn('Rubber Band の Worker でエラー', e.message); this.stretchFailed(); };
      return true;
    }
    stretchFailed() {
      if (this.stretchBroken) return;
      this.stretchBroken = true;
      if (this.onStretchError) this.onStretchError();
      // 鳴らしている途中なら、ここから昔の鳴らし方 (音程も変わる) で続ける
      if (this.playing && this.stream) {
        const at = Math.max(this.ctx.currentTime + 0.05, this.stream.start + this.stream.scheduled / this.ctx.sampleRate);
        this.stream = null;
        this.startPlain(at);
      }
    }
    /// 曲の pos 秒から、伸ばして鳴らし始める
    startStream(pos) {
      const ctx = this.ctx;
      const sr = ctx.sampleRate;
      if (this.workerSong !== this.songId) {
        const channels = [];
        for (let c = 0; c < this.music.numberOfChannels; c++) channels.push(this.music.getChannelData(c).slice());
        this.worker.postMessage({ type: 'load', key: this.songId, sampleRate: this.music.sampleRate, channels }, channels.map((a) => a.buffer));
        this.workerSong = this.songId;
      }
      const job = ++this.job;
      const start = pos >= 0 ? this.startCtx : this.startCtx + (-pos) / this.rate;
      this.stream = { job, start, scheduled: 0, pending: false, done: false, nch: this.music.numberOfChannels };
      this.worker.postMessage({ type: 'start', job, key: this.songId, rate: this.rate, from: Math.max(0, pos) * this.music.sampleRate, finer: true });
      this.requestMore(Math.round(sr * 0.25));       // 最初は小さめの塊 (早く鳴らすため)
    }
    requestMore(frames) {
      const st = this.stream;
      if (!st || st.pending || st.done) return;
      st.pending = true;
      this.worker.postMessage({ type: 'more', job: st.job, frames });
    }
    /// 先の分が 3 秒より少なくなったら、次の塊を頼む
    feedStream() {
      const st = this.stream;
      if (!st || st.pending || st.done) return;
      const ahead = st.start + st.scheduled / this.ctx.sampleRate - this.ctx.currentTime;
      if (ahead < 3) this.requestMore(Math.round(this.ctx.sampleRate * 1.5));
    }
    onStretched(m) {
      const st = this.stream;
      if (!st || m.job !== st.job || !this.playing) return;
      if (m.error) { console.warn('Rubber Band:', m.error); this.stretchFailed(); return; }
      st.pending = false;
      if (m.done) st.done = true;
      const len = m.channels[0] ? m.channels[0].length : 0;
      if (len > 0) {
        const ctx = this.ctx;
        const sr = ctx.sampleRate;
        const buf = ctx.createBuffer(m.channels.length, len, sr);
        m.channels.forEach((a, c) => buf.copyToChannel(a, c));
        const s = ctx.createBufferSource();
        s.buffer = buf;
        s.connect(this.musicGain);
        const when = st.start + m.at / sr;
        const now = ctx.currentTime + 0.005;
        if (when >= now) s.start(when);
        else if (when + len / sr > now) s.start(now, now - when);       // 間に合わなかった分は飛ばして、時刻を合わせる
        else { s.disconnect(); s.buffer = null; }
        if (s.buffer) {
          this.streamSrcs.push(s);
          s.onended = () => { const k = this.streamSrcs.indexOf(s); if (k >= 0) this.streamSrcs.splice(k, 1); s.disconnect(); };
        }
        st.scheduled = m.at + len;
      }
      this.feedStream();
    }
    pump() {
      if (!this.playing) return;
      const ctx = this.ctx;
      this.feedStream();
      const horizon = ctx.currentTime + 0.35;
      while (this.nextEvent < this.events.length) {
        const e = this.events[this.nextEvent];
        const at = this.ctxTimeOf(e.t);
        if (at > horizon) break;
        this.nextEvent++;
        if (at < ctx.currentTime - 0.02) continue;          // 大きく遅れた分は捨てる
        const buf = this.se[e.k];
        if (!buf) continue;
        const s = ctx.createBufferSource();
        s.buffer = buf;
        s.connect(this.seGain);
        s.start(Math.max(at, ctx.currentTime));
        this.voices.push(s);
        s.onended = () => { const k = this.voices.indexOf(s); if (k >= 0) this.voices.splice(k, 1); };
      }
    }
    playNow(kind) {
      const ctx = this.ensure();
      if (ctx.state === 'suspended') ctx.resume();
      const buf = this.se && this.se[kind];
      if (!buf || !this.seOn) return;
      const s = ctx.createBufferSource();
      s.buffer = buf;
      s.connect(this.seGain);
      s.start();
    }
    /// 譜面の時刻に合わせてノーツ音を予約する (曲と同じ時計。もう過ぎていればすぐ鳴らす)
    playAt(kind, chartSec) {
      if (!this.playing) { this.playNow(kind); return; }
      const ctx = this.ctx;
      const buf = this.se && this.se[kind];
      if (!buf || !this.seOn) return;
      const s = ctx.createBufferSource();
      s.buffer = buf;
      s.connect(this.seGain);
      s.start(Math.max(this.ctxTimeOf(chartSec), ctx.currentTime));
      this.voices.push(s);
      s.onended = () => { const k = this.voices.indexOf(s); if (k >= 0) this.voices.splice(k, 1); };
    }
    ctxTimeOf(chartSec) { return this.startCtx + (chartSec - this.chart0) / this.rate; }
    /// performance.now() の時刻 p に「聞こえていた」譜面の秒 (キーを押した瞬間の時刻を、フレームを待たずに出す)
    chartTimeAtPerf(p, extraLatencySec) {
      if (!this.playing) return this.chart0 || 0;
      const ctx = this.ctx;
      let heard;
      const ts = ctx.getOutputTimestamp ? ctx.getOutputTimestamp() : null;
      if (ts && ts.contextTime > 0 && ts.performanceTime > 0) heard = ts.contextTime + (p - ts.performanceTime) / 1000;
      else heard = ctx.currentTime - (ctx.outputLatency || ctx.baseLatency || 0) - (performance.now() - p) / 1000;
      heard -= (extraLatencySec || 0);
      return this.chart0 + (heard - this.startCtx) * this.rate;
    }
    /// 今「聞こえている」譜面の秒 (出力の遅れを引いた分)
    chartTime(extraLatencySec) {
      if (!this.playing) return this.chart0 || 0;
      const ctx = this.ctx;
      const heard = ctx.currentTime - (ctx.outputLatency || ctx.baseLatency || 0) - (extraLatencySec || 0);
      return this.chart0 + (heard - this.startCtx) * this.rate;
    }
    stop() {
      if (this.timer) { clearInterval(this.timer); this.timer = null; }
      if (this.src) { try { this.src.stop(); } catch (e) { /* もう止まっている */ } this.src.disconnect(); this.src = null; }
      this.stream = null;
      this.job++;
      for (const s of this.streamSrcs) { try { s.stop(); } catch (e) { /* もう止まっている */ } s.disconnect(); }
      this.streamSrcs = [];
      for (const v of this.voices) { try { v.stop(); } catch (e) { /* 同上 */ } }
      this.voices = [];
      this.playing = false;
    }
  }

  window.BXAudio = BXAudio;
})();
