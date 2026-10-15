# びーとり（Unity 本体）対応用：譜面 JSON の追加仕様

BeatTriX Editor（iPad の譜面エディタ）で書き出す JSON に足した項目のうち、Unity 側でまだ対応していないものをまとめた。
エディタのテストプレイ（Swift）では全部実装済みで、ここに書いた動きと同じになっている。Unity 側もこのとおりに作れば、エディタとゲームで同じ見え方・同じ判定になる。

- 時刻はすべて **num / LPB 拍**（0 拍始まり）。例: LPB 4・num 6 は 1.5 拍目
- 拍 → 秒は、`BPM`（0 拍目）と `bpms`（途中の BPM 変化）を入れて計算する
- 「LPB・num・block が完全に一致するノーツに当てる」項目は、**拍を約分してから比べる**（LPB 4・num 2 と LPB 8・num 4 は同じ）。ホールド・スライドは**本体（type 2）の LPB・num・block**（= 始点の位置）で比べ、帯・始点のタップ / ワイプ（LPB×2 の表記）・判定点までまとめて当てる
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
  "speeds_each": [ {"LPB": 4, "num": 256, "block": 3, "speed": 2.0} ],
  "dummy": [ {"LPB": 4, "num": 264, "block": 0} ],
  "appear": [ {"LPB": 4, "num": 256, "block": 0, "atLPB": 4, "atNum": 248} ],
  "disappear": [ {"LPB": 4, "num": 256, "block": 1, "atLPB": 4, "atNum": 248} ],
  "blink": [ {"LPB": 4, "num": 256, "block": 3, "atLPB": 4, "atNum": 240, "stepLPB": 4, "stepNum": 1} ],
  "part": [ {"LPB": 4, "num": 512, "parts": [ {"LPB": 4, "num": 640, "parts": []} ]} ],
  "lyrics": [ {"LPB": 4, "num": 512, "text": "歌詞", "parts": [ {"LPB": 4, "num": 528, "parts": []} ]} ],
  "notes": [ {"LPB": 4, "num": 0, "block": 0, "type": 1, "notes": []} ]
}
```

- `name` は曲名だけ（`(EX)` などの略称は付けない）。略称はファイル名（`曲名(EX).json`）にだけ付ける
- `difficulty`: 0 = BASIC / 1 = HARD / 2 = EXTREME / 3 = INSANE

### C#（JsonUtility）でのクラスの例

```csharp
[System.Serializable] public class BpmEntry    { public int LPB; public int num; public float bpm; }
[System.Serializable] public class SpeedEntry  { public int LPB; public int num; public float speed; }
[System.Serializable] public class SpeedEach   { public int LPB; public int num; public int block; public float speed; }
[System.Serializable] public class DummyEntry  { public int LPB; public int num; public int block; }
[System.Serializable] public class AppearEntry { public int LPB; public int num; public int block; public int atLPB; public int atNum; }
[System.Serializable] public class BlinkEntry  { public int LPB; public int num; public int block; public int atLPB; public int atNum; public int stepLPB; public int stepNum; }
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
public List<BlinkEntry> blink;
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

- `{"LPB", "num", "block", "speed"}`: 一致するノーツ**だけ**、その倍率で流れてくる
- 全体のソフランと**掛け算**: 奥行き = `(pos(ノーツ) − pos(今)) × スクロール速度 × speed`
- ホールド・スライドは、帯の両端・経由点もこの倍率で計算する
- **見た目だけ**。判定の時刻は変わらない
- 同時押しの線は、速さが同じノーツ同士だけに引く（速さが違うと流れてくる位置がずれるため）

## 5. ダミーノーツ（`dummy`）

- `{"LPB", "num", "block"}`: 一致するノーツが**判定の無いノーツ**になる
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
  1. NotesGenerate: `dummy` から「(約分した拍, block)」の集合を作り、一致したノーツ（とホールド・スライドの判定点、始点）に `isDummy = true` を付ける。ノーツ総数からダミーを除く
  2. keyjudge: 押した瞬間は上の順番。押している間は、ダミーのワイプ・判定点を消す（本物の判定は続けて探す）。ダミーを消すときは、判定の文字・エフェクト・カウント・コンボ・スコアを何も呼ばない（SE だけ）
  3. 見逃しの処理: ダミーは MISS にせず消す
  4. リザルト: AP / FC・スコアはダミーを除いたノーツだけで計算する

