using System.Collections.Generic;
using UnityEngine;

// 曲線スライド (譜面 JSON の "curve") の形。エディタ (BeatTriX Editor) の Beatrix.curveTangents / curveValue / curvePoints と同じ計算。
// ・見た目だけ。判定点 (始点・経由点) の時刻とレーンは変えない
// ・単調 3 次補間 (PCHIP)。区間ごとにエルミート曲線で、経由点を必ず通る (ワイプや判定点と帯がずれない)
//   - 折り返す点 (前後で向きが逆) と、止まる点 (前か後ろが同じレーン) では、そこで縦向き (横の動き 0) → 行き過ぎない
//   - 同じ向きに進む途中の点では、前後の傾きを間隔で重み付けした調和平均
//   - 始点と終点では、その区間の傾きのまま (まっすぐ出る / まっすぐ入る)
// 1 本のスライドにつき 1 つ作って、そのスライドの全セグメント (SlideFollower) で共有する
// (2026-10-17: 角を丸める形は、移動が大きいとワイプとずれたのでこれに変更。SlideFollower.cs からの呼び方は同じ)
public class SlideCurve
{
    readonly int n;
    readonly float[] ts;   // 点の時刻 (秒)。始点 + 経由点
    readonly float[] ys;   // 点のレーン (0〜6)
    readonly float[] m;    // 各点での傾き
    readonly bool valid;   // false ならまっすぐ (点が 3 個未満 / 時刻が逆戻り)

    public SlideCurve(float[] times, float[] lanes)
    {
        n = times.Length;
        ts = (float[])times.Clone();
        ys = (float[])lanes.Clone();
        m = new float[n];
        valid = n >= 3 && lanes.Length == n;
        for (int k = 1; valid && k < n; k++) if (ts[k] < ts[k - 1]) valid = false;
        if (!valid) return;

        var h = new float[n - 1];
        var d = new float[n - 1];
        for (int k = 0; k < n - 1; k++)
        {
            h[k] = ts[k + 1] - ts[k];
            d[k] = h[k] > 1e-6f ? (ys[k + 1] - ys[k]) / h[k] : 0f;
        }
        m[0] = d[0];
        m[n - 1] = d[n - 2];
        for (int k = 1; k < n - 1; k++)
        {
            if (d[k - 1] * d[k] <= 0) m[k] = 0;
            else
            {
                float w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1];
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k]);
            }
        }
    }

    // 区間の番号 (始まりの時刻が timeA、終わりが timeB の区間)。見つからなければ -1
    public int SegmentOf(float timeA, float timeB)
    {
        for (int k = 0; k < n - 1; k++)
            if (Mathf.Abs(ts[k] - timeA) < 1e-4f && Mathf.Abs(ts[k + 1] - timeB) < 1e-4f) return k;
        return -1;
    }

    // 区間 k の時刻 t でのレーン (小数)。区間の外の t は区間の端に寄せる
    public float LaneAt(int k, float t)
    {
        if (k < 0 || k >= n - 1) return 0;
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f) return ys[k + 1];
        float u = Mathf.Clamp01((t - ts[k]) / h);
        if (!valid) return Mathf.Lerp(ys[k], ys[k + 1], u);
        float u2 = u * u, u3 = u2 * u;
        return (2 * u3 - 3 * u2 + 1) * ys[k] + (u3 - 2 * u2 + u) * h * m[k]
             + (-2 * u3 + 3 * u2) * ys[k + 1] + (u3 - u2) * h * m[k + 1];
    }

    // 区間 k の帯を描くための、間の時刻 (両端は入れない)
    public void AppendSampleTimes(int k, List<float> outTimes, int samples = 16)
    {
        if (!valid || k < 0 || k >= n - 1) return;
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f || ys[k] == ys[k + 1]) return;
        for (int i = 1; i < samples; i++) outTimes.Add(ts[k] + h * i / samples);
    }
}
