import Foundation

// MARK: - びーとり (Beatrix) 譜面 JSON
//
// 形式:
//   { "name": "曲名(EX)", "maxBlock": 7, "BPM": 153, "LEVEL": 11.7, "difficulty": 2, "artist": "...",
//     "offset": 1080, "preview": 46.86,
//     "bpms":   [ {"LPB": 4, "num": 240, "bpm": 306}, ... ],       // 途中の BPM 変化
//     "speeds": [ {"LPB": 4, "num": 240, "speed": 1.1}, ... ],     // ソフラン (流れる速さの倍率)
//     "notes":  [ {"LPB": 4, "num": 0, "block": 0, "type": 1, "notes": []}, ... ] }
//
//   ・時刻は num / LPB 拍 (0 拍始まり)。block は 0〜6 (7 鍵)
//   ・type: 1 = タップ / 2 = ホールド・スライド (子の notes が経由点) / 3 = 赤タップ / 4 = ワイプ
//   ・ホールド・スライドには「始点」(タップ or ワイプ) が要る。本体と同じ LPB・num だと消えるので、
//     LPB と num を 2 倍にした別表記で、本体のすぐ後ろに書く (読み込むときは本体に吸収する)
//   ・difficulty: 0 = BASIC (BS) / 1 = HARD (HD) / 2 = EXTREME (EX) / 3 = INSANE (IN)。
//     name とファイル名は「曲名(EX)」「曲名(EX).json」のように略称を付ける (付いていないと本家で読めない)
//
// エディタの中では、これまでどおり Malody 形式のノーツ (x: 0...255 の中心 / w: 幅) で持ち、
// 読み込み・保存のときだけ block ⇔ x を変換する。
//   ・ノーツの幅は本家と同じく、レーンの 1/3 (= 85)
//   ・block b の中心は 255 × (3 + 2b) / 18 (レーンの 1/6 から 1/9 ずつ)。block 0 / 3 / 6 が 3 鍵の左・中・右
//   ・タップ / 赤タップは 3 鍵 (block 0 / 3 / 6)、ホールド / ワイプ / スライドは 7 鍵 (block 0〜6) に置く
//   ・始点の種類は、スライドの extra["bxHead"] に持つ (4 = ワイプ、それ以外 = タップ)

enum Beatrix {
    static let blockCount = 7
    static let tapBlocks = [0, 3, 6]
    /// ノーツの幅 (0...255)。本家 (Unity) のプレハブの大きさに合わせている:
    ///   白・赤タップ = 横 0.03 / ワイプ・ホールド始点 = 0.028 (レーンの幅 0.9912 に対して 約 30% / 28%)
    static let tapW = 77
    static let sideW = 72
    /// offset (サンプル数) を秒にするときの 1 秒あたりの値。
    /// 本家の譜面エディタ (NoteEditor) と同じく、曲のファイルのサンプリング周波数を使う (44.1kHz の曲なら 44100、48kHz の曲なら 48000)。
    /// 曲を読み込んだときにエディタが入れる。曲が無いときは 44100
    static var offsetSampleRate: Double = 44100

    /// 3 鍵の 1 マスの幅 (タップを横に動かすときの 1 段)
    static let noteW = 85

    /// そのノーツを描く幅 (タップ / 赤タップは tapW、それ以外は sideW)
    static func width(for n: Note) -> Int {
        isTapLike(n) ? tapW : sideW
    }
    /// スライド / ホールドの始点の種類 (4 = ワイプ。無ければタップ)
    static let headKey = "bxHead"
    /// 1 / 3 / 4 以外の type (知らない種類) を、保存のときにそのまま書き戻すためのキー
    static let rawTypeKey = "bxType"
    /// 始点を本体と別の表記にするための倍率 (本家の譜面と同じ 2 倍)
    static let headLPBMul = 2

    /// block の中心 x (0...255)
    static func centerX(ofBlock b: Int) -> Int {
        let bb = max(0, min(blockCount - 1, b))
        return Int((255.0 * Double(3 + 2 * bb) / 18.0).rounded())
    }

