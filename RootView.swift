import SwiftUI
import UniformTypeIdentifiers

/// 起動画面: びーとりの譜面 (.json) / 音源 (/ 背景画像) を選んでエディタを開く。譜面を選ばずに「新規作成」もできる
struct RootView: View {
    private enum PickTarget {
        case mc, ogg, bg
    }

    @State private var editor: EditorState? = nil
    @State private var showImporter = false
    @State private var target: PickTarget = .mc

    @State private var mcURL: URL? = nil
    @State private var mcData: Data? = nil
    @State private var mcName = ""
    @State private var oggData: Data? = nil
    @State private var oggName = ""
    @State private var oggURL: URL? = nil       // 音源の場所 (アプリの書類フォルダの中なら、新しい譜面をその隣に作る)
    @State private var bgData: Data? = nil
    @State private var bgName = ""

    @State private var newBPM = "120"
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        // iPhone のときは、iPad くらいの大きさで作って縮めて表示する (PhoneLayout.swift)。iPad はそのまま
        PhoneScaled {
        ZStack {
            if let st = editor {
                EditorView(state: st)
                    // 本家と同じく、画面の下端 (ホームインジケータの下) までUIを続ける
                    .ignoresSafeArea(.container, edges: [.top, .leading, .trailing, .bottom])
                    // ホームバー (画面下の白い横棒) を隠し、下端からの1回目の上スワイプではホームに戻らないようにする。
                    // (下端を触る操作 — ノーツ幅スライダーやレーン下側のドラッグ — で、うっかりホーム画面へ戻るのを防ぐ。
                    //  ホームへ戻るときは、下端から2回スワイプする)
                    .compatHideSystemOverlays()
                    .compatDeferBottomGestures()
            } else {
                importView
            }
        }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handle(result)
        }
    }

    private var importView: some View {
        VStack(spacing: 18) {
            Text("BeatTriX Editor")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
            Text("譜面 (曲名(EX).json など) と音源を読み込んでから編集に入ります")
                .foregroundColor(.secondary)

            fileRow(title: "譜面 (.json)", name: mcName, required: false) {
                target = .mc
                showImporter = true
            }
            fileRow(title: "音源 (.ogg)", name: oggName, required: false) {
                target = .ogg
                showImporter = true
            }
            fileRow(title: "背景画像 (任意)", name: bgName, required: false) {
                target = .bg
                showImporter = true
            }

            Button {
                openEditor()
            } label: {
                Text(busy ? "読み込み中…" : "エディタを開く")
                    .font(.title3.bold())
                    .frame(width: 280, height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mcData == nil || busy)

            // 譜面を選ばずに、新しい譜面を作る (曲名は音源のファイル名、難易度は EX。あとで META → Information で変えられる)
            HStack(spacing: 14) {
                Text("新規の BPM")
                TextField("120", text: $newBPM)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button {
                    createNew()
                } label: {
                    Text("新規作成").frame(width: 120, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }

            PhoneOrientationPicker()      // iPhone のときだけ出る

            if busy { ProgressView() }
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .frame(maxWidth: 520)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func fileRow(title: String, name: String, required: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 130, alignment: .leading)
            Text(name.isEmpty ? (required ? "未選択 (必須)" : "未選択") : name)
                .foregroundColor(name.isEmpty ? .secondary : .green)
                .lineLimit(1)
                .frame(width: 280, alignment: .leading)
            Button("選択…", action: action).buttonStyle(.bordered)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            message = "ファイルを開けませんでした: \(e.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let ok = url.startAccessingSecurityScopedResource()
            do {
                let data = try Data(contentsOf: url)
                switch target {
                case .mc:
                    mcData = data
                    mcURL = url           // オートセーブで書き戻すため、アクセス権は開いたままにする
                    mcName = url.lastPathComponent
                case .ogg:
                    oggData = data
                    oggName = url.lastPathComponent
                    oggURL = url
                    if ok { url.stopAccessingSecurityScopedResource() }
                    autoPickChart(forSong: url)
                case .bg:
                    bgData = data
                    bgName = url.lastPathComponent
                    if ok { url.stopAccessingSecurityScopedResource() }
                }
                message = ""
            } catch {
                message = "読込に失敗しました: \(error.localizedDescription)"
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: 音源を選んだら、その曲の EX 譜面を自動で入れる
    //   アプリの書類フォルダ (BeatrixEditor など。下のフォルダも) と、音源と同じフォルダ (読めるときだけ) から、
    //   「曲名(EX).json」(ファイル名) か、中の name が曲名で difficulty が EX の JSON を探す。曲名は音源のファイル名 (拡張子なし)。
    //   見つからなければ何もしない。2 つ以上あれば、どれを使うか選ぶ。
    //   もう別の曲の譜面を選んでいたときも入れ替える (同じ曲の譜面を選んでいたときは、そのまま)

    private func autoPickChart(forSong song: URL) {
        let key = ChartFinder.songKey(song.deletingPathExtension().lastPathComponent)
        if key.isEmpty { return }
        if let cur = mcURL, ChartFinder.songKey(cur.deletingPathExtension().lastPathComponent) == key { return }
        Task.detached(priority: .userInitiated) {
            let found = ChartFinder.findEXCharts(songKey: key, near: song)
            await MainActor.run {
                if found.isEmpty { return }
                if found.count == 1 {
                    useChart(found[0], auto: true)
                    return
                }
                var actions = found.map { u in
                    ChoicePrompt.Action(title: ChartFinder.label(u)) { useChart(u, auto: true) }
                }
                actions.append(ChoicePrompt.Action(title: "選ばない", style: .cancel) {})
                ChoicePrompt.show(title: "この曲の EX 譜面が \(found.count) 個あります",
                                  message: "どれを使いますか？ (フォルダ / ファイル名 / 最後に変えた日時)", actions: actions, delay: 0.5)
            }
        }
    }

    /// 見つけた譜面を「譜面」に入れる (自分で選んだときと同じ)
    private func useChart(_ url: URL, auto: Bool) {
        guard let d = try? Data(contentsOf: url) else {
            message = "譜面を読み込めませんでした: \(url.lastPathComponent)"
            return
        }
        mcData = d
        mcURL = url
        mcName = url.lastPathComponent
        message = auto ? "曲名から譜面を入れました: \(url.lastPathComponent)" : ""
    }

    private func openEditor() {
        guard let url = mcURL else { return }
        // 最初に選んだ時点の mcData は、編集前の古い内容。Quit で戻ってきたあとにそれで開き直すと、
        // 編集した内容が消えるうえ、オートセーブ (アプリを離れたときの保存も) で、保存済みのファイルが古い内容で上書きされてしまう。
        // → 開くたびに、ファイルから読み直す (読めなかったときだけ、選んだときの内容を使う)
        guard let data = (try? Data(contentsOf: url)) ?? mcData else { return }
        mcData = data
        busy = true
        message = ""
        Task { @MainActor in
            do {
                let chart = try ChartData.parseBeatrix(data)
                var audio: AudioController? = nil
                var note = ""
                if let od = oggData {
                    let a = AudioController()
                    do {
                        try await a.load(data: od, fileName: oggName)
                        audio = a
                    } catch {
                        note = "音源を読み込めませんでした(無音で開きます): \(error.localizedDescription)"
                    }
                }
                let st = EditorState(
                    chart: chart, mcURL: url, mcName: mcName, audio: audio,
                    oggData: oggData, oggFileName: oggName,
                    bgData: bgData, bgFileName: bgName, audioURL: oggURL
                )
                st.onClose = {
                    editor = nil
                }
                if !note.isEmpty { st.showToast(note) }
                editor = st
                busy = false
            } catch {
                busy = false
                message = "譜面を読めませんでした。びーとりの JSON (notes が入ったもの) を選んでください。mc は変換ツールで JSON にしてから開いてください。"
            }
        }
    }

    /// 新しい譜面を作って開く。ファイルは「曲名(EX).json」で、
    /// 音源がアプリの書類フォルダの中 (例: BeatrixEditor/Song/曲名/) にあれば音源と同じフォルダ、それ以外は BeatrixEditor フォルダに作る
    private func createNew() {
        let bpm = Double(newBPM.trimmingCharacters(in: .whitespaces)) ?? 120
        if bpm <= 0 {
            message = "BPM は 0 より大きい数で入力してください"
            return
        }
        var title = (oggName as NSString).deletingPathExtension
        if title.isEmpty { title = "新しい譜面" }
        let chart = ChartData.newBeatrix(title: title, bpm: bpm, difficulty: .extreme)
        let dir = EditorState.chartDirectory(json: nil, audio: oggURL)
        let url = dir.appendingPathComponent(chart.bxFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            message = "\(dir.lastPathComponent) フォルダに同じ名前の譜面 (\(chart.bxFileName)) があります。上の「譜面」で選んで開いてください"
            return
        }
        do {
            try chart.beatrixData().write(to: url, options: .atomic)
        } catch {
            message = "新しい譜面を作れませんでした: \(error.localizedDescription)"
            return
        }
        mcURL = url
        mcData = nil
        mcName = url.lastPathComponent
        openEditor()
    }
}

/// 曲名から譜面 (JSON) を探す (RootView の「音源を選んだら EX 譜面を自動で入れる」で使う)
enum ChartFinder {
    /// 曲名の比べ方: 全角半角・大文字小文字・空白や記号の違いと、末尾の (EX) などは無視する
    static func songKey(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"[(（](bs|hd|ex|in)[)）]$"#, options: .regularExpression) { t.removeSubrange(r) }
        let drop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "_-‐－—~〜・.,!！?？'\"’”()[]{}（）「」『』【】*:<>|/\\"))
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { !drop.contains($0) }))
    }

    /// その曲の EX 譜面を探す (アプリの書類フォルダの下全部と、音源と同じフォルダ)。同じファイルは 1 つにまとめる
    static func findEXCharts(songKey key: String, near song: URL) -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var roots = [docs]
        let parent = song.deletingLastPathComponent()
        if !parent.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path) { roots.append(parent) }
        var found: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let access = root != docs && root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var count = 0
            for case let u as URL in en {
                count += 1
                if count > 8000 { break }
                if en.level > 6 { en.skipDescendants(); continue }
                guard u.pathExtension.lowercased() == "json" else { continue }
                let path = u.standardizedFileURL.path
                if seen.contains(path) { continue }
                if isEXChart(u, key: key) {
                    seen.insert(path)
                    found.append(u)
                }
            }
        }
        // 新しく変えたものから順に
        return found.sorted { modified($0) > modified($1) }
    }

    private static func isEXChart(_ u: URL, key: String) -> Bool {
        let base = u.deletingPathExtension().lastPathComponent
        let up = base.uppercased()
        let exName = up.hasSuffix("(EX)") || up.hasSuffix("（EX）")
        // 1) ファイル名が「曲名(EX)」
        if exName && songKey(base) == key { return true }
        // 2) 中身: name が曲名で、difficulty が EX (無ければ name の (EX) / ファイル名の (EX))
        guard let d = try? Data(contentsOf: u), d.count < 8_000_000,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["notes"] != nil else { return false }
        let info = Beatrix.splitName((o["name"] as? String) ?? "")
        let diff = Beatrix.intValue(o["difficulty"]) ?? info.diff?.rawValue ?? (exName ? 2 : -1)
        return diff == BeatrixDifficulty.extreme.rawValue && songKey(info.title) == key
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 選ぶダイアログの表示: 「フォルダ / ファイル名 (日時)」
    static func label(_ u: URL) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return u.deletingLastPathComponent().lastPathComponent + " / " + u.lastPathComponent + "  (" + f.string(from: modified(u)) + ")"
    }
}
