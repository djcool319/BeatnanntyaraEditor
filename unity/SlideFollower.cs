using UnityEngine;
using UnityEngine.Playables;

public class SlideFollower : MonoBehaviour
{
    public PlayableDirector director;
    public LineRenderer line;
    public int laneA, laneB;
    public float timeA, timeB;
    public bool missed = false;

    // ★ソフラン：このスライドだけの速さの倍率(speeds_each)。指定が無ければ1
    public float eachSpeed = 1f;

    // ★出現・消える：見える時間(秒)。この間だけ帯と光を表示する(判定には関係ない)
    public float showTime = float.NegativeInfinity;
    public float hideTime = float.PositiveInfinity;

    // ★ソフラン：この区間の途中でソフランが変わる時刻(帯をそこで折る)
    private readonly System.Collections.Generic.List<float> _cutTimes = new System.Collections.Generic.List<float>();

    [HideInInspector] public System.Collections.Generic.List<SlideFollower> chainMembers; // ★追加：同じスライドの兄弟セグメント

    // ★曲線スライド(curve)：同じスライドの全セグメントで共有する曲線。null なら今まで通りまっすぐ(見た目だけ。判定は変えない)
    [HideInInspector] public SlideCurve curve;
    private int _curveSeg = -1;

    // ★帯の点を置く時刻(両端を除く)。ソフランの変わり目と、曲線の細かい点を時刻順に並べたもの
    private readonly System.Collections.Generic.List<float> _midTimes = new System.Collections.Generic.List<float>();

    [SerializeField] private GameObject snapIndicator;

    //private Color idleColor = new Color(0.192f, 0.231f, 0.403f, 1f);
    //private Color activeColor = new Color(0.345f, 0.415f, 0.725f, 1f);
    private Color idleColor = new Color(0.213f, 0.256f, 0.446f, 0.8f);
    private Color activeColor = new Color(0.362f, 0.436f, 0.760f, 0.9f);

    private Material _material;
    private bool _initialized = false;

    private float lastHeldRealTime = -999f; // ★追加：最後に押下判定が出たリアルタイム
    private const float ReleaseGraceSeconds = 0.2f; // ★追加：離してから何秒activeを維持するか

    [Range(0f, 1f)] private float indicatorSpreadFactor = 0.955f; // ★追加：1で今と同じ、小さいほど中央寄りに縮む
    [Range(1f, 4f)] private float indicatorSpreadCurve = 4f; // ★追加：大きいほど中心付近の影響を抑え、端だけに効かせる

    // ★追加：SnapIndicatorの移動を0.01秒遅らせるためのバッファ
    private readonly System.Collections.Generic.Queue<(float time, float x, float z)> _indicatorBuffer = new System.Collections.Generic.Queue<(float, float, float)>();
    private const float IndicatorMoveDelay = 0.015f;

    void EnsureInit()
    {
        if (_initialized) return;
        if (line == null) return;

        // ★色合わせ：LineRenderer は「線の色(Color のグラデーション)」をマテリアルの色に掛け算する。
        //   白・不透明以外が入っていると、ホールドと同じマテリアル・同じ色でも暗く(薄く)見えるので、白にそろえる
        line.startColor = Color.white;
        line.endColor = Color.white;

        // ★色合わせ：ホールド(Bar)と同じ光の当たり方にする
        //   マテリアルが Standard(ライトの影響を受けるシェーダー)なので、
        //   ・線に「面の向き」の情報が無いと、ライトの計算が崩れて白っぽくくすむ → 生成する
        //   ・Bar は Light Probes / Reflection Probes が Blend Probes → 線も同じにする
        line.generateLightingData = true;
        line.lightProbeUsage = UnityEngine.Rendering.LightProbeUsage.BlendProbes;
        line.reflectionProbeUsage = UnityEngine.Rendering.ReflectionProbeUsage.BlendProbes;

        _material = line.material;
        _material.color = idleColor;

        // Inspectorでアタッチ済みならここはスキップされる
        if (snapIndicator == null)
        {
            var found = transform.Find("SnapIndicator");
            if (found != null) snapIndicator = found.gameObject;
        }
        if (snapIndicator != null) snapIndicator.SetActive(false);

        // ★ソフラン：区間の途中にあるソフランの変わり目を集めて、線の点を増やす
        _cutTimes.Clear();
        for (int i = 0; i < ChartScroll.ChangeCount; i++)
        {
            float ct = (float)ChartScroll.ChangeTime(i);
            if (ct > timeA + 0.0001f && ct < timeB - 0.0001f) _cutTimes.Add(ct);
        }

        // ★曲線スライド：曲線の細かい点も足す(ソフランの変わり目と合わせて時刻順)
        _midTimes.Clear();
        _midTimes.AddRange(_cutTimes);
        _curveSeg = (curve != null && timeB - timeA > 1e-6f) ? curve.SegmentOf(timeA, timeB) : -1;
        if (_curveSeg >= 0) curve.AppendSampleTimes(_curveSeg, _midTimes);
        _midTimes.Sort();
        line.positionCount = 2 + _midTimes.Count;

        _initialized = true;
    }

