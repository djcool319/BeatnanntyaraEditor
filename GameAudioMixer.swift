// MARK: - 音声システム (C++ のミキサー版。GitHub Actions のビルド = ipa のときだけ)
//
// これまで (Swift Playgrounds で動かす前提の作り) は、
//   ・曲     … AVAudioEngine の AVAudioPlayerNode
//   ・ノーツ音 … 別の AVAudioEngine (BeatrixSounds) に「この時刻に鳴らして」と時刻で予約
// の 2 本立てだった。2 つのエンジンはそれぞれ出力の遅れ・時計を持つので、ノーツ音と曲は「時刻の計算」でしか合わず、
// 出力の遅れの見積もりのずれ・時計のずれ・予約の丸めの分だけ、少しずつずれていた。
//
// この版は、曲とノーツ音を「1 本の音の流れ」の中で混ぜる (Vendor/CBxAudio の C++ のミキサー)。
//   ・曲の PCM はデコード用のスレッドがリングバッファに書く。出力 (AVAudioSourceNode) がそれを読む
//   ・ノーツ音は「タイムラインのフレーム番号」(= 再生を始めてから出力したフレーム数) で予約する。
//     曲のサンプルと同じ番号で数えるので、ノーツ音は曲のそのサンプルとぴったり同じ位置で鳴る
//     (出力の遅れ・時計・画面のフレームに関係なく、サンプル単位で合う)
//   ・テストプレイの打鍵音・ワイプ音・「しゅ〜」も同じミキサーで鳴らす (別のエンジンの遅れが乗らない)
//   ・画面の時計は、ミキサーが出力したブロックの「タイムラインのフレーム」と「ホスト時刻」から作る
//
// 使う側 (EditorState / BeatrixPlayView / GameView) から見た使い方は、これまでの GameAudio と同じ。
// 足したもの: mixesSE / scheduleSE / playSENow / setHoldSE / cancelSE / setSEVolume

#if canImport(CBxAudio)
import Foundation
import AVFoundation
import CBxAudio

