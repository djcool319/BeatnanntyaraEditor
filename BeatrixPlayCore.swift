import Foundation

// MARK: - びーとり式テストプレイの中身 (判定とノーツ生成。画面は BeatrixPlayView.swift)
//
// 本家 (Unity) の NotesGenerate.cs と keyjudge.cs を、そのまま Swift に移したもの。
// 譜面は、保存する JSON と同じもの (ChartData.beatrixNotes) から作るので、本家と同じノーツになる。
//
//   ノーツの種類 (判定用の type)
//     1 = 白タップ / 2 = ホールド・スライドの始点タップ / 3 = 赤タップ / 4 = ワイプ / 5 = ホールド・スライドの判定点 (見えない)
//   ・ホールド (子がすべて同じ block): 始点から半拍ごとに判定点 (+0.02 秒)。終点ちょうどには置かない
//   ・スライド (子に別の block がある): 始点と経由点に判定点
//   ・白タップの直前 0.16 秒以内に、同じボタンの範囲のワイプ / 判定点があれば、そのタップは GREAT / MISS を出さない
//
//   ボタンは 4 つ (左 / 中央左 / 中央右 / 右)。押した瞬間に取れるレーン、押している間に取れるレーンは本家と同じ
//   判定の幅 (秒、ずれ = 押した時刻 − ノーツの時刻)
//     白タップ: ±0.03 PERFECT+ / ±0.06 PERFECT / −0.11〜+0.09 GREAT / ±0.13 MISS
//     始点タップ: ±0.06 PERFECT+ / −0.11〜+0.09 GREAT / ±0.13 MISS
//     赤タップ: ±0.075 PERFECT+ (それ以外は押しても取れない)
//     縦連 (同じレーンの速い連打。下の markTateren): ±0.06 まで PERFECT+。GREAT / MISS の幅で押しても何もしない (スルー)
//   押した瞬間は、本家の CheckJudgementCore と同じ順番で判定する (2026-10-20 本家に合わせた):
//     1) PERFECT の幅のダミーが本物より近ければ、ダミーを消すだけ
//     2) 本物の候補 (白・始点 ±0.13 / 赤 ±0.075) を「PERFECT の幅に入っているもの (時刻の早い順) → それ以外 (近い順)」に並べて、順に判定
//        ・縦連で PERFECT の幅の外 → ここで終わり (何もしない)
//        ・同じレーンの縦連を取ってから 0.1 秒以内で、PERFECT の幅の外 → 終わり (多重反応の対策)
//        ・何かを取ってから 0.1 秒以内で、白・始点を 0.11 秒より早く押した (MISS になる所) → 終わり (多重反応の対策)
//     3) 本物が何も取れなかったら、範囲の中のダミーを 1 つ消す
//     ワイプ・判定点: 押している間に ±0.12 で PERFECT+
//     見逃し: タップ系は +0.09、ワイプ・判定点は +0.12 を過ぎたら MISS
//   ※ 時刻は BPM 変化 (bpms) も入れて計算する (エディタと同じ)。本家の NotesGenerate は今 BPM だけで計算している

enum BxJudge {
    case perfectPlus, perfect, great, miss
}

struct BxNote {
    let t: Double
    let lane: Int
    let type: Int
    var sp: Double = 1                     // ノーツ個別の速さ (speeds_each)
    var dummy = false                      // ダミー (判定なし。取れば消えるだけ)
    var vis: [[BxVisEvent]] = []           // 出現 / 消える。どれか 1 つの列で見えていれば見える (空なら いつも見える)
    var suppressed = false
    var tateren = false                    // 縦連 (本家の NotesGenerate.MarkTaterenNotes と同じ印)
    var lightTateren = false
    var multi = false                      // 多重 (同じ時刻・同じレーンに白タップ / タップの始点が 2 個以上)。ピンクで描く               // 軽い縦連 (BPM140 の 16 分 + 2ms 以内。指のずれから拾ったタップでも取れるだけ)
    var done = false
    var missed = false                     // 見逃した (本家と同じく、判定ラインを過ぎても流れ続ける)
}

struct BxHold {
    let t0: Double
    let t1: Double
    let lane: Int
    var sp: Double = 1
    var dummy = false
    var vis: [[BxVisEvent]] = []
}

/// 見え方の切り替え (時刻と、見える / 見えない)
struct BxVisEvent {
    let t: Double
    let show: Bool
}

