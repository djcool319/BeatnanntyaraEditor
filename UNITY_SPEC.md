# びーとり（Unity 本体）対応用：譜面 JSON の追加仕様

BeatTriX Editor（iPad の譜面エディタ）で書き出す JSON に足した項目のうち、Unity 側でまだ対応していないものをまとめた。
エディタのテストプレイ（Swift）では全部実装済みで、ここに書いた動きと同じになっている。Unity 側もこのとおりに作れば、エディタとゲームで同じ見え方・同じ判定になる。

- 時刻はすべて **num / LPB 拍**（0 拍始まり）。例: LPB 4・num 6 は 1.5 拍目
- 拍 → 秒は、`BPM`（0 拍目）と `bpms`（途中の BPM 変化）を入れて計算する
- `speeds_each` / `dummy` / `appear` / `disappear` は、**ノーツ 1 つを指す**（指し方は下の「0-1. ノーツの指し方」）
- どの項目も、無いときは空の配列 `[]` で書き出す（キーが無い古い譜面もあるので、無ければ空として扱う）

## 0. JSON 全体（キーの順番）

```json
{
  "name": "曲名",
  "maxBlock": 7,
  "BPM": 149,
  "LEVEL": 4.7,
  "difficulty": 2,
  "artist": "作曲者",
  "offset": 720,
  "preview": 14.52,
  "ver": 1001,
  "bpms": [ {"LPB": 4, "num": 240, "bpm": 306} ],
  "speeds": [ {"LPB": 4, "num": 240, "speed": 1.1} ],
  "speeds_each": [ {"LPB": 4, "num": 256, "block": 3, "type": 1, "nth": 0, "speed": 2.0} ],
  "dummy": [ {"LPB": 4, "num": 264, "block": 0, "type": 2, "nth": 0} ],
  "appear": [ {"LPB": 4, "num": 264, "block": 0, "type": 2, "nth": 1, "atLPB": 4, "atNum": 256} ],
  "disappear": [ {"LPB": 4, "num": 264, "block": 0, "type": 2, "nth": 0, "atLPB": 4, "atNum": 256},
                 {"LPB": 4, "num": 270, "block": 3, "type": 1, "nth": 0, "atLPB": 4, "atNum": 250} ],
  "curve": [ {"LPB": 4, "num": 128, "block": 3, "type": 2, "nth": 0} ],
  "part": [ {"LPB": 4, "num": 512, "parts": [ {"LPB": 4, "num": 640, "parts": []} ]} ],
  "lyrics": [ {"LPB": 4, "num": 512, "text": "歌詞", "parts": [ {"LPB": 4, "num": 528, "parts": []} ]} ],
  "notes": [ {"LPB": 4, "num": 0, "block": 0, "type": 1, "notes": []} ]
}
```

- `name` は曲名だけ（`(EX)` などの略称は付けない）。略称はファイル名（`曲名(EX).json`）にだけ付ける
- `difficulty`: 0 = BASIC / 1 = HARD / 2 = EXTREME / 3 = INSANE

### 0-1. ノーツの指し方（`speeds_each` / `dummy` / `appear` / `disappear` / `curve` 共通）（2026-10-15 変更）

同じ位置（同じ拍・同じ block）に、まっすぐのホールドとギザギザのスライドを重ねて入れ替える、のような演出ができるように、**位置だけでなく「どのノーツか」まで指す**ようにした。

- `LPB`・`num`・`block`: ノーツの位置（ホールド・スライドは本体 = 始点の位置）。**拍は約分してから比べる**（LPB 4・num 2 と LPB 8・num 4 は同じ）
- `type`: ノーツの種類（`notes` の `type` と同じ。1 = タップ / 2 = ホールド・スライドの本体 / 3 = 赤タップ / 4 = ワイプ）
- `nth`: その位置・その `type` のノーツの中で**何番目か**（0 始まり）。`notes` の並び順で数える
  - **始点の表記**（本体と同じ位置の type 1 / 4。LPB・num を 2 倍にして書いてあるもの）は**数えない・指さない**。始点は本体に付いていく
