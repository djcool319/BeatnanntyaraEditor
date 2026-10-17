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

/// 歌詞の入力ダイアログの中身 (index: 既にある歌詞の番号。nil なら新しく置く)
struct LyricEdit: Identifiable {
    let id = UUID()
    let index: Int?
    let start: Beat
    let end: Beat
    var text: String
}

/// BPM・offset の自動検出の状態
enum TempoDetectPhase {
    case running
    case done(BeatrixTempoAnalysis)
    case failed(String)
}

/// 解析を途中でやめるための旗 (裏のスレッドから読む)
final class TempoDetectCancelFlag: @unchecked Sendable {
    var cancelled = false
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

    // MARK: ノーツ個別の速さ (speeds_each)

    /// 選択中のノーツの速さ (入力欄の最初の値)。ばらばらなら空
    var selectedNoteSpeedText: String {
        let ids = selectedIDs
        let sps = Set(chart.notes.filter { ids.contains($0.id) }.map { Beatrix.noteSpeed($0) ?? 1 })
        guard sps.count == 1, let v = sps.first else { return "" }
        return Beatrix.speedLabel(v)
    }

    /// 選択中のノーツに、個別の速さを付ける (1 か空欄で解除)。
    /// 選んだノーツだけ (同じ位置にある別のノーツには付けない)。スライド / ホールドの始点は本体に付いていく
    func applyNoteSpeedInput(_ text: String) {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        if ids.isEmpty {
            showToast("先にノーツを選択してください")
            return
        }
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "x", with: "")
        var value: Double? = nil
        if !t.isEmpty {
            guard let v = Double(t), v.isFinite, v != 0, abs(v) <= 100 else {
                showToast("速さは 0 以外の数で入力してください (例: 2 / 0.5 / 1.25)")
                return
            }
            value = abs(v - 1) < 1e-9 ? nil : v
        }
        var keys = Set<BeatrixKey>()
        for n in chart.notes where ids.contains(n.id) {
            keys.insert(BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x))))
        }
        pushUndo()
        var count = 0
        for i in chart.notes.indices {
            let n = chart.notes[i]
            guard ids.contains(n.id) else { continue }       // 選んだノーツだけ (同じ位置の別のノーツには付けない)
            if let v = value {
                chart.notes[i].extra[Beatrix.speedKey] = v
            } else {
                chart.notes[i].extra.removeValue(forKey: Beatrix.speedKey)
            }
            count += 1
        }
        chartChanged()
        if let v = value {
            showToast("ノーツの速さを ×\(Beatrix.speedLabel(v)) にしました (\(count) 個)")
        } else {
            showToast("ノーツの速さを解除しました (全体のソフランだけで流れます)")
        }
    }

    // MARK: BPM・offset の自動検出

    /// 曲を解析して、結果のダイアログを出す (解析は裏で。解析中もダイアログに「解析中」と出す)
    func startTempoDetect() {
        if isPlaying { pause() }
        guard let od = oggData else {
            showToast("曲が読み込まれていないので、解析できません")
            return
        }
        tempoDetectCancel?.cancelled = true
        let flag = TempoDetectCancelFlag()
        tempoDetectCancel = flag
        tempoDetect = .running
        let ext0 = (oggFileName as NSString).pathExtension
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: TempoDetectPhase
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tempodetect", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("audio.\(ext0.isEmpty ? "ogg" : ext0)")
                try od.write(to: url, options: .atomic)
                let a = try BeatrixTempoDetector.analyze(url: url) { flag.cancelled }
                result = .done(a)
            } catch let e as BeatrixTempoDetector.Failure {
                result = .failed(e.text)
            } catch {
                result = .failed("曲を読み込めませんでした (\(error.localizedDescription))")
            }
            DispatchQueue.main.async {
                guard let self = self, !flag.cancelled, self.tempoDetectCancel === flag else { return }
                self.tempoDetect = result
            }
        }
    }

    func cancelTempoDetect() {
        tempoDetectCancel?.cancelled = true
        tempoDetectCancel = nil
        tempoDetect = nil
    }

    /// 検出結果を入れる。bpm / offset のどちらかだけでもよい
    func applyTempoDetect(bpm: Double?, offsetRaw: Int?) {
        tempoDetectCancel = nil
        tempoDetect = nil
        if bpm == nil && offsetRaw == nil { return }
        if isPlaying { pause() }
        pushUndo()
        var parts: [String] = []
        if let b = bpm {
            if chart.notes.isEmpty || chart.times.count <= 1 {
                chart.times = [TimePoint(beat: .zero, bpm: b)]
            } else {
                chart.times.sort { $0.beat < $1.beat }
                chart.times[0].bpm = b
            }
            chartChanged()
            parts.append("BPM \(Beatrix.speedLabel(b))")
        }
        if let raw = offsetRaw {
            setBeatrixOffset(raw)
            parts.append("offset \(raw)")
        }
        showToast(parts.joined(separator: " / ") + " を入れました")
    }

    // MARK: 出現 / 消える (appear / disappear)

    enum AppearAction {
        case appear, vanish, clearHere, clear
    }

    /// 選択中のノーツに、再生ライン (シアンの横棒) の拍で「出現」/「消える」を足す (何回でも付けられる)。
    ///   clearHere: 再生ラインの拍の出現 / 消えるだけ外す / clear: 全部外す
    /// 選んだノーツだけに付ける (同じ位置にある別のノーツには付けない。ホールドとスライドを重ねて入れ替える演出ができるように)
    func setAppear(_ action: AppearAction) {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let idx = chart.notes.indices.filter { ids.contains(chart.notes[$0].id) }
        if idx.isEmpty {
            showToast("先にノーツを選択してください")
            return
        }
        let at = Beat.nearest(viewBeat, den: snapDen)
        pushUndo()
        for i in idx {
            var ap = Beatrix.atBeats(chart.notes[i], Beatrix.appearKey)
            var va = Beatrix.atBeats(chart.notes[i], Beatrix.vanishKey)
            switch action {
            case .appear:
                va.removeAll { $0 == at }            // 同じ拍の「消える」とは同時に付けない (置き換える)
                if !ap.contains(at) { ap.append(at) }
            case .vanish:
                ap.removeAll { $0 == at }
                if !va.contains(at) { va.append(at) }
            case .clearHere:
                ap.removeAll { $0 == at }
                va.removeAll { $0 == at }
            case .clear:
                ap = []
                va = []
            }
            Beatrix.setAtBeats(&chart.notes[i], Beatrix.appearKey, ap)
            Beatrix.setAtBeats(&chart.notes[i], Beatrix.vanishKey, va)
        }
        chartChanged()
        let count = idx.count
        switch action {
        case .appear: showToast("\(at.label) で出現するようにしました (\(count) 個)")
        case .vanish: showToast("\(at.label) で消えるようにしました (\(count) 個)")
        case .clearHere: showToast("\(at.label) の出現 / 消えるを外しました (\(count) 個)")
        case .clear: showToast("出現 / 消えるを全部解除しました (\(count) 個)")
        }
    }

    // MARK: ダミー (dummy)

    /// 選択中のノーツを ダミー ⇔ 普通 で切り替える (選択の中に普通のノーツが 1 つでもあれば、全部ダミーにする)。
    /// 選んだノーツだけ (同じ位置にある別のノーツには付けない)。スライド / ホールドの始点は本体に付いていく
    func toggleDummy() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let sel = chart.notes.filter { ids.contains($0.id) }
        if sel.isEmpty {
            showToast("先にノーツを選択してください")
            return
        }
        let toDummy = sel.contains { !Beatrix.isDummy($0) }
        var keys = Set<BeatrixKey>()
        for n in sel { keys.insert(BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x)))) }
        pushUndo()
        var count = 0
        for i in chart.notes.indices {
            let n = chart.notes[i]
            guard ids.contains(n.id) else { continue }       // 選んだノーツだけ (同じ位置の別のノーツには付けない)
            if toDummy {
                chart.notes[i].extra[Beatrix.dummyKey] = true
            } else {
                chart.notes[i].extra.removeValue(forKey: Beatrix.dummyKey)
            }
            count += 1
        }
        chartChanged()
        showToast(toDummy ? "ダミーにしました (\(count) 個。判定なし)" : "ダミーを解除しました (\(count) 個)")
    }

    // MARK: 曲線スライド (curve)

    /// 選択中のスライドを 曲線 ⇔ 普通 で切り替える (選択の中に普通のスライドが 1 つでもあれば、全部曲線にする)。
    /// 見た目 (エディタの帯 / テストプレイ) だけが丸くなる。判定の位置は経由点のまま
    func toggleCurve() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let sel = chart.notes.filter { ids.contains($0.id) && $0.isSlide }
        if sel.isEmpty {
            showToast("先にスライドを選択してください")
            return
        }
        let toCurve = sel.contains { !Beatrix.isCurve($0) }
        pushUndo()
        var count = 0
        for i in chart.notes.indices where ids.contains(chart.notes[i].id) && chart.notes[i].isSlide {
            if toCurve {
                chart.notes[i].extra[Beatrix.curveKey] = true
            } else {
                chart.notes[i].extra.removeValue(forKey: Beatrix.curveKey)
            }
            count += 1
        }
        chartChanged()
        showToast(toCurve ? "曲線スライドにしました (\(count) 個。見た目だけ角を丸く、判定は今のまま)" : "曲線を解除しました (\(count) 個)")
    }

    /// 選択中のスライドを「曲線に作り直す」(Curve bake)。
    /// 置いた中継点を「形の目安 (制御点)」にして、それに沿った大きくなめらかな曲線 (3 次 B スプライン) を作り、
    /// その曲線がレーンの真ん中を通る拍ごとに、中継点を置き直す (元の中継点は、始点・終点・横に飛ぶ点以外は消える)。
    /// 拍は、曲線から 0.15 レーン以内に収まるいちばん粗い拍 (1/16 → … → 1/384) に合わせる。
    /// 判定点が変わる (スコア・ノーツ数が変わる)。曲線 (curve) の印も付ける (足した点の間も丸く描く)。Undo で戻せる
    func bakeCurve() {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        let ids = selectedIDs
        let idx = chart.notes.indices.filter { ids.contains(chart.notes[$0].id) && chart.notes[$0].isSlide }
        if idx.isEmpty {
            showToast("先にスライドを選択してください")
            return
        }
        var newSegs: [Int: [Seg]] = [:]
        for i in idx {
            let n = chart.notes[i]
            if let segs = Self.bakedSegs(n) { newSegs[i] = segs }
        }
        if newSegs.isEmpty {
            showToast("曲線にできるスライドがありません (中継点が 2 個以上いります)")
            return
        }
        pushUndo()
        for (i, segs) in newSegs {
            chart.notes[i].segs = segs
            chart.notes[i].extra[Beatrix.curveKey] = true
        }
        chartChanged()
        showToast("曲線に作り直しました (\(newSegs.count) 本。判定点が変わります。Undo で戻せます)")
    }

    /// 1 本のスライドを曲線に作り直した seg。作り直せなければ nil
    static func bakedSegs(_ n: Note) -> [Seg]? {
        var beats: [Beat] = [n.beat]
        var lanes: [Int] = [Beatrix.block(ofX: Double(n.x))]
        for sg in n.segs {
            beats.append(n.beat + sg.beat)
            lanes.append(Beatrix.block(ofX: Double(n.x + sg.x)))
        }
        guard beats.count >= 3, zip(beats, beats.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        let xs = beats.map { $0.value }
        // 横に飛ぶ線 (時間 0 の区間) で区切って、ひと続きごとに曲線にする
        var pieces: [[Int]] = [[0]]
        for k in 1..<beats.count {
            if beats[k] == beats[k - 1] { pieces.append([k]) } else { pieces[pieces.count - 1].append(k) }
        }
        var out: [Seg] = []
        func addOriginal(_ k: Int) {
            if k == 0 { return }
            out.append(n.segs[k - 1])
        }
        var changed = false
        for (pi, piece) in pieces.enumerated() {
            if pi > 0 { addOriginal(piece[0]) }               // 横に飛んだ先の点はそのまま
            guard piece.count >= 3 else {
                for k in piece.dropFirst() { addOriginal(k) }
                continue
            }
            let samples = Beatrix.bSplineSamples(piece.map { xs[$0] }, piece.map { Double(lanes[$0]) })
            func valueAt(_ t: Double) -> Double {
                var j = 1
                while j < samples.count - 1 && samples[j].t < t { j += 1 }
                let p = samples[j - 1]
                let q = samples[j]
                let h = q.t - p.t
                return h <= 1e-12 ? q.v : p.v + (q.v - p.v) * min(1, max(0, (t - p.t) / h))
            }
            let endBeat = beats[piece[piece.count - 1]]
            var lastBeat = beats[piece[0]]
            var lastLane = lanes[piece[0]]
            for j in 1..<samples.count {
                let (t1, v1) = (samples[j - 1].t, samples[j - 1].v)
                let (t2, v2) = (samples[j].t, samples[j].v)
                let lo = Int(min(v1, v2).rounded(.up))
                let hi = Int(max(v1, v2).rounded(.down))
                if lo > hi { continue }
                let order: [Int] = v2 >= v1 ? Array(lo...hi) : Array((lo...hi).reversed())
                for L in order {
                    if Double(L) == v1 { continue }           // 前の区切りで数えた
                    let target = t1 + (t2 - t1) * (Double(L) - v1) / (v2 - v1)
                    // 同じレーンが続くときは、少し (1/32 拍) 離れているときだけ置く (平らな区間の終わり)
                    if L == lastLane && target - lastBeat.value < 1.0 / 32 { continue }
                    var put: Beat? = nil
                    var bestErr = Double.greatestFiniteMagnitude
                    for den in [16, 32, 48, 64, 96, 192, 384] {
                        let c = Beat.nearest(target, den: den)
                        guard lastBeat < c && c < endBeat else { continue }
                        let err = abs(valueAt(c.value) - Double(L))
                        if err < bestErr {
                            bestErr = err
                            put = c
                        }
                        if err <= 0.15 { break }
                    }
                    if let c = put {
                        out.append(Seg(beat: c - n.beat, x: Beatrix.centerX(ofBlock: L) - n.x))
                        lastBeat = c
                        lastLane = L
                        changed = true
                    }
                }
            }
            addOriginal(piece[piece.count - 1])               // 終わりの点はそのまま
        }
        // 元と同じ点の数・位置なら作り直していない
        if !changed && out.count == n.segs.count { return nil }
        return out
    }

    // MARK: 区間ごとの曲がり方 (ease)

    func toggleEaseTool() {
        editing = true
        toggleTool(.ease)
        if tool == .ease {
            showToast("スライドの帯 (点と点の間) をタップすると、その区間の曲がり方を選べます")
        }
    }

    /// Ease ツールでレーンをタップしたとき: 触れた帯の区間を探して、選ぶダイアログを出す
    func easeTap(at p: CGPoint, g: LaneGeo) {
        let tb = g.beatOf(p.y)
        var best: (id: UUID, seg: Int, d: CGFloat)? = nil
        for n in chart.notes where n.isSlide {
            let hw = CGFloat(n.w) / 255.0 * g.trackW / 2.0
            var bs: [Double] = [n.beat.value]
            var xs: [Double] = [Double(n.x)]
            for s in n.segs {
                bs.append(n.beat.value + s.beat.value)
                xs.append(Double(n.x + s.x))
            }
            let es = Beatrix.eases(n)
            for k in 0..<(bs.count - 1) {
                let lo = min(bs[k], bs[k + 1])
                let hi = max(bs[k], bs[k + 1])
                guard hi - lo > 1e-9, tb >= lo, tb <= hi else { continue }
                let u = (tb - bs[k]) / (bs[k + 1] - bs[k])
                let x = xs[k] + (xs[k + 1] - xs[k]) * Beatrix.easeFraction(es[k], u)
                let d = abs(g.px(x) - p.x)
                guard d <= hw + 14 else { continue }
                if best == nil || d < best!.d { best = (n.id, k, d) }
            }
        }
        guard let b = best else {
            showToast("スライドの帯 (点と点の間) をタップしてください")
            return
        }
        selectedIDs = [b.id]
        easeTarget = EaseTarget(noteID: b.id, seg: b.seg)
    }

    /// 選んだ曲がり方を付ける。all = true なら、そのスライドの全区間に
    func setEase(_ e: Int, all: Bool) {
        guard let t = easeTarget, let i = chart.notes.firstIndex(where: { $0.id == t.noteID }), chart.notes[i].isSlide else {
            easeTarget = nil
            return
        }
        easeTarget = nil
        var es = Beatrix.eases(chart.notes[i])
        if all {
            es = es.map { _ in e }
        } else if t.seg < es.count {
            es[t.seg] = e
        }
        pushUndo()
        if es.contains(where: { $0 != 0 }) {
            chart.notes[i].extra[Beatrix.easeKey] = es
        } else {
            chart.notes[i].extra.removeValue(forKey: Beatrix.easeKey)
        }
        chartChanged()
        let name = ["まっすぐ", "Ease In", "Ease Out"][max(0, min(2, e))]
        showToast(all ? "このスライドの全区間を「\(name)」にしました" : "区間 \(t.seg + 1) を「\(name)」にしました")
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

    /// Slide ボタン: 作成中なら「完」。
    /// それ以外: オフ → Slide (前回の 始点あり / なし のまま) → 押すと 始点あり / なし が入れ替わる → もう一度押すとオフ。
    /// 始点なしにしたら、自分で始点ありに戻すまで、次に Slide を選んだときも始点なしのまま (アイコンも変わる)
    func slideButtonTapped() {
        if slideDraft != nil {
            finishSlide()
        } else if tool != .slide {
            tool = .slide
            slideModeToggled = false
            showToast(slideWithHead ? "スライド (始点あり): 始点 → 経由点を順にタップ → 完"
                                    : "スライド (始点なし): 始点 → 経由点を順にタップ → 完")
        } else if !slideModeToggled {
            slideWithHead.toggle()
            slideModeToggled = true
            showToast(slideWithHead ? "始点ありに切り替えました" : "始点なしに切り替えました")
        } else {
            tool = .unselected
        }
    }

    /// 同時押し: 1 本目の指とは別に、2 本目以降の指でタップしたとき (Tap / Red / Wipe のとき)
    func placeTapAt(_ p: CGPoint, size: CGSize) {
        guard !isPlaying, tool == .note || tool == .red || tool == .wipe else { return }
        let g = geo(size)
        if hitNote(at: p, g: g) != nil { return }           // ノーツの上なら置かない (1 本目と同じく、選択の操作とみなす)
        let b = placeBeat(p.y, g)
        let q = snapNote(centerX: g.xOf(p.x), widthUnits: widthUnits)
        addNote(Note(beat: b, x: q.x, w: q.w, type: tool == .wipe ? 4 : (tool == .red ? 3 : nil)))
    }

    // MARK: 歌詞 (lyrics)

    /// Lyrics ツールでレーンをタップしたとき。
    /// 既にある歌詞の区間の中をタップ → その歌詞の編集 (文字の変更・削除) / それ以外 → 1 回目が始点、2 回目が終点 (文字を入れる)
    func lyricsTap(beat b: Beat) {
        if isPlaying {
            showToast("再生中は編集できません。停止してから操作してください")
            return
        }
        if let s = lyricsStart {
            lyricsStart = nil
            if s == b {
                showToast("始点と同じ位置です。もう一度、始点からタップしてください")
                return
            }
            lyricEdit = LyricEdit(index: nil, start: min(s, b), end: max(s, b), text: "")
            return
        }
        let list = chart.bxLyrics
        // 中をタップした歌詞 (重なっているときは、あとから始まるほう)
        if let i = list.indices.last(where: { list[$0].start <= b && b < list[$0].end }) {
            lyricEdit = LyricEdit(index: i, start: list[i].start, end: list[i].end, text: list[i].text)
            return
        }
        lyricsStart = b
        showToast("歌詞の始点を置きました。終点をタップしてください")
    }

    /// ダイアログの OK
    func commitLyric(_ text: String) {
        guard let e = lyricEdit else { return }
        lyricEdit = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = chart.bxLyrics
        if t.isEmpty {
            if let i = e.index, i < list.count {
                pushUndo()
                list.remove(at: i)
                chart.bxLyrics = list
                chartChanged()
                showToast("歌詞を消しました")
            } else {
                showToast("歌詞が空なので、置きませんでした")
            }
            return
        }
        pushUndo()
        if let i = e.index, i < list.count {
            list[i].text = t
        } else {
            list.append(BeatrixLyric(start: e.start, end: e.end, text: t))
        }
        chart.bxLyrics = list
        chartChanged()
        showToast("歌詞「\(t)」(\(e.start.label) 〜 \(e.end.label))")
    }

    /// ダイアログの 削除
    func deleteLyric() {
        guard let e = lyricEdit, let i = e.index else { lyricEdit = nil; return }
        lyricEdit = nil
        var list = chart.bxLyrics
        guard i < list.count else { return }
        pushUndo()
        list.remove(at: i)
        chart.bxLyrics = list
        chartChanged()
        showToast("歌詞を消しました")
    }

    func toggleLyricsTool() {
        editing = true
        toggleTool(.lyrics)
        if tool == .lyrics {
            showToast("始点 → 終点の順にレーンをタップすると、その間に出す歌詞を入れられます (歌詞の区間の中をタップで編集・削除)")
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
        return chartDir.appendingPathComponent(Beatrix.safeFileName("\(t)(\(d.abbr))") + ".json")
    }

    func hasChart(for d: BeatrixDifficulty) -> Bool {
        FileManager.default.fileExists(atPath: chartURL(for: d).path)
    }

    /// 難易度を切り替える。今の譜面を保存してから、
    ///   その難易度のファイルがあれば → それを開く
    ///   無ければ → copyNotes が true なら今のノーツをコピー、false なら空の譜面で「曲名(XX).json」を作る
    /// (BPM・offset・曲名・part などはそのまま引き継ぐ。開いた譜面に part が無いときも、今の part を入れる)
    func switchDifficulty(to d: BeatrixDifficulty, copyNotes: Bool) {
        if d == chart.bxDifficulty { return }
        if isPlaying { pause() }
        saveNow()
        let url = chartURL(for: d)
        let curParts = chart.bxParts
        if let data = try? Data(contentsOf: url), var c = try? ChartData.parseBeatrix(data) {
            // 開く譜面に part が 1 つも無ければ、今の譜面の part を引き継ぐ (part (サビ) はどの難易度も同じなので)
            var note = ""
            if c.bxParts.isEmpty && !curParts.isEmpty {
                c.bxParts = curParts
                note = "\npart を \(curParts.count) 個引き継ぎました"
            }
            replaceChart(c, url: url)
            if !note.isEmpty { saveNow() }
            showToast("\(d.label) の譜面を開きました (\(url.lastPathComponent))" + note)
            return
        }
        // 新しく作るときは、曲の情報・BPM・ソフラン・part はそのまま。空から作る場合はノーツだけ消す
        var c = chart
        c.bxDifficulty = d
        c.bxParts = curParts
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
        lyricsStart = nil
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
                    .lineLimit(1)
                    .fixedSize()                          // 縮めない (「...」にしない)
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

// MARK: - BPM・offset の自動検出のダイアログ (画面の真ん中)

struct TempoDetectDialog: View {
    @ObservedObject var state: EditorState
    @State private var pick = 0
    @State private var useBPM = true
    @State private var useOffset = true
    @State private var shiftBeats = 0.0
    @State private var shiftText = ""

    var body: some View {
        if let phase = state.tempoDetect {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("BPM・offset の自動検出")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    content(phase)
                }
                .padding(22)
                .frame(width: 460)
                .background(Color(white: 0.1).opacity(0.97))
                .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private func content(_ phase: TempoDetectPhase) -> some View {
        switch phase {
        case .running:
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("曲を解析しています…")
                    .foregroundColor(.white)
            }
            HStack {
                Spacer()
                button("やめる", primary: false) { state.cancelTempoDetect() }
            }
        case .failed(let msg):
            Text(msg)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                button("閉じる", primary: false) { state.cancelTempoDetect() }
            }
        case .done(let a):
            resultView(a)
        }
    }

    @ViewBuilder
    private func resultView(_ a: BeatrixTempoAnalysis) -> some View {
        let idx = min(pick, max(0, a.candidates.count - 1))
        let bpm = a.candidates.isEmpty ? a.rawBPM : a.candidates[idx]
        let raw = a.offsetRaw(bpm: bpm, shiftBeats: shiftBeats)
        VStack(alignment: .leading, spacing: 8) {
            Text("BPM (左がおすすめ。倍・半分の取り違えがあるので、曲に合うほうを選んでください)")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(a.candidates.enumerated()), id: \.offset) { e in
                    Button {
                        pick = e.offset
                    } label: {
                        Text(Beatrix.speedLabel(e.element))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(e.offset == idx ? .black : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(e.offset == idx ? Color(red: 0.4, green: 0.85, blue: 1) : Color.clear)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(String(format: "解析の値: %.3f", a.rawBPM))
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.5))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("offset: \(raw)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(String(format: "0 拍目 = 曲の %.3f 秒 (+ 再生の補正 %d ms = 今の基準)",
                        Double(raw - Beatrix.playbackCorrectionMs) / Beatrix.offsetSampleRate, Beatrix.playbackCorrectionMs))
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.7))
            // 0 拍目をずらす (何拍でも。+ で曲の後ろへ、− で前へ)
            Text("0 拍目をずらす: \(Self.beatsLabel(shiftBeats)) 拍  (+ で曲の後ろへ / − で前へ)")
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.top, 4)
            HStack(spacing: 6) {
                small("-1") { setShift(shiftBeats - 1) }
                small("-0.5") { setShift(shiftBeats - 0.5) }
                small("0") { setShift(0) }
                small("+0.5") { setShift(shiftBeats + 0.5) }
                small("+1") { setShift(shiftBeats + 1) }
            }
            HStack(spacing: 6) {
                TextField("拍を入力 (例: 2 / -1.5 / 1/4)", text: $shiftText)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
                    .onSubmit { applyShiftText() }
                small("決定") { applyShiftText() }
            }
            if raw - Beatrix.playbackCorrectionMs < 0 {
                Text("0 拍目が曲の始まり (0 秒) より前になっています (offset がマイナス寄り)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1, green: 0.6, blue: 0.4))
            }
        }
        if let hint = a.changeHint {
            Text("⚠︎ " + hint)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 1, green: 0.8, blue: 0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("BPM を入れる", isOn: $useBPM).foregroundColor(.white)
        Toggle("offset を入れる", isOn: $useOffset).foregroundColor(.white)
        if !state.chart.notes.isEmpty && useBPM {
            Text("ノーツがある譜面です。BPM を変えると、ノーツの時刻 (秒) もずれます")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 1, green: 0.5, blue: 0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("検出は目安です。入れたあと、再生してノーツ音と曲が合っているか確かめてください (Information の ±10ms で微調整できます)")
            .font(.system(size: 11))
            .foregroundColor(Color.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Spacer()
            button("キャンセル", primary: false) { state.cancelTempoDetect() }
            button("入れる", primary: true) {
                state.applyTempoDetect(bpm: useBPM ? bpm : nil, offsetRaw: useOffset ? raw : nil)
            }
        }
        .onAppear {
            // 結果が出るたびに、選択を初期値に戻す
            pick = 0
            useBPM = true
            useOffset = true
            shiftBeats = 0
            shiftText = ""
        }
    }

    private func setShift(_ v: Double) {
        let r = (v * 1000).rounded() / 1000
        shiftBeats = abs(r) < 1e-9 ? 0 : r
        shiftText = Self.beatsLabel(shiftBeats)
    }

    /// 入力欄の拍: "2" / "-1.5" / "1/4" / "-3/2" / "+0.25"
    private func applyShiftText() {
        let t = shiftText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "ー", with: "-")
        var v: Double? = nil
        if t.contains("/") {
            let ps = t.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
            if ps.count == 2, let n = Double(ps[0]), let d = Double(ps[1]), d != 0 { v = n / d }
        } else {
            v = Double(t)
        }
        if let v = v, v.isFinite, abs(v) <= 10000 {
            setShift(v)
        } else {
            state.showToast("拍は 2 / -1.5 / 1/4 のように入力してください")
        }
    }

    static func beatsLabel(_ v: Double) -> String {
        let s = Beatrix.speedLabel(v)
        return v > 0 ? "+" + s : s
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(primary ? .black : .white)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(primary ? Color.white : Color.clear)
                .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

/// Ease ツールでタップしたスライドの区間
struct EaseTarget: Identifiable {
    let id = UUID()
    let noteID: UUID
    let seg: Int
}