/// 見えるか。列ごとに: 最初の切り替えが「出現」ならそれまでは見えない、「消える」ならそれまでは見える。あとは切り替えのとおり。
/// 列が複数あるとき (同じ位置のスライド 2 本が 1 つの始点を使っているとき) は、どれか 1 つで見えていれば見える
func bxVisible(at t: Double, _ vis: [[BxVisEvent]]) -> Bool {
    if vis.isEmpty { return true }
    for list in vis {
        guard let first = list.first else { return true }
        var v = !first.show
        for e in list {
            if e.t > t { break }
            v = e.show
        }
        if v { return true }
    }
    return false
}

struct BxSlidePoint {
    let t: Double
    let lane: Int
}

/// 帯を描くための点 (横の位置はレーンの左端 = 0 / 右端 = 1)
struct BxDrawPoint {
    let t: Double
    let f: Double
}

struct BxSlide {
    let pts: [BxSlidePoint]
    var draw: [BxDrawPoint] = []           // 描く形 (曲線スライドは細かい点。ふつうは経由点そのまま)
    var sp: Double = 1
    var dummy = false
    var vis: [[BxVisEvent]] = []
}

/// 同時押しの線 (2 つのレーンが 2 以上離れているとき)
struct BxSim {
    let t: Double
    let a: Int
    let b: Int
    var sp: Double = 1
    var ia = 0                    // つないでいるノーツ (BxPlayChart.notes / BxGame.notes の番号)
    var ib = 0
}

/// ソフラン (speeds) の 1 区間: 時刻 t から速さ speed。pos = その時刻までに流れた量 (速さ 1 なら秒と同じ)
struct BxScroll {
    let t: Double
    let pos: Double
    let speed: Double
}

struct BxPlayChart {
    var notes: [BxNote] = []
    var holds: [BxHold] = []
    var slides: [BxSlide] = []
    var sims: [BxSim] = []
    var beats: [Double] = []
    var parts: [(start: Double, end: Double)] = []
    /// 歌詞 (始まりの時刻順)。start <= 今 < end の間だけ text を出す
    var lyrics: [(start: Double, end: Double, text: String)] = []
    var endTime: Double = 0
    /// ソフラン。時刻順。空なら全部 1 倍
    var scroll: [BxScroll] = []

