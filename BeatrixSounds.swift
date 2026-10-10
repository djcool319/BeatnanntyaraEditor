import Foundation
import AVFoundation
import QuartzCore

/// びーとりの効果音。エディタの再生中のノーツ音と、テストプレイの打鍵音で使う。
///   ・白タップ / ホールド・スライドの始点 (タップ) = tap
///   ・ワイプ / 始点がワイプ                     = yellow
///   ・赤タップ                                  = red_note (本家と同じく tap も一緒に鳴らす)
///   ・ホールド / スライドを押さえている間          = 小さな鈴がきらきら鳴る音 (コードで作った音。押さえている間だけ鳴り続ける)
/// 音量は SETTING の「ノーツサウンドの音量」(KeySound.shared.volume) に従う。
/// 音のデータは BeatrixSoundData.swift (wav を変換して埋め込んだもの)。
///
/// すべてメインスレッドから呼ぶこと。
final class BeatrixSounds {
    static let shared = BeatrixSounds()

    enum Kind {
        case tap, wipe, red
    }

    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var cursor = 0
    private var pendingUntil: [Double] = []      // ノードごとの「先行予約した音が鳴り終わる時刻」(CACurrentMediaTime と同じ時間軸)
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private let holdNode = AVAudioPlayerNode()
    private var holdBuffer: AVAudioPCMBuffer?
    private var holdOn = false
    private var configured = false
    private static let voices = 12               // 同時に鳴らせる数 (ラウンドロビン)
    private static let sampleRate = 44100.0

    /// 「しゅ〜」の大きさ (ノーツ音の音量に対する比。1.0 でタップ音と同じくらいの大きさ)
    var holdLevel: Float = 0.5

    private init() {}

    private var volume: Float { min(max(KeySound.shared.volume, 0), 1) }

    // MARK: 準備

    func prepare() {
        _ = ensureRunning()
    }

