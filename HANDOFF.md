# BeatTriX Editor 引き継ぎメモ

（このメモの内容は 2026-10-11 時点のもの）

友達が作った Malody のスライド譜面エディタ（Swift Playgrounds の iPad アプリ、SwiftUI）を、自作 Unity 音ゲー「びーとり（Beatrix）」用の譜面エディタに作り変えたもの。アプリ名は **BeatTriX Editor**。

- リポジトリ: https://github.com/djcool319/BeatnanntyaraEditor （main ブランチ）
- ipa（push のたびに GitHub Actions が作り直す。リンクは毎回同じ）:
  https://github.com/djcool319/BeatnanntyaraEditor/releases/download/latest/BeatTriXEditor.ipa
- 書き出す譜面は、前に使っていた NoteEditor と同じ形式の JSON（Unity 側でそのまま読む想定）

## 0. ユーザーについて・進め方の約束

- ユーザーが触れる開発環境は Unity くらい。Swift や Web 系はあまり分からない
- コードは部分ごとの差し替え指示ではなく、**ファイル全体**で渡す。Swift 側は Claude がリポジトリを直接直して、push すると ipa が自動でできる
- Unity 側のスクリプトを直すときも、ファイル全体で渡す
- 会話は日本語。くだけた口調
- 確認の流れ: Claude が直して push → Actions が ipa を作る（1〜2 分）→ ユーザーが iPad に入れて試し、感想や動画で返してくる

---

## 1. 譜面 JSON の仕様

### 1-1. 全体

```json
{
  "name": "曲名",
  "maxBlock": 7,
  "BPM": 153,
  "LEVEL": 11.7,
  "difficulty": 2,
  "artist": "作曲者",
  "offset": 1080,
  "preview": 46.86,
  "ver": 1001,
  "bpms":   [ {"LPB":4, "num":240, "bpm":306} ],
  "speeds": [ {"LPB":4, "num":240, "speed":1.1} ],
  "speeds_each": [ {"LPB":4, "num":256, "block":3, "speed":2.0} ],
  "dummy":  [ {"LPB":4, "num":264, "block":0} ],
  "appear":    [ {"LPB":4, "num":256, "block":0, "atLPB":4, "atNum":248} ],
  "disappear": [ {"LPB":4, "num":256, "block":1, "atLPB":4, "atNum":248} ],
  "part":   [ {"LPB":4, "num":560, "parts":[ {"LPB":4, "num":688, "parts":[]} ]} ],
  "lyrics": [ {"LPB":4, "num":560, "text":"歌詞", "parts":[ {"LPB":4, "num":576, "parts":[]} ]} ],
  "notes":  [ {"LPB":4, "num":0, "block":0, "type":1, "notes":[]} ]
}
```

| キー | 意味 |
|---|---|
| `name` | 曲名だけ（`(EX)` などの略称は付けない）。略称（BS / HD / EX / IN）はファイル名にだけ付ける。読み込みは、略称付きの古い name でも読める |
| ファイル名 | `曲名(EX).json` のように、曲名に略称を付ける（name には略称を付けない）。ファイル名に使えない文字 `/ \ : * ? " < > \|` は `_` に置き換える |
| `maxBlock` | 7（固定） |
| `BPM` | 0 拍目の BPM |
| `LEVEL` | 難易度の数値（小数あり）。Lv の表示は下の 1-6 |
| `difficulty` | 0 = BASIC（BS）/ 1 = HARD（HD）/ 2 = EXTREME（EX）/ 3 = INSANE（IN） |
| `artist` | 作曲者 |
| `offset` | **ms（ミリ秒）**。1000 = 1 秒。ノーツを曲に対して後ろへずらす向き（0 拍目が曲の何 ms 目か）。前はサンプル数（44100 = 1 秒）だった。前の形式の譜面は Information の「サンプル数 → ms に変換」で直す。Unity 側も ms で読むように直す予定 |
| `preview` | 選曲画面で流す位置（秒） |
| `ver` | 譜面のバージョン（整数）。Information で入力。空欄なら書き出さない |
| `part` | 区間（サビなど）。外側の LPB/num が始まり、`parts[0]` が終わり。本家では区間に入ると演出が出る |
| `bpms` | 途中の BPM 変化 |
| `speeds` | ソフラン（ノーツ**全体**の流れる速さの倍率。その拍から先ずっと） |
| `speeds_each` | ノーツ**個別**の速さ（1-5） |
| `dummy` | ダミーノーツ（判定の無いノーツ）の位置（1-5b） |
| `appear` / `disappear` | ノーツが途中から出てくる / 途中で消える（1-5c） |
| `lyrics` | 歌詞（1-5d）。part と同じ形に `text` を足したもの |
| `notes` | ノーツ（1-3） |

- 時刻はすべて **num / LPB 拍**（0 拍始まり）。例: LPB 4・num 6 は 1.5 拍目
- 書き出すときは、拍を約分した LPB と num にする（`Beatrix.lpbNum`）
- 書き出しの見た目は NoteEditor と同じ（`BeatrixJSONWriter`）: キーの順番は上の例のとおり固定、ノーツは LPB → num → block → type → notes、字下げ 2、`"キー": 値`、空の配列は `[]`

### 1-2. 時刻の計算

- BPM 変化（`bpms`）を入れて、拍 → 秒にする（エディタの TimeMap）
- **Unity の NotesGenerate は今 `BPM` だけで計算していて、`bpms` / `speeds` / `speeds_each` を読んでいない**（3 章を参照）

### 1-3. ノーツ（`notes`）

- `block`: 0〜6（7 鍵）
  - タップ・赤タップは 3 鍵ぶんなので、block 0 / 3 / 6 だけを使う
  - ホールド・ワイプ・スライドは 7 鍵（block 0〜6）
- `type`:
  - 1 = タップ
  - 2 = ホールド・スライドの本体。子の `notes` が経由点（子も `type: 2`、子の `notes` は空）
  - 3 = 赤タップ
  - 4 = ワイプ
- ホールドとスライドの見分け方: 子がすべて親と同じ block ならホールド、違う block を含めばスライド
- **始点（ヘッド）の書き方**
  - 本体と同じ LPB・num で書くと Unity 側で消えてしまう。そのため、**LPB と num を 2 倍にした別表記**のタップ（type 1）かワイプ（type 4）を、本体のすぐ後ろに書く
  - 例: 本体が `{"LPB":4,"num":8,"block":2,"type":2,...}` なら、始点は `{"LPB":8,"num":16,"block":2,"type":1}`
  - Unity の NotesGenerate は、本体と同じ位置（block と、約分した拍）の type 1 をホールドの始点（内部 NoteType 2）として扱う
  - 始点なし（ヘッド 0）のときは、始点を書かない
  - 始点に赤タップが重なっているときは、赤タップを始点として扱い、タップの始点は書かない（同じ位置にタップが 2 つ重なると、1 回押しても片方が残ってミスになるため）

### 1-4. ソフラン（`speeds`）

- `{"LPB","num","speed"}`。その拍から先、ノーツ全体の流れる速さが speed 倍になる（最初は 1.0）
- エディタでは ✦（Effect list）の **scroll** で入れる。Malody の effect の jump は Beatrix に無いので書き出さない

### 1-5. ノーツ個別の速さ（`speeds_each`）（今回追加）

- `{"LPB","num","block","speed"}`
- **LPB・num・block が完全に一致するノーツだけ**が、その倍率で流れてくる。ホールド・スライドは始点の位置で一致させるので、帯ごと全部その速さになる
- 全体のソフランと**掛け算**（全体 1.5 × 個別 2 = 3 倍）
- 同じ位置に複数あるときは 1 つにまとめて書き出す
- 見た目だけが変わり、判定の時刻は変わらない

### 1-5b. ダミーノーツ（`dummy`）（2026-10-12 追加）

**Unity 側にも同じ仕様で実装する予定。** 実装のしかたは 3-1 を参照。

- `"dummy": [ {"LPB": 4, "num": 264, "block": 0}, ... ]`
- **LPB・num・block が完全に一致するノーツだけ**がダミーになる（`speeds_each` と同じ当て方）
  - 一致を見るときは、拍を約分して比べる（LPB 4・num 2 と LPB 8・num 4 は同じ）
  - ホールド・スライドは**始点の位置**で一致させる。本体（type 2）・始点のタップ / ワイプ（LPB×2 の表記）・判定点がまとめてダミーになる
  - 同じ位置に複数のノーツがあれば全部ダミー