- 指したノーツ**1 つだけ**に効く（同じ位置の別のノーツには効かない）
- **前の形式**（`type` が無いもの）: その位置のノーツ**全部**に効く（古い譜面も読めるように）
- **始点の扱い**: 始点（type 1 / 4 の始点の表記）は、同じ位置の本体（type 2）に付いていく
  - 同じ位置に本体が 2 つ以上あって、始点を 1 つ共有しているとき:
    - `dummy`: 本体が**全部**ダミーのときだけ、始点もダミー
    - `appear` / `disappear`: 本体の**どれか 1 つでも見えている**間は、始点も見える
    - `speeds_each`: 最初の本体（`nth` = 0）の速さ
- **実装のしかた（案）**: NotesGenerate で `notes` を上から読むときに、始点の表記以外のノーツについて「(約分した拍, block, type) ごとの通し番号」を数えておく。それが `nth`。`(拍, block, type, nth)` → 生成したノーツ の辞書を作り、各項目をそこから引く

### C#（JsonUtility）でのクラスの例

```csharp
[System.Serializable] public class BpmEntry    { public int LPB; public int num; public float bpm; }
[System.Serializable] public class SpeedEntry  { public int LPB; public int num; public float speed; }
// JsonUtility は、JSON にキーが無いと 0 になる。type は 1〜4 しか使わないので、type == 0 なら「前の形式 (type 無し)」として扱えばよい
[System.Serializable] public class SpeedEach   { public int LPB; public int num; public int block; public int type; public int nth; public float speed; }
[System.Serializable] public class DummyEntry  { public int LPB; public int num; public int block; public int type; public int nth; }
[System.Serializable] public class CurveEntry  { public int LPB; public int num; public int block; public int type; public int nth; }
[System.Serializable] public class AppearEntry { public int LPB; public int num; public int block; public int type; public int nth; public int atLPB; public int atNum; }
[System.Serializable] public class RangeEnd    { public int LPB; public int num; }
[System.Serializable] public class PartEntry   { public int LPB; public int num; public List<RangeEnd> parts; }
[System.Serializable] public class LyricEntry  { public int LPB; public int num; public string text; public List<RangeEnd> parts; }

// 譜面データのクラスに足すもの
public List<BpmEntry> bpms;
public List<SpeedEntry> speeds;
public List<SpeedEach> speeds_each;
public List<DummyEntry> dummy;
public List<AppearEntry> appear;
public List<AppearEntry> disappear;
public List<CurveEntry> curve;
public List<PartEntry> part;
public List<LyricEntry> lyrics;
```

（`parts` の中の `parts` は空の配列なので、`RangeEnd` には入れなくてよい。JsonUtility は知らないキーを無視する）

---

## 1. offset（ms）

- `offset` は **ms（ミリ秒）**。1000 = 1 秒。曲のサンプリング周波数（44.1kHz / 48kHz）とは関係ない
- 0 拍目が曲の何 ms 目か（+ にするとノーツが曲に対して遅くなる）
- Unity の設定:
  - `Chart Offset Sample Rate`: 44100 → **1000**
  - `Editor Playback Correction Samples`: 1800 → **0**
  - `Offset Adjust Ms`: 今の値のまま（全曲まとめてずらす用）

## 2. BPM 変化（`bpms`）

- `{"LPB", "num", "bpm"}`: その拍から先の BPM。0 拍目の BPM は `BPM`
- 拍 → 秒は、BPM 変化の区間ごとに足していく

## 3. ソフラン（`speeds`）

- `{"LPB", "num", "speed"}`: その拍から先、**ノーツ全体**の流れる速さが speed 倍になる（最初は 1.0）
- 実装: 「流れた量」`pos(t)` を、時刻 t まで速さを積分した値にする（区間ごとに `(t − 区間の始まり) × speed` を足す）。ノーツの奥行き（判定ラインからの距離）は `(pos(ノーツの時刻) − pos(今)) × スクロール速度`
- **見た目だけ**。判定の時刻は変わらない

## 4. ノーツ個別の速さ（`speeds_each`）