    /// 時刻 t までに流れた量 (ソフランを入れた「位置」)。ノーツの見た目の奥行きは (pos(ノーツ) − pos(今)) × 速さ
    func pos(_ t: Double) -> Double {
        if scroll.isEmpty || t <= scroll[0].t { return t }
        var lo = 0
        var hi = scroll.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if scroll[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let s = scroll[lo]
        return s.pos + (t - s.t) * s.speed
    }

    /// ボタンごとの範囲 (本家の ButtonZones)。黄色直後のタップの抑制に使う
    static let buttonZones: [[Int]] = [[0, 1, 2], [1, 2, 3, 4], [2, 3, 4, 5], [4, 5, 6]]

    static func make(from chart: ChartData) -> BxPlayChart {
        let tm = TimeMap(chart.times)
        func sec(_ d: [String: Any]) -> Double { tm.sec(atBeat: Beatrix.beat(of: d).value) }
        func block(_ d: [String: Any]) -> Int { max(0, min(6, Beatrix.intValue(d["block"]) ?? 0)) }
        func kids(_ d: [String: Any]) -> [[String: Any]] { (d["notes"] as? [[String: Any]]) ?? [] }

        let entries = chart.beatrixEntries()
        let raw = entries.map { $0.dict }
        var out = BxPlayChart()

        // ノーツ個別の速さ・ダミー (ノーツごと。始点の表記は、同じ位置のスライド / ホールドに付いていく)
        func spOf(_ idx: Int) -> Double {
            let e = entries[idx]
            if e.isHead { return e.bodies.first.flatMap { Beatrix.noteSpeed($0) } ?? 1 }
            return e.source.flatMap { Beatrix.noteSpeed($0) } ?? 1
        }
        func dummyOf(_ idx: Int) -> Bool {
            let e = entries[idx]
            if e.isHead { return !e.bodies.isEmpty && e.bodies.allSatisfy { Beatrix.isDummy($0) } }   // 始点は、全部の本体がダミーのときだけダミー
            return e.source.map { Beatrix.isDummy($0) } ?? false
        }

        // 出現 / 消える (ノーツごと。始点の表記は、同じ位置のスライド / ホールドに付いていく)
        func visList(_ n: Note) -> [BxVisEvent] {
            Beatrix.visEvents(n).map { BxVisEvent(t: tm.sec(atBeat: $0.beat.value), show: $0.show) }
        }
        func visOf(_ idx: Int) -> [[BxVisEvent]] {
            let e = entries[idx]
            if e.isHead {
                let sets = e.bodies.map { visList($0) }
                return sets.contains { $0.isEmpty } ? [] : sets
            }
            guard let n = e.source else { return [] }
            let l = visList(n)
            return l.isEmpty ? [] : [l]
        }

        // ソフラン (speeds): 0 拍目より前は 1 倍
        var sps: [(t: Double, speed: Double)] = []
        for e in chart.effects.sorted(by: { $0.beat < $1.beat }) where e.kind == .scroll {
            let t = tm.sec(atBeat: e.beat.value)
            if let last = sps.last, abs(last.t - t) < 1e-9 {
                sps[sps.count - 1].speed = e.value
            } else {
                sps.append((t: t, speed: e.value))
            }
        }
        if !sps.isEmpty {
            var pos = sps[0].t
            for (i, p) in sps.enumerated() {
                if i > 0 { pos += (p.t - sps[i - 1].t) * sps[i - 1].speed }
                out.scroll.append(BxScroll(t: p.t, pos: pos, speed: p.speed))
            }
        }

        // ホールド始点 (子のある type 2) の位置。同じ位置の白タップは「始点タップ」(type 2) になる
        var holdStarts = Set<BeatrixKey>()
        for n in raw where (Beatrix.intValue(n["type"]) ?? 1) == 2 && !kids(n).isEmpty {
            holdStarts.insert(BeatrixKey(beat: Beatrix.beat(of: n), block: block(n)))
        }

        for (idx, n) in raw.enumerated() {
            let type = Beatrix.intValue(n["type"]) ?? 1
            if type == 2 { continue }                      // 本体 (子あり) は下で。子の無い type 2 は本家でも使っていない
            let blk = block(n)
            var tp = type
            if type == 1 && holdStarts.contains(BeatrixKey(beat: Beatrix.beat(of: n), block: blk)) { tp = 2 }
            if tp < 1 || tp > 4 { tp = 1 }
            out.notes.append(BxNote(t: sec(n), lane: blk, type: tp, sp: spOf(idx), dummy: dummyOf(idx), vis: visOf(idx)))
        }

        for (idx, n) in raw.enumerated() where (Beatrix.intValue(n["type"]) ?? 1) == 2 && !kids(n).isEmpty {
            let ks = kids(n)
            let blk = block(n)
            let isSlide = ks.contains { block($0) != blk }
            let dm = dummyOf(idx)
            if !isSlide {
                // ホールド: 半拍ごとに判定点
                let startBeat = Beatrix.beat(of: n).value
                guard let last = ks.last else { continue }
                let endBeat = Beatrix.beat(of: last).value
                if endBeat <= startBeat { continue }
                out.holds.append(BxHold(t0: sec(n), t1: sec(last), lane: blk, sp: spOf(idx), dummy: dm, vis: visOf(idx)))
                var curLane = blk
                var curBeat = startBeat
                for k in ks {
                    let eb = Beatrix.beat(of: k).value
                    out.notes.append(BxNote(t: tm.sec(atBeat: curBeat) + 0.02, lane: curLane, type: 5, dummy: dm))
                    var j = 1
                    while j < 100_000 {
                        let b = curBeat + Double(j) * 0.5
                        if b >= eb - 0.0001 { break }
                        out.notes.append(BxNote(t: tm.sec(atBeat: b) + 0.02, lane: curLane, type: 5, dummy: dm))
                        j += 1
                    }
                    curLane = block(k)
                    curBeat = eb
                }
            } else {
                // スライド: 始点と経由点に判定点
                var pts = [BxSlidePoint(t: sec(n), lane: blk)]
                for k in ks { pts.append(BxSlidePoint(t: sec(k), lane: block(k))) }
                // 描く形: 曲線スライドは経由点をなめらかにつないだ細かい点、ふつうは経由点そのまま (判定点は経由点のまま)
                let frac = { (lane: Int) -> Double in Double(3 + 2 * lane) / 18.0 }
                var draw = pts.map { BxDrawPoint(t: $0.t, f: frac($0.lane)) }
                if let src = entries[idx].source, Beatrix.isCurve(src) || Beatrix.hasEase(src) {
                    draw = Beatrix.slideShape(pts.map { $0.t }, pts.map { frac($0.lane) }, eases: Beatrix.eases(src),
                                              curve: Beatrix.isCurve(src), laneUnit: 2.0 / 18.0).map { BxDrawPoint(t: $0.x, f: $0.y) }
                }
                out.slides.append(BxSlide(pts: pts, draw: draw, sp: spOf(idx), dummy: dm, vis: visOf(idx)))
                for p in pts { out.notes.append(BxNote(t: p.t, lane: p.lane, type: 5, dummy: dm)) }
            }
        }

        out.notes.sort { $0.t < $1.t }

        // 黄色 (ワイプ / 判定点) の直後 0.16 秒以内のタップは、GREAT / MISS を出さない
        //   (ダミーは判定が無いので、抑える側にも抑えられる側にもならない)
        for i in out.notes.indices where out.notes[i].type == 1 && !out.notes[i].dummy {
            var j = i - 1
            while j >= 0 && out.notes[i].t - out.notes[j].t <= 0.16 {
                let o = out.notes[j]
                let gap = out.notes[i].t - o.t
                if (o.type == 4 || o.type == 5) && !o.dummy && gap > 0 && sameZone(out.notes[i].lane, o.lane) {
                    out.notes[i].suppressed = true
                    break
                }
                j -= 1
            }
        }

        markTateren(&out.notes)

        // 多重: 同じ時刻 (1ms 以内)・同じレーンの白タップ / タップの始点が 2 個以上
        var multiCount: [String: [Int]] = [:]
        for (i, n) in out.notes.enumerated() where n.type == 1 || n.type == 2 {
            multiCount["\(Int((n.t * 1000).rounded()))-\(n.lane)", default: []].append(i)
        }
        for (_, idx) in multiCount where idx.count >= 2 {
            for i in idx { out.notes[i].multi = true }
        }

        // 同時押しの線 (判定点は除く)
        //   (ノーツ個別の速さが違うノーツどうしは、流れてくる位置が違うので線を引かない)
        //   線の時刻は、丸めた値ではなくノーツの時刻そのものを使う (ソフランが強いと、丸めの差でも線がずれて見えるため)。
        //   線は、つないでいるノーツのどちらかが見えなくなったら (取った / 出現前 / 消えたあと) 消す
        struct SimKey: Hashable { let ms: Int; let sp: Double }
        var groups: [SimKey: [Int]] = [:]
        for (i, n) in out.notes.enumerated() where n.type != 5 {
            groups[SimKey(ms: Int((n.t * 1000).rounded()), sp: n.sp), default: []].append(i)
        }
        for (k, idx) in groups where idx.count >= 2 {
            for a in 0..<idx.count {
                for b in (a + 1)..<idx.count {
                    let na = out.notes[idx[a]]
                    let nb = out.notes[idx[b]]
                    if abs(na.lane - nb.lane) <= 1 { continue }
                    out.sims.append(BxSim(t: na.t, a: na.lane, b: nb.lane, sp: k.sp, ia: idx[a], ib: idx[b]))
                }
            }
        }

        var end = out.notes.last?.t ?? 0
        for h in out.holds { end = max(end, h.t1) }
        for s in out.slides { if let l = s.pts.last { end = max(end, l.t) } }
        out.endTime = end

        // 1 拍ごとの線
        var b = 0
        while b < 100_000 {
            let t = tm.sec(atBeat: Double(b))
            if t > end + 4 { break }
            out.beats.append(t)
            b += 1
        }

        out.parts = chart.bxParts.map { (start: tm.sec(atBeat: $0.start.value), end: tm.sec(atBeat: $0.end.value)) }
        out.lyrics = chart.bxLyrics.map { (start: tm.sec(atBeat: $0.start.value), end: tm.sec(atBeat: $0.end.value), text: $0.text) }
        return out
    }

    /// 縦連の印 (本家の NotesGenerate.MarkTaterenNotes と同じ)
    ///   1) 同じレーンで、隣との間隔が BPM200 の 16 分 (75ms) + 2ms 以内 → 縦連の核
    ///   2) 核の前後へ、間隔が「核のいちばん狭い間隔 × 1.5 + 3ms」以内のあいだ広げる
    ///   3) つながりの中で「前とつながっているノーツ」が縦連 (いちばん最初の 1 個は普通のノーツ扱い)
    ///   対象は白タップ・始点・赤タップ (ダミーは除く)。同じレーン・同じ時刻のノーツは 1 つとして数える
    static func markTateren(_ notes: inout [BxNote]) {
        let gapSec = 60.0 / 200.0 / 4.0 + 0.002
        for lane in 0..<7 {
            var idx: [Int] = []
            for i in notes.indices where notes[i].lane == lane && (1...3).contains(notes[i].type) && !notes[i].dummy {
                idx.append(i)
            }
            if idx.count < 2 { continue }
            idx.sort { notes[$0].t < notes[$1].t }
            var times: [Double] = []
            var groups: [[Int]] = []
            for i in idx {
                if let last = times.last, notes[i].t - last <= 0.0005 {
                    groups[groups.count - 1].append(i)
                    continue
                }
                times.append(notes[i].t)
                groups.append([i])
            }
            let n = times.count
            if n < 2 { continue }
            var linked = [Bool](repeating: false, count: n - 1)
            var a0 = 0
            while a0 < n - 1 {
                if times[a0 + 1] - times[a0] > gapSec { a0 += 1; continue }
                var b0 = a0
                var minGap = times[a0 + 1] - times[a0]
                while b0 + 1 < n - 1 && times[b0 + 2] - times[b0 + 1] <= gapSec {
                    b0 += 1
                    minGap = min(minGap, times[b0 + 1] - times[b0])
                }
                for k in a0...b0 { linked[k] = true }
                let limit = minGap * 1.5 + 0.003
                var k = a0 - 1
                while k >= 0 && times[k + 1] - times[k] <= limit { linked[k] = true; k -= 1 }
                k = b0 + 1
                while k < n - 1 && times[k + 1] - times[k] <= limit { linked[k] = true; k += 1 }
                a0 = b0 + 1
            }
            for k in 1..<n where linked[k - 1] {
                for i in groups[k] { notes[i].tateren = true }
            }
            // 軽い縦連: 縦連じゃないところで、前のノーツとの間隔が BPM140 の 16 分 + 2ms 以内 (最初の 1 個は外す)
            let lightGap = 60.0 / 140.0 / 4.0 + 0.002
            for k in 1..<n where !linked[k - 1] && times[k] - times[k - 1] <= lightGap {
                for i in groups[k] where !notes[i].tateren { notes[i].lightTateren = true }
            }
        }
    }

    static func sameZone(_ a: Int, _ b: Int) -> Bool {
        buttonZones.contains { $0.contains(a) && $0.contains(b) }
    }
}

/// 判定の本体。時刻はすべて譜面時刻 (秒)
final class BxGame {
    private(set) var notes: [BxNote]
    private(set) var first = 0
    private(set) var perfectPlus = 0
    private(set) var perfect = 0
    private(set) var great = 0
    private(set) var miss = 0
    private(set) var combo = 0
    private(set) var maxCombo = 0
    private(set) var lastJudge: BxJudge? = nil
    private(set) var lastJudgeAt = -Double.infinity
    private(set) var lastEarly: Bool? = nil          // PERFECT / GREAT のとき、早い (true) か遅い (false) か
    /// 音を鳴らすとき (ノーツの type: 1 / 2 = タップ、3 = 赤タップ、4 = ワイプ と、そのノーツの時刻)
    var onSound: ((Int, Double) -> Void)? = nil
    /// 判定が出たとき (タッチエフェクト用): ノーツの type / レーン / 判定 / 早い (true)・遅い (false)・見逃し (nil) / ノーツの時刻
    var onJudge: ((Int, Int, BxJudge, Bool?, Double) -> Void)? = nil

