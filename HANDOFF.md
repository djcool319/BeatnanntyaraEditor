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
  "part":   [ {"LPB":4, "num":560, "parts":[ {"LPB":4, "num":688, "parts":[]} ]} ],
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
| `offset` | **サンプル数**。曲のサンプルレートに関係なく、**いつも 44100 = 1 秒**（48kHz の曲でも同じ。Unity 側を 44100 だけで扱えるように）。ノーツを曲に対して後ろへずらす向き |
| `preview` | 選曲画面で流す位置（秒） |
| `ver` | 譜面のバージョン（整数）。Information で入力。空欄なら書き出さない |
| `part` | 区間（サビなど）。外側の LPB/num が始まり、`parts[0]` が終わり。本家では区間に入ると演出が出る |
| `bpms` | 途中の BPM 変化 |
| `speeds` | ソフラン（ノーツ**全体**の流れる速さの倍率。その拍から先ずっと） |
| `speeds_each` | ノーツ**個別**の速さ（1-5） |
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
9. **Note speed**（今回追加）— 選択中のノーツに個別の速さを付ける。1 か空欄、または「解除」で外れる。同じ位置（拍と block）のノーツにもまとめて付く
10. Slide modify
11. Slide to Wipe
12. Wipe to Slide

### 4-5b. BPM・offset の自動検出（BeatrixTempoDetect.swift）

- ノーツが 1 つも無い譜面を開くと自動で解析して、結果のダイアログを出す。Information の「曲を解析する」でいつでも実行できる
- BPM: 立ち上がりの強さ（スペクトルフラックス、窓 512・128 サンプルおき）に、BPM の波とその 2〜4 倍の波を当てて探す（170 前後を優先）。曲の頭から最大 2 分で 0.001 刻みまで詰め、整数・0.5 刻みに近ければ丸める。倍・半分も候補に出して、人が選ぶ
- offset: 最初の 30 秒で、拍の位置の立ち上がりの合計が最大になる位相 → 拍ごとのずれの中央値で微調整 → 約 2ms 足す。0 拍目は音が鳴り始めたところに一番近い拍。JSON の offset = 0 拍目の秒 × サンプルレート + 再生の補正（今の基準）。「0 拍目をずらす」で ±0.5 / ±1 拍のボタンと、拍の入力（2 / -1.5 / 1/4）で何拍でもずらせる（+ で曲の後ろへ）
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
- offset（サンプル数。±10ms のボタンあり）
- ファイル名（表示）

### 4-8. SETTING

- 曲の音量
- ノーツサウンドの音量
- 背景画像の暗さ
- 伸ばした音の立ち上がり（遅い再生用）
- 時系列順でない seg を許可
- すぐ下の線に置く
- Slide modify での縦移動を許可
- **再生の補正**（初期値 1800 サンプル。NoteEditor の clapOffsetSamples と同じ）
  - JSON の offset は変えずに、再生とテストプレイのときだけノーツを早める
  - ±441 のボタンと「1800 に戻す」ボタンあり

### 4-9. offset の計算

- 秒 = (raw − 再生の補正) / サンプルレート
- rate はいつも 44100（曲のサンプルレートは使わない）
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
  - offset（サンプル数）: このテストプレイの間だけ使う。**譜面には保存しない**
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
   - 「再生の補正 1800 サンプル」と「テストプレイの補正 −30ms」で、今は合っているとのこと
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
