# BeatTriX Editor — PC 版 (Windows)

iPad 版と **同じ JSON** (`曲名(EX).json`) を読み書きする、Windows 用の譜面エディターです。
iPad で作った譜面を PC で開いて続きを作り、また iPad に戻しても、中身は変わりません
(書き出しの並び・キーの順番・数の書き方まで iPad 版と同じ。`renderer/js/format.js` は `BeatrixFormat.swift` をそのまま移したもの)。

## 入れ方
1. GitHub の **Releases → 「PC版 (Windows) 最新ビルド」(pc-latest)** から `BeatTriXEditor-win-x64.zip` をダウンロード
2. 好きな場所に展開して、中の **BeatTriXEditor.exe** をダブルクリック (インストール不要)
   - 初回に「Windows によって PC が保護されました」と出たら → 詳細情報 → 実行
3. 譜面の JSON をウィンドウにドラッグするか、Ctrl+O で開く。**同じフォルダの曲 (ogg / mp3 / wav)** は自動で読む

## データを壊さないための仕組み
- 保存するとき、前の中身を **`曲名(EX).json.bak`** に残す (1 つ前の版)
- さらに日時付きの控えを、アプリのフォルダ (ヘルプ → バックアップのフォルダを開く) に最新 100 個まで残す
- 書き出した文字を読み直して、もう一度書き出しても同じになるか確かめてから保存する (違えば保存しない)
- 一時ファイルに書いてから置き換え、置き換えたあと読み直して中身が一致するか確かめる
- 中身が変わっていなければ、ファイルを書き換えない
- iPad 版が知らないキー (part / lyrics / 自分で足したキーなど) もそのまま残す

## 操作
| キー / マウス | 動き |
|---|---|
| Space | 再生 / 停止 (曲とノーツ音を同じ時計で鳴らすので、ずれない) |
| ホイール / Ctrl+ホイール | スクロール / ズーム |
| `[` `]` | 分割を粗く / 細かく |
| Q / Esc | 選択ツール |
| 1〜8 | タップ / 赤タップ / ワイプ / ホールド / スライド / 中継点 / Ease / 消す |
| クリック | 置く (ノーツの上なら選んで、そのままドラッグで移動) |
| 空いた所をドラッグ (選択ツール) | 囲んで選ぶ。Ctrl / Shift で追加 |
| 右クリック | ノーツを消す (スライドを置いている途中なら完了) |
| Enter | スライドを完了 |
| Ctrl+Z / Ctrl+Y | 元に戻す / やり直す |
| Ctrl+C / X / V | コピー / 切り取り / 再生ラインに貼り付け |
| ↑ ↓ ← → | 選んだノーツを 1 分割 / 1 鍵ずつ動かす |
| M / R / H / C / B | 左右反転 / 白⇔赤 / 始点の種類 / 曲線 / Curve bake |
| Ctrl+S | 保存 |
| F1 | ショートカット一覧 |

ホールドは「始点を押して終点までドラッグ」か「始点クリック → 終点クリック」。
スライドは「始点 → 中継点を順にクリック → Enter か右クリック」。
左の「ホールドに始点 / スライドに始点」で、始点のタップを付けるかを選べる (iPad 版と同じく、始点は普通のタップとして置かれ、保存で始点の表記になる)。

上の **BS / HD / EX / IN** の札で難易度を切り替え (同じフォルダの `曲名(XX).json`。無ければ空 / コピーで作る)。

## 今できること / まだのこと
- できる: 開く・保存・新規、タップ / 赤 / ワイプ / ホールド / スライド、選択・移動・コピー、中継点の編集、Ease、曲線 / Curve bake、ダミー、ノーツ個別の速さ、出現 / 消える、BPM 変化、ソフラン、曲の情報、難易度の切り替え、再生
- 表示だけ (保存では残る): part、歌詞
- まだ: テストプレイ (D F J K で遊ぶ)、BPM の自動検出、part / 歌詞の編集

## 開発
```
cd pc
npm install
npm start          # 起動
npm test           # 譜面の読み書きの確認 (node test/roundtrip.js 譜面.json で手元の譜面も確認できる)
npm run pack:win   # exe を作る (dist/BeatTriXEditor-win32-x64)
```
- Electron。画面は `renderer/` (普通の JS + Canvas)、ファイルの読み書きは `main.js` だけ
- `renderer/js/format.js` … 譜面の読み書き (iPad 版 BeatrixFormat.swift と同じ)。**形式を変えるときは両方を同じに直す**
- `renderer/js/editor.js` … 編集の操作 (EditorState+Tools / +Beatrix と同じ動き)
- `renderer/js/view.js` … レーンの描画 (Renderers.swift と同じ色・形)
- `renderer/js/audio.js` … 再生 (Web Audio。曲とノーツ音を同じ AudioContext の時刻に予約)
- `renderer/js/sounddata.js` … ノーツ音 (BeatrixSoundData.swift と同じ音)
- GitHub Actions: `.github/workflows/build-pc.yml` (pc フォルダを変えると Windows でビルド → Releases の pc-latest)