    /// 押した瞬間に取れるレーン (本家の CheckJudgement の引数)。0 = 左 / 1 = 中央左 / 2 = 中央右 / 3 = 右
    static let tapZones: [[Int]] = [[0, 1, 2], [3, 2, 1, 4], [3, 2, 4, 5], [6, 5, 4]]
    /// 押している間に取れるレーン (本家の CheckSlideJudgement の引数)
    static let holdZones: [[Int]] = [[0, 1, 2], [1, 2, 3, 4], [2, 3, 4, 5], [4, 5, 6]]

    /// 判定のあるノーツの数 (ダミーは数えない)
    private(set) var total = 0
    var judged: Int { perfectPlus + perfect + great + miss }

    // MARK: スコア (本家と同じ減点方式)
    //   ・1 ノーツの持ち点は 2。PERFECT+ / PERFECT = 2、GREAT = 1 (−1)、MISS = 0 (−2)
    //   ・スコア = 1,000,000 × 持ち点の合計 ÷ (2 × ノーツ数)
    //   ・AP (GREAT・MISS なし) で、PERFECT (+ じゃない方 = 内部) も 0 なら 1,111,111 (AP+)
    //   ・ランク: 1,111,111 AP+ / 1,000,000 AP / 990,000〜 SS / 980,000〜 S / 940,000〜 AA / 900,000〜 A / 820,000〜 B / 750,000〜 C / それ未満 D
    //   ・クリアは 900,000 以上。左のゲージは「到達可能なスコア」で、1,000,000 以上で満タン、900,000 で 0

