import Foundation
import Accelerate

// MARK: - BPM・offset の自動検出 (Malody の「BPM / offset の解析」のようなもの)
//
// 流れ:
//   1. 曲を読み込んで (最大 6 分)、左右を混ぜて 1 本にする
//   2. 音の立ち上がりの強さ (スペクトルフラックス。窓 512) を 128 サンプルごと (44.1kHz で約 2.9ms) に求める
//   3. BPM: 立ち上がりの列に、いろいろな BPM の「拍の波」(とその 2〜4 倍の波) を当てて、いちばん合うものを探す。
//        ・まず 0.25 刻みで大まかに (170 前後を優先)
//        ・次に、曲の頭から最大 2 分を使って 0.002 刻みで細かく
//        ・倍 (×2) と半分 (÷2) も候補として出す (どちらが正しいかは曲の感じ方しだいなので、人が選ぶ)
//        ・整数 / 0.5 刻みに近ければ、その値に丸める
//   4. offset: 選んだ BPM の拍の位置 (位相) を、曲の最初の 30 秒で「拍の位置の立ち上がりの合計」が最大になるところに決め、
//        さらに拍ごとのずれの中央値で細かく合わせる (解析の窓のぶん約 2ms 早く出るので、そのぶん足す)。0 拍目は「音が鳴り始めたところにいちばん近い拍」。
//        JSON の offset (サンプル数) = 0 拍目の秒 × 曲のサンプリング周波数 + SETTING の「再生の補正」
//        (エディタでノーツ音がちょうど音に重なる値 = 今の基準)
//   5. BPM 変化: 15 秒ずつずらしながら局所の BPM を見て、最初の BPM から 1% 以上ずれた区間が続いたら
//        「このあたりで変わっていそう」と知らせるだけ (自動では入れない。誤検出しやすいため)

final class BeatrixTempoAnalysis {
    let sampleRate: Double
    /// 検出した BPM (丸める前)
    let rawBPM: Double
    /// 候補 (先頭がおすすめ。丸めた値)
    let candidates: [Double]
    /// BPM が変わっていそうな場所の説明 (なければ nil)
    let changeHint: String?
    /// 音が鳴り始めた秒
    let musicStart: Double

    private let env: [Double]          // 立ち上がりの強さ (フレームごと)
    private let frameRate: Double      // 1 秒あたりのフレーム数
    private let frameShift: Double     // フレーム n の時刻 = n / frameRate + frameShift

    fileprivate init(sampleRate: Double, rawBPM: Double, candidates: [Double], changeHint: String?, musicStart: Double,
                     env: [Double], frameRate: Double, frameShift: Double) {
        self.sampleRate = sampleRate
        self.rawBPM = rawBPM
        self.candidates = candidates
        self.changeHint = changeHint
        self.musicStart = musicStart
        self.env = env
        self.frameRate = frameRate
        self.frameShift = frameShift
    }

    /// その BPM での 0 拍目の秒 (曲の頭から)
    func firstBeatSec(bpm: Double) -> Double {
        BeatrixTempoDetector.firstBeat(env: env, frameRate: frameRate, shift: frameShift, bpm: bpm, musicStart: musicStart)
    }

    /// その BPM での JSON の offset (サンプル数。再生の補正込み = 今の基準)。halfBeat: 半拍うしろへずらす (裏拍を拍と取り違えたとき用)
    func offsetRaw(bpm: Double, halfBeat: Bool = false) -> Int {
        var t = firstBeatSec(bpm: bpm)
        if halfBeat {
            let half = 30 / bpm
            t = t >= half ? t - half : t + half          // 0 拍目が 0 秒より前にならないよう、近いほうへ
        }
        return Int((t * sampleRate).rounded()) + Beatrix.playbackCorrectionSamples
    }
}

enum BeatrixTempoDetector {
    struct Failure: Error {
        let text: String
    }

    private static let fftSize = 512
    private static let hop = 128
    private static let maxSeconds = 360.0

