import Foundation

// MARK: - びーとり (Beatrix) 譜面 JSON
//
// 形式:
//   { "name": "曲名", "maxBlock": 7, "BPM": 153, "LEVEL": 11.7, "difficulty": 2, "artist": "...",
//     "offset": 1080, "preview": 46.86,
//     "bpms":   [ {"LPB": 4, "num": 240, "bpm": 306}, ... ],       // 途中の BPM 変化
//     "speeds": [ {"LPB": 4, "num": 240, "speed": 1.1}, ... ],     // ソフラン (ノーツ全体の流れる速さの倍率。その拍から先ずっと)
//     "speeds_each": [ {"LPB": 4, "num": 240, "block": 3, "speed": 2.0}, ... ],
//     "lyrics": [ {"LPB": 4, "num": 560, "text": "歌詞", "parts": [ {"LPB": 4, "num": 576, "parts": []} ]}, ... ],
//                                                                  // 歌詞 (part と同じ形 + text。始まり〜終わりの間だけ表示)
//     "curve": [ {"LPB": 4, "num": 128, "block": 3, "type": 2, "nth": 0}, ... ],
//                  // 曲線スライド。指したスライドの見た目を、経由点をなめらかな曲線でつないだ形にする (判定の位置は経由点のまま)
//     "dummy": [ {"LPB": 4, "num": 240, "block": 3}, ... ],         // ダミーノーツ。LPB・num・block が完全に一致するノーツ
//                                                                  // (ホールド・スライドは始点の位置) は、流れてくるけど判定が無い
//     "appear":    [ {"LPB": 4, "num": 256, "block": 3, "type": 2, "nth": 0, "atLPB": 4, "atNum": 248}, ... ],
//     "disappear": [ {"LPB": 4, "num": 256, "block": 3, "type": 2, "nth": 1, "atLPB": 4, "atNum": 248}, ... ],
//                  // 出現 / 消える (1 つのノーツに何回でも)。LPB・num・block・type・nth で 1 つのノーツを指す
//                  // (nth = その位置・その type の何番目か。"notes" の順、始点の表記は数えない)。
//                  // appear の拍で見えるようになり、disappear の拍で見えなくなる。最初の切り替えが appear なら、それまでは見えない
//                                                                  // ノーツ個別の速さ。LPB・num・block が完全に一致するノーツ
//                                                                  // (ホールド・スライドは始点の位置) だけ、その倍率で流れてくる
//     "notes":  [ {"LPB": 4, "num": 0, "block": 0, "type": 1, "notes": []}, ... ] }
//
//   ・時刻は num / LPB 拍 (0 拍始まり)。block は 0〜6 (7 鍵)
//   ・type: 1 = タップ / 2 = ホールド・スライド (子の notes が経由点) / 3 = 赤タップ / 4 = ワイプ
//   ・ホールド・スライドには「始点」(タップ or ワイプ) が要る。本体と同じ LPB・num だと消えるので、
//     LPB と num を 2 倍にした別表記で、本体のすぐ後ろに書く (読み込むときは本体に吸収する)
//   ・difficulty: 0 = BASIC (BS) / 1 = HARD (HD) / 2 = EXTREME (EX) / 3 = INSANE (IN)。
//     ファイル名にだけ「曲名(EX).json」のように略称を付ける。name は曲名だけ (略称は付けない)
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
    /// JSON の offset を秒にするときの「1 秒あたりの値」。offset は ms (ミリ秒) なので、いつも 1000。
    /// (前は 44100 = 1 秒のサンプル数だった。名前はそのまま使っている)
    static var offsetSampleRate: Double = 1000

    /// 再生のときだけ使う補正 (ms)。JSON の offset はそのまま。
    /// 本家 (Unity) の Editor Playback Correction と同じ考え方。offset を ms にしたので、本家と同じく初期値は 0 (SETTING で変えられる)
    static var playbackCorrectionMs: Int = 0

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
    /// ノーツ個別の速さ ("speeds_each")。無ければ 1 倍 (全体のソフランだけ)
    static let speedKey = "bxSpeed"
    /// ダミーノーツ ("dummy")。true なら判定が無い
    static let dummyKey = "bxDummy"
    /// 曲線スライド ("curve")。true なら、見た目だけ経由点をなめらかな曲線でつなぐ (判定の位置は経由点のまま)
    static let curveKey = "bxCurve"

    static func isCurve(_ n: Note) -> Bool {
        (n.extra[curveKey] as? Bool) == true
    }

    /// 経由点 (x = 拍か秒、y = 横の位置) を、なめらかな曲線でつないだ細かい点の列にする。
    /// 単調な 3 次の補間 (Fritsch–Carlson) なので、経由点を通り、経由点の間で行き過ぎ (はみ出し) が起きない。
    /// 同じ位置が続くところ (まっすぐの区間) はまっすぐのまま。x が同じ (時間 0 の) 区間は直線でつなぐ
    /// curvePoints の各経由点での傾き (単調 3 次補間 Fritsch–Carlson)。点が 3 個未満なら直線の傾き
    static func curveTangents(_ xs: [Double], _ ys: [Double]) -> [Double] {
        let n = xs.count
        guard n >= 2, ys.count == n else { return [Double](repeating: 0, count: n) }
        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            let h = xs[k + 1] - xs[k]
            d[k] = h > 1e-12 ? (ys[k + 1] - ys[k]) / h : 0
        }
        if n == 2 { return [d[0], d[0]] }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for k in 1..<(n - 1) {
            m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 {
                m[k] = 0
                m[k + 1] = 0
                continue
            }
            let a = m[k] / d[k]
            let b = m[k + 1] / d[k]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                m[k] = tau * a * d[k]
                m[k + 1] = tau * b * d[k]
            }
        }
        return m
    }

    /// 区間 k の中の位置 (u = 0〜1) での曲線の値 (エルミート曲線)
    static func curveValue(_ xs: [Double], _ ys: [Double], _ m: [Double], segment k: Int, u t: Double) -> Double {
        let h = xs[k + 1] - xs[k]
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1]
    }

    static func curvePoints(_ xs: [Double], _ ys: [Double], samples: Int = 16) -> [(x: Double, y: Double)] {
        let n = xs.count
        guard n >= 3, ys.count == n else { return zip(xs, ys).map { (x: $0, y: $1) } }
        let m = curveTangents(xs, ys)
        var out: [(x: Double, y: Double)] = [(x: xs[0], y: ys[0])]
        for k in 0..<(n - 1) {
            let h = xs[k + 1] - xs[k]
            if h <= 1e-12 {
                out.append((x: xs[k + 1], y: ys[k + 1]))
                continue
            }
            for i in 1...samples {
                let t = Double(i) / Double(samples)
                out.append((x: xs[k] + h * t, y: curveValue(xs, ys, m, segment: k, u: t)))
            }
        }
        return out
    }

    static func isDummy(_ n: Note) -> Bool {
        (n.extra[dummyKey] as? Bool) == true
    }

    /// 出現 ("appear") / 消える ("disappear") の拍。extra には [LPB, num] で持つ
    static let appearKey = "bxAppear"
    static let vanishKey = "bxVanish"

    /// 出現 / 消えるの拍のリスト (何回でも付けられる)。extra には [[LPB, num], ...] で持つ (前の形式 [LPB, num] も読める)
    static func atBeats(_ n: Note, _ key: String) -> [Beat] {
        guard let a = n.extra[key] as? [Any], !a.isEmpty else { return [] }
        if a.first is [Any] {
            var out: [Beat] = []
            for e in a {
                guard let p = e as? [Any], p.count == 2, let l = intValue(p[0]), let m = intValue(p[1]) else { continue }
                out.append(beat(lpb: l, num: m))
            }
            return out.sorted()
        }
        if a.count == 2, let l = intValue(a[0]), let m = intValue(a[1]) { return [beat(lpb: l, num: m)] }
        return []
    }

    static func setAtBeats(_ n: inout Note, _ key: String, _ list: [Beat]) {
        if list.isEmpty {
            n.extra.removeValue(forKey: key)
            return
        }
        var uniq: [Beat] = []
        for b in list.sorted() where !uniq.contains(b) { uniq.append(b) }
        n.extra[key] = uniq.map { b -> [Int] in
            let p = lpbNum(b)
            return [p.lpb, p.num]
        }
    }

    /// 見え方が切り替わる拍 (時刻順)。show = true が出現、false が消える
    static func visEvents(_ n: Note) -> [(beat: Beat, show: Bool)] {
        let ev = atBeats(n, appearKey).map { (beat: $0, show: true) } + atBeats(n, vanishKey).map { (beat: $0, show: false) }
        return ev.sorted { a, b in a.beat == b.beat ? (!a.show && b.show) : a.beat < b.beat }
    }

    /// 出現 / 消えるの拍を、ノーツと一緒にずらす (コピー・貼り付け・移動のとき。拍はノーツと同じく絶対の位置で持っているため)
    static func shiftAtBeats(_ n: inout Note, from orig: Note, by delta: Beat, subtract: Bool = false) {
        for key in [appearKey, vanishKey] {
            let list = atBeats(orig, key)
            if list.isEmpty { continue }
            setAtBeats(&n, key, list.map { subtract ? $0 - delta : $0 + delta })
        }
    }

    static func noteSpeed(_ n: Note) -> Double? {
        doubleValue(n.extra[speedKey])
    }

    /// 速さの表示 (2 → "2" / 1.25 → "1.25")
    static func speedLabel(_ v: Double) -> String {
        var t = String(format: "%.3f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
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

/// JSON の "offset" の単位 (今は使っていない。offset は ms で固定)。
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

    /// びーとりの offset は ms で固定 (切り替えはしない)
    static var current: BeatrixOffsetUnit {
        get { .milliseconds }
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

    /// "ver" (譜面のバージョン。整数)。nil なら書き出さない
    var bxVer: Int? {
        get { Beatrix.intValue(bx["ver"]) }
        set {
            var b = bx
            if let v = newValue { b["ver"] = v } else { b.removeValue(forKey: "ver") }
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
        let effective = Double(bxOffsetRaw - Beatrix.playbackCorrectionMs)
        offsetMs = -Int((effective / Beatrix.offsetSampleRate * 1000.0).rounded())
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
        for k in ["notes", "bpms", "speeds", "speeds_each", "dummy", "appear", "disappear", "curve"] { b.removeValue(forKey: k) }
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
        var singles: [(beat: Beat, block: Int, type: Int, raw: Int)] = []
        var noteRaw: [Int] = []          // 作ったノーツ (notes の順) が、rawNotes の何番目から来たか
        for (ri, e) in rawNotes.enumerated() {
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
                noteRaw.append(ri)
            } else {
                singles.append((beat: bt, block: blk, type: type, raw: ri))
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
            noteRaw.append(s.raw)
        }
        // スライド / ホールドの本体は「始点なし」(0)。始点は、上で普通のノーツとして入れてある
        for i in notes.indices where notes[i].isSlide {
            notes[i].extra[Beatrix.headKey] = 0
        }

        // ノーツを指す項目 (speeds_each / dummy / appear / disappear) の当て先。
        //   type があれば、その位置 (拍・block) の「その type の nth 番目」(rawNotes の順。始点の表記は数えない) のノーツ 1 つだけ。
        //   type が無ければ (前の形式)、その位置のノーツ全部
        var bodyKeys = Set<BeatrixKey>()
        for e in rawNotes where (Beatrix.intValue(e["type"]) ?? 1) == 2 && !((e["notes"] as? [[String: Any]]) ?? []).isEmpty {
            bodyKeys.insert(BeatrixKey(beat: Beatrix.beat(of: e), block: max(0, min(Beatrix.blockCount - 1, Beatrix.intValue(e["block"]) ?? 0))))
        }
        struct TypedKey: Hashable { let key: BeatrixKey; let type: Int; let nth: Int }
        var rawToNote: [Int: Int] = [:]
        for (ni, ri) in noteRaw.enumerated() { rawToNote[ri] = ni }
        var typed: [TypedKey: Int] = [:]          // → notes の番号
        var counter: [String: Int] = [:]
        for (ri, e) in rawNotes.enumerated() {
            let type = Beatrix.intValue(e["type"]) ?? 1
            let k = BeatrixKey(beat: Beatrix.beat(of: e), block: max(0, min(Beatrix.blockCount - 1, Beatrix.intValue(e["block"]) ?? 0)))
            let hasKids = !((e["notes"] as? [[String: Any]]) ?? []).isEmpty
            if (type == 1 || type == 4) && bodyKeys.contains(k) { continue }      // 始点の表記 (本体に付いていく)
            if type == 2 && !hasKids { continue }
            let ck = "\(k.beat.value)-\(k.block)-\(type)"
            let nth = counter[ck] ?? 0
            counter[ck] = nth + 1
            if let ni = rawToNote[ri] { typed[TypedKey(key: k, type: type, nth: nth)] = ni }
        }
        func targets(_ e: [String: Any]) -> [Int] {
            let blk = max(0, min(Beatrix.blockCount - 1, Beatrix.intValue(e["block"]) ?? 0))
            let k = BeatrixKey(beat: Beatrix.beat(of: e), block: blk)
            if let t = Beatrix.intValue(e["type"]) {
                if let ni = typed[TypedKey(key: k, type: t, nth: Beatrix.intValue(e["nth"]) ?? 0)] { return [ni] }
                return []
            }
            return notes.indices.filter { BeatrixKey(beat: notes[$0].beat, block: Beatrix.block(ofX: Double(notes[$0].x))) == k }
        }

        // ノーツ個別の速さ
        for e in (obj["speeds_each"] as? [[String: Any]]) ?? [] {
            guard let sp = Beatrix.doubleValue(e["speed"]) else { continue }
            for ni in targets(e) { notes[ni].extra[Beatrix.speedKey] = sp }
        }
        // ダミー
        for e in (obj["dummy"] as? [[String: Any]]) ?? [] {
            for ni in targets(e) { notes[ni].extra[Beatrix.dummyKey] = true }
        }
        // 曲線スライド
        for e in (obj["curve"] as? [[String: Any]]) ?? [] {
            for ni in targets(e) where notes[ni].isSlide { notes[ni].extra[Beatrix.curveKey] = true }
        }
        // 出現 / 消える (何回でも)
        for (jsonKey, key) in [("appear", Beatrix.appearKey), ("disappear", Beatrix.vanishKey)] {
            for e in (obj[jsonKey] as? [[String: Any]]) ?? [] {
                let at = Beatrix.beat(lpb: Beatrix.intValue(e["atLPB"]) ?? 4, num: Beatrix.intValue(e["atNum"]) ?? 0)
                for ni in targets(e) {
                    Beatrix.setAtBeats(&notes[ni], key, Beatrix.atBeats(notes[ni], key) + [at])
                }
            }
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
        out["name"] = bxTitle            // name は曲名だけ (略称 (EX) などはファイル名にだけ付ける)
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
        out["speeds_each"] = beatrixSpeedsEach()
        out["dummy"] = beatrixDummies()
        out["curve"] = beatrixTargets().filter { $0.note.isSlide && Beatrix.isCurve($0.note) }.map { $0.ref }
        out["appear"] = beatrixAtList(Beatrix.appearKey)
        out["disappear"] = beatrixAtList(Beatrix.vanishKey)

        if out["lyrics"] == nil { out["lyrics"] = [Any]() }
        out["notes"] = beatrixNotes()
        return BeatrixJSONWriter.data(out)
    }

    /// 出現 / 消えるを JSON の "appear" / "disappear" の形にする (同じ位置に複数あるときは 1 つにまとめる)
    func beatrixAtList(_ key: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for t in beatrixTargets() {
            for at in Beatrix.atBeats(t.note, key) {
                var d = t.ref
                let q = Beatrix.lpbNum(at)
                d["atLPB"] = q.lpb
                d["atNum"] = q.num
                out.append(d)
            }
        }
        return out
    }

    /// "notes" の 1 つ 1 つ (始点の表記を除く) を指す {"LPB","num","block","type","nth"} と、そのもとのノーツ。
    /// nth = 同じ位置・同じ type の中で何番目か ("notes" の順)。speeds_each / dummy / appear / disappear で使う
    func beatrixTargets() -> [(ref: [String: Any], note: Note)] {
        var out: [(ref: [String: Any], note: Note)] = []
        var counter: [String: Int] = [:]
        for e in beatrixEntries() where !e.isHead {
            guard let n = e.source else { continue }
            let type = Beatrix.intValue(e.dict["type"]) ?? 1
            let blk = Beatrix.intValue(e.dict["block"]) ?? 0
            let ck = "\(n.beat.value)-\(blk)-\(type)"
            let nth = counter[ck] ?? 0
            counter[ck] = nth + 1
            let p = Beatrix.lpbNum(n.beat)
            out.append((ref: ["LPB": p.lpb, "num": p.num, "block": blk, "type": type, "nth": nth], note: n))
        }
        return out
    }

    /// ダミーを JSON の "dummy" の形にする (ノーツ 1 つずつ)
    func beatrixDummies() -> [[String: Any]] {
        beatrixTargets().filter { Beatrix.isDummy($0.note) }.map { $0.ref }
    }

    /// ノーツ個別の速さを JSON の "speeds_each" の形にする (ノーツ 1 つずつ)
    func beatrixSpeedsEach() -> [[String: Any]] {
        beatrixTargets().compactMap { t -> [String: Any]? in
            guard let sp = Beatrix.noteSpeed(t.note) else { return nil }
            var d = t.ref
            d["speed"] = sp
            return d
        }
    }

    /// ノーツを JSON の "notes" の形にする (スライド / ホールドの後ろに始点を付ける)
    func beatrixNotes() -> [[String: Any]] {
        beatrixEntries().map { $0.dict }
    }

    /// "notes" の 1 つ 1 つと、そのもとになったノーツ。
    /// 並びは 拍 → x → エディタの中の順 (同じ位置にスライドが 2 本あっても、いつも同じ順になるように)
    func beatrixEntries() -> [BeatrixOutEntry] {
        let sorted = notes.enumerated().sorted { a, b in
            if a.element.beat != b.element.beat { return a.element.beat < b.element.beat }
            if a.element.x != b.element.x { return a.element.x < b.element.x }
            return a.offset < b.offset
        }.map { $0.element }
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

        var bodiesAt: [BeatrixKey: [Note]] = [:]
        for n in sorted where n.isSlide {
            bodiesAt[BeatrixKey(beat: n.beat, block: Beatrix.block(ofX: Double(n.x))), default: []].append(n)
        }
        var out: [BeatrixOutEntry] = []
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
                out.append(BeatrixOutEntry(dict: ["LPB": p.lpb, "num": p.num, "block": blk, "type": 2, "notes": kids], source: n))
                if !headDone.contains(k) && (starts[k] ?? 1) != 0 {
                    headDone.insert(k)
                    out.append(BeatrixOutEntry(dict: ["LPB": p.lpb * Beatrix.headLPBMul, "num": p.num * Beatrix.headLPBMul, "block": blk,
                                                      "type": starts[k] ?? 1, "notes": [Any]()],
                                               source: nil, bodies: bodiesAt[k] ?? [], isHead: true))
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
                out.append(BeatrixOutEntry(dict: ["LPB": p.lpb, "num": p.num, "block": blk, "type": t, "notes": [Any]()], source: n))
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

// MARK: - lyrics (歌詞。part の文字付き版)
//   JSON: "lyrics": [ {"LPB": 4, "num": 560, "text": "〜〜", "parts": [ {"LPB": 4, "num": 576, "parts": []} ]} ]
//   外側の LPB / num が表示の始まり、parts[0] が終わり (part と同じ形に text を足したもの)。始まり <= 今 < 終わり の間だけ text を出す

struct BeatrixLyric {
    var start: Beat
    var end: Beat
    var text: String
}

extension ChartData {
    var bxLyrics: [BeatrixLyric] {
        get {
            var out: [BeatrixLyric] = []
            for p in (bx["lyrics"] as? [[String: Any]]) ?? [] {
                guard let e = (p["parts"] as? [[String: Any]])?.first else { continue }
                let s = Beatrix.beat(of: p)
                let en = Beatrix.beat(of: e)
                if s < en { out.append(BeatrixLyric(start: s, end: en, text: (p["text"] as? String) ?? "")) }
            }
            return out.sorted { $0.start < $1.start }
        }
        set {
            var list: [[String: Any]] = []
            for l in newValue.sorted(by: { $0.start < $1.start }) {
                let s = Beatrix.lpbNum(l.start)
                let e = Beatrix.lpbNum(l.end)
                let endDict: [String: Any] = ["LPB": e.lpb, "num": e.num, "parts": [Any]()]
                list.append(["LPB": s.lpb, "num": s.num, "text": l.text, "parts": [endDict]])
            }
            var b = bx
            b["lyrics"] = list
            bx = b
        }
    }
}

/// "notes" の 1 つと、そのもとになったノーツ (書き出し・テストプレイで使う)
struct BeatrixOutEntry {
    var dict: [String: Any]
    var source: Note? = nil          // もとのノーツ (始点の表記は nil)
    var bodies: [Note] = []          // 始点の表記のとき: 同じ位置のスライド / ホールド (始点はこれらに付いていく)
    var isHead = false
}

/// 「拍 + block」の組 (スライドの始点を探すのに使う)
struct BeatrixKey: Hashable {
    let beat: Beat
    let block: Int
}


// MARK: - JSON の書き出し (NoteEditor と同じ見た目)
//   ・キーの順番を固定する (上: name → maxBlock → BPM → LEVEL → difficulty → artist → offset → preview → ver
//     → bpms → speeds → speeds_each → dummy → appear → disappear → part → lyrics → notes / ノーツ: LPB → num → block → type → notes)。知らないキーは最後に名前順
//   ・字下げは 2 つ、"キー": 値 (コロンの前に空白を入れない)、中身が空の配列は []
//   ・数は、整数なら小数点を付けない (149)、小数は短い表記 (4.7)

enum BeatrixJSONWriter {
    static let topOrder = ["name", "maxBlock", "BPM", "LEVEL", "difficulty", "artist", "offset", "preview", "ver",
                           "bpms", "speeds", "speeds_each", "dummy", "appear", "disappear", "curve", "part", "lyrics", "notes"]
    static let innerOrder = ["LPB", "num", "block", "type", "nth", "bpm", "speed", "atLPB", "atNum", "text", "notes", "parts"]

    static func data(_ obj: [String: Any]) -> Data {
        var out = ""
        write(obj, indent: 0, order: topOrder, into: &out)
        out += "\n"
        return Data(out.utf8)
    }

    private static func orderedKeys(_ d: [String: Any], _ order: [String]) -> [String] {
        let known = order.filter { d[$0] != nil }
        let rest = d.keys.filter { !order.contains($0) }.sorted()
        return known + rest
    }

    private static func write(_ v: Any, indent: Int, order: [String], into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let pad1 = String(repeating: "  ", count: indent + 1)
        if let d = v as? [String: Any] {
            if d.isEmpty { out += "{}"; return }
            out += "{\n"
            let keys = orderedKeys(d, order)
            for (i, k) in keys.enumerated() {
                out += pad1 + string(k) + ": "
                write(d[k]!, indent: indent + 1, order: innerOrder, into: &out)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        } else if let a = v as? [Any] {
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, e) in a.enumerated() {
                out += pad1
                write(e, indent: indent + 1, order: innerOrder, into: &out)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        } else if let s = v as? String {
            out += string(s)
        } else if let n = v as? NSNumber {
            out += number(n)
        } else if v is NSNull {
            out += "null"
        } else {
            out += string("\(v)")
        }
    }

    private static func number(_ n: NSNumber) -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        if !d.isFinite { return "0" }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"          // Swift の Double の表記は、元の値に戻せるいちばん短い形 (4.7 など)
    }

    private static func string(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
           let t = String(data: data, encoding: .utf8) {
            return t
        }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