    /// 今まで取った分のスコア (途中経過。内部 0 の AP+ のままなら 1,111,111 満点の割合で数える)
    var score: Int {
        guard total > 0 else { return 0 }
        let got = Double(2 * (perfectPlus + perfect) + great)
        let full = (perfect == 0 && great == 0 && miss == 0) ? 1_111_111.0 : 1_000_000.0
        return Int((got / Double(2 * total) * full).rounded(.down))
    }

    /// 到達可能なスコア (今からすべて PERFECT+ を取ったときの最終スコア)
    var achievableScore: Int {
        guard total > 0 else { return 1_111_111 }
        if great == 0 && miss == 0 { return perfect == 0 ? 1_111_111 : 1_000_000 }
        let lost = Double(great + 2 * miss)
        return Int(((Double(2 * total) - lost) / Double(2 * total) * 1_000_000).rounded(.down))
    }

    /// スコアのランク
    static func rank(of score: Int) -> String {
        if score >= 1_111_111 { return "AP+" }
        if score >= 1_000_000 { return "AP" }
        if score >= 990_000 { return "SS" }
        if score >= 980_000 { return "S" }
        if score >= 940_000 { return "AA" }
        if score >= 900_000 { return "A" }
        if score >= 820_000 { return "B" }
        if score >= 750_000 { return "C" }
        return "D"
    }