final class GameAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private let mixer: OpaquePointer
    private let source: PCMSource
    private let cache: CachedPCMSource?
    private let format: AVAudioFormat
    private let sr: Double

    /// 曲のファイルのサンプリング周波数
    var sampleRate: Double { sr }

    // デコード (decodeQueue 上でだけ触る)
    private let decodeQueue = DispatchQueue(label: "bx.decode", qos: .userInteractive)
    private var pumpTimer: DispatchSourceTimer?
    private let chunk = 4096
    private let ringFrames = 1 << 18                // 曲のリングバッファ (44.1kHz で約 5.9 秒)
    private let tmpL: UnsafeMutablePointer<Float>
    private let tmpR: UnsafeMutablePointer<Float>
    private var srcEOF = false
    private var minBuffered = Int.max               // 診断: 再生中にリングバッファの曲がいちばん少なくなった値 (フレーム)

    private let genLock = NSLock()
    private var _generation = 0
    private var generation: Int {
        genLock.lock(); defer { genLock.unlock() }
        return _generation
    }
    @discardableResult
    private func bumpGeneration() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        _generation += 1
        return _generation
    }
    private let runLock = NSLock()
    private var _pumpRunning = false                // 再生中か (decodeQueue からも読む)
    private var pumpRunning: Bool {
        get { runLock.lock(); defer { runLock.unlock() }; return _pumpRunning }
        set { runLock.lock(); _pumpRunning = newValue; runLock.unlock() }
    }

    // 時計 (メインのスレッドでだけ触る)
    private var baseFrame: Int64 = 0                // タイムラインの lead フレーム目 = 曲のこのフレーム
    private var lead: Int64 = 0                     // 曲の頭より前の無音のフレーム数
    private var offsetTotal = 0.0                   // 譜面時刻 = 曲の位置 + offsetTotal
    private var latency = 0.0                       // 出力の遅れ (出力バッファ + 機器)
    private var beginUptime = 0.0
    private(set) var running = false
    private var warmKey: (base: Int64, lead: Int64)? = nil
    private var warmGroup: DispatchGroup?
    private var holdOn = false
    private(set) var lastBeginMs = 0.0
    private(set) var lastBeginWarm = false
    private(set) var lastBeginCached = false
    var hasCache: Bool { cache != nil }

    // 再生速度 (1.0 未満は、伸ばした音を流す。TimeStretch.swift / RubberBandPCMSource.swift)
    private var stretched: PCMSource?
    private(set) var stretchEngine = ""
    private(set) var stretchSize = 1024
    private(set) var rate = 1.0
    private var activeSource: PCMSource { stretched ?? source }

    /// ノーツ音を曲と同じ流れで鳴らせる (このビルドでは常に true)
    var mixesSE: Bool { true }

    init(url: URL, cache useCache: Bool = false) throws {
        let isOgg = url.pathExtension.lowercased() == "ogg"
        let make: () throws -> PCMSource = {
            if isOgg { return try OggPCMSource(url: url) }
            return try FilePCMSource(url: url)
        }
        let base = try make()
        let src: PCMSource
        var cached: CachedPCMSource? = nil
        if useCache {
            let c = CachedPCMSource(live: base, makeFiller: make)
            cached = c
            src = c
        } else {
            src = base
        }
        let rate = src.sampleRate
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            throw AudioLoadError(text: "音声フォーマットを作れません")
        }
        guard let mx = bx_new(rate, Int32(1 << 18)) else {
            throw AudioLoadError(text: "ミキサーを作れません")
        }
        source = src
        cache = cached
        sr = rate
        format = f
        mixer = mx
        tmpL = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        tmpR = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        tmpL.initialize(repeating: 0, count: 16384)
        tmpR.initialize(repeating: 0, count: 16384)

        // ノーツ音を登録 (曲と同じサンプリング周波数に直して)
        for s in BeatrixSounds.mixerSounds(sampleRate: rate) {
            s.l.withUnsafeBufferPointer { lp in
                s.r.withUnsafeBufferPointer { rp in
                    bx_set_sound(mx, s.id, lp.baseAddress, rp.baseAddress, Int32(s.l.count))
                }
            }
        }
        bx_set_se_gain(mx, min(max(KeySound.shared.volume, 0), 1))

        // 出力: オーディオのスレッドから C++ のミキサーを呼ぶだけ (メモリの確保もロック待ちもしない)
        node = AVAudioSourceNode(format: f) { _, ts, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let t = ts.pointee
            let host: UInt64 = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : 0
            bx_render(mx, host, Int32(frameCount), l, r)
            return noErr
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: f)
        engine.prepare()
        try engine.start()
        cached?.startFilling()

        // リングバッファの補充 (10ms おき。再生中も停止中の先読みも)
        let t = DispatchSource.makeTimerSource(queue: decodeQueue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.pump(self.generation, limit: Int.max)
        }
        t.resume()
        pumpTimer = t
    }

    deinit {
        pumpTimer?.cancel()
        engine.stop()
        bx_free(mixer)
        tmpL.deallocate()
        tmpR.deallocate()
    }

    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// 出力の遅れ (出力バッファ + 機器) の合計 (秒)
    private func totalLatency() -> Double {
        let s = AVAudioSession.sharedInstance()
        return s.outputLatency + s.ioBufferDuration
    }

    /// 譜面時刻 tc から始めるときの、曲のフレームと頭の無音
    private func plan(chartTime tc: Double, offsetTotal off: Double) -> (base: Int64, lead: Int64) {
        let m0 = tc - off
        if m0 >= 0 { return (Int64((m0 * sr).rounded()), 0) }
        return (0, Int64((-m0 * sr / rate).rounded()))
    }

    // MARK: 補充 (decodeQueue 上でだけ)

    /// リングバッファに曲を書く (limit フレームまで / 空きがある分だけ)
    private func pump(_ g: Int, limit: Int) {
        var written = 0
        while generation == g && !srcEOF && written < limit {
            let space = Int(bx_music_space(mixer))
            if space < chunk { break }
            let want = min(chunk, limit - written)
            let n = activeSource.read(into: tmpL, tmpR, frames: want)
            if n <= 0 {
                srcEOF = true
                bx_music_eof(mixer)
                break
            }
            guard generation == g else { return }
            _ = bx_music_write(mixer, tmpL, tmpR, Int32(n))
            written += n
        }
        if pumpRunning && !srcEOF {
            let b = Int(bx_music_buffered(mixer))
            if b < minBuffered { minBuffered = b }
        }
    }

    /// 止めて、曲のフレーム base から (頭に lead フレームの無音) 用意する。最初の少しだけ書いておく
    private func prepare(base: Int64, lead ld: Int64, _ g: Int) {
        bx_reset(mixer, ld)
        srcEOF = false
        activeSource.seek(to: base)
        pump(g, limit: chunk * 2)
    }

    // MARK: 再生

    /// 譜面時刻 chartTime から再生を始める。warm() で同じ位置を用意してあれば、すぐ始まる
    func begin(chartTime tc: Double, offsetTotal off: Double) {
        let t0 = uptime()
        if running { halt() }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        latency = totalLatency()
        offsetTotal = off
        let p = plan(chartTime: tc, offsetTotal: off)
        if let w = warmKey, w.base == p.base, w.lead == p.lead {
            warmGroup?.wait()
            lastBeginWarm = true
        } else {
            let g = bumpGeneration()
            decodeQueue.sync { prepare(base: p.base, lead: p.lead, g) }
            lastBeginWarm = false
        }
        warmKey = nil
        warmGroup = nil
        baseFrame = p.base
        lead = p.lead
        lastBeginCached = cache?.isCached(frame: p.base) ?? false
        cache?.setPaused(true)
        decodeQueue.async { [weak self] in self?.minBuffered = Int.max }
        pumpRunning = true
        holdOn = false
        beginUptime = uptime()
        bx_start(mixer)
        running = true
        lastBeginMs = (uptime() - t0) * 1000
    }

    /// 停止中に、次の再生位置を先に用意しておく (別のスレッドで。メインを止めない)
    func warm(chartTime tc: Double, offsetTotal off: Double) {
        guard !running else { return }
        let p = plan(chartTime: tc, offsetTotal: off)
        cache?.setFocus(frame: p.base)
        if let w = warmKey, w.base == p.base, w.lead == p.lead { return }
        let g = bumpGeneration()
        warmKey = p
        let grp = DispatchGroup()
        grp.enter()
        warmGroup = grp
        decodeQueue.async { [weak self] in
            guard let self = self, self.generation == g else { grp.leave(); return }
            self.prepare(base: p.base, lead: p.lead, g)
            grp.leave()
        }
    }

    func halt() {
        running = false
        pumpRunning = false
        bx_stop(mixer)
        holdOn = false
        cache?.setPaused(false)
        warmKey = nil
        warmGroup = nil
        bumpGeneration()                // 補充を止める (次の begin / warm で作り直す)
    }

    func shutdown() {
        halt()
        pumpTimer?.cancel()
        cache?.stop()
        engine.stop()
    }

    /// 再生中に offset を変えたとき: 曲はそのまま流し、譜面の時計だけ delta 秒ずらす
    func shiftOffset(by delta: Double) {
        offsetTotal += delta
    }

    /// 曲の音量 0...1
    func setVolume(_ v: Float) {
        bx_set_music_gain(mixer, min(max(v, 0), 1))
    }

    /// ノーツ音の音量 0...1
    func setSEVolume(_ v: Float) {
        bx_set_se_gain(mixer, min(max(v, 0), 1))
    }

    // MARK: 速度

    private func makeStretcher(rate: Double, size: Int) -> PCMSource {
        #if canImport(CRubberBand)
        if let s = RubberBandPCMSource(base: source, rate: rate, sharp: size == 512) {
            stretchEngine = s.engineLabel
            return s
        }
        #endif
        stretchEngine = "自前(窓\(size))"
        return StretchedPCMSource(base: source, rate: rate, fftSize: size)
    }

    /// 再生速度 (0.1...1.0。音程は変えない)。停止中に呼ぶ
    func setRate(_ r: Double) {
        guard !running else { return }
        let nr = min(max(r, 0.1), 1.0)
        if nr == rate { return }
        let sz = stretchSize
        bumpGeneration()
        decodeQueue.sync {
            bx_reset(mixer, 0)
            srcEOF = false
            stretched = nr < 1.0 ? makeStretcher(rate: nr, size: sz) : nil
        }
        warmKey = nil
        warmGroup = nil
        rate = nr
    }

    /// 時間伸縮の窓の大きさ (1024 = 標準 / 512 = 立ち上がりがはっきり)。停止中に呼ぶ
    func setStretchSize(_ size: Int) {
        guard !running else { return }
        let sz = size == 512 ? 512 : 1024
        if sz == stretchSize { return }
        stretchSize = sz
        guard rate < 1.0 else { return }
        let r = rate
        bumpGeneration()
        decodeQueue.sync {
            bx_reset(mixer, 0)
            srcEOF = false
            stretched = makeStretcher(rate: r, size: sz)
        }
        warmKey = nil
        warmGroup = nil
    }

    /// 診断用: 再生中にリングバッファの曲がいちばん少なくなった量 (4096 フレームを 1 として) と、いっぱいの量。
    /// 曲が足りなくなった (音が途切れた) ことがあれば、最小は 0
    func queueStats() -> (min: Int, target: Int) {
        let under = bx_underruns(mixer)
        let mb = decodeQueue.sync { minBuffered }
        let target = ringFrames / chunk
        if under > 0 { return (0, target) }
        return (mb == Int.max ? -1 : mb / chunk, target)
    }

    // MARK: 時計

    /// これまでの GameAudio との互換用 (この版は、時計を毎回ミキサーから読むので何もしない)
    func refreshAnchor() {}

    /// 出力の遅れ (秒)
    var outputLatency: Double { latency }

    /// タイムラインのフレーム F の、譜面時刻
    private func chartTime(frame f: Double) -> Double {
        (Double(baseFrame) + (f - Double(lead)) * rate) / sr + offsetTotal
    }

    /// 譜面時刻 t の、タイムラインのフレーム
    private func frame(atChartTime t: Double) -> Double {
        Double(lead) + ((t - offsetTotal) * sr - Double(baseFrame)) / rate
    }

    /// 今のミキサーの時計 (ブロックの先頭のフレームと、その音が聞こえるホスト時刻)
    private func clock() -> (frame: Double, heard: Double)? {
        var f: Int64 = 0
        var h: UInt64 = 0
        guard bx_clock(mixer, &f, &h) != 0 else { return nil }
        return (Double(f), AVAudioTime.seconds(forHostTime: h) + latency)
    }

    /// ホスト時刻 (systemUptime / UITouch.timestamp と同じ時間軸) に聞こえている、譜面時刻
    func chartTime(atUptime h: Double) -> Double {
        if let c = clock() {
            return chartTime(frame: c.frame + (h - c.heard) * sr)
        }
        // 再生を始めてから、まだ 1 回も出力していないとき (数 ms): 次の出力から始まる見込みで
        let heard0 = beginUptime + AVAudioSession.sharedInstance().ioBufferDuration + latency
        return chartTime(frame: max(0, (h - heard0) * sr))
    }

    /// chartTime(atUptime:) の逆
    func uptime(atChartTime t: Double) -> Double {
        let f = frame(atChartTime: t)
        if let c = clock() { return c.heard + (f - c.frame) / sr }
        let heard0 = beginUptime + AVAudioSession.sharedInstance().ioBufferDuration + latency
        return heard0 + f / sr
    }

    // MARK: ノーツ音 (曲と同じ流れで鳴らす)

    /// 譜面時刻 t (= 曲のその位置) にノーツ音を鳴らす。曲のサンプルとぴったり同じ位置で鳴る
    func scheduleSE(_ kind: BeatrixSounds.Kind, chartTime t: Double) {
        guard running else { return }
        let f = Int64(frame(atChartTime: t).rounded())
        for id in BeatrixSounds.mixerIDs(of: kind) {
            bx_schedule(mixer, f, id, 1.0)
        }
    }

    /// すぐ鳴らす (テストプレイの打鍵)
    func playSENow(_ kind: BeatrixSounds.Kind) {
        for id in BeatrixSounds.mixerIDs(of: kind) {
            bx_play_now(mixer, id, 1.0)
        }
    }

    /// ホールド / スライドを押さえている間の「しゅ〜」 (毎フレーム呼んでよい。変わったときだけ伝える)
    func setHoldSE(_ on: Bool) {
        if on == holdOn { return }
        holdOn = on
        bx_set_loop(mixer, BeatrixSounds.mixerHoldID, on ? BeatrixSounds.shared.mixerHoldGain : 0)
    }

    /// まだ鳴っていないノーツ音の予約を全部捨てる (offset を変えたときなど)
    func cancelSE() {
        bx_cancel_from(mixer, Int64.min)
    }
}
#endif