- 同じ位置に複数あるときは 1 つにまとめて書き出す。ダミーが無い譜面では `"dummy": []`
- **ダミーのふるまい**
  - ノーツは普通に生成されて、普通と**同じ見た目**で流れてくる（ひっかけ用。見分けは付かない）
  - **判定が無い**: PERFECT / GREAT / MISS の文字・タッチエフェクトは出ない。判定のカウント（P+ / P / G / M）、コンボ、スコア、ノーツ総数（スコアの分母）に**一切数えない**
  - **押さなくてもよい**: 見逃しても MISS にならない。AP / FC などの記録に影響しない
  - タップ・赤タップ・始点: 本物と同じ幅の中で押すと、**消えるだけ**（白タップ・始点は ±0.13 秒、赤タップは ±0.06 秒）。押した音（SE）は鳴る
  - ワイプ: 押している間に ±0.12 秒の中に来ると消える（本物と同じく、判定ラインに来るまでは流れ続ける）。音は鳴る
  - ホールド・スライド: 押さえていれば帯が**青く光る**（本物と同じ）。判定点はダミー（数えない）。押さえている間の「しゅ〜」も鳴る
  - 押さないまま判定ラインを過ぎたら、本物の見逃しと同じタイミング（タップ系 +0.09 秒、ワイプ・判定点 +0.12 秒）で消える
  - **押した瞬間の順番**（縦連の中にダミーがあっても巻き込まないように。2026-10-12 修正）:
    1. 範囲の中に、PERFECT のタイミング（±0.06 秒）のダミーがあって、そのダミーが範囲の中のどの本物よりも押した時刻に近い（同じ近さも含む）なら、**そのダミーを消すだけ**で終わり（本物は判定しない）
    2. そうでなければ、本物のノーツで今までどおり判定する
    3. 本物が何も取れなかったときだけ、範囲の中のダミー（白タップ・始点 ±0.13 秒 / 赤タップ ±0.06 秒）を 1 つ消す
  - 「黄色の直後のタップの抑制」（2-3）には関わらない（ダミーのワイプ・判定点は本物のタップを抑えないし、ダミーのタップは抑えられる対象でもない）
  - 同時押しの線は、本物と同じく引く（見分けが付かないように）
  - `speeds_each` と組み合わせられる（ダミーで速さも違うノーツ）
- エディタ: More → **Dummy** で、選んだノーツを ダミー ⇔ 普通 で切り替える。エディタではダミーを薄く描いて、左上に「D」を出す（テストプレイでは本物と同じ見た目）

### 1-5c. 出現 / 消える（`appear` / `disappear`）（2026-10-12 追加）

**Unity 側にも同じ仕様で実装する予定。** 実装のしかたは 3-2 を参照。

まっすぐのホールドが急にギザギザのスライドに入れ替わる、のような演出に使う。

- `"appear": [ {"LPB": 4, "num": 256, "block": 0, "atLPB": 4, "atNum": 248}, ... ]`
- `"disappear": [ {"LPB": 4, "num": 256, "block": 1, "atLPB": 4, "atNum": 248}, ... ]`
- `LPB`・`num`・`block` が完全に一致するノーツ（ホールド・スライドは始点の位置）に当てる（`speeds_each` / `dummy` と同じ当て方）
- `atLPB`・`atNum`: 境目の拍（num / LPB 拍）
  - `appear`: 曲がその拍になるまで、ノーツは**見えない**。その拍から急に見える
  - `disappear`: その拍から、ノーツは**見えなくなる**
  - 両方付けてもよい（見える間だけ見える）
- **見た目だけ**。判定はそのまま（見えない間も判定はある）。消すほうは `dummy` と組み合わせるのが基本
- ホールド・スライドは、帯・始点・ノーツ全部がまとめて見えなくなる
- 同時押しの線も、つないでいるノーツのどちらかが見えない間は出さない
- 例: まっすぐのホールド → ギザギザのスライドに入れ替える
  1. まっすぐのホールドを置いて、ダミーにして、`disappear` を入れ替えの拍にする
  2. 同じところにギザギザのスライド（本物）を置いて、`appear` を同じ拍にする
- エディタ: 再生ライン（シアンの横棒）を境目の拍に合わせて、ノーツを選んで More → **Appear / Vanish** →「この拍から出現する」/「この拍で消える」/「解除」。エディタではノーツの右下に「出 4:1/2」「消 5:0/1」と出る（エディタ上では見えなくならない）

### 1-5d. 歌詞（`lyrics`）（2026-10-12 追加）

**Unity 側にも同じ仕様で実装する予定。** Unity 向けの説明は UNITY_SPEC.md の 7 章。

- `"lyrics": [ {"LPB": 4, "num": 560, "text": "歌詞", "parts": [ {"LPB": 4, "num": 576, "parts": []} ]}, ... ]`
- `part` と同じ形に `text` を足したもの。外側の LPB・num が表示の始まり、`parts[0]` が終わり
- `始まり <= 今 < 終わり` の間だけ表示。重なっているときは、あとから始まるほう
- テストプレイ: 判定ラインの 38pt 上、レーンの幅の中に 15pt の白文字（黒い影付き、長いときは縮める）で 1 行
- エディタ: More → **Lyrics** のあと、始点 → 終点の順にレーンをタップ → 歌詞を入力。歌詞の区間の中をタップすると、文字の変更・削除（空にして OK でも消える）。エディタでは、レーンの右端の内側に黄緑の線と「♪ 歌詞」が出る

### 1-6. Lv の表示（本家の GetLvRank と同じ）

| LEVEL | 表示 |
|---|---|
| 1.99 未満 | F |
| 2.99 未満 | E |
| 3.99 未満 | D |
| 4.99 未満 | C |
| 5.99 未満 | B |
| 6.69 未満 | A |
| 6.99 未満 | A+ |
| 7.69 未満 | S |
| 7.99 未満 | S+ |
| 8.69 未満 | X |
| 8.99 未満 | X+ |
| 8.99 以上 9 未満 | Oops! |
| 9 以上 | ∞ |

### 1-7. 難易度の色

- BASIC = 青
- HARD = オレンジ寄りの黄色
- EXTREME = 赤
- INSANE = 紫

---

## 2. 判定の仕組み（Unity の keyjudge.cs / NotesGenerate.cs を Swift に移したもの。BeatrixPlayCore.swift）

### 2-1. ノーツの種類（判定用の内部 type）

| type | 中身 |
|---|---|
| 1 | 白タップ |
| 2 | ホールド・スライドの始点タップ |
| 3 | 赤タップ |
| 4 | ワイプ |
| 5 | ホールド・スライドの判定点（見えない） |

### 2-2. ボタン（4 つ）

画面を横に 4 つに分ける: 左 1/3 / 中央の左半分 / 中央の右半分 / 右 1/3。位置は判定ラインの高さでのレーンで分け、レーンの外は端のボタンになる。

- **押した瞬間**に取れるレーン（CheckJudgement）: `[[0,1,2], [3,2,1,4], [3,2,4,5], [6,5,4]]`
  - 押した瞬間に取れるのは、タップ・始点・赤タップ
- **押している間**に取れるレーン（CheckSlideJudgement）: `[[0,1,2], [1,2,3,4], [2,3,4,5], [4,5,6]]`
  - 押している間に取れるのは、ワイプ・ホールド・スライド
- ボタンの光は 3 鍵ぶん。真ん中は左半分・右半分のどちらで押しても、真ん中 1 つが光る。光るのはそのレーンの奥から手前まで全部
- ホールド・スライドを押さえているかどうか（IsLaneButtonHeld）:
  - レーン 0〜2 → 左ボタン
  - レーン 2〜4 → 中央のどちらか
  - レーン 4〜6 → 右ボタン

### 2-3. 判定の幅

秒。ずれ = 押した時刻 − ノーツの時刻。

**白タップ（type 1）**

| 判定 | 幅 |
|---|---|
| PERFECT+ | ±0.03 |
| PERFECT | ±0.06 |
| GREAT | −0.11〜+0.09 |
| MISS（押したとき） | ±0.13 |

**始点タップ（type 2）**

| 判定 | 幅 |
|---|---|
| PERFECT+ | ±0.06 |
| GREAT | −0.11〜+0.09 |
| MISS | ±0.13 |

**赤タップ（type 3）**

- ±0.06 で PERFECT+
- それ以外のタイミングで押しても取れない（反応しない）

**ワイプ・判定点（type 4・5）**