    /// 到達可能なランク
    var achievableRank: String { Self.rank(of: achievableScore) }

    /// クリアゲージ (0〜1)。到達可能なスコアが 1,000,000 以上で 1、900,000 で 0
    var clearGauge: Double {
        max(0, min(1, Double(achievableScore - 900_000) / 100_000))
    }

    init(chart: BxPlayChart, startTime: Double) {
        var ns = chart.notes
        for i in ns.indices where ns[i].t < startTime { ns[i].done = true }      // 途中から始めるとき、前のノーツは処理済み
        notes = ns
        total = ns.filter { !$0.dummy }.count
        advance()
    }

    private func advance() {
        while first < notes.count && notes[first].done { first += 1 }
    }

    // 多重反応の対策 (本家の keyjudge と同じ)
    private static let doubleTapGuardSec = 0.1
    private var lastLaneHit = [Double](repeating: -999, count: 7)    // そのレーンの縦連を取った時刻
    private var lastAnyHit = -999.0                                    // 何かを取った時刻

    /// PERFECT の幅: 白・始点 ±0.06 / 赤 ±0.075
    private func perfectWindow(_ n: BxNote) -> Double { n.type == 3 ? 0.075 : 0.06 }

    /// ボタンを押した瞬間 (本家の CheckJudgementCore と同じ順番)
    func press(zone: Int, at now: Double) {
        guard zone >= 0 && zone < Self.tapZones.count else { return }
        let lanes = Self.tapZones[zone]
        // 押した時刻の ±0.15 秒の中の、白・始点・赤
        var win: [Int] = []
        var j = first
        while j < notes.count {
            let n = notes[j]
            if n.t - now > 0.15 { break }
            if !n.done && (1...3).contains(n.type) && lanes.contains(n.lane) && now - n.t <= 0.15 { win.append(j) }
            j += 1
        }

        // 1) PERFECT のタイミング (±0.06) のダミーが、本物より近い (同じも含む) なら、ダミーを消すだけ
        var bestDummy: Int? = nil
        var bestDummyLag = Double.infinity
        var bestRealLag = Double.infinity
        for i in win {
            let n = notes[i]
            let a = abs(now - n.t)
            if n.dummy {
                if a <= 0.06 && a < bestDummyLag { bestDummyLag = a; bestDummy = i }
            } else {
                let range = n.tateren ? perfectWindow(n) : (n.type == 3 ? 0.075 : 0.13)
                if a <= range && a < bestRealLag { bestRealLag = a }
            }
        }
        if let d = bestDummy, bestDummyLag <= bestRealLag {
            onSound?(notes[d].type, notes[d].t)
            notes[d].done = true
            advance()
            return
        }

        // 2) 本物: PERFECT の幅に入っているもの (時刻の早い順) → それ以外 (押した時刻に近い順)
        var cand: [(i: Int, lag: Double)] = []
        for i in win where !notes[i].dummy {
            let a = abs(now - notes[i].t)
            if a <= (notes[i].type == 3 ? 0.075 : 0.13) { cand.append((i, a)) }
        }
        cand.sort { x, y in
            let px = x.lag <= perfectWindow(notes[x.i])
            let py = y.lag <= perfectWindow(notes[y.i])
            if px != py { return px }
            if px {
                if notes[x.i].t != notes[y.i].t { return notes[x.i].t < notes[y.i].t }
                return x.i < y.i
            }
            return x.lag != y.lag ? x.lag < y.lag : x.i < y.i
        }
        for c in cand {
            let n = notes[c.i]
            let lag = now - n.t
            if n.tateren && c.lag > perfectWindow(n) { break }                                   // 縦連: スルー
            if now - lastLaneHit[n.lane] < Self.doubleTapGuardSec && c.lag > perfectWindow(n) { break }   // 縦連を取った直後の同じレーン
            let since = now - lastAnyHit
            if since >= -0.05 && since < Self.doubleTapGuardSec && (n.type == 1 || n.type == 2) && lag < -0.11 { break }   // 取った直後の多重で早押し MISS にしない
            if judgeTap(c.i, lag: lag) {
                if n.tateren { lastLaneHit[n.lane] = now }
                lastAnyHit = now
                return
            }
        }

        // 3) 本物が何も取れなかったら、範囲の中のダミーを 1 つ消す (白・始点 ±0.13 / 赤 ±0.075)
        for i in win where notes[i].dummy {
            let n = notes[i]
            if abs(now - n.t) <= (n.type == 3 ? 0.075 : 0.13) {
                onSound?(n.type, n.t)
                notes[i].done = true
                advance()
                return
            }
        }
    }

