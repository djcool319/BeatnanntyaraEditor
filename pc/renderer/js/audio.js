// 再生: 曲とノーツ音を、同じ AudioContext の時間軸に予約して鳴らす (サンプル単位でぴったり合う)
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
      for (const k of ['tap', 'wipe', 'red']) if (d[k]) this.se[k] = decodePCM(this.ctx, d[k]);
      return this.ctx;
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
      return this.music.duration;
    }
    duration() { return this.music ? this.music.duration : 0; }

    /// chartSec から再生。offsetSec = 0 拍目が曲の何秒目か。events = [{t: 譜面の秒, k: 'tap'|'wipe'|'red'}] (t の小さい順)
    play(chartSec, offsetSec, events) {
      const ctx = this.ensure();
      if (ctx.state === 'suspended') ctx.resume();
      this.stop();
      const rate = this.rate;
      this.startCtx = ctx.currentTime + 0.08;
      this.chart0 = chartSec;
      this.offset = offsetSec;
      if (this.music) {
        const pos = chartSec + offsetSec;
        if (pos < this.music.duration) {
          const s = ctx.createBufferSource();
          s.buffer = this.music;
          s.playbackRate.value = rate;
          s.connect(this.musicGain);
          if (pos >= 0) s.start(this.startCtx, pos);
          else s.start(this.startCtx + (-pos) / rate, 0);
          this.src = s;
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
    pump() {
      if (!this.playing) return;
      const ctx = this.ctx;
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
    ctxTimeOf(chartSec) { return this.startCtx + (chartSec - this.chart0) / this.rate; }
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
      for (const v of this.voices) { try { v.stop(); } catch (e) { /* 同上 */ } }
      this.voices = [];
      this.playing = false;
    }
  }

  window.BXAudio = BXAudio;
})();