    // ★ソフラン：全体ソフラン(speeds)と個別の速さ(speeds_each)を入れたZ座標
    float ZAt(float time, double now)
    {
        return ChartScroll.Z(time, now, setting.notesSpeed * eachSpeed, GameManager.noteslineZ) + 0.03f;
    }

    void Update()
    {
        EnsureInit();
        if (director == null || line == null || _material == null) return;

        double now = !ChartClock.Instance.StartOffsetFinished
            ? director.time
            : ChartClock.Instance.Time;

        float zA = ZAt(timeA, now);
        float zB = ZAt(timeB, now);

        // LineRendererの描画
        // ★ソフラン：途中でソフランが変わるときは、その時刻の位置にも点を置く(無ければ今まで通り2点)
        // ★曲線スライド：曲線の細かい点も置く。横の位置は曲線から(見た目だけ)
        int last = _midTimes.Count + 1;
        line.SetPosition(0, new Vector3(_curveSeg >= 0 ? DrawX(timeA) : BlockToX(laneA), 0.69f, zA));
        for (int i = 0; i < _midTimes.Count; i++)
        {
            line.SetPosition(i + 1, new Vector3(DrawX(_midTimes[i]), 0.69f, ZAt(_midTimes[i], now)));
        }
        line.SetPosition(last, new Vector3(_curveSeg >= 0 ? DrawX(timeB) : BlockToX(laneB), 0.69f, zB));

        bool withinWindow = (float)now >= timeA && (float)now <= timeB;
        float progress = withinWindow ? Mathf.InverseLerp(timeA, timeB, (float)now) : 0f;

        float currentLaneF = Mathf.Lerp(laneA, laneB, progress);
        int currentLane = Mathf.RoundToInt(currentLaneF);

        bool selfActiveRaw = withinWindow && !missed && IsLaneButtonHeld(currentLane);
        if (selfActiveRaw) lastHeldRealTime = Time.time;

        // ★離してから0.1秒以内ならactive扱いを継続(ただし区間の時間窓は超えない)
        bool selfActive = withinWindow && !missed &&
                           (selfActiveRaw || (Time.time - lastHeldRealTime <= ReleaseGraceSeconds));

        // ★チェーン内のどこか1区間でもアクティブなら、全セグメント同じ色にする
        bool chainActive = selfActive;
        if (chainMembers != null)
        {
            foreach (var m in chainMembers)
            {
                if (m != null && m != this && m.EvaluateSelfActive(now))
                {
                    chainActive = true;
                    break;
                }
            }
        }

        _material.color = chainActive ? activeColor : idleColor;

        // ★出現・消える：見えない間は、帯も判定ラインの光も出さない
        bool visible = ChartScroll.IsVisible(showTime, hideTime, now);
        if (line.enabled != visible) line.enabled = visible;
        if (!visible) selfActive = false;

        if (snapIndicator != null)
        {
            snapIndicator.SetActive(selfActive);
            if (selfActive)
            {
                // ★ x だけインジケーター専用の縮小マッピングを使う(端レーンで広がりすぎるのを抑制)
                float indicatorXA = IndicatorBlockToX(laneA);
                float indicatorXB = IndicatorBlockToX(laneB);

                float rawX = Mathf.Lerp(indicatorXA, indicatorXB, progress);
                // ★曲線スライド：光も帯(曲線)の上を動かす(見た目だけ。押しているかの判定は上の currentLane のまま)
                if (_curveSeg >= 0) rawX = IndicatorBlockToX(curve.LaneAt(_curveSeg, (float)now));
                // ★ソフラン：「今の時刻」の帯の位置 = 判定ラインの位置(ソフランが無いときの今までの値と同じ)
                float rawZ = GameManager.noteslineZ + 0.03f;

                // ★今フレームで計算した「本来の移動先」をバッファに積む
                _indicatorBuffer.Enqueue((Time.time, rawX, rawZ));

                // ★0.01秒より古いものは使う対象なので取り出しつつ、それより新しいものは残す
                float x = rawX;
                float z = rawZ;
                float targetTime = Time.time - IndicatorMoveDelay;

                while (_indicatorBuffer.Count > 0)
                {
                    var oldest = _indicatorBuffer.Peek();
                    if (oldest.time <= targetTime)
                    {
                        x = oldest.x;
                        z = oldest.z;
                        _indicatorBuffer.Dequeue();
                    }
                    else
                    {
                        break;
                    }
                }

                snapIndicator.transform.localPosition = new Vector3(x, 0.71f, z - 0.06f);
                snapIndicator.transform.rotation = Quaternion.Euler(90f, 0f, 0f);
                snapIndicator.transform.localScale = new Vector3(0.028f, 0.015f, 0.005f);
            }
            else
            {
                // ★非アクティブになったらバッファをクリア(次にアクティブになった時に古い値を引きずらないため)
                _indicatorBuffer.Clear();
            }
        }
    }