    /// そのボタンの範囲に、今の前後 window 秒以内の (まだ取っていない) 縦連・軽い縦連のノーツがあるか (本家の HasTaterenNear)
    func hasTaterenNear(zone: Int, at now: Double, window: Double = 0.15) -> Bool {
        guard zone >= 0 && zone < Self.tapZones.count else { return false }
        let lanes = Self.tapZones[zone]
        var i = first
        while i < notes.count {
            let n = notes[i]
            if n.t - now > window { break }
            if !n.done && !n.dummy && (n.tateren || n.lightTateren) && lanes.contains(n.lane) && abs(n.t - now) <= window { return true }
            i += 1
        }
        return false
    }

    /// 指のずれから拾った「縦連専用のタップ」(本家の CheckTaterenOnly): いちばん近い縦連・軽い縦連のノーツが
    /// ±0.05 秒の中にあるときだけ、それを判定する。ほかのノーツ・ダミーには一切さわらない
    func pressTaterenOnly(zone: Int, at now: Double) {
        guard zone >= 0 && zone < Self.tapZones.count else { return }
        let lanes = Self.tapZones[zone]
        var best: Int? = nil
        var bestLag = Double.infinity
        var i = first
        while i < notes.count {
            let n = notes[i]
            if n.t - now > 0.07 { break }
            if !n.done && !n.dummy && (n.tateren || n.lightTateren) && (1...3).contains(n.type) && lanes.contains(n.lane) {
                let a = abs(now - n.t)
                if a <= 0.05 && a < bestLag { bestLag = a; best = i }
            }
            i += 1
        }
        guard let b = best else { return }
        let n = notes[b]
        if judgeTap(b, lag: now - n.t) {
            if n.tateren { lastLaneHit[n.lane] = now }
            lastAnyHit = now
        }
    }