## 6. 出現 / 消える（`appear` / `disappear`）

- `{"LPB", "num", "block", "atLPB", "atNum"}`: 一致するノーツの見え方を変える。`atLPB`・`atNum` が境目の拍
  - `appear`: 曲がその拍になるまで、ノーツは**見えない**。その拍から急に見える
  - `disappear`: その拍から、ノーツは**見えなくなる**
  - 両方付けてもよい
- **見た目だけ**。判定はそのまま（見えない間も判定はある）。消すほうは `dummy` と組み合わせるのが基本
- ホールド・スライドは、帯・始点・ノーツ全部をまとめて隠す
- 同時押しの線は、つないでいるノーツのどちらかが見えない間は隠す
- 使い方の例（まっすぐのホールドが急にギザギザのスライドに入れ替わる）:
  1. まっすぐのホールド（ダミー）に `disappear` を入れ替えの拍で付ける
  2. 同じところのギザギザのスライド（本物）に `appear` を同じ拍で付ける
- **実装の手順（案）**
  1. NotesGenerate: 一致したノーツに `showTime`（appear の拍の秒）と `hideTime`（disappear の拍の秒）を持たせる（無ければ −∞ / +∞）
  2. 毎フレーム: `曲の時刻 < showTime` または `曲の時刻 >= hideTime` の間は、Renderer（SpriteRenderer / MeshRenderer / LineRenderer など）を非表示にする。判定の処理には触らない

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

## 8. 点滅（`blink`）

- `{"LPB", "num", "block", "atLPB", "atNum", "stepLPB", "stepNum"}`: 一致するノーツ（ホールド・スライドは始点の位置）を点滅させる
  - `atLPB`・`atNum`: 点滅を**始める拍**（num / LPB 拍）
  - `stepLPB`・`stepNum`: 見える ⇔ 消えるを切り替える**間隔**（拍の長さ。例: LPB 4・num 1 = 1/4 拍）
- **ふるまい**
  - 始める拍より前: 普通に見える
  - 始める拍から、**そのノーツの拍（判定ラインに来る時刻）まで**: `見える（1 間隔）→ 消える（1 間隔）→ 見える → …` をくり返す（始めは見える）
  - ノーツの拍を過ぎたら: 普通に見える（ホールド・スライドは、始点の拍を過ぎたら帯も普通に見える）
  - 切り替わりの拍 = 始める拍 + 間隔 × k（k = 1, 2, 3 …、ノーツの拍より前のものだけ）。拍 → 秒は BPM 変化込み
  - 見えるかどうか = 「今までに切り替わった回数」が偶数なら見える、奇数なら消えている
- **見た目だけ**。判定はそのまま（消えている間も判定はある）
- `appear` / `disappear` と一緒に付けてもよい（どれか 1 つでも「見えない」なら見えない）
- ホールド・スライドは、帯・始点・ノーツ全部をまとめて点滅させる。同時押しの線も、つないでいるノーツのどちらかが見えない間は隠す
- **実装の手順（案）**
  1. 読み込み時: 一致したノーツに、切り替わりの時刻（秒）のリスト `blinkTimes` を持たせる（始める拍 + 間隔 × k を、ノーツの拍まで並べて秒にする）
  2. 毎フレーム: `blinkTimes` のうち `今の時刻` 以下のものの数を数えて（二分探索）、奇数なら Renderer を非表示、偶数なら表示（`appear` / `disappear` の条件とも合わせる）
  3. 判定の処理には触らない
- エディタ: 再生ラインを点滅を始めたい拍に合わせて、ノーツを選んで More → **Blink** → 間隔（例: 1/4）を入れて OK。「解除」で外す

## 9. 参考（変わっていないもの）

- `notes`: `type` 1 = タップ / 2 = ホールド・スライドの本体（子の `notes` が経由点）/ 3 = 赤タップ / 4 = ワイプ。始点は本体のすぐ後ろに LPB・num を 2 倍にした別表記のタップ / ワイプ
- `part`: `{"LPB", "num", "parts": [ {"LPB", "num", "parts": []} ]}`。外側が始まり、`parts[0]` が終わり
