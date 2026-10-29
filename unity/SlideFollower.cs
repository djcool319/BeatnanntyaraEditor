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

    // ★自動ポーズ用：この区間に付いている、まだ判定されていない判定点の数(NotesGenerate が数えて、keyjudge が判定したら減らす)
    [HideInInspector] public int remainingJudge = 0;

    // ★出現・消える：見える / 見えないの切り替え(何回でも)。null = いつも見える(判定には関係ない)
    public NoteVis vis;

    // ★ソフラン：この区間の途中でソフランが変わる時刻(帯をそこで折る)
    private readonly System.Collections.Generic.List<float> _cutTimes = new System.Collections.Generic.List<float>();

    [HideInInspector] public System.Collections.Generic.List<SlideFollower> chainMembers; // ★追加：同じスライドの兄弟セグメント

    // ★曲線スライド(curve)：同じスライドの全セグメントで共有する曲線。null なら今まで通りまっすぐ(見た目だけ。判定は変えない)
    [HideInInspector] public SlideCurve curve;
    // ★区間の曲がり方(ease)：0 = まっすぐ / 1 = Ease In(はじめゆっくり→あと速く) / 2 = Ease Out(はじめ速く→あとゆっくり)
    //   0 以外なら curve より優先(見た目だけ。判定は変えない)
    [HideInInspector] public int ease = 0;
    private const int EaseSamples = 16;
    private int _curveSeg = -1;

    // ★帯の点を置く時刻(両端を除く)。ソフランの変わり目と、曲線の細かい点を時刻順に並べたもの
    private readonly System.Collections.Generic.List<float> _midTimes = new System.Collections.Generic.List<float>();

    [SerializeField] private GameObject snapIndicator;

    //private Color idleColor = new Color(0.192f, 0.231f, 0.403f, 1f);
    //private Color activeColor = new Color(0.345f, 0.415f, 0.725f, 1f);
    private Color idleColor = new Color(0.213f, 0.256f, 0.446f, 0.8f);
    private Color activeColor = new Color(0.362f, 0.436f, 0.760f, 0.9f);

    private Material _material;

    // ★判定ラインの光(SnapIndicator)の奥行きの微調整。エフェクトの位置(keyjudge の effectZ)を動かしたら、ここも同じだけ動かす
    //   今：エフェクトを +0.02(判定バー -9.83 → -9.81)、そのあと -0.005 したので、合計 +0.015
    private const float snapZShift = 0.0135f; // ★0.015 から -0.0015

    // =====================================================================
    // ★平らな帯：スライドの帯を、ホールドの帯と同じように「レーンの上に平らに寝かせた帯」で描く
    //   (前は LineRenderer の Alignment = View で、帯がカメラの方に起き上がっていたのを、平らに寝かせた)
    //
    // ★2026-10-29：平らな帯を、LineRenderer ではなく「横に ±太さ」のメッシュで描くようにした (エディタのテストプレイと同じ見た目)
    //   LineRenderer (TransformZ) は、平らに寝かせても「線の向きに直角」に太さを付けるので、
    //   ソフランで速さ 0 の区間 (奥へ進まず横にだけ動く所) で線が真横を向くと、太さが奥行き方向にしか付かず、帯がとても細くなっていた。
    //   中継点ごとに線の向きが縦 ⇔ 横に変わると、角で太さの向きが斜めにねじれて、帯全体が細く・ギザギザに見えていた。
    //   今は、どの点でも「横 (レーンの左右) に ±太さの半分」の 2 頂点を置いて、となりの点と四角でつなぐだけ。
    //   ・太さは LineRenderer の Width、色はそのマテリアル。LineRenderer 自体は描かない (帯は子の「RibbonMesh」で描く。自動で作る)
    //   ・帯の点の座標・SnapIndicator・描く順番 (sortingOrder)・出現/消える・自動ポーズの処理は今までと同じ
    //   ・奥へ進まない区間 (速さ 0) の帯は、高さ 0 になって見えない (エディタと同じ)
    // =====================================================================
    private bool flatBand = true;

    // ★帯の描く順番(小さいほど先 = 下)。ノーツは 0、レーンの床は DrawFirst で -10
    public const int BandOrderIdle = -2;   // 押していない帯
    public const int BandOrderActive = -1; // 押している帯(押していない帯より上)
    // ★帯が見えなくなった(裏返しになった)ときは true にする
    private bool flatBandFlip = false;

    private Matrix4x4 _lineBase = Matrix4x4.identity; // 帯の点の座標を、世界の座標にするための変換(今までの座標の意味を変えないため)
    private Matrix4x4 _snapBase = Matrix4x4.identity; // 光(SnapIndicator)の座標を、世界の座標にするための変換

    // ★帯のメッシュ
    private Transform _ribbon;
    private MeshRenderer _ribbonRenderer;
    private Mesh _mesh;
    private Vector3[] _points;          // 帯の中心の点 (今まで LineRenderer に渡していたのと同じ座標)
    private Vector3[] _verts;
    private Vector3[] _normals;
    private int[] _tris;
    private float _halfWidth = 0.014f;  // 帯の太さの半分 (世界の長さ)
    // ★帯の太さの倍率 (1 = LineRenderer の Width と同じ)。太すぎ / 細すぎのときはここで合わせる
    [SerializeField] private float bandWidthScale = 1f;
    private static bool _loggedWidth = false;

    // 帯の点を置く(今までと同じ座標を渡せばよい)
    void SetLinePoint(int i, Vector3 p)
    {
        _points[i] = p;
    }
    private bool _initialized = false;

    private float lastHeldRealTime = -999f; // ★追加：最後に押下判定が出たリアルタイム
    private const float ReleaseGraceSeconds = 0.3f; // ★追加：離してから何秒activeを維持するか

    [Range(0f, 1f)] private float indicatorSpreadFactor = 0.955f; // ★追加：1で今と同じ、小さいほど中央寄りに縮む
    [Range(1f, 4f)] private float indicatorSpreadCurve = 4f; // ★追加：大きいほど中心付近の影響を抑え、端だけに効かせる

    // ★追加：SnapIndicatorの移動を0.01秒遅らせるためのバッファ
    private readonly System.Collections.Generic.Queue<(float time, float x, float z)> _indicatorBuffer = new System.Collections.Generic.Queue<(float, float, float)>();
    private const float IndicatorMoveDelay = 0.015f;

    void EnsureInit()
    {
        if (_initialized) return;
        if (line == null) return;

        // ★今までの座標の意味を覚える (LineRenderer の点の座標 → 世界の座標)。line の向きはもう変えない
        _lineBase = line.useWorldSpace ? Matrix4x4.identity : line.transform.localToWorldMatrix;
        _snapBase = transform.localToWorldMatrix; // 光は今まで「この親から見た座標」で置いていた

        // ★帯の太さは、LineRenderer が実際に描いていた太さ = Width のカーブの値 × Width Multiplier (世界の長さ)
        //   (startWidth だけだと、カーブの値 (1 など) が返ってきて、とても太くなることがある)
        float curveW = (line.widthCurve != null && line.widthCurve.length > 0) ? line.widthCurve.Evaluate(0f) : 1f;
        _halfWidth = Mathf.Max(0.0001f, curveW * line.widthMultiplier * 0.5f * bandWidthScale);
        if (!_loggedWidth)
        {
            _loggedWidth = true;   // 確認用 (1 回だけ)。太さがおかしいときは、この値を教えてください
            Debug.Log("SlideFollower 帯の太さ: curve=" + curveW + " multiplier=" + line.widthMultiplier + " startWidth=" + line.startWidth
                      + " → 帯の幅=" + (_halfWidth * 2f) + " / レーン1つの幅=" + _lineBase.MultiplyVector(new Vector3(0.112333333f, 0f, 0f)).magnitude);
        }

        _material = line.material;
        _material.color = idleColor;

        // ★LineRenderer 自体は描かない (帯は下のメッシュで描く)
        line.enabled = false;

        // ★帯のメッシュ用の子オブジェクトを作る (頂点は毎フレーム、世界の座標からこの子の座標に直して入れる)
        var go = new GameObject("RibbonMesh");
        go.layer = line.gameObject.layer;
        _ribbon = go.transform;
        _ribbon.SetParent(transform, false);
        _ribbon.localPosition = Vector3.zero;
        _ribbon.localRotation = Quaternion.identity;
        _ribbon.localScale = Vector3.one;
        var mf = go.AddComponent<MeshFilter>();
        _ribbonRenderer = go.AddComponent<MeshRenderer>();
        _ribbonRenderer.sharedMaterial = _material;
        // ★色合わせ：ホールド(Bar)と同じ光の当たり方 (Light Probes / Reflection Probes = Blend Probes)
        _ribbonRenderer.lightProbeUsage = UnityEngine.Rendering.LightProbeUsage.BlendProbes;
        _ribbonRenderer.reflectionProbeUsage = UnityEngine.Rendering.ReflectionProbeUsage.BlendProbes;
        _ribbonRenderer.shadowCastingMode = line.shadowCastingMode;
        _ribbonRenderer.receiveShadows = line.receiveShadows;
        _ribbonRenderer.sortingLayerID = line.sortingLayerID;
        _ribbonRenderer.sortingOrder = BandOrderIdle;
        _mesh = new Mesh();
        _mesh.name = "SlideRibbon";
        _mesh.MarkDynamic();
        mf.sharedMesh = _mesh;

        // Inspectorでアタッチ済みならここはスキップされる
        if (snapIndicator == null)
        {
            var found = transform.Find("SnapIndicator");
            if (found != null) snapIndicator = found.gameObject;
        }
        if (snapIndicator != null) snapIndicator.SetActive(false);

        // ★ソフラン：区間の途中にあるソフランの変わり目を集めて、帯の点を増やす
        _cutTimes.Clear();
        for (int i = 0; i < ChartScroll.ChangeCount; i++)
        {
            float ct = (float)ChartScroll.ChangeTime(i);
            if (ct > timeA + 0.0001f && ct < timeB - 0.0001f) _cutTimes.Add(ct);
        }

        // ★曲線スライド：曲線の細かい点も足す(ソフランの変わり目と合わせて時刻順)
        _midTimes.Clear();
        _midTimes.AddRange(_cutTimes);
        _curveSeg = (ease == 0 && curve != null && timeB - timeA > 1e-6f) ? curve.SegmentOf(timeA, timeB) : -1;
        if (_curveSeg >= 0) curve.AppendSampleTimes(_curveSeg, _midTimes);
        // ★ease：区間を細かく刻む
        if (ease != 0 && timeB - timeA > 1e-6f && laneA != laneB)
        {
            for (int i = 1; i < EaseSamples; i++) _midTimes.Add(timeA + (timeB - timeA) * i / EaseSamples);
        }
        _midTimes.Sort();

        int count = 2 + _midTimes.Count;
        _points = new Vector3[count];
        _verts = new Vector3[count * 2];
        _normals = new Vector3[count * 2];
        _tris = new int[(count - 1) * 6];
        _mesh.vertices = _verts;
        _mesh.normals = _normals;
        _mesh.triangles = _tris;

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
        if (line.enabled) line.enabled = false;      // ほかのスクリプトが LineRenderer を表示に戻しても、二重に描かない

        double now = !ChartClock.Instance.StartOffsetFinished
            ? director.time
            : ChartClock.Instance.Time;

        // ★自動ポーズで時刻を戻したとき：スライドが「最後まで全部」流し終わっていたら、そのスライドは出さない(残骸が流れないように)
        //   途中まで流れていたスライドは、切らずに今まで通り全部描く(途中で切ると、帯が浮いたように途切れて見えるので)
        double played = ChartClock.Instance != null ? ChartClock.Instance.PlayedUntil : double.NegativeInfinity;
        bool alreadyDone = played >= ChainEndTime() && ChainRemaining() <= 0; // ★判定点がまだ残っていたら消さない
        bool cut = false;
        float cutT = timeA;

        float zA = ZAt(cutT, now);
        float zB = ZAt(timeB, now);

        // 帯の点 (今まで LineRenderer に渡していたのと同じ座標)
        // ★ソフラン：途中でソフランが変わるときは、その時刻の位置にも点を置く(無ければ今まで通り2点)
        // ★曲線スライド：曲線の細かい点も置く。横の位置は曲線から(見た目だけ)
        int last = _midTimes.Count + 1;
        float xA = cut ? DrawX(cutT) : (_curveSeg >= 0 ? DrawX(timeA) : BlockToX(laneA));
        SetLinePoint(0, new Vector3(xA, 0.69f, zA));
        for (int i = 0; i < _midTimes.Count; i++)
        {
            float mt = cut ? Mathf.Max(_midTimes[i], cutT) : _midTimes[i]; // 流し終わった所の点は、切った所に寄せる
            SetLinePoint(i + 1, new Vector3(DrawX(mt), 0.69f, ZAt(mt, now)));
        }
        SetLinePoint(last, new Vector3(_curveSeg >= 0 ? DrawX(timeB) : BlockToX(laneB), 0.69f, zB));
        UpdateRibbonMesh();

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

        // ★重なったスライドの色対策：押している(光っている)帯を、押していない帯より必ず上に描く
        //   (重なった所が、押している色と押していない色でまだらにならないように)
        //   どっちもノーツ(0)より下なので、帯の上のワイプ・始点は隠れない。※レーンの床は DrawFirst(-10)でこれより下にしておく
        int order = chainActive ? BandOrderActive : BandOrderIdle;
        if (_ribbonRenderer.sortingOrder != order) _ribbonRenderer.sortingOrder = order;

        // ★出現・消える：見えない間は、帯も判定ラインの光も出さない
        bool visible = NoteVis.Visible(vis, now) && !alreadyDone; // ★流し終わっていた区間は出さない
        if (_ribbonRenderer.enabled != visible) _ribbonRenderer.enabled = visible;
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
                else if (ease != 0) rawX = IndicatorBlockToX(Mathf.Lerp(laneA, laneB, EaseFraction(ease, progress)));
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

                Vector3 snapLocal = new Vector3(x, 0.71f, z - 0.06f + snapZShift);
                if (flatBand) snapIndicator.transform.position = _snapBase.MultiplyPoint3x4(snapLocal); // 帯を回しても、光の場所は今まで通り
                else snapIndicator.transform.localPosition = snapLocal;
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

    // ★帯のメッシュを作り直す
    //   どの点でも、横 (点の座標の x 方向 = レーンの左右) に ±太さの半分の 2 頂点を置き、となりの点と四角 (三角形 2 つ) でつなぐ。
    //   角で頂点を斜めにずらさないので、帯が細くなったり、大きな三角形が出たりしない
    void UpdateRibbonMesh()
    {
        int count = _points.Length;
        Matrix4x4 toRibbon = _ribbon.worldToLocalMatrix;
        // 横の向きと上の向き (世界の座標)。点の座標の x 方向 / y 方向
        Vector3 side = _lineBase.MultiplyVector(Vector3.right).normalized * _halfWidth;
        Vector3 up = _lineBase.MultiplyVector(Vector3.up).normalized;
        if (flatBandFlip) up = -up;
        Vector3 upLocal = toRibbon.MultiplyVector(up).normalized;

        for (int i = 0; i < count; i++)
        {
            Vector3 c = _lineBase.MultiplyPoint3x4(_points[i]);
            _verts[i * 2] = toRibbon.MultiplyPoint3x4(c - side);
            _verts[i * 2 + 1] = toRibbon.MultiplyPoint3x4(c + side);
            _normals[i * 2] = upLocal;
            _normals[i * 2 + 1] = upLocal;
        }
        for (int k = 0; k < count - 1; k++)
        {
            int l0 = k * 2, r0 = k * 2 + 1, l1 = k * 2 + 2, r1 = k * 2 + 3;
            int t = k * 6;
            // 面の表が上 (カメラのある側) を向くように、三角形の頂点の順番を決める (奥へ進む / 手前に戻る のどちらでも)
            Vector3 n = Vector3.Cross(_verts[l1] - _verts[l0], _verts[r1] - _verts[l0]);
            bool keep = Vector3.Dot(n, upLocal) >= 0f;
            if (keep)
            {
                _tris[t] = l0; _tris[t + 1] = l1; _tris[t + 2] = r1;
                _tris[t + 3] = l0; _tris[t + 4] = r1; _tris[t + 5] = r0;
            }
            else
            {
                _tris[t] = l0; _tris[t + 1] = r1; _tris[t + 2] = l1;
                _tris[t + 3] = l0; _tris[t + 4] = r0; _tris[t + 5] = r1;
            }
        }
        _mesh.vertices = _verts;
        _mesh.normals = _normals;
        _mesh.triangles = _tris;
        _mesh.RecalculateBounds();
    }

    void OnDestroy()
    {
        if (_mesh != null) Destroy(_mesh);
    }

    // ★このスライド(区間ぜんぶ)で、まだ判定されていない判定点の数
    int ChainRemaining()
    {
        if (chainMembers == null) return remainingJudge;
        int n = 0;
        foreach (var m in chainMembers) if (m != null) n += m.remainingJudge;
        return n;
    }

    // ★このスライド(同じスライドの区間ぜんぶ)の最後の時刻
    float ChainEndTime()
    {
        float end = timeB;
        if (chainMembers != null)
            foreach (var m in chainMembers)
                if (m != null && m.timeB > end) end = m.timeB;
        return end;
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
        if (ease != 0) u = EaseFraction(ease, u);
        return Mathf.Lerp(BlockToX(laneA), BlockToX(laneB), u);
    }

    // ★ease：区間の中の位置 u (0〜1) で、横にどれだけ進んだか (0〜1)。エディタの Beatrix.easeFraction と同じ
    public static float EaseFraction(int e, float u)
    {
        float t = Mathf.Clamp01(u);
        if (e == 1) return t * t;                       // Ease In
        if (e == 2) return 1 - (1 - t) * (1 - t);       // Ease Out
        return t;
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