    /// x (0...255) にいちばん近い block。tapOnly のときは 0 / 3 / 6 のどれか
    static func block(ofX px: Double, tapOnly: Bool = false) -> Int {
        let list = tapOnly ? tapBlocks : Array(0..<blockCount)
        var best = list[0]
        var bestD = Double.greatestFiniteMagnitude
        for b in list {
            let d = Swift.abs(Double(centerX(ofBlock: b)) - px)
            if d < bestD {
                bestD = d
                best = b
            }
        }
        return best
    }

    /// 選択したノーツを横に動かすときの 1 段。タップを含むなら 3 鍵ぶん (85)、それ以外は 1 block ぶん (255 / 9)
    static func snapDX(_ raw: Double, tapLike: Bool) -> Int {
        let step = tapLike ? 85.0 : 255.0 / 9.0
        return Int(((raw / step).rounded() * step).rounded())
    }

    /// タップ / 赤タップ (スライドでもワイプでもない)
    static func isTapLike(_ n: Note) -> Bool { !n.isSlide && n.type != 4 }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double, d.isFinite { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// スライド / ホールドの始点の種類 (1 = タップ / 4 = ワイプ / 0 = 始点なし)。何も書いていなければタップ
    static func headType(_ n: Note) -> Int {
        switch intValue(n.extra[headKey]) {
        case 4: return 4
        case 0: return 0
        default: return 1
        }
    }

    /// ノーツの位置を 7 鍵の中心に、幅を 1/3 にそろえる。変わったときだけ新しい配列を返す。
    /// (タップを 3 鍵に寄せるのは、置くとき・動かすときだけ。読み込んだ譜面を勝手に動かさないため)
    static func normalized(_ notes: [Note]) -> [Note]? {
        var out = notes
        var changed = false
        for i in out.indices {
            var n = out[i]
            let nx = centerX(ofBlock: block(ofX: Double(n.x)))
            if n.isSlide {
                for j in n.segs.indices {
                    let ax = n.x + n.segs[j].x
                    let sx = centerX(ofBlock: block(ofX: Double(ax))) - nx
                    if sx != n.segs[j].x {
                        n.segs[j].x = sx
                        changed = true
                    }
                }
                if n.type != nil {
                    n.type = nil
                    changed = true
                }
            }
            if nx != n.x {
                n.x = nx
                changed = true
            }
            let want = width(for: n)
            if n.w != want {
                n.w = want
                changed = true
            }
            out[i] = n
        }
        return changed ? out : nil
    }

    /// Beat → (LPB, num)。LPB は、できるだけ 4 / 8 / 6 / 12 / 16 ... のような見慣れた値にする
    static func lpbNum(_ b: Beat) -> (lpb: Int, num: Int) {
        let g = gcdInt(b.numerator, b.d)
        let d = max(1, b.d / g)
        let n = b.numerator / g
        for c in [4, 8, 6, 12, 16, 24, 32, 48, 64, 96, 192] where c % d == 0 {
            return (c, n * (c / d))
        }
        return (d, n)
    }

    static func beat(lpb: Int, num: Int) -> Beat {
        Beat.ticks(num, den: max(1, lpb))
    }

    static func beat(of dict: [String: Any]) -> Beat {
        beat(lpb: intValue(dict["LPB"]) ?? 4, num: intValue(dict["num"]) ?? 0)
    }

    /// "曲名(EX)" → ("曲名", .extreme)。略称が付いていなければ (名前そのまま, nil)
    static func splitName(_ name: String) -> (title: String, diff: BeatrixDifficulty?) {
        let t = name.trimmingCharacters(in: .whitespaces)
        let upper = t.uppercased()
        for d in BeatrixDifficulty.allCases {
            for suffix in ["(\(d.abbr))", "（\(d.abbr)）"] where upper.hasSuffix(suffix) {
                let base = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                return (base, d)
            }
        }
        return (t, nil)
    }

    /// LEVEL → 表示する Lv (本家の GetLvRank と同じ。9 以上は ∞)
    static func lvRank(_ lv: Double) -> String {
        let v = Float(lv)
        if v >= 9 { return "∞" }
        if v < 1.99 { return "F" }
        if v < 2.99 { return "E" }
        if v < 3.99 { return "D" }
        if v < 4.99 { return "C" }
        if v < 5.99 { return "B" }
        if v < 6.69 { return "A" }
        if v < 6.99 { return "A+" }
        if v < 7.69 { return "S" }
        if v < 7.99 { return "S+" }
        if v < 8.69 { return "X" }
        if v < 8.99 { return "X+" }
        return "Oops!"
    }

    /// ファイル名に使えない文字を "_" にする
    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let r = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? "chart" : r
    }
}