- `{"LPB", "num", "block", "type", "nth", "speed"}`: 指したノーツ（0-1）**だけ**、その倍率で流れてくる
- 全体のソフランと**掛け算**: 奥行き = `(pos(ノーツ) − pos(今)) × スクロール速度 × speed`
- ホールド・スライドは、帯の両端・経由点もこの倍率で計算する
- **見た目だけ**。判定の時刻は変わらない
- 同時押しの線は、速さが同じノーツ同士だけに引く（速さが違うと流れてくる位置がずれるため）

## 5. ダミーノーツ（`dummy`）

- `{"LPB", "num", "block", "type", "nth"}`: 指したノーツ（0-1）が**判定の無いノーツ**になる
- **ふるまい**
  - 普通と**同じ見た目**で流れてくる（ひっかけ用。見分けは付かない）
  - PERFECT / GREAT / MISS の文字・タッチエフェクトは**出さない**。判定のカウント・コンボ・スコア・ノーツ総数（スコアの分母）に**一切数えない**
  - 見逃しても MISS にならない。AP / FC などの記録に影響しない
  - タップ・赤タップ・始点: 本物と同じ幅の中で押すと**消えるだけ**（白タップ・始点は ±0.13 秒、赤タップは ±0.06 秒）。SE は鳴らす
  - ワイプ: 押している間に ±0.12 秒の中に来ると消える（本物と同じく、判定ラインに来るまでは流れ続ける）。SE は鳴らす
  - ホールド・スライド: 押さえていれば帯が青く光る（本物と同じ）。判定点は数えない。押さえている間の音も鳴らす
  - 押さないまま判定ラインを過ぎたら、本物の見逃しと同じタイミング（タップ系 +0.09 秒、ワイプ・判定点 +0.12 秒）で消す
  - 黄色（ワイプ・判定点）直後のタップの抑制には関わらない（ダミーは抑える側にも抑えられる側にもならない）
  - 同時押しの線は本物と同じく引く
- **押した瞬間の順番**（縦連の中のダミーで、後ろの本物が巻き込まれないように）
  1. ボタンの範囲の中に、**±0.06 秒（PERFECT のタイミング）のダミー**があり、そのダミーが範囲の中のどの本物よりも押した時刻に近い（同じ近さも含む）なら、**そのダミーを消すだけ**で終わり（本物は判定しない）
  2. そうでなければ、本物のノーツだけで今までどおり判定する
  3. 本物が何も取れなかったときだけ、範囲の中のダミーを 1 つ消す
- **実装の手順（案）**
  1. NotesGenerate: `dummy` で指したノーツ（0-1。ホールド・スライドは判定点も）に `isDummy = true` を付ける。始点は 0-1 の「始点の扱い」のとおり。ノーツ総数からダミーを除く
  2. keyjudge: 押した瞬間は上の順番。押している間は、ダミーのワイプ・判定点を消す（本物の判定は続けて探す）。ダミーを消すときは、判定の文字・エフェクト・カウント・コンボ・スコアを何も呼ばない（SE だけ）
  3. 見逃しの処理: ダミーは MISS にせず消す
  4. リザルト: AP / FC・スコアはダミーを除いたノーツだけで計算する

## 6. 出現 / 消える（`appear` / `disappear`）（2026-10-15 変更: 何回でも切り替えられる）

- `{"LPB", "num", "block", "type", "nth", "atLPB", "atNum"}`: 指したノーツ（0-1）の見え方を、`atLPB`・`atNum` の拍で切り替える
  - `appear`: その拍で**見えるようになる**
  - `disappear`: その拍で**見えなくなる**
  - **1 つのノーツに何個でも付けられる**（同じノーツを指す項目が `appear` / `disappear` に何個あってもよい）。出る → 消える → 出る → … ができる
- **見えるかどうかの決め方**（ノーツごと）
  1. そのノーツの `appear` と `disappear` の拍を全部集めて、拍の順に並べる
  2. **最初の切り替えより前**: 最初が `appear` なら**見えない**、最初が `disappear` なら**見える**
  3. あとは、今の時刻までに起きた最後の切り替えのとおり（`appear` なら見える、`disappear` なら見えない）
  4. 切り替えが 1 つも無いノーツは、いつも見える
  - 同じ拍に `appear` と `disappear` が両方あることは無い（エディタで付けるときに置き換える）
