import SwiftUI
import UIKit

// MARK: - びーとり用の編集
//   ・Head Tap / Wipe : 選択中のスライド / ホールドの始点を、タップ ⇔ ワイプ で切り替える (More)
//   ・Tap / Red       : 選択中のタップを、通常 ⇔ 赤 で切り替える (More)
//   ・Part            : part の区間を置く / 消す (More → Part のあと、レーンをタップ)
//   ・難易度の切り替え  : 画面上の難易度の札から。難易度ごとに別のファイル「曲名(BS).json」「曲名(EX).json」…

extension BeatrixDifficulty {
    /// 難易度の色 (BASIC = 青 / HARD = オレンジ寄りの黄色 / EXTREME = 赤 / INSANE = 紫)
    var uiColor: UIColor {
        switch self {
        case .basic: return UIColor(red: 0.16, green: 0.47, blue: 1.00, alpha: 1)
        case .hard: return UIColor(red: 1.00, green: 0.66, blue: 0.08, alpha: 1)
        case .extreme: return UIColor(red: 0.90, green: 0.12, blue: 0.16, alpha: 1)
        case .insane: return UIColor(red: 0.60, green: 0.22, blue: 0.92, alpha: 1)
        }
    }

    var color: Color { Color(uiColor) }
}

extension EditorState {
    func toggleSlideHead() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let idx = chart.notes.indices.filter { ids.contains(chart.notes[$0].id) && chart.notes[$0].isSlide }
        if idx.isEmpty {
            showToast("先にスライド / ホールドを選択してください")
            return
        }
        // 始点を タップ → ワイプ → なし → タップ … の順に切り替える (最初に選んだものを基準に、全部そろえる)
        let next: Int
        switch Beatrix.headType(chart.notes[idx[0]]) {
        case 1: next = 4
        case 4: next = 0
        default: next = 1
        }
        pushUndo()
        for i in idx {
            if next == 1 {
                chart.notes[i].extra.removeValue(forKey: Beatrix.headKey)
            } else {
                chart.notes[i].extra[Beatrix.headKey] = next
            }
        }
        chartChanged()
        let name = next == 1 ? "タップ" : (next == 4 ? "ワイプ" : "なし")
        showToast("始点を「\(name)」にしました (\(idx.count) 本)")
    }

    func toggleRedTap() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let idx = chart.notes.indices.filter { ids.contains(chart.notes[$0].id) && Beatrix.isTapLike(chart.notes[$0]) }
        if idx.isEmpty {
            showToast("先にタップを選択してください")
            return
        }
        let toRed = idx.contains { chart.notes[$0].type != 3 }
        pushUndo()
        for i in idx {
            chart.notes[i].type = toRed ? 3 : nil
            chart.notes[i].extra.removeValue(forKey: Beatrix.rawTypeKey)
        }
        chartChanged()
        showToast(toRed ? "赤タップにしました (\(idx.count) 個)" : "通常のタップにしました (\(idx.count) 個)")
    }

    // MARK: part

    /// Part ツールでレーンをタップしたとき。
    /// 既にある区間の中をタップ → その区間を消す / それ以外 → 1 回目が始点、2 回目が終点 (区間ができる)
    func partTap(beat b: Beat) {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        var parts = chart.bxParts
        if let s = partStart {
            partStart = nil
            if s == b {
                showToast("始点と同じ位置です。もう一度、始点からタップしてください")
                return
            }
            let lo = min(s, b)
            let hi = max(s, b)
            // 重なる区間は 1 つにまとめる
            var start = lo
            var end = hi
            var kept: [BeatrixPart] = []
            for p in parts {
                if p.end < lo || p.start > hi {
                    kept.append(p)
                } else {
                    start = min(start, p.start)
                    end = max(end, p.end)
                }
            }
            kept.append(BeatrixPart(start: start, end: end))
            pushUndo()
            chart.bxParts = kept
            chartChanged()
            showToast("part を置きました (\(start.label) 〜 \(end.label))")
            return
        }
        if let i = parts.firstIndex(where: { $0.start <= b && b <= $0.end }) {
            pushUndo()
            parts.remove(at: i)
            chart.bxParts = parts
            chartChanged()
            showToast("part を消しました")
            return
        }
        partStart = b
        showToast("part の始点を置きました。終点の拍をタップしてください")
    }

    /// Hold ボタン: 押すたびに「始点あり」→「始点なし」→ オフ。アイコンも変わる
    func holdButtonTapped() {
        if tool != .hold {
            tool = .hold
            holdWithHead = true
            showToast("ホールド (始点あり): 始点をタップ → 終点をタップ")
        } else if holdWithHead {
            holdWithHead = false
            showToast("ホールド (始点なし): 始点をタップ → 終点をタップ")
        } else {
            tool = .unselected
        }
    }

    func togglePartTool() {
        editing = true
        toggleTool(.part)
        if tool == .part {
            showToast("始点 → 終点の順にレーンをタップすると part になります (区間の中をタップで削除)")
        }
    }

    // MARK: 難易度

    /// その難易度のファイル (アプリ内の BeatrixEditor フォルダの「曲名(XX).json」)
    func chartURL(for d: BeatrixDifficulty) -> URL {
        let t = chart.bxTitle.isEmpty ? "chart" : chart.bxTitle
        return Self.appChartDirectory().appendingPathComponent(Beatrix.safeFileName("\(t)(\(d.abbr))") + ".json")
    }

    func hasChart(for d: BeatrixDifficulty) -> Bool {
        FileManager.default.fileExists(atPath: chartURL(for: d).path)
    }

    /// 難易度を切り替える。今の譜面を保存してから、
    ///   その難易度のファイルがあれば → それを開く
    ///   無ければ → copyNotes が true なら今のノーツをコピー、false なら空の譜面で「曲名(XX).json」を作る
    /// (BPM・offset・曲名などはそのまま引き継ぐ)
    func switchDifficulty(to d: BeatrixDifficulty, copyNotes: Bool) {
        if d == chart.bxDifficulty { return }
        if isPlaying { pause() }
        saveNow()
        let url = chartURL(for: d)
        if let data = try? Data(contentsOf: url), let c = try? ChartData.parseBeatrix(data) {
            replaceChart(c, url: url)
            showToast("\(d.label) の譜面を開きました (\(url.lastPathComponent))")
            return
        }
        var c = chart
        c.bxDifficulty = d
        if !copyNotes { c.notes = [] }
        replaceChart(c, url: url)
        saveNow()
        showToast("\(d.label) の譜面を作りました (\(url.lastPathComponent))")
    }

    private func replaceChart(_ c: ChartData, url: URL) {
        tool = .unselected
        selectedIDs = []
        orderIDs = []
        slideDraft = nil
        partStart = nil
        ghost = nil
        chart = c
        mcURL = url
        clearHistory()
        chartChanged()
    }
}