enum BeatrixDifficulty: Int, CaseIterable {
    case basic = 0, hard = 1, extreme = 2, insane = 3

    var abbr: String {
        switch self {
        case .basic: return "BS"
        case .hard: return "HD"
        case .extreme: return "EX"
        case .insane: return "IN"
        }
    }

    var label: String {
        switch self {
        case .basic: return "BASIC"
        case .hard: return "HARD"
        case .extreme: return "EXTREME"
        case .insane: return "INSANE"
        }
    }
}

/// JSON の "offset" の単位。びーとりは「44100 = 1 秒」(44.1kHz のサンプル数)。
/// 念のため Information で切り替えられるようにしてある (次回起動時も保存される)
enum BeatrixOffsetUnit: Int, CaseIterable {
    case samples44100 = 0, samples48000 = 1, milliseconds = 2

    var label: String {
        switch self {
        case .samples44100: return "44.1kHz"
        case .samples48000: return "48kHz"
        case .milliseconds: return "ms"
        }
    }

    /// 1 秒あたりの値
    var perSecond: Double {
        switch self {
        case .samples44100: return 44100
        case .samples48000: return 48000
        case .milliseconds: return 1000
        }
    }

    /// びーとりの offset は「44100 = 1 秒あとにずらす」で固定 (NoteEditor の OffsetSamples と同じ。切り替えはしない)
    static var current: BeatrixOffsetUnit {
        get { .samples44100 }
        set { }
    }
}

// MARK: - ChartData ⇔ びーとり JSON

extension ChartData {
    /// 読み込んだ JSON のうち、notes / bpms / speeds 以外 (name は「略称を除いた曲名」にしてある)。保存のときにそのまま書き戻す
    var bx: [String: Any] {
        get { root["beatrix"] as? [String: Any] ?? [:] }
        set { root["beatrix"] = newValue }
    }

    var bxTitle: String {
        get { (bx["name"] as? String) ?? "" }
        set {
            var b = bx
            b["name"] = newValue
            bx = b
            setMetaString(["song", "title"], newValue)      // テストプレイの曲名用
        }
    }

    var bxArtist: String {
        get { (bx["artist"] as? String) ?? "" }
        set {
            var b = bx
            b["artist"] = newValue
            bx = b
        }
    }

    var bxDifficulty: BeatrixDifficulty {
        get { Beatrix.intValue(bx["difficulty"]).flatMap { BeatrixDifficulty(rawValue: $0) } ?? .extreme }
        set {
            var b = bx
            b["difficulty"] = newValue.rawValue
            bx = b
            setMetaString(["version"], newValue.abbr)
        }
    }

    var bxLevel: Double {
        get { Beatrix.doubleValue(bx["LEVEL"]) ?? 1.0 }
        set {
            var b = bx
            b["LEVEL"] = newValue
            bx = b
        }
    }

    var bxPreview: Double? {
        get { Beatrix.doubleValue(bx["preview"]) }
        set {
            var b = bx
            if let v = newValue { b["preview"] = v } else { b.removeValue(forKey: "preview") }
            bx = b
        }
    }

    /// JSON の "offset" (単位は BeatrixOffsetUnit.current)。変えると、エディタの再生に使うオフセット (ms) も変わる
    var bxOffsetRaw: Int {
        get { Beatrix.intValue(bx["offset"]) ?? 0 }
        set {
            var b = bx
            b["offset"] = newValue
            bx = b
            applyBeatrixOffset()
        }
    }