    private func configureIfNeeded() {
        if configured { return }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) else { return }
        buffers[.tap] = Self.decode(BeatrixSoundData.tap, format: fmt)
        buffers[.wipe] = Self.decode(BeatrixSoundData.wipe, format: fmt)
        buffers[.red] = Self.decode(BeatrixSoundData.red, format: fmt)
        holdBuffer = Self.makeHoldNoise(format: fmt)
        for _ in 0..<Self.voices {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: fmt)
            nodes.append(n)
        }
        engine.attach(holdNode)
        engine.connect(holdNode, to: engine.mainMixerNode, format: fmt)
        holdNode.volume = 0
        pendingUntil = Array(repeating: 0, count: nodes.count)
        configured = true
    }

    private func ensureRunning() -> Bool {
        configureIfNeeded()
        guard configured else { return false }
        if !engine.isRunning {
            AudioSessionSetup.activate()
            engine.prepare()
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        for n in nodes where !n.isPlaying { n.play() }
        engine.mainMixerNode.outputVolume = volume
        return true
    }

    // MARK: 鳴らす

    /// すぐ鳴らす (テストプレイの打鍵・SETTING の試聴)
    func playNow(_ kind: Kind) {
        guard volume > 0.001, ensureRunning() else { return }
        for k in parts(of: kind) {
            guard let buf = buffers[k] else { continue }
            let n = nodes[cursor]
            cursor = (cursor + 1) % nodes.count
            n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }
    }

    /// time: CACurrentMediaTime() と同じ時間軸 (秒)。すでに過ぎていたらすぐ鳴らす (エディタの再生中の先行予約)
    func play(_ kind: Kind, atTime time: Double) {
        guard volume > 0.001, ensureRunning() else { return }
        for k in parts(of: kind) {
            guard let buf = buffers[k] else { continue }
            let idx = cursor
            let n = nodes[idx]
            cursor = (cursor + 1) % nodes.count
            if time > CACurrentMediaTime() + 0.002 {
                let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time))
                n.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
                let dur = Double(buf.frameLength) / Self.sampleRate
                pendingUntil[idx] = max(pendingUntil[idx], time + dur + 0.01)
            } else {
                n.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
            }
        }
    }

    /// 赤タップは、本家と同じく tap と red_note を重ねる
    private func parts(of kind: Kind) -> [Kind] {
        kind == .red ? [.tap, .red] : [kind]
    }

    /// 予約済み (まだ鳴っていない) の音を捨てる (エディタの停止・シーク時)
    func cancelScheduled() {
        guard configured else { return }
        let now = CACurrentMediaTime()
        let running = engine.isRunning
        for i in nodes.indices where pendingUntil[i] > now {
            if running { nodes[i].stop() }
            pendingUntil[i] = 0
        }
    }

    // MARK: ホールド / スライドの「しゅ〜」

    /// 押さえている間 true を渡し続ける (毎フレーム呼んでよい。変わったときだけ鳴らす / 止める)
    func setHold(_ on: Bool) {
        if on == holdOn { return }
        holdOn = on
        if on {
            guard volume > 0.001, ensureRunning(), let buf = holdBuffer else { return }
            holdNode.volume = holdLevel
            holdNode.scheduleBuffer(buf, at: nil, options: [.loops, .interrupts], completionHandler: nil)
            holdNode.play()
        } else if configured {
            holdNode.volume = 0
            holdNode.stop()
        }
    }

    // MARK: 音のデータ

    /// 埋め込んだ 16bit・ステレオ (左右交互) の PCM を、再生用のバッファにする
    private static func decode(_ base64: String, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let frames = data.count / 4
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        let l = ch[0]
        let r = ch[1]
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let a = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
                let b = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                l[i] = Float(a) / 32768
                r[i] = Float(b) / 32768
            }
        }
        return buf
    }

    /// ホールド / スライドを押さえている間の音: 小さな鈴がランダムにきらきら鳴る音 + ごく薄い高音の響き (自作)。
    /// ・C7 / G7 の柔らかい響きを小さく鳴らし続ける (少しずらした高さを重ねて、ゆっくり揺らぐ)
    /// ・その上に、E7〜E8 あたりの短い「チリン」を 2 秒に 28 回、ランダムな時刻・高さ・左右で重ねる
    /// 2 秒をくり返す。響きは 2 秒でちょうど元に戻る高さ (0.5Hz 刻み)、「チリン」は 2 秒の終わりからはみ出した分を頭に回してあるので、継ぎ目が分からない
    private static func makeHoldNoise(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let count = Int(sr * 2.0)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(count)
        var raw: [[Double]] = [Array(repeating: 0, count: count), Array(repeating: 0, count: count)]
        // 柔らかい響き
        for c in 0..<2 {
            let ph = Double(c)
            for i in 0..<count {
                let t = Double(i) / sr
                var v = 0.5 * sin(2.0 * Double.pi * 2093 * t + ph) + 0.5 * sin(2.0 * Double.pi * 2094 * t)
                v += 0.3 * sin(2.0 * Double.pi * 3136 * t) + 0.3 * sin(2.0 * Double.pi * 3137.5 * t + ph)
                raw[c][i] = v * 0.18
            }
        }
        // きらきら (短い鈴の音をランダムに)
        var seed: UInt32 = 24680
        func rnd() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed) / 4294967295.0
        }
        let bells: [Double] = [2637, 3136, 3520, 3951, 4186, 4699, 5274]
        let len = Int(sr * 0.18)
        for _ in 0..<28 {
            let start = Int(rnd() * Double(count))
            let f = bells[min(bells.count - 1, Int(rnd() * Double(bells.count)))]
            let amp = 0.5 + 0.5 * rnd()
            let pan = rnd()
            for k in 0..<len {
                let tt = Double(k) / sr
                let env = exp(-tt / 0.045) * min(1.0, tt / 0.002)
                let v = amp * env * (sin(2.0 * Double.pi * f * tt) + 0.3 * sin(2.0 * Double.pi * f * 2.01 * tt))
                let idx = (start + k) % count
                raw[0][idx] += v * (1.0 - pan * 0.6)
                raw[1][idx] += v * (0.4 + pan * 0.6)
            }
        }
        // 大きさは平均の音量 (RMS) でそろえる (控えめ)。最終的な大きさは holdLevel で調整
        var sum = 0.0
        for c in 0..<2 { for v in raw[c] { sum += v * v } }
        let rms = (sum / Double(2 * count)).squareRoot()
        let gain = rms > 0 ? 0.10 / rms : 0
        for c in 0..<2 {
            for i in 0..<count {
                ch[c][i] = Float(max(-1.0, min(1.0, raw[c][i] * gain)))
            }
        }
        return buf
    }
}