- 押している間に ±0.12 で PERFECT+

**見逃し（MISS）**

- タップ系（type 1〜3）は +0.09 を過ぎたら
- ワイプ・判定点（type 4・5）は +0.12 を過ぎたら

**その他のルール**

- 押した瞬間の判定は、ボタンの範囲の中で、まだ取っていない一番早いノーツから見る（0.2 秒より先は見ない）
- **黄色の直後のタップの抑制**: 白タップの 0.16 秒以内の前に、同じボタンの範囲（ButtonZones `[[0,1,2],[1,2,3,4],[2,3,4,5],[4,5,6]]`）のワイプか判定点があれば、そのタップは GREAT と押したときの MISS を出さない（PERFECT 以上でしか取れない）

### 2-4. ホールド

- 子がすべて同じ block のもの
- 始点から**半拍ごと**に判定点（type 5）を置く。各判定点は +0.02 秒ずらす。終点ちょうどには置かない
- 経由点があるときは、区間ごとに同じ処理をする

### 2-5. スライド

- 子に別の block を含むもの
- 始点と経由点に判定点（type 5）を置く
- 帯は経由点の間を直線（台形）でつなぐ

### 2-6. ワイプ

- 押している間に、範囲に入れば PERFECT+
- 早く押しても**すぐには消えない**（本家と同じく、判定ラインに来るまで流れ続ける）
- 音とエフェクトも、判定ラインに来た瞬間に出す

### 2-7. スコア（仮）

- 本家の計算式が分からないので仮の式: PERFECT+ = 100% / PERFECT = 99% / GREAT = 50% で、1,000,000 点満点
- 途中から始めたときは、開始位置より前のノーツを処理済みにする

---

## 3. Unity 側（びーとり本体）について分かっていること

- ユーザーから keyjudge.cs / NotesGenerate.cs / followers や Unity の設定を見せてもらい、テストプレイはそれを Swift に移した
- NotesGenerate:
  - 本体と同じ位置（block と、約分した num/LPB）の type 1 をホールドの始点（NoteType 2）として扱う
  - 子がすべて同じ block ならホールド、違えばスライド
  - ホールドの判定点は半拍ごと +0.02 秒、スライドは経由点
- **未対応**: NotesGenerate は `BPM` だけで時刻を計算しており、`bpms` / `speeds` / `speeds_each` を読んでいない
- ノーツの大きさは、Unity のプレハブの比から取った（タップ幅 0.03 / ワイプ・始点 0.028、レーン 0.9912、厚み タップ 0.02 / ワイプ 0.015）
- 効果音は本家の tap.wav / yellow.wav / red_note.wav を使っている
- PlayFab でプレイヤーデータとランキングを管理している（チート対策を検討中。この件はエディタとは別）

---

**Unity 側の対応は UNITY_SPEC.md にまとめてある（offset の ms 化・bpms・speeds・speeds_each・dummy・appear / disappear・lyrics。C# のクラスの例付き）。Unity の作業をするチャットには、まずこのファイルを渡す。**

### 3-1. Unity 側でダミーノーツを実装するときの手順（案）

エディタのテストプレイ（BeatrixPlayCore.swift の `BxPlayChart.make` と `BxGame`）と同じ動きになるようにする。

1. **譜面データのクラス**に `dummy` を足す（JsonUtility なら `public List<DummyEntry> dummy;`、`DummyEntry` は `int LPB; int num; int block;`）
2. **NotesGenerate**:
   - 読み込んだ `dummy` から「(約分した拍, block)」の集合を作る
   - ノーツを生成するとき、そのノーツ（ホールド・スライドは本体の LPB/num/block）が集合に入っていれば、生成したノーツ（とホールド・スライドの判定点、始点のタップ / ワイプ）に `isDummy = true` を付ける
   - 見た目（プレハブ・色・大きさ）は本物と同じ
   - ノーツ総数（スコアの分母・AP / FC の判定に使う数）には、ダミーを**数えない**
   - 黄色直後のタップの抑制を計算するとき、ダミーは無視する
3. **keyjudge**:
   - 押した瞬間（CheckJudgement）: 1-5b の「押した瞬間の順番」のとおり。①PERFECT のタイミングのダミーが本物より近ければダミーを消して終わり → ②本物で判定 → ③取れなければダミーを 1 つ消す
   - 押している間（CheckSlideJudgement）: ダミーのワイプ・判定点が ±0.12 秒に入ったら消す（ワイプは判定ラインに来るまで流す）。本物の判定はそのまま続けて探す
   - ダミーを消すときは、判定の文字・エフェクト・カウント・コンボ・スコアを**何も呼ばない**（SE だけ鳴らす）
   - 見逃し: ダミーは MISS にせず、そのまま消す
   - ホールド・スライドの帯の光り方（IsLaneButtonHeld）は本物と同じ
4. **リザルト / 記録**: AP / FC の判定やスコアは、ダミーを除いたノーツだけで計算する

### 3-2. Unity 側で出現 / 消えるを実装するときの手順（案）

1. 譜面データのクラスに `appear` と `disappear` を足す（どちらも `List<AppearEntry>`、`AppearEntry` は `int LPB; int num; int block; int atLPB; int atNum;`）
2. NotesGenerate: ノーツ（ホールド・スライドは本体の LPB/num/block）が一致したら、そのノーツ（帯・始点・判定点の見た目も含む）に `showTime`（appear の秒）と `hideTime`（disappear の秒）を持たせる。秒は BPM 変化込みで計算する
3. 毎フレーム: `曲の時刻 < showTime` または `曲の時刻 >= hideTime` のあいだは、Renderer（SpriteRenderer / MeshRenderer / LineRenderer など）を非表示にする。**判定の処理には触らない**
4. 同時押しの線があれば、それも同じ条件で隠す

## 4. エディタの機能（実装済み）

### 4-1. 起動画面（RootView）

- びーとりの譜面（.json）・音源・背景画像を選んで開く
- 譜面を選ばずに「新規作成」もできる（曲名と BPM を入れる。EXTREME で作られる）

### 4-2. 保存

- **自動保存**: 変更すると、アプリ内の BeatrixEditor フォルダに `曲名(XX).json` で保存される
- 曲名・難易度を変えると、ファイル名も付け替える
- 「ファイル」アプリから開いた譜面で曲名が変わったときは、元のファイルはそのままにして、アプリ内の新しい名前のファイルへ保存先を切り替える

- **保存するフォルダ**（chartDir）:
  - 開いた譜面がアプリの書類フォルダ（このiPad内 > BeatTriX Editor）の中 → その譜面と同じフォルダ
  - 新規作成や外から開いた譜面で、音源がアプリの書類フォルダの中（例: BeatrixEditor/Song/曲名/）→ 音源と同じフォルダ
  - それ以外 → BeatrixEditor フォルダ
  - 難易度を切り替えて作る別の難易度のファイルも、同じフォルダに作る
  - Information の「保存する場所」に、フォルダ名 / ファイル名を出す

### 4-3. 難易度の切り替え

- 画面の上に難易度の札（色付き）をいつも出していて、押すと切り替えられる
- 難易度ごとに別のファイル（`曲名(BS).json` など）になる
- 切り替えるときは、今の譜面を保存してから:
  - その難易度のファイルがあれば、それを開く
  - 無ければ、新しく作る。今のノーツをコピーするか、空にするかを選べる
- 曲名・BPM・offset・ソフランは引き継ぐ
- **part も引き継ぐ**（今回追加）:
  - 空から作るときも part は残る
  - 開いた譜面に part が 1 つも無ければ、今の譜面の part を入れて保存する

### 4-4. 右ボタン列のツール

| ツール | 内容 |
|---|---|
| Tap | 白タップ（3 鍵） |
| Red | 赤タップ（3 鍵） |
| Wipe | ワイプ（7 鍵） |
| Slide | スライド（7 鍵）。下の説明を参照 |
| Remove | 削除 |
| Order | 順番に選択（Lua プラグイン用） |
| Adv. | Lua プラグインのメニュー（元のエディタから） |
| More | 4-5 を参照 |

**Slide ツールの詳細**

- 同じレーンで置けば**ホールド**になる。Hold ボタンは無くした（スライドに統合）
- 同じレーンの経由点も、元のエディタと同じく置ける
- 始点あり・なしをボタンで切り替えられて、選んだほうが残る（slideWithHead として保存される）
- 「始点あり」で置くと、始点のタップは**別の普通のタップ**として置かれる。始点だけを選んで消したり動かしたりできる