    /// "offset" から、エディタの再生のオフセット (ms) を決める。
    /// びーとりの offset は「0 拍目が曲の何秒目か」、エディタの offsetMs は「譜面時刻 t の音 = 曲の t − offsetMs/1000 秒目」なので、符号が逆
    mutating func applyBeatrixOffset() {
        offsetMs = -Int((Double(bxOffsetRaw) / Beatrix.offsetSampleRate * 1000.0).rounded())
    }

    /// "曲名(EX)"
    var bxFullName: String {
        let t = bxTitle.isEmpty ? "chart" : bxTitle
        return "\(t)(\(bxDifficulty.abbr))"
    }

    /// "曲名(EX).json"
    var bxFileName: String { Beatrix.safeFileName(bxFullName) + ".json" }

    /// 新しい譜面 (ノーツなし)
    static func newBeatrix(title: String, bpm: Double, difficulty: BeatrixDifficulty) -> ChartData {
        var c = ChartData(root: [:], times: [TimePoint(beat: .zero, bpm: max(1, bpm))], notes: [], soundEntries: [],
                          effects: [], otherEffects: [], hadEffectKey: false)
        c.bx = ["maxBlock": 7, "LEVEL": 1.0, "offset": 0, "artist": "", "preview": 0.0]
        c.bxTitle = title
        c.bxDifficulty = difficulty
        c.applyBeatrixOffset()
        return c
    }

    /// びーとりの JSON を読む
    static func parseBeatrix(_ data: Data) throws -> ChartData {
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = Data(body.dropFirst(3)) }      // BOM
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawNotes = obj["notes"] as? [[String: Any]] else {
            throw ChartError.invalid
        }

        var b = obj
        for k in ["notes", "bpms", "speeds"] { b.removeValue(forKey: k) }
        let nameInfo = Beatrix.splitName((obj["name"] as? String) ?? "")
        b["name"] = nameInfo.title
        var diff = nameInfo.diff ?? .extreme
        if let d = Beatrix.intValue(obj["difficulty"]), let dd = BeatrixDifficulty(rawValue: d) { diff = dd }
        b["difficulty"] = diff.rawValue

        // BPM: "BPM" が 0 拍目から、"bpms" が途中の変化
        var baseBPM = 120.0
        if let v = Beatrix.doubleValue(obj["BPM"]), v > 0 { baseBPM = v }
        var times = [TimePoint(beat: .zero, bpm: baseBPM)]
        for e in (obj["bpms"] as? [[String: Any]]) ?? [] {
            guard let bpm = Beatrix.doubleValue(e["bpm"]), bpm > 0 else { continue }
            let bt = Beatrix.beat(of: e)
            if bt <= Beat.zero {
                times[0].bpm = bpm
            } else if let i = times.firstIndex(where: { $0.beat == bt }) {
                times[i].bpm = bpm
            } else {
                times.append(TimePoint(beat: bt, bpm: bpm))
            }
        }
        times.sort { $0.beat < $1.beat }

        // ソフラン: エディタの effect の scroll として持つ (テストプレイの見た目に反映される)
        var effects: [EffectPoint] = []
        for e in (obj["speeds"] as? [[String: Any]]) ?? [] {
            guard let sp = Beatrix.doubleValue(e["speed"]) else { continue }
            effects.append(EffectPoint(beat: Beatrix.beat(of: e), kind: .scroll, value: sp))
        }
        effects.sort { $0.beat < $1.beat }

