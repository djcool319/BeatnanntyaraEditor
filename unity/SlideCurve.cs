using System.Collections.Generic;
using UnityEngine;

// 曲線スライド (譜面 JSON の "curve") の形。エディタ (BeatTriX Editor) の Beatrix.curvePlan / curveTangents / curveValue と同じ計算。
// ・見た目だけ。判定点 (始点・経由点) の時刻とレーンは変えない
// ・始点から同じ向きに進んで折り返す (または止まる) 点までのひと続き → 4 分の 1 の円 f(u) = √(1 − (1 − u)²)
//   (真横から出て、ぐるっと回って縦に収まる)
// ・折り返す (または止まる) 点から同じ向きに進んで終点までのひと続き → 逆向きの 4 分の 1 の円 1 − √(1 − u²)
// ・それ以外の区間 → 単調 3 次補間 (PCHIP)。経由点を通り、経由点の間で行き過ぎない
// 1 本のスライドにつき 1 つ作って、そのスライドの全セグメント (SlideFollower) で共有する
public class SlideCurve
{
    readonly int n;
    readonly float[] ts;   // 点の時刻 (秒)。始点 + 経由点
    readonly float[] ys;   // 点のレーン (0〜6)
    readonly float[] m;    // PCHIP の傾き
    readonly int[] shape;  // 区間ごと: 0 = PCHIP / 1 = 円 (始まり側) / 2 = 円 (終わり側)
    readonly int[] rs, re; // 区間ごと: 円をかける範囲 (点の番号)

    public SlideCurve(float[] times, float[] lanes)
    {
        n = times.Length;
        ts = (float[])times.Clone();
        ys = (float[])lanes.Clone();
        m = new float[n];
        int segs = Mathf.Max(0, n - 1);
        shape = new int[segs];
        rs = new int[segs];
        re = new int[segs];
        for (int k = 0; k < segs; k++) { rs[k] = k; re[k] = k + 1; }
        if (n < 3) return;
        MakeTangents();
        MakePlan();
    }

    // ---- 傾き (PCHIP) ----
    void MakeTangents()
    {
        var h = new float[n - 1];
        var d = new float[n - 1];
        for (int k = 0; k < n - 1; k++)
        {
            h[k] = ts[k + 1] - ts[k];
            d[k] = h[k] > 1e-6f ? (ys[k + 1] - ys[k]) / h[k] : 0f;
        }
        for (int k = 1; k < n - 1; k++)
        {
            if (d[k - 1] * d[k] <= 0) m[k] = 0;
            else
            {
                float w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1];
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k]);
            }
        }
        m[0] = EndTangent(h[0], h[1], d[0], d[1]);
        m[n - 1] = EndTangent(h[n - 2], h[n - 3], d[n - 2], d[n - 3]);
    }

    static float EndTangent(float h0, float h1, float d0, float d1)
    {
        if (d0 == 0) return 0;
        if (d0 * d1 <= 0) return 2 * d0;
        float e = ((2 * h0 + h1) * d0 - h0 * d1) / Mathf.Max(1e-6f, h0 + h1);
        if (e * d0 <= 0) return 0;
        if (Mathf.Abs(e) > Mathf.Abs(3 * d0)) return 3 * d0;
        return e;
    }

    // ---- 円をかける範囲 ----
    void MakePlan()
    {
        int headEnd = -1;
        float d0 = ys[1] - ys[0];
        if (d0 != 0)
        {
            int j = 1;
            while (j + 1 < n && (ys[j + 1] - ys[j]) * d0 > 0) j++;
            if (j < n - 1 && Fits(0, j, 1))
            {
                for (int k = 0; k < j; k++) { shape[k] = 1; rs[k] = 0; re[k] = j; }
                headEnd = j;
            }
        }
        float dl = ys[n - 1] - ys[n - 2];
        if (dl != 0)
        {
            int i = n - 2;
            while (i - 1 >= 0 && (ys[i] - ys[i - 1]) * dl > 0) i--;
            if (i > 0 && i >= headEnd && Fits(i, n - 1, 2))
            {
                for (int k = i; k < n - 1; k++) { shape[k] = 2; rs[k] = i; re[k] = n - 1; }
            }
        }
    }

    // ひと続きの途中の点が、どれも円から幅の 1 割以内にあるか (離れていたら円にしない = 判定点が帯から外れない)
    bool Fits(int a, int b, int kind)
    {
        float span = ts[b] - ts[a];
        if (span <= 1e-6f) return false;
        float tol = Mathf.Abs(ys[b] - ys[a]) * 0.1f;
        for (int i = a + 1; i < b; i++)
        {
            if (ts[i] < ts[i - 1] - 1e-6f) return false;
            float v = Arc(ys[a], ys[b], (ts[i] - ts[a]) / span, kind);
            if (Mathf.Abs(v - ys[i]) > tol) return false;
        }
        return true;
    }

    static float Arc(float a, float b, float u, int kind)
    {
        float t = Mathf.Clamp01(u);
        if (kind == 1) { float v = 1 - t; return a + (b - a) * Mathf.Sqrt(Mathf.Max(0, 1 - v * v)); }
        return a + (b - a) * (1 - Mathf.Sqrt(Mathf.Max(0, 1 - t * t)));
    }

    // 区間 k の中の位置 u (0〜1) でのレーン (小数)
    float Value(int k, float u)
    {
        float h = ts[k + 1] - ts[k];
        if (shape[k] != 0)
        {
            float span = ts[re[k]] - ts[rs[k]];
            float x = ts[k] + h * u;
            return Arc(ys[rs[k]], ys[re[k]], span > 1e-6f ? (x - ts[rs[k]]) / span : u, shape[k]);
        }
        float u2 = u * u, u3 = u2 * u;
        return (2 * u3 - 3 * u2 + 1) * ys[k] + (u3 - 2 * u2 + u) * h * m[k]
             + (-2 * u3 + 3 * u2) * ys[k + 1] + (u3 - u2) * h * m[k + 1];
    }

    // 区間の番号 (始まりの時刻が timeA の区間)。見つからなければ -1
    public int SegmentOf(float timeA, float timeB)
    {
        for (int k = 0; k < n - 1; k++)
            if (Mathf.Abs(ts[k] - timeA) < 1e-4f && Mathf.Abs(ts[k + 1] - timeB) < 1e-4f) return k;
        return -1;
    }

    // 区間 k の時刻 t でのレーン (小数)。点が 3 個未満なら直線
    public float LaneAt(int k, float t)
    {
        if (k < 0 || k >= n - 1) return 0;
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f) return ys[k + 1];
        float u = Mathf.Clamp01((t - ts[k]) / h);
        if (n < 3) return Mathf.Lerp(ys[k], ys[k + 1], u);
        return Value(k, u);
    }

    // 区間 k の帯を描くための、間の時刻 (両端は入れない)。円の区間は、横に速く動く側ほど細かく刻む
    public void AppendSampleTimes(int k, List<float> outTimes, int samples = 16)
    {
        if (n < 3 || k < 0 || k >= n - 1) return;
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f) return;
        int cnt = shape[k] == 0 ? samples : samples * 2;
        for (int i = 1; i < cnt; i++)
        {
            float s = (float)i / cnt;
            float u = s;
            if (shape[k] == 1 && k == rs[k]) u = s * s;
            if (shape[k] == 2 && k + 1 == re[k]) u = 1 - (1 - s) * (1 - s);
            outTimes.Add(ts[k] + h * u);
        }
    }
}