    /// ボタンを押している間 (毎フレーム、押しているボタンごとに 1 回)
    func hold(zone: Int, at now: Double) {
        guard zone >= 0 && zone < Self.holdZones.count else { return }
        let lanes = Self.holdZones[zone]
        var i = first
        while i < notes.count {
            let n = notes[i]
            if n.t - now > 0.12 { break }
            if !n.done && n.dummy && (n.type == 4 || n.type == 5) && lanes.contains(n.lane) && abs(now - n.t) <= 0.12 {
                // ダミー: 消えるだけ (ワイプは音だけ鳴らす)。本物の判定は続けて探す
                if n.type == 4 { onSound?(4, n.t) }
                notes[i].done = true
                i += 1
                continue
            }
            if !n.done && !n.dummy && (n.type == 4 || n.type == 5) && lanes.contains(n.lane) && abs(now - n.t) <= 0.12 {
                if n.type == 4 { onSound?(4, n.t) }
                record(i, .perfectPlus, early: nil)
                return
            }
            i += 1
        }
    }

    /// オート: 時刻が来たノーツを全部 PERFECT+ で取る (ダミーは取らない。見逃しと同じく消えるだけ)
    func auto(to now: Double) {
        var i = first
        while i < notes.count {
            let n = notes[i]
            if n.t > now { break }
            if !n.done && !n.dummy {
                if n.type <= 4 { onSound?(n.type, n.t) }
                record(i, .perfectPlus, early: nil)
            }
            i += 1
        }
        advance()
    }

    /// 毎フレーム: 見逃したノーツを MISS にする
    func update(to now: Double) {
        var i = first
        while i < notes.count {
            let n = notes[i]
            if n.t > now { break }
            if !n.done {
                let late = now - n.t
                if (n.type <= 3 && late > 0.09) || (n.type >= 4 && late > 0.12) {
                    if n.dummy {
                        notes[i].done = true          // ダミーは見逃しても MISS にしない (消えるだけ)
                    } else {
                        record(i, .miss, early: nil)
                    }
                }
            }
            i += 1
        }
        advance()
    }

    private func judgeTap(_ i: Int, lag: Double) -> Bool {
        let n = notes[i]
        let a = abs(lag)
        switch n.type {
        case 1:
            let suppressed = n.suppressed || n.tateren          // 縦連は GREAT / MISS の幅で押しても何もしない
            if a <= 0.03 || (n.tateren && a <= 0.06) {
                onSound?(n.type, n.t)
                record(i, .perfectPlus, early: nil)
            } else if a <= 0.06 {
                onSound?(n.type, n.t)
                record(i, .perfect, early: lag < 0)
            } else if !suppressed && lag <= 0.09 && lag >= -0.11 {
                onSound?(n.type, n.t)
                record(i, .great, early: lag < 0)
            } else if !suppressed && a <= 0.13 {
                record(i, .miss, early: lag < 0)          // 押したときの MISS (早い / 遅い)
            } else {
                return false
            }
        case 2:
            if a <= 0.06 {
                onSound?(n.type, n.t)
                record(i, .perfectPlus, early: nil)
            } else if !n.tateren && lag <= 0.09 && lag >= -0.11 {
                onSound?(n.type, n.t)
                record(i, .great, early: lag < 0)
            } else if !n.tateren && a <= 0.13 {
                record(i, .miss, early: lag < 0)          // 押したときの MISS (早い / 遅い)
            } else {
                return false
            }
        case 3:
            if a <= 0.075 {
                onSound?(n.type, n.t)
                record(i, .perfectPlus, early: nil)
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }

    private func record(_ i: Int, _ j: BxJudge, early: Bool?) {
        notes[i].done = true
        if j == .miss && early == nil { notes[i].missed = true }
        onJudge?(notes[i].type, notes[i].lane, j, early, notes[i].t)
        switch j {
        case .perfectPlus: perfectPlus += 1
        case .perfect: perfect += 1
        case .great: great += 1
        case .miss: miss += 1
        }
        if j == .miss {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
        }
        lastJudge = j
        lastEarly = early
        lastJudgeAt = notes[i].t
        advance()
    }

    /// 本家の IsLaneButtonHeld: そのレーンのホールド / スライドを押さえているか
    static func laneHeld(_ lane: Int, zones: Set<Int>) -> Bool {
        if lane <= 2 && zones.contains(0) { return true }
        if lane >= 2 && lane <= 4 && (zones.contains(1) || zones.contains(2)) { return true }
        if lane >= 4 && zones.contains(3) { return true }
        return false
    }
}