- **見た目だけ**。判定はそのまま（見えない間も判定はある）。消えている間に取らせたくないときは `dummy` と組み合わせる
- ホールド・スライドは、帯・判定点の見た目・ノーツ全部をまとめて切り替える。始点は 0-1 の「始点の扱い」のとおり（同じ位置の本体のどれか 1 つでも見えていれば見える）
- 同時押しの線は、つないでいるノーツのどちらかが見えない間は隠す
- 使い方の例（まっすぐのホールドが急にギザギザのスライドに入れ替わる。**同じ位置・同じ拍でできる**）:
  1. まっすぐのホールド（`type` 2・`nth` 0、ダミー）に、入れ替えの拍で `disappear`
  2. 同じ位置のギザギザのスライド（`type` 2・`nth` 1、本物）に、同じ拍で `appear`
  3. → 入れ替えの拍までは、まっすぐのホールドだけが見えて、その拍からギザギザのスライドだけが見える（1/64 ずらす必要はない）
- **実装の手順（案）**
  1. NotesGenerate: 指したノーツに、切り替えのリスト `visEvents`（[(秒, 見える/見えない)] を時刻順）を持たせる。秒は BPM 変化込み
  2. 毎フレーム: 上の「見えるかどうかの決め方」で見えるか決めて、Renderer（SpriteRenderer / MeshRenderer / LineRenderer など）の表示 / 非表示を切り替える。判定の処理には触らない
  3. 共有している始点は、本体のどれか 1 つでも見えていれば表示

## 7. 歌詞（`lyrics`）

- `part` と同じ形に `text` を足したもの: `{"LPB", "num", "text", "parts": [ {"LPB", "num", "parts": []} ]}`
  - 外側の `LPB`・`num` が**表示の始まり**、`parts[0]` が**終わり**
  - `始まり <= 曲の時刻 < 終わり` の間だけ `text` を表示する
  - 重なっているときは、あとから始まるほうを出す
- 表示の位置: **判定ラインのすぐ上**に、**小さい文字**で、レーンの真ん中に 1 行（エディタのテストプレイは、判定ラインの 38pt 上、15pt の太めの白文字、黒い影付き。長いときは縮める）
- **実装の手順（案）**
  1. 読み込み時に、各歌詞の始まり・終わりを秒にしておく（BPM 変化込み）
  2. 判定ラインの少し上に TextMeshPro（UI）を 1 つ置く
  3. 毎フレーム: 今の時刻を含む歌詞の `text` を入れる（無ければ空）。文字が変わったときだけ書き換える

## 7-2. 曲線スライド（`curve`）（2026-10-16 追加）

- `{"LPB", "num", "block", "type": 2, "nth"}`: 指したスライド（0-1 の指し方。`type` はいつも 2）を、**見た目だけ丸く**する
  - ギザギザ（3 → 5 → 6 → 6 → 5 → 3 のような「く」の字）が、角の取れたなめらかなカーブで流れてくる
  - **判定はそのまま**。判定点（始点と経由点）の時刻・レーンは今までと同じ。曲線は経由点を必ず通るので、判定点は帯の上に乗ったまま
  - 項目が無いスライドは今までどおり（経由点を直線でつなぐ）。ホールド（まっすぐ）に付けても見た目は変わらない