**ノーツの置き方**

- 何本かの指で同時に置ける（LaneMultiTouch）
- SETTING「タップした位置のすぐ下の線にノーツを置く」（初期値オン）

**エディタでの表示**

- 同時押しの線
- part の白い線と区間
- 個別の速さが付いたノーツの右上に「×2」

### 4-5. More メニュー（上から順に）

1. Copy
2. Paste
3. Time range（時間の範囲で選択）
4. Lasso（なぞって囲んだノーツを選択）
5. Flip notes horizontal
6. Part — 区間の始点 → 終点をタップして置く。区間の中をタップすると消える。重なる区間は 1 つにまとめる
7. Head Tap / Wipe / None — 選択中のスライド・ホールドの始点を「タップ → ワイプ → なし」の順に切り替える
8. Tap / Red — 選択中のタップを、通常 ⇔ 赤で切り替える
9. **Dummy** — 選択中のノーツを ダミー ⇔ 普通 で切り替える（選択に普通のノーツが 1 つでもあれば全部ダミーに）。同じ位置（拍と block）のノーツもまとめて切り替わる
10. **Note speed** — 選択中のノーツに個別の速さを付ける。1 か空欄、または「解除」で外れる。同じ位置（拍と block）のノーツにもまとめて付く
11. Slide modify
12. Slide to Wipe
13. Wipe to Slide

### 4-5b. BPM・offset の自動検出（BeatrixTempoDetect.swift）

- ノーツが 1 つも無い譜面を開くと自動で解析して、結果のダイアログを出す。Information の「曲を解析する」でいつでも実行できる
- BPM: 立ち上がりの強さ（スペクトルフラックス、窓 512・128 サンプルおき）に、BPM の波とその 2〜4 倍の波を当てて探す（170 前後を優先）。曲の頭から最大 2 分で 0.001 刻みまで詰め、整数・0.5 刻みに近ければ丸める。倍・半分も候補に出して、人が選ぶ
- offset: 最初の 30 秒で、拍の位置の立ち上がりの合計が最大になる位相 → 拍ごとのずれの中央値で微調整 → 約 2ms 足す。0 拍目は音が鳴り始めたところに一番近い拍。JSON の offset（ms）= 0 拍目の秒 × 1000 + 再生の補正 ms（今の基準）。「0 拍目をずらす」で ±0.5 / ±1 拍のボタンと、拍の入力（2 / -1.5 / 1/4）で何拍でもずらせる（+ で曲の後ろへ）
- 途中の BPM 変化は自動では入れない（誤検出しやすい）。15 秒ずつ見て 1% 以上ずれる区間が続いたら「このあたりで変わっていそう」と知らせるだけ
- 合成した音での確認: BPM は正確、offset は ±1ms 程度。実際の曲ではまだ試していない

### 4-6. ✦（Effect list）

- scroll = `speeds`（ソフラン）
- jump は書き出さない

### 4-7. Information（META の中）

- 曲名
- 作者
- 難易度（表示だけ）
- LEVEL
- preview
- offset（ms。±10ms のボタンあり）
- 「サンプル数 → ms に変換」ボタン（前の形式の譜面用。offset ÷ 44.1）
- ファイル名（表示）

### 4-8. SETTING

- 曲の音量
- ノーツサウンドの音量
- 背景画像の暗さ
- 伸ばした音の立ち上がり（遅い再生用）
- 時系列順でない seg を許可
- すぐ下の線に置く
- Slide modify での縦移動を許可
- **再生の補正**（ms。初期値 0。Unity の Editor Playback Correction と同じ値にしておく。前は 1800 サンプルだった）
  - JSON の offset は変えずに、再生とテストプレイのときだけノーツを早める
  - ±1 / ±10 のボタンと「0 に戻す」ボタンあり

### 4-9. offset の計算

- 秒 = (raw − 再生の補正) / 1000（どちらも ms）
- 曲のサンプルレートは使わない（コードの Beatrix.offsetSampleRate は 1000、playbackCorrectionMs は ms）
- エディタの内部では offsetMs = −((raw − 補正) / rate × 1000)
- 再生中に offset を変えても、曲は止まらない（GameAudio.shiftOffset）

### 4-10. エディタ再生中のノーツ音

- 白タップ・始点（タップ） → tap
- ワイプ・始点（ワイプ） → yellow
- 赤タップ → red_note と tap を重ねる

### 4-11. アプリアイコン