/// 右ボタン列の Hold のアイコン。
///   始点あり: 縦長の枠 (ホールドの帯) + 下の太い棒 (始点)
///   始点なし: 縦長の枠だけ (下の端まで帯が伸びる。棒の位置に斜線)
struct HoldPanelIcon: View {
    let color: Color
    var withHead: Bool = true

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            if withHead {
                let band = CGRect(x: cx - 7, y: cy - 17, width: 14, height: 27)
                ctx.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 3.5)
                let bar = CGRect(x: cx - 15, y: cy + 9, width: 30, height: 7)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(color))
            } else {
                let band = CGRect(x: cx - 7, y: cy - 17, width: 14, height: 34)
                ctx.stroke(Path(roundedRect: band, cornerRadius: 3), with: .color(color), lineWidth: 3.5)
                var slash = Path()
                slash.move(to: CGPoint(x: cx - 15, y: cy + 17))
                slash.addLine(to: CGPoint(x: cx + 15, y: cy + 7))
                ctx.stroke(slash, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .frame(width: 50, height: PanelIconView.refHeight + 6)
    }
}

/// 画面の上に常に出す「今どの難易度を作っているか」の札。押すと難易度を切り替えられる
struct DifficultyBadge: View {
    @ObservedObject var state: EditorState
    @State private var pending: BeatrixDifficulty? = nil

    var body: some View {
        let d = state.chart.bxDifficulty
        Menu {
            ForEach(BeatrixDifficulty.allCases, id: \.rawValue) { item in
                Button {
                    choose(item)
                } label: {
                    if item == d {
                        Label(item.label, systemImage: "checkmark")
                    } else {
                        Text(state.hasChart(for: item) ? item.label : "\(item.label) (新規)")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(d.label) Lv.\(Beatrix.lvRank(state.chart.bxLevel))")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(d.color)
                Text(state.chart.bxFileName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
            .background(Color.black.opacity(0.6))
            .overlay(Rectangle().stroke(d.color, lineWidth: 1.5))
        }
        .confirmationDialog("\(pending?.label ?? "") の譜面はまだありません",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("今のノーツをコピーして作る") {
                if let p = pending { state.switchDifficulty(to: p, copyNotes: true) }
                pending = nil
            }
            Button("空の譜面で作る") {
                if let p = pending { state.switchDifficulty(to: p, copyNotes: false) }
                pending = nil
            }
            Button("やめる", role: .cancel) { pending = nil }
        }
    }

    private func choose(_ item: BeatrixDifficulty) {
        if item == state.chart.bxDifficulty { return }
        if state.hasChart(for: item) {
            state.switchDifficulty(to: item, copyNotes: false)
        } else {
            pending = item
        }
    }
}
