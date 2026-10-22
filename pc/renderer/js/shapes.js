// スライドの帯の形 (iPad 版 Beatrix.slideShape / curvePoints / curveTangents / easeFraction と同じ計算)
(function (root) {
  'use strict';

  function easeFraction(e, u) {
    const t = Math.min(1, Math.max(0, u));
    if (e === 1) return t * t;
    if (e === 2) return 1 - (1 - t) * (1 - t);
    return t;
  }

  function curveTangents(xs, ys) {
    const n = xs.length;
    if (n < 2) return new Array(n).fill(0);
    const h = [], d = [];
    for (let k = 0; k < n - 1; k++) {
      h[k] = xs[k + 1] - xs[k];
      d[k] = h[k] > 1e-12 ? (ys[k + 1] - ys[k]) / h[k] : 0;
    }
    const m = new Array(n).fill(0);
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for (let k = 1; k < n - 1; k++) {
      if (d[k - 1] * d[k] <= 0) m[k] = 0;
      else {
        const w1 = 2 * h[k] + h[k - 1];
        const w2 = h[k] + 2 * h[k - 1];
        m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k]);
      }
    }
    return m;
  }

  function curveValue(xs, ys, m, k, t) {
    const h = xs[k + 1] - xs[k];
    const t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
      + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1];
  }

  function zipPts(xs, ys) { return xs.map((x, i) => ({ x, y: ys[i] })); }

  function curvePoints(xs, ys, samples) {
    samples = samples || 16;
    const n = xs.length;
    if (n < 3) return zipPts(xs, ys);
    for (let k = 1; k < n; k++) if (xs[k] < xs[k - 1]) return zipPts(xs, ys);
    const m = curveTangents(xs, ys);
    const out = [{ x: xs[0], y: ys[0] }];
    for (let k = 0; k < n - 1; k++) {
      const h = xs[k + 1] - xs[k];
      if (h <= 1e-12 || ys[k + 1] === ys[k]) { out.push({ x: xs[k + 1], y: ys[k + 1] }); continue; }
      for (let i = 1; i <= samples; i++) {
        const u = i / samples;
        out.push({ x: xs[k] + h * u, y: curveValue(xs, ys, m, k, u) });
      }
    }
    return out;
  }

  /// xs = 時刻 (拍)、ys = 横の位置。ease が付いていれば ease の形、無くて curve なら曲線、どちらも無ければ点そのまま
  function slideShape(xs, ys, eases, curve, samples) {
    samples = samples || 16;
    const n = xs.length;
    if (n < 2) return zipPts(xs, ys);
    if (eases && eases.length === n - 1 && eases.some(e => e !== 0)) {
      const out = [{ x: xs[0], y: ys[0] }];
      for (let k = 0; k < n - 1; k++) {
        const h = xs[k + 1] - xs[k];
        if (eases[k] === 0 || h <= 1e-12 || ys[k + 1] === ys[k]) { out.push({ x: xs[k + 1], y: ys[k + 1] }); continue; }
        for (let i = 1; i <= samples; i++) {
          const u = i / samples;
          out.push({ x: xs[k] + h * u, y: ys[k] + (ys[k + 1] - ys[k]) * easeFraction(eases[k], u) });
        }
      }
      return out;
    }
    if (curve) return curvePoints(xs, ys, samples);
    return zipPts(xs, ys);
  }

  const api = { easeFraction, curveTangents, curveValue, curvePoints, slideShape };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.BXShapes = api;
})(typeof window !== 'undefined' ? window : globalThis);