- BT ロゴ（AppIcon/*.png）

---

## 5. テストプレイ（TEST ボタン → びーとり式）

- 見た目は本家と同じ。遠近の付いた 3 鍵レーン、マゼンタの判定ライン、消失点は画面の上の外
- エディタの表示位置から始まる。開始前に 2 秒待つ
- **ホールド・スライドの帯**
  - 判定ラインより手前はいつも隠す
  - 押していないとき: (0.501, 0.592, 1, α0.7)
  - 押さえている間: (0.47, 0.58, 1.0)。ホールドもスライドも同じ色
  - 幅は始点の棒と同じ
- **part** の区間は、床を少し明るくして、レーンの両端を白く光らせる
- 1 拍ごとの線と、同時押しの線（判定点は除く。個別の速さが違うノーツ同士には引かない）を出す
- **効果音**
  - tap / yellow / red_note
  - ホールド・スライドを押さえている間は「しゅ〜」（3kHz あたりのバンドパスノイズをループ。holdLevel 0.3）
  - いろいろな音を試したが、ユーザーは**最初のこの音がいい**と言っている（和音やきらきら音は却下）
- **タッチエフェクト**
  - PERFECT(+): ノーツの色の光の玉、広がる輪、細かい粒（水色・赤・黄色）
  - GREAT: ピンク
  - 早い MISS: 灰色の玉だけ
  - 遅い MISS・見逃しは何も出さない
- **ソフラン**: `speeds`（全体）と `speeds_each`（個別）の両方を見た目に入れた（今回追加）
- 描画は CAShapeLayer を種類ごとに分けて path だけを差し替える方式。文字は UILabel
- **PAUSE 画面**
  - 判定の位置: 「ノーツが判定ラインに触れたとき」（初期値）か「真ん中が重なったとき」
  - スクロール速度（0.5〜2.0）
  - **テストプレイの補正**（初期値 −30ms。次回も残る）
    - エディタでノーツ音がぴったりの譜面が、プレイでちょうどよく感じる分
    - 見た目と判定の両方をずらす
  - 効果音のオン・オフ
  - offset（ms）: このテストプレイの間だけ使う。**譜面には保存しない**
  - 再開 / リトライ / 終了
- 古い Malody 式のテストプレイ（TestPlay.swift）の中身も残っていて、GameAudio / GameSession / PauseOverlay は共通で使っている

---

## 6. 各ファイルの役割

### びーとり用に作った・大きく直したファイル

| ファイル | 役割 |
|---|---|
| BeatrixFormat.swift | JSON の読み書き。`Beatrix` enum（block ⇔ x の変換、centerX、headType、normalized、lpbNum、lvRank、splitName、safeFileName、offsetSampleRate、playbackCorrectionSamples、speedKey / noteSpeed / speedLabel）、BeatrixDifficulty、ChartData の拡張（bx*、parseBeatrix、beatrixData、beatrixNotes、beatrixSpeedsEach、bxParts）、BeatrixPart、BeatrixKey |
| BeatrixPlayCore.swift | テストプレイの中身。BxPlayChart.make（JSON と同じノーツから判定用のノーツ・ホールド・スライド・同時押し・拍線・part・ソフランを作る）と、BxGame（判定） |
| BeatrixPlayView.swift | テストプレイの画面。BeatrixPlayLaunch、BeatrixGameView（描画・入力・エフェクト・HUD・offset）、BeatrixPlayScreen |
| BeatrixSounds.swift | 効果音（tap / wipe / red と、しゅ〜） |
| BeatrixSoundData.swift | 効果音の wav を base64 で埋め込んだもの（44.1kHz・ステレオ・16bit） |
| EditorState+Beatrix.swift | びーとり用の編集（始点の切り替え、赤タップ、Note speed、part、難易度の切り替え、DifficultyBadge、Hold のアイコン） |
| mc-to-json-converter.html | Malody の .mc をびーとりの JSON に変えるツール（ブラウザで動く。bpms・speeds 対応、jump は数えるだけ） |
| .github/workflows/build-ipa.yml | ipa を作る Actions。Package.swift を CI 用に差し替え、scheme は MalodySlideEditor、AppIcon をコピー、CFBundleDisplayName "BeatTriX Editor"、bundle id local.beatrix.charteditor。Release "latest" に BeatTriXEditor.ipa を上げる。失敗したら ::error:: で注記を出す |
| README.md | 使い方と JSON の説明 |

### 元のエディタから引き継いで、びーとり用に手を入れたファイル

| ファイル | 役割 |
|---|---|
| EditorState.swift | エディタの状態全体（ツール、選択、Undo、再生、保存 saveNow、設定の保存、offset） |
| EditorState+Tools.swift | 配置・削除・移動・範囲・反転・Slide⇔Wipe・seg 編集などのツール処理 |
| EditorView.swift | 画面全体（レーン、右ボタン列 RightPanel、More メニュー、入力アラート、テストプレイの起動） |
| Renderers.swift | レーンの描画（線、part、同時押し、ノーツ、速さのラベル、シークバーなど） |
| SideWindow.swift | 右から出る窓（BPM list / Effect list / Information / SETTING） |
| RootView.swift | 起動画面（ファイル選択・新規作成） |
| TestPlay.swift | 元のテストプレイ。GameAudio（曲の再生、ogg デコード）、GameSession（速度・offset・判定の位置・SE・補正の保存）、PauseOverlay |
| MoreMenuIcons.swift | More メニューのアイコン（speed を追加した） |
| Package.swift | Swift Playgrounds 用 |

### 元のエディタのままのファイル（ほとんど触っていない）

| ファイル | 役割 |
|---|---|
| ChartModel.swift | Note（x 0..255、w、type、segs、extra、id）、Seg、TimePoint、EffectPoint、ChartData |
| Beat.swift | 拍の分数 |
| Effects.swift | scroll / jump の表示位置の計算（エディタ側） |
| AudioController.swift | オーディオセッションの設定 |
| PCMCache.swift | 曲を先に PCM に展開しておく |
| TimeStretch.swift / RubberBandPCMSource.swift | 遅い再生用の時間伸縮 |
| KeySound.swift | 元のノーツ音と音量 |
| SeekDensity.swift | シークバーのノーツ密度 |
| GridSettingsDialog.swift | Grid settings |
| PanelIcons.swift / MetaMenuIcons.swift | アイコン |
| EditorState+Meta.swift | META（Back / Information / More / Quit） |
| Sheets.swift | 拍の入力 |
| ZipWriter.swift | zip を書き出す |
| LuaEngine.swift / LuaEngineSource.swift | Lua プラグインの実行（Lua を JS に変換して JavaScriptCore で動かす） |
| PluginBridge.swift / PluginPanel.swift / PluginSession.swift / PluginStore.swift / PluginFilePicker.swift / BuiltinPlugins.swift | Lua プラグインまわり |
| MalodySlideEditorApp.swift | アプリの入口 |

### エディタの中での持ち方

- ノーツは Malody 式のまま持つ（x は 0..255 の中心、w は幅、segs は始点からの相対）
- block の中心 x は round(255 × (3 + 2b) / 18) → [43, 71, 99, 128, 156, 184, 213]
- 幅: タップ 77 / それ以外 72
- chartChanged のたびに `Beatrix.normalized` で 7 鍵の中心に吸着させる
- extra に入れているキー:
  - `bxHead`: 始点の種類（0 = なし / 4 = ワイプ / 無ければタップ）
  - `bxType`: 知らない type をそのまま書き戻すためのもの
  - `bxSpeed`: 個別の速さ
- 読み込むときは、スライド・ホールドを「始点なし（bxHead 0）」にして、始点のタップ・ワイプを別の普通のノーツとして持つ。書き出すときに、また始点の表記（LPB×2）に戻す

---

## 7. 未解決・気になっていること

1. **Unity 側がソフランと BPM 変化を読んでいない**
   - NotesGenerate は `BPM` だけで時刻を計算していて、`bpms` / `speeds` / `speeds_each` は無視される
   - ゲームで使うには Unity 側の対応が必要（データクラスにフィールドを足す、時刻を BPM 変化込みで計算する、ノーツの移動をソフラン込みの位置で計算する、個別の速さを掛ける）
2. **ソフランのテストプレイ反映（`speeds` / `speeds_each`）は入れたばかりで、ユーザーはまだ試していない**
3. **スコアの式が仮**（本家の計算式が分からない）
4. Lv 表示の Oops! は 8.99 以上 9 未満だけで、ほぼ出ない（9 以上は ∞）。本家の GetLvRank と同じつもりだが、確認はしていない
5. offset の感覚のずれ
   - 「再生の補正」と「テストプレイの補正 −30ms」で、今は合っているとのこと
   - 機種やイヤホン（Bluetooth）で変わる可能性あり
6. GitHub Actions で Node.js 20 の非推奨の警告が出ている（今のところビルドは成功する）
7. Malody の jump は JSON に無いので書き出さない

## 8. 次にやる予定・候補

- ユーザーにソフラン（全体・個別）のテストプレイを試してもらい、感想をもらう
- 必要なら、Unity 側の NotesGenerate などを `bpms` / `speeds` / `speeds_each` に対応させる（**ファイル全体**で渡す。今の Unity のスクリプトをユーザーにもらってから直す）
- mc → json 変換ツールは、今は speeds_each に未対応（mc に個別の速さが無いので、今のところ不要）

## 9. ここまでの主なやりとり（経緯）

1. 友達のスライドエディタを、びーとり用（タップ・赤 3 鍵、ホールド・ワイプ・スライド 7 鍵、JSON、難易度ごとのファイル）に作り変えた
2. 細かい調整
   - ノーツを小さく
   - 本家と同じテストプレイ
   - part の編集
   - 自動保存
   - 難易度の札と色
   - offset（44100 = 1 秒）
3. 効果音の差し替え
   - ホールドの音は何度も作り直して、最初の「しゅ〜」に戻した
4. テストプレイの調整
   - 真ん中のレーンの光
   - 再生ボタンの遅れ
   - ホールドを判定ラインより手前で隠す
   - カクつき
   - ワイプがすぐ消える問題
5. ホールドの置き方（タップ → タップ）と始点のあり・なし。のちに Hold をスライドに統合した
6. 始点の赤タップで二重に判定される問題
   - 判定の位置の選択肢
   - ホールドの明るさ
   - Lv の表示
7. ipa を GitHub で作る仕組みを作り、アプリ名を BeatTriX Editor に、アイコンを BT ロゴにした
8. 何本かの指で同時に置く、始点のあり・なしを覚える、同時押しの線、タッチエフェクト、SE のオン・オフ
9. offset のずれ
   - 再生の補正 1800 サンプル（NoteEditor と同じ）
   - テストプレイの補正 −20ms（のちに −30ms に変更）
   - PAUSE の offset は保存しない
   - 再生中に offset を変えても曲を止めない
10. ソフランを「全体（speeds）」と「個別（speeds_each）」に分けた（今回）
11. 難易度を切り替えるときに part を引き継ぐようにした（今回）

## 10. offset を ms にした（2026-10-11）

- JSON の `offset` は ms（1000 = 1 秒）。曲のサンプルレートは関係ない
- Unity 側の設定（ユーザーが対応する方針）:
  - `Chart Offset Sample Rate`: 44100 → 1000（offset いくつで 1 秒か）
  - `Editor Playback Correction Samples`: 1800 → 0（同じ単位で引かれるので、1800 のままだと 1.8 秒ずれる）
  - `Offset Adjust Ms`: 今の値のまま（全曲まとめてずらす用）
- エディタの「再生の補正」も ms・初期値 0（Unity と同じ）
- 前の形式（サンプル数）の譜面は、Information の「サンプル数 → ms に変換」で 1 回だけ変換する

## 11. ダミーノーツ（2026-10-12）

- JSON の `dummy`（1-5b）。エディタ（More → Dummy）とテストプレイは実装済み
- Unity 側は未実装。手順は 3-1

## 12. 出現 / 消える・同時押しの線・ダミーの巻き込み（2026-10-12）

- JSON の `appear` / `disappear`（1-5c）。エディタ（More → Appear / Vanish）とテストプレイは実装済み。Unity 側は未実装（3-2）
- テストプレイの同時押しの線: 線の時刻をミリ秒に丸めていたのを、ノーツの時刻そのものに直した（ソフランが強いとずれて見えた）。つないでいるノーツを取った・見えないときは線を消す
- ダミーの巻き込み: 縦連の中のダミーを PERFECT のタイミングで押すと、後ろの本物が早押しで判定されてしまっていた → 1-5b の順番に直した

## 13. 歌詞（2026-10-12）

- JSON の `lyrics`（1-5d）。エディタ（More → Lyrics）とテストプレイは実装済み。Unity 側は未実装
- Unity 向けの説明を UNITY_SPEC.md にまとめた（これまでの追加仕様も全部入り）

## 14. iPhone 対応（2026-10-12）

- PhoneLayout.swift: iPhone のときだけ、エディタ（と起動画面）を「短い辺 640pt の仮の画面」で作って、画面に合わせて全体を縮めて表示する（`PhoneScaled`）。ノッチ・ホームバーの safe area の中に収める。iPad は今までどおり
- 画面の向き: iPhone だけ横画面 / 縦画面を切り替えられる（SETTING の一番上と起動画面。`AppOrientation`、UserDefaults の `phone.portrait`）。AppDelegate の supportedInterfaceOrientationsFor で向きを決めて、requestGeometryUpdate で回す。iPad は横だけ
- Info.plist（CI）の iPhone 用の向きに Portrait を足した
- テストプレイも iPhone ではエディタと同じく `PhoneScaled` で縮めて表示する（スコア・コンボ・判定の文字・PAUSE の比率が iPad と同じになる）
- 実機（iPhone）での見え方は未確認。崩れていたらスクショをもらって直す

## 15. テストプレイの見た目とスコア（2026-10-13）

- 見た目を本家の画面収録に寄せた（背景の網目と輪、角の丸いノーツ、左上の帯・ゲージ・到達可能ランク、判定の文字、II）。エフェクトはシンプルな光の玉だけ（ユーザーの希望）
- スコア（本家と同じ。ユーザーから聞いた式）:
  - 1 ノーツ 2 点。PERFECT+ / PERFECT = 2、GREAT = 1（−1）、MISS = 0（−2）。スコア = 1,000,000 × 合計 ÷ (2 × ノーツ数)
  - AP で内部（PERFECT の + じゃない方）0 なら 1,111,111
  - ランク: 1,111,111 AP+ / 1,000,000 AP / 990,000〜 SS / 980,000〜 S / 940,000〜 AA / 900,000〜 A / 820,000〜 B / 750,000〜 C / D
  - クリアは 900,000 以上。クリアゲージは到達可能なスコアで、1,000,000 以上で満タン、900,000 で 0

## 16. iOS 15 対応・オート（2026-10-15）

- iOS 15 でも入るようにした（Package / CI の対応 OS を 15.0 に。iOS 16 からの機能は Compat.swift で iOS 16 以上のときだけ使う。CI で minos を ::notice:: に出す）
- テストプレイの PAUSE に「オート（自動で全部 PERFECT）」。時刻が来たノーツを全部 PERFECT+ で取る（BxGame.auto）。ダミーは取らない。ホールド / スライドは押さえている扱いで光る

## 17. 出現 / 消えるを何回でも・ノーツの指し方（2026-10-15）

- 点滅（blink）は、ユーザーの希望と違ったので取り消した（git revert）
- 出現 / 消える: 1 つのノーツに何回でも付けられる（extra の bxAppear / bxVanish は [[LPB, num], ...]。前の [LPB, num] も読める）。最初の切り替えが出現ならそれまで見えない。More → Appear / Vanish に「この拍の出現 / 消えるを外す」「全部解除」
- `speeds_each` / `dummy` / `appear` / `disappear` の JSON に `type` と `nth` を足して、ノーツ 1 つを指すようにした（同じ位置にホールドとスライドを重ねて入れ替える演出を、ずらさずにできる）。`type` が無い古い譜面は、その位置のノーツ全部に当てる
- エディタの Dummy / Note speed / Appear・Vanish は、選んだノーツだけに付く（前は同じ位置のノーツ全部に付いていた）
- 書き出しは beatrixEntries()（"notes" の 1 つ 1 つと、もとのノーツ）を使う。並びは 拍 → x → エディタの中の順で、いつも同じ
- Unity 向けの説明は UNITY_SPEC.md の 0-1・4・5・6 章

## 18. 曲線スライド（2026-10-16）

- More → **Curve**: 選んだスライドを 曲線 ⇔ 普通 で切り替える（EditorState.toggleCurve。選んだスライドだけ。extra の bxCurve = true）
- 見た目だけ丸くする。判定点（始点・経由点）の時刻・レーンは変えない。曲線は経由点を必ず通る
- 曲線の計算は Beatrix.curvePoints（単調 3 次補間 PCHIP、区間ごとに 16 分割）。折り返しの点と、同じレーンが続く区間では行き過ぎない（まっすぐはまっすぐ）
- エディタの帯（Renderers.drawNotes / drawOrder）と、テストプレイの帯（BxSlide.draw → BeatrixGameView）の両方が曲線になる
- JSON: `"curve": [ {"LPB","num","block","type":2,"nth"} ]`（disappear の後、part の前）。読み込みも対応
- Unity 向けの説明は UNITY_SPEC.md の 7-2 章（C# の CurvePoints 付き）
- More → **Curve bake**（EditorState.bakeCurve）: 曲線（Beatrix.curveTangents / curveValue。拍とレーン番号で計算）をなぞって、レーンが 2 つ以上飛ぶ区間の間のレーンに中継点を足す。曲線がそのレーンを通る拍を二分探索で求め、曲線から 0.15 レーン以内に収まるいちばん粗い拍（1/16 → 1/32 → 1/48 → 1/64 → 1/96 → 1/192 → 1/384）に合わせる（1/16 固定だと最大 1 レーン近くずれて、焼き込み後に丸く見えなかった）。判定点が増える。curve の印は付けたまま。JSON は普通の経由点として出るので、Unity 側の追加対応は不要
- 曲線の形を変更（2026-10-16）: Fritsch–Carlson（中は平均、端は区間の傾きそのまま）だと「まっすぐ → 折り返し直前で急に曲がる」形になり、Curve bake 後に角が見えた。中の点は間隔で重みを付けた調和平均（PCHIP）、端は次で折り返すなら区間の傾きの 2 倍（放物線）・それ以外は 3 点の式、にした（Beatrix.curveTangents）。UNITY_SPEC.md 7-2 の式と C# も更新
- 曲線に 4 分の 1 の円を追加（2026-10-16、ユーザー提案の f(t) = √(1 − (1 − t)²)）: 始点から同じ向きに進んで折り返す・止まる点までのひと続きと、折り返す・止まる点から終点までのひと続きを、円で描く（Beatrix.curvePlan / arc）。途中の点が円から幅の 1 割以内のときだけ（bake の点は収まる）。それ以外は PCHIP。Curve bake も同じ曲線をなぞる
- Unity 用に `unity/SlideCurve.cs`（新規）と `unity/SlideFollower.cs`（ユーザーの LineRenderer 版を元に、曲線の帯を描く処理を足したもの。まるごと差し替え）を置いた。UNITY_SPEC.md 7-2
- 曲線の形を「角を丸める」に変更（2026-10-17）: 円（始点から真横に出る）は見た目が気持ち悪いと言われたので、折れ線の角ごとに A・B（角から両側の線の r 倍の位置）を 2 次ベジェでつなぐ形にした（Beatrix.curveShape / curveAt / curvePoints(laneUnit:)）。r = 0.5、角でのずれが 0.4 レーンを超えるなら小さくする。laneUnit は 1 レーンの大きさ（エディタの帯 = 255·2/18、テストプレイ = 2/18、bake = 1）。PCHIP・円のコードは消した。Unity の SlideCurve.cs も同じ式に差し替え（SlideFollower.cs はそのまま）
- Curve bake を「曲線に作り直す」に変更（2026-10-17、ユーザーの本当の希望）: おおまかなギザギザを置いて押すと、大きくなめらかなカーブのスライドになる。中継点を制御点にした 3 次 B スプライン（両端は一致。Beatrix.bSplineSamples）を作り、曲線がレーンの真ん中（整数）を通る拍ごとに中継点を置き直す（EditorState.bakedSegs）。始点・終点・時間 0 の区間（横に飛ぶ線）の点はそのまま、ほかの元の中継点は消える。同じレーンが続くときは 1/32 拍以上離れたときだけ置く（平らな区間の終わり）。拍は曲線から 0.15 レーン以内のいちばん粗い拍。curve の印も付ける（描くときは Curve の角丸めで、置き直した点の間もなめらか）。JSON は普通の経由点なので Unity の追加対応は不要

## 19. 区間ごとの曲がり方 ease（2026-10-17）

- ユーザーが見せた動画（プロセカの譜面エディタ風）のように、スライドの区間ごとに「まっすぐ / Ease In / Ease Out」を選べるようにした
- More → **Ease**（EditTool.ease）: 帯（点と点の間）をタップ → easeTap がその区間を探す → confirmationDialog（easeTarget）で選ぶ → setEase（その区間だけ / このスライド全部）
- extra の bxEase = [Int]（k = 点 k → 点 k+1。0 まっすぐ / 1 Ease In u² / 2 Ease Out 1−(1−u)²）。Beatrix.eases / hasEase / easeFraction / slideShape
- 描画: エディタの帯（Renderers）とテストプレイ（BxSlide.draw）。ease があれば curve より優先。判定は変えない
- JSON: `"ease": [ {"LPB","num","block","type":2,"nth","eases":[…]} ]`（curve の後、part の前）
- Unity: UNITY_SPEC.md 7-3、unity/SlideFollower.cs（ease 対応を足した。まるごと差し替え）
- Curve / Curve bake はそのまま残してある
- 曲線の形を PCHIP（経由点を必ず通る）に戻した（2026-10-17）: 角を丸める形（ベジェ）は、移動が大きい（0 ↔ 6 のギザギザ）と角での丸めを 0.4 レーンに抑えても角のワイプと帯がずれた。PCHIP なら必ず経由点を通り、折り返しでは縦向きになるので、ギザギザはなめらかな波になる。端の傾きは区間の傾きのまま（円・放物線にしない）。Beatrix.curveTangents / curveValue / curvePoints。Unity の SlideCurve.cs も同じ式に差し替え

## 20. 音の再生を C++ のミキサーに（2026-10-17）

- 以前: 曲 = GameAudio（AVAudioEngine の AVAudioPlayerNode）、ノーツ音 = 別の AVAudioEngine（BeatrixSounds）にホスト時刻で予約。2 つのエンジンの出力の遅れ・時計の見積もりの分だけずれていた
- 今（GitHub Actions のビルド = ipa）: `Vendor/CBxAudio`（C++。リポジトリに入れてある）のミキサーで、曲とノーツ音を 1 本の流れにして AVAudioSourceNode から出す（GameAudioMixer.swift の GameAudio）
  - 曲: decodeQueue が 10ms おきにリングバッファ（2^18 フレーム）へ書く（bx_music_write）。出力スレッドが読む（ロックなし）
  - ノーツ音: 「タイムラインのフレーム」（再生を始めてから出力したフレーム数。曲の頭より前の無音 lead を含む）で予約（bx_schedule）。曲のサンプルと同じ番号なので、サンプル単位でぴったり合う。ブロックの途中からでも鳴り始める
  - 譜面時刻 t → フレーム: `lead + ((t − offsetTotal)·sr − baseFrame) / rate`（速度 1 未満は伸ばした音のフレームで数える）
  - 時計: 出力のたびに「ブロック先頭のフレーム」と「ホスト時刻」を記録（bx_clock、シーケンスロック）。聞こえる時刻 = ホスト時刻 + outputLatency + ioBufferDuration（前と同じ見積もり）
  - テストプレイ: 打鍵音（bx_play_now）・ワイプ音（譜面時刻で予約）・「しゅ〜」（bx_set_loop）も同じミキサー
  - 効果音は BeatrixSounds.mixerSounds で曲のサンプリング周波数に直して登録（0 tap / 1 wipe / 2 red / 3 しゅ〜）
- Swift Playgrounds（C++ を入れられない）では、TestPlay.swift の前の GameAudio（`#if !canImport(CBxAudio)`）と BeatrixSounds のまま
- CI: ビルド用の Package.swift に CBxAudio ターゲット（-O3）を足した。ビルド後に「CBxAudio mixer: included」と出れば入っている。Playgrounds 用の Package.swift は Vendor / unity を除外

## 21. 左の帯の倍率をズームに連動（2026-10-17）

- 左の縦長の帯（StripView / StripRenderer）の 1 拍の長さを、真ん中のレーンと同じ（レーンの高さ ÷ 表示拍数）にした（EditorState.stripPPB）。ズームに比例し、帯をドラッグするとレーンと同じだけ動く。前は本家と同じ 1 拍 = 約 178pt 固定（stripBeats = 4.6）
- レーンの高さは LaneRenderer が描くたびに state.laneHeight に入れる

## 22. 始点のタップとスライドの結び付き（2026-10-17）

- 始点のタップ（エディタの中では普通のタップとして持っている）に extra の bxHeadOf（スライドの id）を付ける（Beatrix.headLinkKey / headLink）
  - 付くのは「始点あり」でスライド / ホールドを置いたとき（EditorState+Tools）と、JSON の始点の表記（LPB・num が 2 倍）から読んだとき（parse）
  - 自分で別に置いたタップには付かない
- 結び付いたタップを触ると、そのスライド（後ろの中継点も全部）も選ばれて一緒に動く。動かさずに離すと両方の選択が外れる。スライドを触っても始点のタップは選ばれない
- Head Tap / Wipe / None の始点（bxHead）はスライドそのものの一部なので、前から一緒に動く
- 貼り付けでは、一緒にコピーしたスライドに付け直す
- スライド / ホールドの始点の位置にあるふつうのタップは、エディタで水色に描く（色だけ）
- （2026-10-19）一緒に選ぶかは SETTING の「始点のタップを触ったとき、スライドも一緒に選ぶ」（EditorState.linkHeadTap、UserDefaults の editor.linkHeadTap）で切り替える。初期値はオフ（始点のタップだけ選ばれる＝外せる）。結び付き（bxHeadOf）自体はオフでも付けておく

## 23. 曲線の帯の太さ・iOS 15 の難易度切り替え（2026-10-19）

- 曲線 / ease のスライドは、帯を「進む向きに直角に ±太さ」で作る（RibbonOutline.swift）。前は横に ±太さだったので、横に流れる所で細く見えた。端は今までどおり横向きに切る。角は向きの平均で、細くならないよう長くする（上限 4 倍）
  - エディタ（Renderers の drawNotes / drawOrder）とテストプレイ（BeatrixPlayView。判定ラインでの見た目の縦横比の平面で計算して、遠近に戻す）
  - まっすぐのスライドは今までどおり（横に ±太さ）
  - Unity の LineRenderer は、もともと線の向きに直角に太さを付けるので、追加の対応はいらない
- iOS 15 で、難易度のメニューから「(新規)」の難易度を押しても何も出なかった: Menu の項目から SwiftUI の confirmationDialog を出すと、iOS 15 ではメニューが閉じる途中で出ない。UIKit のダイアログ（Compat.swift の ChoicePrompt、0.35 秒待ってから出す）に変えた
- Unity: 曲線 / ease の区間は LineRenderer をやめて、自前のメッシュ（進む向きに直角の太さ）で描くようにした（unity/SlideFollower.cs。UNITY_SPEC.md 7-2「帯の太さ」）。LineRenderer でも実機で少し細く・ねじれて見えたため
- （2026-10-19）↑ 帯を直角の太さにした変更（エディタ・テストプレイの RibbonOutline と、Unity の SlideFollower のメッシュ）は、ギザギザの曲線で大きな三角形が出るバグになったので取り消した。今は前と同じ「横に ±太さ」。iOS 15 の難易度のダイアログの直しは残している
- （2026-10-19）iOS 15 では、同じ画面に SwiftUI の confirmationDialog を複数付けると片方が出ない・メニューから出すと出ない。なので、ダイアログは全部 UIKit（Compat.swift の ChoicePrompt / TextPrompt）にした: 難易度の新規作成、Appear / Vanish、Ease の区間の曲がり方。SwiftUI の confirmationDialog / alert はもう使っていない（新しく足すときも ChoicePrompt を使う）

## 24. テストプレイの判定を本家（keyjudge.cs / NotesGenerate.cs 2026-10-20 版）に合わせた

- 縦連の印（BxPlayChart.markTateren = MarkTaterenNotes）: 同じレーンで間隔 77ms 以内が核、核の前後へ「核の最小間隔 × 1.5 + 3ms」以内まで広げる。前とつながっているノーツが縦連（最初の 1 個は普通）。白・始点・赤（ダミー除く）、同じ時刻は 1 つ
- 縦連のノーツ: ±0.06 まで PERFECT+。GREAT / MISS の幅で押しても何もしない（スルー）。見逃しは今までどおり MISS
- 押した瞬間（BxGame.press = CheckJudgementCore）: ±0.15 秒の中から、ダミー判定 → 本物を「PERFECT の幅の中（時刻の早い順）→ それ以外（近い順）」で判定。縦連の PERFECT の幅の外 / 同じレーンの縦連を取って 0.1 秒以内で PERFECT の幅の外 / 何か取って 0.1 秒以内の白・始点の早押し MISS（−0.11 より早い）は、そこで終わり（何もしない）
- 赤タップは ±0.075 で PERFECT+（前は ±0.06）。ダミーの赤も ±0.075
- コンボ: 本家と同じく、タップ・始点・赤・ワイプ・判定点（ホールドの半拍ごと / スライドの始点と経由点）を全部 1 つずつ数える（前から同じ）
- まだ入れていないもの: 端と中央の間のゾーン（tap0mArea / tap3mArea。button.cs が無いので範囲が分からない）、指のずれから拾う縦連専用のタップ、子の無い type 2（擦り）、判定の時計の +22ms（JudgeTime。テストプレイの補正で合わせる）
- （続き）TouchLaneDetector.cs のくっついた指の連打対策も入れた: 縦連・軽い縦連（BPM140 の 16 分 + 2ms 以内）のノーツがそのボタンの範囲の前後 0.15 秒にあるとき、指が最後に数えた場所から 0.4cm（iPhone 163pt/inch・iPad 132pt/inch で換算）以上ずれたら（前に数えてから 0.04 秒以上）、縦連専用のタップとして数える（BxGame.pressTaterenOnly = CheckTaterenOnly: 縦連・軽い縦連のノーツが ±0.05 秒にあるときだけ判定）
- 端と中央の間のゾーン（tap0mArea / tap3mArea）は、範囲が Unity のシーン（RectTransform）にしか無いので、まだ入れていない

## 25. PC 版 (Windows) エディター（2026-10-22）

- 同じリポジトリの `pc/` に Electron 版を作った。詳しくは `pc/README.md`
- 譜面の読み書きは `pc/renderer/js/format.js`。BeatrixFormat.swift の parseBeatrix / beatrixData / beatrixEntries / beatrixTargets / BeatrixJSONWriter をそのまま JS にしたもの（キーの順番・数の書き方・始点の表記・nth の数え方も同じ）
  - **形式を変えるときは、Swift と JS の両方を同じに直すこと**。`pc/test/roundtrip.js` で確認できる（`node test/roundtrip.js 譜面.json`）
  - エディタの中のノーツの持ち方（beat / x / w / type / segs / extra の bxHead など）も iPad 版と同じ。id は文字列
- 保存: アプリのフォルダに日時付きの控え（300 個）。譜面のフォルダに .bak は作らない（2026-10-22 に変更。ChartsRaw に増えるのが困るため）。書き出しを読み直して同じになるか確認 → 一時ファイル → 置き換え → 読み直して一致確認
- 再生: Web Audio。曲とノーツ音を同じ AudioContext の時刻に予約する（iPad 版の C++ ミキサーと同じ考え方）。鳴らす音の決め方は EditorState.rebuildKeyTimes と同じ
- 描画: Renderers.swift の drawNotes と同じ色分け（始点の位置のタップは水色、多重はピンク、ダミーは薄く）。棒は拍の線の真ん中に描く（iPad 版の barLift は 0）
- 始点のタップを触ったときにスライドも選ぶか（linkHeadTap）は、iPad 版と同じく初期値オフ（設定タブ）
- ビルド: `.github/workflows/build-pc.yml`（windows-latest）。npm test → electron-packager → `--smoke` で exe を起動して確認 → zip を Releases の `pc-latest` に載せる
  - ipa のワークフローは `pc/**` だけの変更では動かない（paths-ignore）。Package.swift（Playgrounds 用・Actions 用の両方）は `pc` を exclude
- まだ: テストプレイ（D F J K。button.cs: D=tap0 左 / F=tap1 / J=tap2 / K=tap3 右）、BPM 自動検出、part / 歌詞の編集
- （2026-10-22）PC 版に「譜面のフォルダ」「曲のフォルダ」の設定（設定タブ。localStorage の bx.chartFolder / bx.songFolder）。初回は `ホーム\BeatTriX-shin-PlayFab(3k)\Assets\ChartsRaw` / `Assets\Resources` があればそれ（main.js の app:default-folders）
  - 曲は曲のフォルダ（下 4 段まで）と譜面と同じフォルダから、曲名 / ファイル名が同じ（または含む）ものを自動で読む。譜面ごとに選んだ曲を覚える（bx.audioFor）
  - 外から選んだ / ドラッグした曲は、曲のフォルダにコピーしてから使う（file:import-audio。同名で中身が違えば 別名 / 上書き / コピーしない を選ぶ）
- （2026-10-22）ホールドのツールをやめて、スライドだけに（全部同じ鍵 = ホールド。始点から押したままドラッグで 1 つ目の中継点）。キーは 1 タップ / 2 赤 / 3 ワイプ / 4 スライド / 5 中継点 / 6 Ease / 7 消す
- （2026-10-22）曲を選ぶと、その曲の譜面（曲名が同じ。charts:index で譜面のフォルダの JSON の name を見る）を開く。曲と譜面がずれないように
- （2026-10-22）再生しても置いている途中のスライドを終わらせない。再生中のホイール / 右の帯のクリックは、再生したまま移動（110ms 止まってから鳴らし直す）。設定「再生中にホイールを回したら止める」（初期値オフ）
- （2026-10-23）PC 版の分割: iPad 版と同じ「1/N = 1 拍を N 分割」の表示に直し、一覧の横の入力欄で 1〜1024 を直接入れられる（前は 1/(4N) と表示していた）
- （2026-10-23）PC 版: 置くツール（タップ / 赤 / ワイプ）のまま Shift+クリックでスライドを置ける（Shift を離すと完了）。選択の追加は Ctrl+クリック。スライドの始点にタップがもうあれば、それを始点として結び付ける（タップを重ねない）
- （2026-10-23）PC 版: BPM / ソフランの一覧は中身が変わったときだけ作り直す（マウスを動かすたびに作り直していて、✕ が押せないことがあった）。レーンの外（左右の黒い所）ではノーツを置かない
- （2026-10-23）PC 版に Part ツール（8）。iPad 版 partTap と同じ（始点 → 終点。区間の中で消す。重なる区間はまとめる）。区間はレーンの両端の太い白線で描く
- （2026-10-24）PC 版にテストプレイ（renderer/js/playcore.js = BeatrixPlayCore.swift の移植、renderer/js/play.js = BeatrixPlayView.swift の見た目を Canvas で）。D F J K = ボタン 0〜3（keydown の e.timeStamp を AudioContext の getOutputTimestamp で譜面時刻にする）。ワイプの音はノーツの時刻に予約、タップ / 赤は押した瞬間。ポーズ: スクロール速度・判定の位置・補正（初期値 −30ms）・オート・ノーツ音（localStorage の bx.play.*）
- （2026-10-24）PC 版に範囲選択（Time range。ツール 9）と、ノーツ音の差し替え（設定タブ。bx.seFile.tap / wipe / red にファイルのパス）
- （2026-10-24）プレビュー（JSON の preview = 曲の何秒目から流すか。Unity の preview.cs は EX の譜面の preview を music.time に入れる）: iPad の Information と PC の「曲の情報」に「再生ラインをプレビューに」「▶ 試聴」。曲の秒 = 譜面の秒 + offset/1000。PC は 0 拍目より前（前奏）からも再生できるようにした
- （2026-10-27）JSON に "subtitle"（選曲画面でアーティスト名と交互に出す (Game Edit) / -short ver.- など）。キーの順番は artist のすぐ後ろ（Swift / JS の topOrder 両方）。空なら書き出さない。iPad の Information と PC の「曲の情報」で入力（ChartData.bxSubtitle）
- （2026-10-27）PC 版に歌詞ツール（L）。iPad 版 lyricsTap / commitLyric / deleteLyric と同じ（始点 → 終点 → 文字を入れる。区間の中で変える・消す）。入力欄の Enter は日本語の変換中は決定にしない
- （2026-10-28）PC 版に BPM・offset の自動検出（renderer/js/tempo.js = BeatrixTempoDetect.swift の移植。Web Worker で計算、使えなければ画面側で）。ノーツが無い譜面に曲を読むと自動で開く。offset の ±10ms ボタンも