        // ノーツ: 先にスライド (type 2 + 子) を集めて、その始点と同じ位置のタップ / ワイプを始点として吸収する
        var notes: [Note] = []
        var slideAt: [BeatrixKey: Int] = [:]
        var singles: [(beat: Beat, block: Int, type: Int)] = []
        for e in rawNotes {
            let bt = Beatrix.beat(of: e)
            let blk = max(0, min(Beatrix.blockCount - 1, Beatrix.intValue(e["block"]) ?? 0))
            let type = Beatrix.intValue(e["type"]) ?? 1
            let kids = (e["notes"] as? [[String: Any]]) ?? []
            if type == 2 && !kids.isEmpty {
                let sx = Beatrix.centerX(ofBlock: blk)
                var segs: [Seg] = []
                for k in kids {
                    let kb = Beatrix.beat(of: k)
                    let kblk = max(0, min(Beatrix.blockCount - 1, Beatrix.intValue(k["block"]) ?? blk))
                    segs.append(Seg(beat: kb - bt, x: Beatrix.centerX(ofBlock: kblk) - sx))
                }
                let key = BeatrixKey(beat: bt, block: blk)
                if slideAt[key] == nil { slideAt[key] = notes.count }
                notes.append(Note(beat: bt, x: sx, w: Beatrix.sideW, type: nil, segs: segs))
            } else {
                singles.append((beat: bt, block: blk, type: type))
            }
        }
        // 始点 (スライド / ホールドと同じ位置のタップ・ワイプ) も、エディタの中では普通のタップ・ワイプとして持つ
        // (始点だけを選んで消したり動かしたりできるように)。保存するときに、また始点の表記に戻す (beatrixNotes)
        for s in singles {
            var n = Note(beat: s.beat, x: Beatrix.centerX(ofBlock: s.block), w: s.type == 4 ? Beatrix.sideW : Beatrix.tapW)
            switch s.type {
            case 3: n.type = 3
            case 4: n.type = 4
            case 1, 2: n.type = nil
            default:
                n.type = nil
                n.extra[Beatrix.rawTypeKey] = s.type
            }
            notes.append(n)
        }
        // スライド / ホールドの本体は「始点なし」(0)。始点は、上で普通のノーツとして入れてある
        for i in notes.indices where notes[i].isSlide {
            notes[i].extra[Beatrix.headKey] = 0
        }

