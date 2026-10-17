using System.Collections.Generic;
using UnityEngine;

// 曲線スライド (譜面 JSON の "curve") の形。エディタ (BeatTriX Editor) の Beatrix.curveShape / curveAt と同じ計算。
// ・見た目だけ。判定点 (始点・経由点) の時刻とレーンは変えない
// ・経由点をつないだ折れ線の「角」ごとに、角の両側の線の途中 A・B を 2 次ベジェ曲線 (A → 角 → B) でつなぐ
//     A = 角 + (前の点 − 角) × r、B = 角 + (次の点 − 角) × r。r はふつう 0.5 (隣の線の真ん中まで) → 全体がなめらかにつながる
// ・始点と終点は動かさない (始点から斜めに出て、角でゆるく曲がる)
// ・角での横のずれ (= |前 − 角 + 次 − 角| × r / 4) が 0.4 レーン以下になるまで r を小さくする (急なギザギザは小さく丸める)
// ・時間 0 の区間 (横に飛ぶ線) の両端の角は丸めない
// 1 本のスライドにつき 1 つ作って、そのスライドの全セグメント (SlideFollower) で共有する
public class SlideCurve
{
    public const float CornerR = 0.5f;      // 角を丸める最大の r
    public const float MaxDevLanes = 0.4f;  // 角での横のずれの上限 (レーン)

    struct Corner { public float at, av, pt, pv, bt, bv; }  // A (時刻, レーン) / 角 / B

    readonly int n;
    readonly float[] ts;   // 点の時刻 (秒)。始点 + 経由点
    readonly float[] ys;   // 点のレーン (0〜6)
    readonly List<Corner> corners = new List<Corner>();
    readonly bool valid;   // false ならまっすぐ (点が 3 個未満 / 時刻が逆戻り)

    public SlideCurve(float[] times, float[] lanes)
    {
        n = times.Length;
        ts = (float[])times.Clone();
        ys = (float[])lanes.Clone();
        valid = n >= 3 && lanes.Length == n;
        for (int k = 1; valid && k < n; k++) if (ts[k] < ts[k - 1]) valid = false;
        if (!valid) return;

        for (int k = 1; k < n - 1; k++)
        {
            if (ts[k] - ts[k - 1] <= 1e-6f || ts[k + 1] - ts[k] <= 1e-6f) continue;
            float s = Mathf.Abs((ys[k - 1] - ys[k]) + (ys[k + 1] - ys[k])) * 0.25f;
            float r = s * CornerR <= MaxDevLanes ? CornerR : MaxDevLanes / s;
            if (r <= 0) continue;
            corners.Add(new Corner
            {
                at = ts[k] + (ts[k - 1] - ts[k]) * r, av = ys[k] + (ys[k - 1] - ys[k]) * r,
                pt = ts[k], pv = ys[k],
                bt = ts[k] + (ts[k + 1] - ts[k]) * r, bv = ys[k] + (ys[k + 1] - ys[k]) * r,
            });
        }
    }

    // 時刻 t での曲線のレーン (小数)
    public float LaneAtTime(float t)
    {
        if (!valid) return StraightAt(t);
        foreach (var q in corners)
        {
            if (t < q.at || t > q.bt) continue;
            // 時刻 t になる、ベジェの位置 s を求める (時刻は s について 2 次式)
            float a = q.at - 2 * q.pt + q.bt;
            float b = 2 * (q.pt - q.at);
            float c = q.at - t;
            float s;
            if (Mathf.Abs(a) < 1e-9f) s = Mathf.Abs(b) < 1e-9f ? 0 : -c / b;
            else s = (-b + Mathf.Sqrt(Mathf.Max(0, b * b - 4 * a * c))) / (2 * a);
            s = Mathf.Clamp01(s);
            return (1 - s) * (1 - s) * q.av + 2 * s * (1 - s) * q.pv + s * s * q.bv;
        }
        return StraightAt(t);
    }

    // 折れ線のまま (角の外)
    float StraightAt(float t)
    {
        if (n == 0) return 0;
        if (t <= ts[0]) return ys[0];
        for (int k = 0; k < n - 1; k++)
        {
            if (t > ts[k + 1]) continue;
            float h = ts[k + 1] - ts[k];
            if (h <= 1e-6f) return ys[k + 1];
            return ys[k] + (ys[k + 1] - ys[k]) * (t - ts[k]) / h;
        }
        return ys[n - 1];
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
        return LaneAtTime(Mathf.Clamp(t, ts[k], ts[k + 1]));
    }

    // 区間 k の帯を描くための、間の時刻 (両端は入れない)
    public void AppendSampleTimes(int k, List<float> outTimes, int samples = 24)
    {
        if (!valid || k < 0 || k >= n - 1) return;
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f) return;
        for (int i = 1; i < samples; i++) outTimes.Add(ts[k] + h * i / samples);
    }
}