- **曲線の作り方**（エディタのテストプレイと同じ。単調 3 次補間 = Fritsch–Carlson）
  - 点の列: 始点と経由点を時刻順に `(t[k], x[k])`。`t` は秒（BPM 変化込み）、`x` は横の位置（レーンの中心。`(3 + 2·block) / 18` などそっちで使っている値でよい）
  - 経由点の数（始点込み）が 3 未満なら直線のまま
  - 1. 傾き: `d[k] = (x[k+1] - x[k]) / (t[k+1] - t[k])`（`t` が同じなら 0）
  - 2. 各点の接線: 両端は `m[0] = d[0]`、`m[n-1] = d[n-2]`。中は、`d[k-1]` と `d[k]` の符号が違う（または片方 0）なら `m[k] = 0`（**折り返しの点で行き過ぎない**）、同じ符号なら `(d[k-1] + d[k]) / 2`
  - 3. `d[k] == 0`（同じレーンが続く区間）は `m[k] = m[k+1] = 0`（**まっすぐのところはまっすぐのまま**）
  - 4. それ以外は `a = m[k]/d[k]`, `b = m[k+1]/d[k]`, `s = a² + b²` が 9 を超えたら `τ = 3/√s` で `m[k] = τ·a·d[k]`, `m[k+1] = τ·b·d[k]`
  - 5. 区間ごとに 16 分割して、エルミート曲線で点を作る（`h = t[k+1] - t[k]`、`u` = 0〜1）:
    `x(u) = (2u³ - 3u² + 1)·x[k] + (u³ - 2u² + u)·h·m[k] + (-2u³ + 3u²)·x[k+1] + (u³ - u²)·h·m[k+1]`、時刻は `t[k] + h·u`
  - `t` が同じ（時間 0 の）区間は、補間せずに直線でつなぐ
- C#（そのまま使える形）:

```csharp
// ts: 時刻(秒), xs: 横位置。戻り値: 描く点 (時刻, 横位置) の列
public static List<Vector2> CurvePoints(float[] ts, float[] xs, int samples = 16) {
    int n = ts.Length; var outp = new List<Vector2>();
    if (n < 3) { for (int i = 0; i < n; i++) outp.Add(new Vector2(ts[i], xs[i])); return outp; }
    var d = new float[n - 1]; var m = new float[n];
    for (int k = 0; k < n - 1; k++) { float h = ts[k + 1] - ts[k]; d[k] = h > 1e-6f ? (xs[k + 1] - xs[k]) / h : 0f; }
    m[0] = d[0]; m[n - 1] = d[n - 2];
    for (int k = 1; k < n - 1; k++) m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2;
    for (int k = 0; k < n - 1; k++) {
        if (d[k] == 0) { m[k] = 0; m[k + 1] = 0; continue; }
        float a = m[k] / d[k], b = m[k + 1] / d[k], s = a * a + b * b;
        if (s > 9) { float tau = 3 / Mathf.Sqrt(s); m[k] = tau * a * d[k]; m[k + 1] = tau * b * d[k]; }
    }
    outp.Add(new Vector2(ts[0], xs[0]));
    for (int k = 0; k < n - 1; k++) {
        float h = ts[k + 1] - ts[k];
        if (h <= 1e-6f) { outp.Add(new Vector2(ts[k + 1], xs[k + 1])); continue; }
        for (int i = 1; i <= samples; i++) {
            float u = (float)i / samples, u2 = u * u, u3 = u2 * u;
            float x = (2*u3 - 3*u2 + 1) * xs[k] + (u3 - 2*u2 + u) * h * m[k] + (-2*u3 + 3*u2) * xs[k + 1] + (u3 - u2) * h * m[k + 1];
            outp.Add(new Vector2(ts[k] + h * u, x));
        }
    }
    return outp;
}
```

- **実装の手順（案）**
  1. NotesGenerate: `curve` で指したスライドに `isCurve = true` を付ける。判定点（始点・経由点）は今までどおり作る
  2. 帯（メッシュ / LineRenderer）を作るところで、`isCurve` なら経由点の代わりに `CurvePoints` の点の列で帯を作る（細かい区間を今までの「2 点の間の帯」と同じやり方で並べるだけ）。ソフラン・`speeds_each` による位置の計算は、細かい点の時刻でそのまま行う
  3. 判定・スコア・SE には触らない

## 8. 参考（変わっていないもの）

- `notes`: `type` 1 = タップ / 2 = ホールド・スライドの本体（子の `notes` が経由点）/ 3 = 赤タップ / 4 = ワイプ。始点は本体のすぐ後ろに LPB・num を 2 倍にした別表記のタップ / ワイプ
- `part`: `{"LPB", "num", "parts": [ {"LPB", "num", "parts": []} ]}`。外側が始まり、`parts[0]` が終わり
