import Foundation
import AVFoundation
import QuartzCore

/// びーとりの効果音。エディタの再生中のノーツ音と、テストプレイの打鍵音で使う。
///   ・白タップ / ホールド・スライドの始点 (タップ) = tap
///   ・ワイプ / 始点がワイプ                     = yellow
///   ・赤タップ                                  = red_note (本家と同じく tap も一緒に鳴らす)
///   ・ホールド / スライドを押さえている間          = キラキラした高い持続音 (コードで作った音。押さえている間だけ鳴り続ける)
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
    var holdLevel: Float = 0.45

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

    /// ホールド / スライドを押さえている間の音: キラキラした高い持続音 (音ゲーのホールド音っぽいもの。自作)。
    /// ・G6 / D7 / G7 / D8 の和音 (5 度の重ね) を、少しだけずらした高さの音と重ねて「揺らぎ」を出す (左右でずらし方を変えて広がりも)
    /// ・1 秒に 10 回、軽く音量を揺らしてキラキラ感を出す
    /// 2 秒をくり返す。どの音も 2 秒でちょうど元に戻る高さ (0.5Hz 刻み) にしてあるので、継ぎ目でプツッとならない
    private static func makeHoldNoise(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let count = Int(sr * 2.0)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(count)
        // (高さ Hz, 大きさ)
        let tones: [(Double, Double)] = [(1568, 0.5), (2349, 0.3), (3136, 0.15), (4698, 0.06)]
        var raw: [[Double]] = [Array(repeating: 0, count: count), Array(repeating: 0, count: count)]
        var sum = 0.0
        for c in 0..<2 {
            let detune = 1.5 + 0.5 * Double(c)          // 左は +1.5Hz、右は +2Hz ずらした音を重ねる
            for i in 0..<count {
                let t = Double(i) / sr
                var v = 0.0
                for (f, a) in tones {
                    v += a * sin(2.0 * Double.pi * f * t)
                    v += a * sin(2.0 * Double.pi * (f + detune) * t + Double(c))
                }
                v *= 0.8 + 0.2 * sin(2.0 * Double.pi * 10.0 * t)     // キラキラの揺れ
                raw[c][i] = v
                sum += v * v
            }
        }
        // 大きさは平均の音量 (RMS) でそろえる。最終的な大きさは holdLevel で調整
        let rms = (sum / Double(2 * count)).squareRoot()
        let gain = rms > 0 ? 0.18 / rms : 0
        for c in 0..<2 {
            for i in 0..<count {
                ch[c][i] = Float(raw[c][i] * gain)
            }
        }
        return buf
    }
}