    /// 曲のファイルを解析する (時間が掛かるので、メインスレッド以外で呼ぶ)。cancelled が true を返したら途中でやめる
    static func analyze(url: URL, cancelled: () -> Bool) throws -> BeatrixTempoAnalysis {
        let isOgg = url.pathExtension.lowercased() == "ogg"
        let src: PCMSource = isOgg ? try OggPCMSource(url: url) : try FilePCMSource(url: url)
        let sr = src.sampleRate
        guard sr > 0 else { throw Failure(text: "曲のサンプリング周波数が分かりません") }

        // 1. 読み込み (モノラル)
        let chunk = 32768
        var l = [Float](repeating: 0, count: chunk)
        var r = [Float](repeating: 0, count: chunk)
        var mono: [Float] = []
        let limit = Int(sr * maxSeconds)
        mono.reserveCapacity(min(limit, Int(sr * 240)))
        src.seek(to: 0)
        while mono.count < limit {
            if cancelled() { throw Failure(text: "取り消しました") }
            let n = l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    src.read(into: lp.baseAddress!, rp.baseAddress!, frames: chunk)
                }
            }
            if n <= 0 { break }
            for i in 0..<n { mono.append((l[i] + r[i]) * 0.5) }
        }
        guard mono.count > Int(sr * 8) else { throw Failure(text: "曲が短すぎて解析できません (8 秒以上必要です)") }

        // 2. 立ち上がりの強さ
        let (flux, energy) = try onsetStrength(mono, cancelled: cancelled)
        let frameRate = sr / Double(hop)
        let shift = Double(fftSize / 2) / sr            // フレームの時刻 = 窓の真ん中
        let env = postProcess(flux, frameRate: frameRate)

        // 音が鳴り始めたフレーム (いちばん大きいところから -30dB)
        let maxE = energy.max() ?? 0
        var startFrame = 0
        if maxE > 0 {
            let th = maxE * 0.001
            startFrame = energy.firstIndex { $0 > th } ?? 0
        }
        let musicStart = Double(startFrame) / frameRate + shift
        if cancelled() { throw Failure(text: "取り消しました") }

        // 3. BPM (大まかに)
        let coarseEnd = min(env.count, startFrame + Int(60 * frameRate))
        let coarseSeg = Array(env[startFrame..<coarseEnd])
        guard coarseSeg.count > Int(6 * frameRate) else { throw Failure(text: "音の鳴っている部分が短すぎて解析できません") }
        let step = 0.25
        let lo = 30.0
        let hi = 1680.0
        let count = Int((hi - lo) / step) + 1
        var mag = [Double](repeating: 0, count: count)
        for i in 0..<count {
            if i % 200 == 0 && cancelled() { throw Failure(text: "取り消しました") }
            mag[i] = beatMagnitude(coarseSeg, frameRate: frameRate, bpm: lo + Double(i) * step)
        }
        func m(_ bpm: Double) -> Double {
            let i = Int(((bpm - lo) / step).rounded())
            var best = 0.0
            for j in (i - 1)...(i + 1) where j >= 0 && j < count { best = max(best, mag[j]) }
            return best
        }
        // 拍の波だけだと、裏拍 (8 分のハイハットなど) で打ち消されて弱くなることがあるので、2〜4 倍の波も足す
        func harm(_ b: Double) -> Double { m(b) + m(b * 2) + 0.5 * m(b * 3) + 0.5 * m(b * 4) }
        var bestB = 120.0
        var bestS = -1.0
        var b = 60.0
        while b <= 420.0 {
            let s = harm(b)
            let oct = log2(b / 170.0)
            let w = exp(-0.5 * (oct / 0.7) * (oct / 0.7))
            if s * w > bestS {
                bestS = s * w
                bestB = b
            }
            b += step
        }

        // 細かく (頭から最大 2 分)
        let fineEnd = min(env.count, startFrame + Int(120 * frameRate))
        let fineSeg = Array(env[startFrame..<fineEnd])
        func fineHarm(_ b: Double) -> Double {
            beatMagnitude(fineSeg, frameRate: frameRate, bpm: b) + beatMagnitude(fineSeg, frameRate: frameRate, bpm: b * 2)
                + 0.5 * beatMagnitude(fineSeg, frameRate: frameRate, bpm: b * 3) + 0.5 * beatMagnitude(fineSeg, frameRate: frameRate, bpm: b * 4)
        }
        var fineB = bestB
        var fineM = -1.0
        var fb = bestB - 0.6
        while fb <= bestB + 0.6 {
            if cancelled() { throw Failure(text: "取り消しました") }
            let v = fineHarm(fb)
            if v > fineM {
                fineM = v
                fineB = fb
            }
            fb += 0.01
        }
        var fb2 = fineB - 0.012
        let center = fineB
        while fb2 <= center + 0.012 {
            let v = fineHarm(fb2)
            if v > fineM {
                fineM = v
                fineB = fb2
            }
            fb2 += 0.001
        }
        if cancelled() { throw Failure(text: "取り消しました") }

        var cands: [Double] = [snap(fineB)]
        for alt in [fineB * 2, fineB / 2] where alt >= 40 && alt <= 900 {
            cands.append(snap(alt))
        }

        // 5. BPM 変化の目安
        let hint = changeHint(env: env, frameRate: frameRate, shift: shift, from: startFrame, bpm: fineB)

        return BeatrixTempoAnalysis(sampleRate: sr, rawBPM: fineB, candidates: cands, changeHint: hint, musicStart: musicStart,
                                    env: env, frameRate: frameRate, frameShift: shift)
    }

    /// 整数 / 0.5 刻みに近ければ丸める。それ以外は小数 2 桁
    static func snap(_ b: Double) -> Double {
        let r1 = b.rounded()
        if abs(b - r1) <= 0.05 { return r1 }
        let r2 = (b * 2).rounded() / 2
        if abs(b - r2) <= 0.04 { return r2 }
        return (b * 100).rounded() / 100
    }

    // MARK: 立ち上がりの強さ

    private static func onsetStrength(_ x: [Float], cancelled: () -> Bool) throws -> (flux: [Double], energy: [Double]) {
        let n = fftSize
        let half = n / 2
        let frames = (x.count - n) / hop + 1
        guard frames > 10 else { return ([], []) }
        let log2n = vDSP_Length(9)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw Failure(text: "FFT を準備できません")
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var pw = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: half)
        var cur = [Float](repeating: 0, count: half)
        var flux = [Double](repeating: 0, count: frames)
        var energy = [Double](repeating: 0, count: frames)

        for f in 0..<frames {
            if f % 4000 == 0 && cancelled() { throw Failure(text: "取り消しました") }
            let start = f * hop
            var e: Float = 0
            x.withUnsafeBufferPointer { xp in
                vDSP_svesq(xp.baseAddress! + start, 1, &e, vDSP_Length(n))
                vDSP_vmul(xp.baseAddress! + start, 1, window, 1, &buf, 1, vDSP_Length(n))
            }
            energy[f] = Double(e)
            buf.withUnsafeBufferPointer { bp in
                bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(half))
                            vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                            pw.withUnsafeMutableBufferPointer { pp in
                                vDSP_zvmags(&sc, 1, pp.baseAddress!, 1, vDSP_Length(half))
                            }
                        }
                    }
                }
            }
            // 対数で圧縮 (小さい音の立ち上がりも拾う)
            var s: Double = 0
            for k in 1..<half {
                let v = log1pf(10 * sqrtf(pw[k]))
                cur[k] = v
                let d = v - prev[k]
                if d > 0 { s += Double(d) }
            }
            flux[f] = f == 0 ? 0 : s
            swap(&prev, &cur)
        }
        return (flux, energy)
    }

    /// 近くの平均を引いて、マイナスを 0 にする (ゆっくりした音量の変化を消して、立ち上がりだけ残す)
    private static func postProcess(_ flux: [Double], frameRate: Double) -> [Double] {
        let n = flux.count
        guard n > 0 else { return [] }
        let w = max(1, Int(0.1 * frameRate))
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cum[i + 1] = cum[i] + flux[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - w)
            let b = min(n, i + w + 1)
            let mean = (cum[b] - cum[a]) / Double(b - a)
            out[i] = max(0, flux[i] - mean)
        }
        return out
    }

    // MARK: 拍の波との合い具合

    /// その BPM の拍の波 (複素数) と、立ち上がりの列との内積の大きさ
    static func beatMagnitude(_ seg: [Double], frameRate: Double, bpm: Double) -> Double {
        let c = beatPhasor(seg, frameRate: frameRate, bpm: bpm, firstFrame: 0)
        return (c.re * c.re + c.im * c.im).squareRoot()
    }

    /// Σ env[n] · e^{-2πi · (n + firstFrame) / (1 拍のフレーム数)}
    static func beatPhasor(_ seg: [Double], frameRate: Double, bpm: Double, firstFrame: Int) -> (re: Double, im: Double) {
        let w = 2 * Double.pi * (bpm / 60) / frameRate
        let cw = cos(w)
        let sw = -sin(w)
        let p0 = -w * Double(firstFrame)
        var zr = cos(p0)
        var zi = sin(p0)
        var ar = 0.0
        var ai = 0.0
        var k = 0
        for v in seg {
            ar += v * zr
            ai += v * zi
            let nr = zr * cw - zi * sw
            zi = zr * sw + zi * cw
            zr = nr
            k += 1
            if k == 1024 {
                // 誤差がたまらないよう、ときどき大きさを 1 に戻す
                let mm = (zr * zr + zi * zi).squareRoot()
                zr /= mm
                zi /= mm
                k = 0
            }
        }
        return (ar, ai)
    }

    // MARK: offset (0 拍目)

    static func firstBeat(env: [Double], frameRate: Double, shift: Double, bpm: Double, musicStart: Double) -> Double {
        guard bpm > 0, !env.isEmpty else { return max(0, musicStart) }
        let period = 60 / bpm
        let periodF = period * frameRate
        let startFrame = max(0, Int((musicStart - shift) * frameRate))
        let endFrame = min(env.count, startFrame + Int(30 * frameRate))
        guard endFrame > startFrame + 4 else { return max(0, musicStart) }
        let seg = Array(env[startFrame..<endFrame])

        // 位相: 拍の位置 (1 拍おき) の立ち上がりの合計がいちばん大きくなる位置 (フレーム単位、0 ..< periodF)。
        // 少しのずれを許すため、立ち上がりの列を軽くぼかしてから足す
        var sm = [Double](repeating: 0, count: env.count)
        let g: [Double] = (-6...6).map { exp(-0.5 * Double($0 * $0) / 4.0) }
        for i in startFrame..<endFrame {
            var v = 0.0
            for (j, gw) in g.enumerated() {
                let k = i + j - 6
                if k >= 0 && k < env.count { v += env[k] * gw }
            }
            sm[i] = v
        }
        func smAt(_ f: Double) -> Double {
            let i = Int(f.rounded(.down))
            if i < 0 || i + 1 >= sm.count { return 0 }
            let u = f - Double(i)
            return sm[i] * (1 - u) + sm[i + 1] * u
        }
        var phaseF = 0.0
        var bestComb = -1.0
        var p = 0.0
        while p < periodF {
            var f = p + ((Double(startFrame) - p) / periodF).rounded(.up) * periodF
            var sum = 0.0
            while f < Double(endFrame) {
                sum += smAt(f)
                f += periodF
            }
            if sum > bestComb {
                bestComb = sum
                phaseF = p
            }
            p += 0.25
        }

        // 拍ごとに、近くのいちばん強い立ち上がりとのずれを測り、強いもの半分の中央値だけ動かす
        var devs: [(d: Double, s: Double)] = []
        let win = max(2, Int(periodF * 0.15))
        var beatF = phaseF + (Double(startFrame) / periodF).rounded(.down) * periodF
        while beatF < Double(endFrame) {
            let ci = Int(beatF.rounded())
            if ci - win >= startFrame && ci + win < endFrame {
                var bi = ci
                var bv = -1.0
                for j in (ci - win)...(ci + win) where env[j] > bv {
                    bv = env[j]
                    bi = j
                }
                if bv > 0 && bi > 0 && bi < env.count - 1 {
                    // 山の頂上を、前後の値から放物線で細かく
                    let a = env[bi - 1]
                    let b = env[bi]
                    let cc = env[bi + 1]
                    let den = a - 2 * b + cc
                    let off = den != 0 ? max(-0.5, min(0.5, 0.5 * (a - cc) / den)) : 0
                    devs.append((d: Double(bi) + off - beatF, s: bv))
                }
            }
            beatF += periodF
        }
        if devs.count >= 4 {
            let strong = devs.sorted { $0.s > $1.s }.prefix(max(2, devs.count / 2)).map { $0.d }.sorted()
            phaseF += strong[strong.count / 2]
        }

        // 0 拍目 = 音が鳴り始めたところ (最初のはっきりした立ち上がり) にいちばん近い拍
        let sortedVals = seg.sorted()
        let p95 = sortedVals[min(sortedVals.count - 1, Int(Double(sortedVals.count) * 0.95))]
        var onsetF = Double(startFrame)
        if let i = seg.firstIndex(where: { $0 > p95 * 0.3 }) { onsetF = Double(startFrame + i) }
        let k = ((onsetF - phaseF) / periodF).rounded()
        // 解析の窓のぶん、立ち上がりが約 2ms 早く出るので足す
        var t = (phaseF + k * periodF) / frameRate + shift + 0.002
        while t < 0 { t += period }
        return t
    }

    // MARK: BPM 変化の目安

    private static func changeHint(env: [Double], frameRate: Double, shift: Double, from startFrame: Int, bpm: Double) -> String? {
        let winF = Int(15 * frameRate)
        let stepF = Int(7.5 * frameRate)
        var flagged: [Int] = []           // ずれていた窓の始まりのフレーム
        var flaggedBPM: [Double] = []
        var pos = startFrame
        while pos + winF <= env.count {
            let seg = Array(env[pos..<(pos + winF)])
            func hm(_ x: Double) -> Double {
                beatMagnitude(seg, frameRate: frameRate, bpm: x) + beatMagnitude(seg, frameRate: frameRate, bpm: x * 2)
            }
            let here = hm(bpm)
            var bestB = bpm
            var bestM = here
            var b = bpm * 0.94
            while b <= bpm * 1.06 {
                let v = hm(b)
                if v > bestM {
                    bestM = v
                    bestB = b
                }
                b += bpm * 0.002
            }
            if abs(bestB - bpm) / bpm > 0.01 && bestM > here * 1.3 {
                flagged.append(pos)
                flaggedBPM.append(bestB)
            } else {
                flagged.append(-1)
                flaggedBPM.append(0)
            }
            pos += stepF
        }
        // 2 つ続けてずれていたところを、変わっていそうな場所として出す
        for i in 1..<max(1, flagged.count) where flagged[i] >= 0 && flagged[i - 1] >= 0 {
            let sec = Double(flagged[i - 1]) / frameRate + shift
            let mm = Int(sec) / 60
            let ss = Int(sec) % 60
            let nb = (flaggedBPM[i] + flaggedBPM[i - 1]) / 2
            return String(format: "%d:%02d あたりから BPM が変わっていそうです (約 %.1f)。途中の BPM 変化は自動では入れないので、BPM list で入れてください", mm, ss, nb)
        }
        return nil
    }
}
