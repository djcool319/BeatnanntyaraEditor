import CoreGraphics

/// スライドの帯の輪郭 (曲線スライド / ease のスライド用)。
///
/// 今までの帯は、点ごとに「横に ±幅」ずらした台形をつないでいた。まっすぐの区間はこれでよいが、
/// 曲線で横に大きく流れる所では、帯が進む向きに対して斜めに切ることになるので、道中が細く見えていた。
/// ここでは、帯が進む向きに「直角に ±幅」ずらして輪郭を作る (角は向きの平均でつなぐ) ので、太さがどこでも同じに見える。
/// 始まりと終わりの端だけは、今までどおり横向き (始点・終点の棒と平行) に切る。
enum RibbonOutline {
    /// pts: 帯の中心を通る点 (同じ座標系で、縦横の長さの比が見た目と同じもの)。
    /// halfWidth: 帯の太さの半分。返り値: 片側 (a) と、もう片側 (b) の点 (どちらも pts と同じ順・同じ数)
    static func outline(_ pts: [CGPoint], halfWidth hw: CGFloat) -> (a: [CGPoint], b: [CGPoint]) {
        // 同じ位置が続く点は 1 つにまとめる (向きが決まらないため)
        var p: [CGPoint] = []
        for q in pts {
            if let last = p.last, hypot(q.x - last.x, q.y - last.y) < 0.01 { continue }
            p.append(q)
        }
        let n = p.count
        guard n >= 2 else {
            let q = pts.first ?? .zero
            return ([CGPoint(x: q.x - hw, y: q.y)], [CGPoint(x: q.x + hw, y: q.y)])
        }
        // 区間ごとの向き (長さ 1) と、その左手の向き
        var dirs: [CGPoint] = []
        for i in 0..<(n - 1) {
            let dx = p[i + 1].x - p[i].x
            let dy = p[i + 1].y - p[i].y
            let l = max(1e-9, hypot(dx, dy))
            dirs.append(CGPoint(x: dx / l, y: dy / l))
        }
        func normal(_ d: CGPoint) -> CGPoint { CGPoint(x: -d.y, y: d.x) }

        var a: [CGPoint] = []
        var b: [CGPoint] = []
        a.reserveCapacity(n)
        b.reserveCapacity(n)
        for i in 0..<n {
            if i == 0 || i == n - 1 {
                // 端: 帯の縁の線と、端を通る横の線が交わる所 (端は横向きに切る)
                let d = i == 0 ? dirs[0] : dirs[n - 2]
                let nm = normal(d)
                let pa = CGPoint(x: p[i].x + nm.x * hw, y: p[i].y + nm.y * hw)
                let pb = CGPoint(x: p[i].x - nm.x * hw, y: p[i].y - nm.y * hw)
                if abs(d.y) > 0.25 {
                    // 縁の線 pa + t·d が、横の線 y = p.y と交わる t
                    let ta = (p[i].y - pa.y) / d.y
                    let tb = (p[i].y - pb.y) / d.y
                    var xa = pa.x + d.x * ta
                    var xb = pb.x + d.x * tb
                    // 横に寝すぎた区間で端が伸びすぎないように (太さの 3 倍まで)
                    xa = min(max(xa, p[i].x - 3 * hw), p[i].x + 3 * hw)
                    xb = min(max(xb, p[i].x - 3 * hw), p[i].x + 3 * hw)
                    a.append(CGPoint(x: xa, y: p[i].y))
                    b.append(CGPoint(x: xb, y: p[i].y))
                } else {
                    // ほぼ横向きの区間 (横に飛ぶ線): 今までどおり横にずらす
                    let s: CGFloat = nm.x >= 0 ? 1 : -1
                    a.append(CGPoint(x: p[i].x + s * hw, y: p[i].y))
                    b.append(CGPoint(x: p[i].x - s * hw, y: p[i].y))
                }
            } else {
                // 途中: 前後の向きの平均の向きにずらす。角で細くならないよう、角度に応じて長くする (上限 4 倍)
                let n1 = normal(dirs[i - 1])
                let n2 = normal(dirs[i])
                var mx = n1.x + n2.x
                var my = n1.y + n2.y
                let ml = hypot(mx, my)
                if ml < 1e-6 {
                    mx = n1.x
                    my = n1.y
                } else {
                    mx /= ml
                    my /= ml
                }
                let cosv = max(0.25, mx * n1.x + my * n1.y)
                let len = hw / cosv
                a.append(CGPoint(x: p[i].x + mx * len, y: p[i].y + my * len))
                b.append(CGPoint(x: p[i].x - mx * len, y: p[i].y - my * len))
            }
        }
        return (a, b)
    }

    /// 輪郭を 1 つの閉じた形にする (a を順に、b を逆順に)
    static func addOutline(_ path: CGMutablePath, _ a: [CGPoint], _ b: [CGPoint]) {
        guard let f = a.first else { return }
        path.move(to: f)
        for q in a.dropFirst() { path.addLine(to: q) }
        for q in b.reversed() { path.addLine(to: q) }
        path.closeSubpath()
    }
}