    // ★追加：他セグメントから呼ばれる。自分の区間が「今押されてる状態」かどうかだけ返す
    // ★Updateの外(クラスのメンバ関数)に移動
    bool IsLaneButtonHeld(int lane)
    {
        if (lane <= 2 && button.tap0) return true;
        if (lane >= 2 && lane <= 4 &&
            (button.tap1 || button.tap1_1 || button.tap1ue ||
             button.tap2 || button.tap2_1 || button.tap2ue)) return true;
        if (lane >= 4 && button.tap3) return true;
        return false;
    }

    float BlockToX(int block) => -0.337f + block * 0.112333333f;

    // ★曲線スライド：時刻 t での帯の横の位置。曲線なら曲線のレーン(小数)、そうでなければ今まで通り laneA → laneB をまっすぐ
    float DrawX(float t)
    {
        if (_curveSeg >= 0) return -0.337f + curve.LaneAt(_curveSeg, t) * 0.112333333f;
        float u = Mathf.InverseLerp(timeA, timeB, t);
        return Mathf.Lerp(BlockToX(laneA), BlockToX(laneB), u);
    }

    // ★SnapIndicator専用。laneの中心(3)を基準に、端に行くほど縮めて広がりすぎを抑える
    // ★SnapIndicator専用。中心付近は元の座標をほぼ維持し、端に行くほど縮めて広がりすぎを抑える
    float IndicatorBlockToX(float laneF)
    {
        const float centerLane = 3f; // maxBlock=7 なので中心は0〜6の真ん中=3
        const float maxOffsetLane = 3f; // 中心からレーン0 or 6までの距離

        float x = -0.337f + laneF * 0.112333333f;
        float centerX = -0.337f + centerLane * 0.112333333f;
        float offset = x - centerX;

        // -1〜1に正規化した「中心からの距離」
        float t = Mathf.Clamp((laneF - centerLane) / maxOffsetLane, -1f, 1f);

        // 中心(t=0)ではblend=0(factorの影響なし)、端(t=±1)ではblend=1(factorがフルに効く)
        float blend = Mathf.Pow(Mathf.Abs(t), indicatorSpreadCurve);

        float appliedFactor = Mathf.Lerp(1f, indicatorSpreadFactor, blend);

        return centerX + offset * appliedFactor;
    }

    // ★追加：他セグメントから呼ばれる。自分の区間が「今押されてる状態」かどうかだけ返す
    public bool EvaluateSelfActive(double now)
    {
        bool withinWindow = (float)now >= timeA && (float)now <= timeB;
        if (!withinWindow || missed) return false;

        // ★他セグメントから見た時も、自分のUpdate()が更新したlastHeldRealTimeを使ってグレース判定
        return Time.time - lastHeldRealTime <= ReleaseGraceSeconds;
    }
}