        var c = ChartData(root: ["beatrix": b], times: times, notes: notes, soundEntries: [],
                          effects: effects, otherEffects: [], hadEffectKey: !effects.isEmpty)
        c.setMetaString(["song", "title"], nameInfo.title)
        c.setMetaString(["version"], diff.abbr)
        c.applyBeatrixOffset()
        return c
    }

    /// びーとりの JSON に書き出す
    func beatrixData() throws -> Data {
        var out = bx
        out["name"] = bxFullName
        if out["maxBlock"] == nil { out["maxBlock"] = Beatrix.blockCount }
        out["difficulty"] = bxDifficulty.rawValue
        if out["LEVEL"] == nil { out["LEVEL"] = 1.0 }
        if out["offset"] == nil { out["offset"] = 0 }

        let ts = times.sorted { $0.beat < $1.beat }
        out["BPM"] = ts.first?.bpm ?? 120
        var bpms: [[String: Any]] = []
        for t in ts.dropFirst() {
            let p = Beatrix.lpbNum(t.beat)
            bpms.append(["LPB": p.lpb, "num": p.num, "bpm": t.bpm])
        }
        out["bpms"] = bpms

        var speeds: [[String: Any]] = []
        for e in effects.sorted(by: { $0.beat < $1.beat }) where e.kind == .scroll {
            let p = Beatrix.lpbNum(e.beat)
            speeds.append(["LPB": p.lpb, "num": p.num, "speed": e.value])
        }
        out["speeds"] = speeds

        out["notes"] = beatrixNotes()
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    }

    /// ノーツを JSON の "notes" の形にする (スライド / ホールドの後ろに始点を付ける)
    func beatrixNotes() -> [[String: Any]] {
        let sorted = notes.sorted { a, b in
            a.beat == b.beat ? a.x < b.x : a.beat < b.beat
        }
        // スライドの始点 → 始点の種類 (1 = タップ / 4 = ワイプ)
        var starts: [BeatrixKey: Int] = [:]
        for n in sorted where n.isSlide {
            let k = BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x)))
            let h = Beatrix.headType(n)
            // 同じ位置のスライドが複数あるときは ワイプ > タップ > なし
            if let old = starts[k] {
                if h == 4 || old == 4 {
                    starts[k] = 4
                } else if h == 1 || old == 1 {
                    starts[k] = 1
                }
            } else {
                starts[k] = h
            }
        }
        // 始点と同じ位置に別に置いてあるタップ / ワイプは、それを始点にする (タップ / ワイプ自体は下で出力しない)
        for n in sorted where !n.isSlide && (n.type == nil || n.type == 4) && n.extra[Beatrix.rawTypeKey] == nil {
            let k = BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x)))
            guard let cur = starts[k] else { continue }
            if n.type == 4 {
                starts[k] = 4
            } else if cur == 0 {
                starts[k] = 1
            }
        }
        // 始点と同じ位置に赤タップがあるときは、赤タップを始点として扱う (タップの始点は出さない)。
        // 両方出すと、同じ位置にタップが 2 つ重なって、1 回押しても片方が残ってミスになるため
        for n in sorted where !n.isSlide && n.type == 3 {
            let k = BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x)))
            if starts[k] == 1 { starts[k] = 0 }
        }

        var out: [[String: Any]] = []
        var headDone = Set<BeatrixKey>()
        for n in sorted {
            let blk = Beatrix.block(ofX: Double(n.x))
            let k = BeatrixKey(beat: n.beat, block: blk)
            let p = Beatrix.lpbNum(n.beat)
            if n.isSlide {
                var kids: [[String: Any]] = []
                for s in n.segs {
                    let q = Beatrix.lpbNum(n.beat + s.beat)
                    kids.append(["LPB": q.lpb, "num": q.num, "block": Beatrix.block(ofX: Double(n.x + s.x)),
                                 "type": 2, "notes": [Any]()])
                }
                out.append(["LPB": p.lpb, "num": p.num, "block": blk, "type": 2, "notes": kids])
                if !headDone.contains(k) && (starts[k] ?? 1) != 0 {
                    headDone.insert(k)
                    out.append(["LPB": p.lpb * Beatrix.headLPBMul, "num": p.num * Beatrix.headLPBMul, "block": blk,
                                "type": starts[k] ?? 1, "notes": [Any]()])
                }
            } else {
                let rawType = Beatrix.intValue(n.extra[Beatrix.rawTypeKey])
                if rawType == nil && (n.type == nil || n.type == 4) && starts[k] != nil { continue }   // 始点として出力済み
                let t: Int
                if let r = rawType {
                    t = r
                } else if n.type == 3 {
                    t = 3
                } else if n.type == 4 {
                    t = 4
                } else {
                    t = 1
                }
                out.append(["LPB": p.lpb, "num": p.num, "block": blk, "type": t, "notes": [Any]()])
            }
        }
        return out
    }
}

// MARK: - part (譜面の区間。本家では区間に入ると演出が出る)
//   JSON: "part": [ {"LPB": 4, "num": 560, "parts": [ {"LPB": 4, "num": 688, "parts": []} ]} ]
//   外側の LPB / num が始まり、parts[0] が終わり

struct BeatrixPart {
    var start: Beat
    var end: Beat
}

extension ChartData {
    var bxParts: [BeatrixPart] {
        get {
            var out: [BeatrixPart] = []
            for p in (bx["part"] as? [[String: Any]]) ?? [] {
                guard let e = (p["parts"] as? [[String: Any]])?.first else { continue }
                let s = Beatrix.beat(of: p)
                let en = Beatrix.beat(of: e)
                if s < en { out.append(BeatrixPart(start: s, end: en)) }
            }
            return out.sorted { $0.start < $1.start }
        }
        set {
            var list: [[String: Any]] = []
            for p in newValue.sorted(by: { $0.start < $1.start }) {
                let s = Beatrix.lpbNum(p.start)
                let e = Beatrix.lpbNum(p.end)
                let endDict: [String: Any] = ["LPB": e.lpb, "num": e.num, "parts": [Any]()]
                let d: [String: Any] = ["LPB": s.lpb, "num": s.num, "parts": [endDict]]
                list.append(d)
            }
            var b = bx
            b["part"] = list
            bx = b
        }
    }
}

/// 「拍 + block」の組 (スライドの始点を探すのに使う)
struct BeatrixKey: Hashable {
    let beat: Beat
    let block: Int
}
