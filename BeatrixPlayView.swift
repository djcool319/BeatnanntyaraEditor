import SwiftUI
import UIKit
import AVFoundation

// MARK: - びーとり式テストプレイの画面
//
// 奥から手前へノーツが流れてくる、本家と同じ見た目 (遠近の付いた 3 鍵のレーン + マゼンタの判定ライン)。
// 判定は BeatrixPlayCore.swift (本家の keyjudge.cs と同じ)。
//
// 操作: 画面を横に 4 つに分けたボタン (レーンの 左 1/3 / 中央の左半分 / 中央の右半分 / 右 1/3 の延長)。
//       押した瞬間 → タップ・始点・赤タップ、押している間 → ワイプ・ホールド・スライド
//       (押したときの光り方は 3 鍵ぶん。真ん中は左半分でも右半分でも、真ん中 1 つが光る)
// 時計・ポーズ・リトライ・音は、これまでのテストプレイ (TestPlay.swift の GameAudio / GameSession) をそのまま使う。
// スクロール速度・オフセットは PAUSE 画面で変えられる (これまでと同じ設定)
//
// 描き方: 毎フレーム画面全体を CPU で描き直すと重く、カクつく原因になるので、
//   ノーツ・帯・線を種類ごとの CAShapeLayer にまとめ、毎フレームは「形 (path)」だけを差し替える (塗りは GPU)。
//   文字 (スコアなど) は UILabel で、値が変わったときだけ書き換える。

struct BeatrixPlayLaunch: Identifiable {
    let id = UUID()
    let chart: BxPlayChart
    let audio: GameAudio?
    let startSec: Double          // 譜面時刻 (秒)。エディタの表示位置
    let offsetRaw: Int            // 譜面の offset (JSON の値。44100 = 1 秒あとにずらす)
    let title: String
    let difficulty: BeatrixDifficulty
    let level: Double             // LEVEL (Lv の表示用)
}

final class BeatrixGameView: UIView, GameSessionView {
    // ---- 見た目の調整用 ----
    /// スクロール速度 1.0 のときの「奥行きの進み方」(大きいほど速い)。1.0 で、画面の上端から判定ラインまで 約 0.8 秒
    private let baseDepthSpeed = 2.3
    private static let countIn = 2.0          // 秒: 開始前の待ち
    /// ノーツの横幅 (レーンの幅に対する比)。本家のプレハブ: タップ 0.03 / ワイプ・始点 0.028 (レーン 0.9912)
    private let tapWidth = 0.3027
    private let sideWidth = 0.2825
    /// ノーツの厚み (奥行き)。本家のプレハブ: タップ 0.02 / ワイプ 0.015
    private let tapDepth = 0.032
    private let wipeDepth = 0.024
    // ------------------------

    private let source: BxPlayChart
    private var game: BxGame
    private let audio: GameAudio?
    private let session: GameSession
    private let startAt: Double
    private let songTitle: String
    private let difficulty: BeatrixDifficulty
    private let level: Double
    private var link: CADisplayLink?
    private var running = false
    private var pausedT = 0.0
    private var silentHost = 0.0
    private var silentChart = 0.0
    private var observers: [NSObjectProtocol] = []
    private var touchZones: [ObjectIdentifier: Int] = [:]
    private var viewTime = 0.0
    /// ワイプの音は、本家と同じく「ノーツが判定ラインに来て消える瞬間」に鳴らす (早めに押したときは、その時刻まで待つ)
    private var pendingWipeSounds: [Double] = []
    /// ワイプのエフェクトも、音と同じく判定ラインに来た瞬間に出す (時刻, レーン, 判定)
    private var pendingWipeEffects: [(t: Double, lane: Int, judge: BxJudge)] = []
    private let effectHost = CALayer()

    // 描画用のレイヤー (下から順に重なる)
    private let floorLayer = CAShapeLayer()
    private let partFillLayer = CAShapeLayer()
    private let partEdgeLayer = CAShapeLayer()
    private let beatLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let dividerLayer = CAShapeLayer()
    private let zoneLayer = CAShapeLayer()
    private let holdIdleLayer = CAShapeLayer()
    private let holdActiveLayer = CAShapeLayer()
    private let slideIdleLayer = CAShapeLayer()
    private let slideActiveLayer = CAShapeLayer()
    private let simLayer = CAShapeLayer()
    private let tapLayer = CAShapeLayer()
    private let headLayer = CAShapeLayer()
    private let redLayer = CAShapeLayer()
    private let wipeLayer = CAShapeLayer()
    private let judgeLayer = CAShapeLayer()

    // 文字
    private let scoreBox = UIView()
    private let scoreLabel = UILabel()
    private let titleBox = UIView()
    private let titleLabel = UILabel()
    private let diffLabel = UILabel()
    private let countsLabel = UILabel()
    private let comboLabel = UILabel()
    private let judgeLabel = UILabel()
    private let earlyLabel = UILabel()
    private let countLabel = UILabel()
    private let resultLabel = UILabel()
    private var shownScore = -1
    private var shownCombo = -1
    private var shownCounts = ""
    private var shownJudgeKey = ""
    private var shownCount = -1
    private var shownResult = false

    private var firstTime: Double { startAt - Self.countIn }

    init(launch: BeatrixPlayLaunch, session: GameSession) {
        self.source = launch.chart
        self.audio = launch.audio
        self.session = session
        self.startAt = launch.startSec
        session.chartOffsetRaw = launch.offsetRaw          // PAUSE で変えられる (テストプレイの間だけ。譜面には入らない)
        self.songTitle = launch.title
        self.difficulty = launch.difficulty
        self.level = launch.level
        self.game = BxGame(chart: launch.chart, startTime: launch.startSec - Self.countIn)
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        isMultipleTouchEnabled = true
        setupLayers()
        setupLabels()
        attachSounds()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupLayers() {
        func add(_ l: CAShapeLayer, fill: UIColor?, stroke: UIColor? = nil, width: CGFloat = 0) {
            l.fillColor = fill?.cgColor
            l.strokeColor = stroke?.cgColor
            l.lineWidth = width
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull()]   // アニメーションさせない
            layer.addSublayer(l)
        }
        add(floorLayer, fill: UIColor(white: 0.04, alpha: 1))
        add(partFillLayer, fill: UIColor(white: 1, alpha: 0.06))
        add(partEdgeLayer, fill: UIColor(white: 1, alpha: 0.9))
        add(beatLayer, fill: nil, stroke: UIColor(white: 1, alpha: 0.18), width: 1)
        add(edgeLayer, fill: nil, stroke: UIColor(white: 0.85, alpha: 1), width: 2)
        add(dividerLayer, fill: nil, stroke: UIColor(white: 1, alpha: 0.35), width: 1.2)
        add(zoneLayer, fill: UIColor(white: 1, alpha: 0.10))
        add(holdIdleLayer, fill: UIColor(red: 0.501, green: 0.592, blue: 1, alpha: 0.7))          // 押していないときはスライドと同じ色
        add(holdActiveLayer, fill: UIColor(red: 0.47, green: 0.58, blue: 1.0, alpha: 1))           // 押さえている間は明るく
        add(slideIdleLayer, fill: UIColor(red: 0.501, green: 0.592, blue: 1, alpha: 0.7))
        add(slideActiveLayer, fill: UIColor(red: 0.47, green: 0.58, blue: 1.0, alpha: 1))         // 押さえている間はホールドと同じ色
        add(simLayer, fill: nil, stroke: UIColor(white: 0.8, alpha: 0.7), width: 2)
        add(tapLayer, fill: .white)
        add(headLayer, fill: UIColor(red: 0.62, green: 0.85, blue: 1.0, alpha: 1))
        add(redLayer, fill: UIColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 1))
        add(wipeLayer, fill: UIColor(red: 0.97, green: 0.96, blue: 0.27, alpha: 1))
        add(judgeLayer, fill: UIColor(red: 0.95, green: 0.1, blue: 0.95, alpha: 1))
        effectHost.actions = ["sublayers": NSNull()]
        layer.addSublayer(effectHost)          // タッチエフェクト (判定ラインより上に重ねる)
    }

    private func setupLabels() {
        scoreBox.backgroundColor = UIColor(white: 0.92, alpha: 1)
        titleBox.backgroundColor = UIColor(white: 0.15, alpha: 0.9)
        scoreLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .heavy)
        scoreLabel.textColor = .black
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.text = songTitle
        diffLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        diffLabel.textColor = .white
        diffLabel.backgroundColor = difficulty.uiColor
        diffLabel.text = "  " + difficulty.label + " Lv." + Beatrix.lvRank(level)
        countsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countsLabel.textColor = UIColor(white: 0.75, alpha: 1)
        comboLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 84, weight: .heavy)
        comboLabel.textColor = UIColor(white: 0.75, alpha: 0.75)
        comboLabel.textAlignment = .center
        judgeLabel.font = UIFont.systemFont(ofSize: 60, weight: .heavy)
        judgeLabel.textAlignment = .center
        earlyLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        earlyLabel.textAlignment = .center
        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        resultLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        resultLabel.textColor = .white
        resultLabel.textAlignment = .center
        resultLabel.numberOfLines = 0
        resultLabel.backgroundColor = UIColor(white: 0, alpha: 0.6)
        resultLabel.isHidden = true
        for v in [scoreBox, titleBox, diffLabel, countsLabel, comboLabel, judgeLabel, earlyLabel, countLabel, resultLabel] {
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        scoreBox.addSubview(scoreLabel)
        titleBox.addSubview(titleLabel)
    }

    private func attachSounds() {
        // 白タップ・始点 = tap / 赤タップ = red_note (+ tap) / ワイプ = yellow (ノーツが判定ラインに来たとき)
        game.onSound = { [weak self] type, t in
            guard let self = self, self.session.seOn else { return }      // 効果音オフ
            switch type {
            case 3: BeatrixSounds.shared.playNow(.red)
            case 4: self.pendingWipeSounds.append(t)
            default: BeatrixSounds.shared.playNow(.tap)
            }
        }
        // タッチエフェクト (本家の message_tap と同じく、判定ごとに出す)
        game.onJudge = { [weak self] type, lane, judge, early, t in
            guard let self = self else { return }
            if type == 4 && judge != .miss {
                self.pendingWipeEffects.append((t: t, lane: lane, judge: judge))     // ワイプは判定ラインに来たときに出す
                return
            }
            self.spawnEffect(type: type, lane: lane, judge: judge, early: early)
        }
    }

    // MARK: タッチエフェクト
    //   PERFECT (+): ノーツの色の光の玉 + 広がる輪 + 細かい粒 (白タップ・始点・判定点 = 水色 / 赤タップ = 赤 / ワイプ = 黄色)
    //   GREAT     : ピンクの光の玉 + 細い輪 (少し控えめ)
    //   早い MISS : 灰色の光の玉だけ (控えめ)。遅い MISS・見逃しは出さない

    private func spawnEffect(type: Int, lane: Int, judge: BxJudge, early: Bool?) {
        guard bounds.width > 0 else { return }
        let color: UIColor
        var scale: CGFloat = 1
        var ring = true
        var particles = true
        switch judge {
        case .perfectPlus, .perfect:
            switch type {
            case 3: color = UIColor(red: 1.0, green: 0.35, blue: 0.55, alpha: 1)
            case 4: color = UIColor(red: 1.0, green: 0.96, blue: 0.55, alpha: 1)
            case 5:
                color = UIColor(red: 0.25, green: 1.0, blue: 0.95, alpha: 1)
                scale = 0.75
                ring = false
            default: color = UIColor(red: 0.25, green: 1.0, blue: 0.95, alpha: 1)
            }
        case .great:
            color = UIColor(red: 1.0, green: 0.55, blue: 0.85, alpha: 1)
            scale = 0.85
            particles = false
        case .miss:
            guard early == true else { return }
            color = UIColor(white: 0.62, alpha: 1)
            scale = 0.7
            ring = false
            particles = false
        }
        let g = geo()
        let center = CGPoint(x: g.x(Self.laneFrac(lane), 0), y: g.judgeY)
        let r = g.halfJ / 3 * 0.85 * scale              // 光の玉の半径 (1 鍵の幅の半分くらい)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var made: [CALayer] = []

        // 光の玉 (真ん中が白く、外へ向かってノーツの色が透けていく)
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [UIColor.white.cgColor, color.cgColor, color.withAlphaComponent(0.35).cgColor, color.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.25, 0.55, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: r * 2.6, height: r * 2.6)
        glow.position = center
        effectHost.addSublayer(glow)
        fade(glow, scaleFrom: 0.7, to: 1.15, duration: 0.30)
        made.append(glow)

        // 広がる輪
        if ring {
            let ringLayer = CAShapeLayer()
            ringLayer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            ringLayer.position = center
            ringLayer.path = UIBezierPath(ovalIn: ringLayer.bounds).cgPath
            ringLayer.fillColor = nil
            ringLayer.strokeColor = color.withAlphaComponent(0.9).cgColor
            ringLayer.lineWidth = judge == .great ? 1.5 : 2.5
            effectHost.addSublayer(ringLayer)
            fade(ringLayer, scaleFrom: 0.5, to: 1.6, duration: 0.38)
            made.append(ringLayer)
        }

        // 細かい粒 (外へ飛んで消える)
        if particles {
            for k in 0..<7 {
                let p = CALayer()
                let size: CGFloat = 3 + CGFloat(k % 3)
                p.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                p.cornerRadius = size / 2
                p.backgroundColor = color.cgColor
                p.position = center
                effectHost.addSublayer(p)
                let ang = Double(k) / 7.0 * 2 * Double.pi + Double.random(in: -0.3...0.3)
                let dist = r * CGFloat.random(in: 1.0...1.7)
                let to = CGPoint(x: center.x + CGFloat(cos(ang)) * dist, y: center.y + CGFloat(sin(ang)) * dist * 0.6)
                let mv = CABasicAnimation(keyPath: "position")
                mv.fromValue = NSValue(cgPoint: center)
                mv.toValue = NSValue(cgPoint: to)
                let op = CABasicAnimation(keyPath: "opacity")
                op.fromValue = 1
                op.toValue = 0
                let gr = CAAnimationGroup()
                gr.animations = [mv, op]
                gr.duration = 0.42
                gr.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.position = to
                p.opacity = 0
                p.add(gr, forKey: "fx")
                made.append(p)
            }
        }
        CATransaction.commit()

        // 終わったら消す (アニメーションより少しあと)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in made { l.removeFromSuperlayer() }
            CATransaction.commit()
        }
    }

    /// 大きくなりながら消える
    private func fade(_ l: CALayer, scaleFrom s0: CGFloat, to s1: CGFloat, duration: CFTimeInterval) {
        let sc = CABasicAnimation(keyPath: "transform.scale")
        sc.fromValue = s0
        sc.toValue = s1
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 1
        op.toValue = 0
        let gr = CAAnimationGroup()
        gr.animations = [sc, op]
        gr.duration = duration
        gr.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.opacity = 0
        l.transform = CATransform3DMakeScale(s1, s1, 1)
        l.add(gr, forKey: "fx")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height
        for l in [floorLayer, partFillLayer, partEdgeLayer, beatLayer, edgeLayer, dividerLayer, zoneLayer,
                  holdIdleLayer, holdActiveLayer, slideIdleLayer, slideActiveLayer, simLayer,
                  tapLayer, headLayer, redLayer, wipeLayer, judgeLayer] {
            l.frame = bounds
        }
        effectHost.frame = bounds
        scoreBox.frame = CGRect(x: 0, y: 18, width: 300, height: 34)
        scoreLabel.frame = CGRect(x: 10, y: 0, width: 290, height: 34)
        titleBox.frame = CGRect(x: 0, y: 52, width: 300, height: 50)
        titleLabel.frame = CGRect(x: 10, y: 0, width: 286, height: 50)
        // 文字の長さに合わせて帯を伸ばす (INSANE Lv.Oops! などで「...」にならないように)
        let diffW = ceil(diffLabel.sizeThatFits(CGSize(width: 1000, height: 24)).width) + 16
        diffLabel.frame = CGRect(x: 0, y: 102, width: max(170, diffW), height: 24)
        countsLabel.frame = CGRect(x: 10, y: 130, width: 400, height: 18)
        let g = geo()
        let midY = g.judgeY - h * 0.33
        comboLabel.frame = CGRect(x: 0, y: midY, width: w, height: 96)
        judgeLabel.frame = CGRect(x: 0, y: midY + 96, width: w, height: 70)
        earlyLabel.frame = CGRect(x: 0, y: midY + 166, width: w, height: 28)
        countLabel.frame = CGRect(x: 0, y: h * 0.22, width: w, height: 70)
        resultLabel.frame = CGRect(x: w / 2 - 260, y: h * 0.28, width: 520, height: 200)
        updateStaticLayers()
        renderFrame()
    }

    // MARK: 開始・停止・ポーズ (GameView と同じ流れ)

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link == nil { startGame() }
        } else {
            teardown()
        }
    }

    private func startGame() {
        session.view = self
        BeatrixSounds.shared.prepare()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] _ in self?.pause() })
        begin(at: firstTime)
    }

    private func teardown() {
        link?.invalidate()
        link = nil
        running = false
        BeatrixSounds.shared.setHold(false)
        audio?.shutdown()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    private func begin(at tc: Double) {
        // エディタと同じ offset (JSON の値 ÷ 44100 秒だけ、ノーツを曲に対して後ろへ)。
        // エディタの内部の offsetMs と同じ向き: 譜面時刻 t の音 = 曲の t + offset/44100 秒目
        // (SETTING の「再生の補正」も同じく引く。エディタの再生と同じずれ方にする)
        // さらに「テストプレイの補正」(初期値 -20ms = ノーツを 20ms 早める。エディタでノーツ音ぴったりの譜面が、プレイでちょうどよく感じる分)
        let off = -Double((session.chartOffsetRaw ?? 0) - Beatrix.playbackCorrectionSamples) / Beatrix.offsetSampleRate
            - session.playAdjustMs / 1000
        if let a = audio {
            a.begin(chartTime: tc, offsetTotal: off)
        } else {
            silentHost = uptime() + 0.05
            silentChart = tc
        }
        running = true
        link?.isPaused = false
        if session.paused { session.paused = false }
    }

    private func chartTime(at h: Double) -> Double {
        if let a = audio { return a.chartTime(atUptime: h) }
        return silentChart + (h - silentHost)
    }

    func pause() {
        guard running else { return }
        pausedT = chartTime(at: uptime())
        running = false
        link?.isPaused = true
        touchZones.removeAll()
        pendingWipeSounds.removeAll()
        pendingWipeEffects.removeAll()
        BeatrixSounds.shared.setHold(false)
        audio?.halt()
        session.pauseInfo = ""
        session.paused = true
        renderFrame()
    }

    func resume() {
        guard !running else { return }
        begin(at: pausedT)
    }

    func retry() {
        game = BxGame(chart: source, startTime: firstTime)
        attachSounds()
        touchZones.removeAll()
        pendingWipeSounds.removeAll()
        pendingWipeEffects.removeAll()
        begin(at: firstTime)
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard running else { return }
        audio?.refreshAnchor()
        let t = chartTime(at: uptime())
        let zones = Set(touchZones.values)
        for z in zones { game.hold(zone: z, at: t) }
        game.update(to: t)
        BeatrixSounds.shared.setHold(session.seOn && anyHoldActive(at: t, zones: zones))      // ホールド / スライドを押さえている間の「しゅ〜」
        if !pendingWipeSounds.isEmpty {
            let before = pendingWipeSounds.count
            pendingWipeSounds.removeAll { $0 <= t }
            if pendingWipeSounds.count < before && session.seOn { BeatrixSounds.shared.playNow(.wipe) }
        }
        if !pendingWipeEffects.isEmpty {
            let due = pendingWipeEffects.filter { $0.t <= t }
            if !due.isEmpty {
                pendingWipeEffects.removeAll { $0.t <= t }
                for e in due { spawnEffect(type: 4, lane: e.lane, judge: e.judge, early: nil) }
            }
        }
        viewTime = chartTime(at: l.targetTimestamp)          // 画面に出る時刻で描く
        renderFrame()
    }

    /// 今、押さえているホールド / スライドがあるか (帯の色が明るくなる条件と同じ)
    private func anyHoldActive(at t: Double, zones: Set<Int>) -> Bool {
        if zones.isEmpty { return false }
        for h in source.holds where holdActive(h, at: t, zones: zones) { return true }
        for s in source.slides where slideActive(s, at: t, zones: zones) { return true }
        return false
    }

    private func holdActive(_ h: BxHold, at t: Double, zones: Set<Int>) -> Bool {
        t >= h.t0 && t <= h.t1 && BxGame.laneHeld(h.lane, zones: zones)
    }

    private func slideActive(_ s: BxSlide, at t: Double, zones: Set<Int>) -> Bool {
        if zones.isEmpty { return false }
        guard let f = s.pts.first, let l = s.pts.last, t >= f.t && t <= l.t else { return false }
        for k in 0..<(s.pts.count - 1) where t >= s.pts[k].t && t <= s.pts[k + 1].t {
            let a = s.pts[k]
            let b = s.pts[k + 1]
            let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
            let laneNow = Int((Double(a.lane) + Double(b.lane - a.lane) * u).rounded())
            if BxGame.laneHeld(laneNow, zones: zones) { return true }
        }
        return false
    }

    // MARK: 入力

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        for tc in touches {
            let z = zone(at: tc.location(in: self))
            touchZones[ObjectIdentifier(tc)] = z
            game.press(zone: z, at: chartTime(at: tc.timestamp))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard running else { return }
        for tc in touches {
            touchZones[ObjectIdentifier(tc)] = zone(at: tc.location(in: self))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for tc in touches { touchZones[ObjectIdentifier(tc)] = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// 触った位置 → ボタン (判定ラインの高さでのレーンの位置で分ける。レーンの外は端のボタン)
    private func zone(at p: CGPoint) -> Int {
        let g = geo()
        let f = Double((p.x - (g.midX - g.halfJ)) / (2 * g.halfJ))
        if f < 1.0 / 3.0 { return 0 }
        if f < 0.5 { return 1 }
        if f < 2.0 / 3.0 { return 2 }
        return 3
    }

    // MARK: 遠近

    /// 奥行き d (判定ライン = 0、奥が +) → 画面。消失点は画面の上の外にある (本家のスクリーンショットから測った比)
    private struct Geo {
        let midX: CGFloat
        let judgeY: CGFloat
        let vanishY: CGFloat
        let halfJ: CGFloat          // 判定ラインでのレーンの半分の幅

        func s(_ d: Double) -> CGFloat { CGFloat(1.0 / (1.0 + max(d, -0.85))) }
        func y(_ d: Double) -> CGFloat { vanishY + (judgeY - vanishY) * s(d) }
        /// frac: レーンの左端 = 0 / 右端 = 1
        func x(_ frac: Double, _ d: Double) -> CGFloat { midX + CGFloat(frac - 0.5) * 2 * halfJ * s(d) }
        func depth(atY yy: CGFloat) -> Double {
            let sv = (yy - vanishY) / (judgeY - vanishY)
            return Double(1 / max(sv, 0.01)) - 1
        }
    }

    private func geo() -> Geo {
        let w = bounds.width
        let h = bounds.height
        let judgeY = h * 0.80
        let halfJ = min(w * 0.4625, h * 0.62)
        return Geo(midX: w / 2, judgeY: judgeY, vanishY: judgeY - h * 1.24, halfJ: halfJ)
    }

    private var depthSpeed: Double { baseDepthSpeed * min(max(session.speed, 0.5), 2.0) }

    /// 判定の位置: 「触れたとき」なら、ジャストの瞬間にノーツの手前の端が判定ラインに来るよう、
    /// 全体を ノーツの厚みの半分だけ奥へずらして描く (判定の時刻そのものは変わらない)
    private var visualShift: Double { session.judgeAtEdge ? tapDepth / 2 : 0 }

    private func depth(_ t: Double) -> Double { (t - viewTime) * depthSpeed + visualShift }

    private static func laneFrac(_ lane: Int) -> Double { Double(3 + 2 * lane) / 18.0 }

    private var depthRange: (bot: Double, top: Double) {
        let g = geo()
        return (bot: max(-0.8, g.depth(atY: bounds.height)), top: g.depth(atY: 0) + 0.05)
    }

    private func addQuad(_ p: CGMutablePath, _ g: Geo, f0: Double, f1: Double, d0: Double, d1: Double) {
        p.move(to: CGPoint(x: g.x(f0, d0), y: g.y(d0)))
        p.addLine(to: CGPoint(x: g.x(f1, d0), y: g.y(d0)))
        p.addLine(to: CGPoint(x: g.x(f1, d1), y: g.y(d1)))
        p.addLine(to: CGPoint(x: g.x(f0, d1), y: g.y(d1)))
        p.closeSubpath()
    }

    /// 画面の大きさが変わったときだけ作る形 (床・レーンの線・判定ライン)
    private func updateStaticLayers() {
        guard bounds.width > 0 else { return }
        let g = geo()
        let r = depthRange
        let floor = CGMutablePath()
        addQuad(floor, g, f0: 0, f1: 1, d0: r.bot, d1: r.top)
        floorLayer.path = floor
        let edges = CGMutablePath()
        for f in [0.0, 1.0] {
            edges.move(to: CGPoint(x: g.x(f, r.bot), y: g.y(r.bot)))
            edges.addLine(to: CGPoint(x: g.x(f, r.top), y: g.y(r.top)))
        }
        edgeLayer.path = edges
        let div = CGMutablePath()
        for f in [1.0 / 3.0, 2.0 / 3.0] {
            div.move(to: CGPoint(x: g.x(f, r.bot), y: g.y(r.bot)))
            div.addLine(to: CGPoint(x: g.x(f, r.top), y: g.y(r.top)))
        }
        dividerLayer.path = div
        let judge = CGMutablePath()
        addQuad(judge, g, f0: -0.01, f1: 1.01, d0: -0.006, d1: 0.006)
        judgeLayer.path = judge
    }

    // MARK: 毎フレームの描画

    private func renderFrame() {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderLane()
        renderNotes()
        renderHUD()
        CATransaction.commit()
    }

    private func renderLane() {
        let g = geo()
        let r = depthRange
        let zones = Set(touchZones.values)

        // part の区間: 床を少し明るく、レーンの両端を白く光らせる
        var inPart = false
        let pFill = CGMutablePath()
        let pEdge = CGMutablePath()
        for p in source.parts {
            if viewTime >= p.start && viewTime < p.end { inPart = true }
            let d0 = max(depth(p.start), r.bot)
            let d1 = min(depth(p.end), r.top)
            if d1 <= d0 { continue }
            addQuad(pFill, g, f0: 0, f1: 1, d0: d0, d1: d1)
            addQuad(pEdge, g, f0: -0.012, f1: 0.0, d0: d0, d1: d1)
            addQuad(pEdge, g, f0: 1.0, f1: 1.012, d0: d0, d1: d1)
        }
        partFillLayer.path = pFill
        partEdgeLayer.path = pEdge
        edgeLayer.lineWidth = inPart ? 4 : 2
        edgeLayer.strokeColor = (inPart ? UIColor.white : UIColor(white: 0.85, alpha: 1)).cgColor

        // 1 拍ごとの線
        let beats = CGMutablePath()
        for t in source.beats {
            let d = depth(t)
            if d < r.bot || d > r.top { continue }
            beats.move(to: CGPoint(x: g.x(0, d), y: g.y(d)))
            beats.addLine(to: CGPoint(x: g.x(1, d), y: g.y(d)))
        }
        beatLayer.path = beats

        // 押しているボタンの光 (本家と同じく、そのレーンの奥から手前まで全部。真ん中は 1 と 2 のどちらでも、真ん中 1 つ)
        let zp = CGMutablePath()
        if zones.contains(0) { addQuad(zp, g, f0: 0, f1: 1.0 / 3.0, d0: r.bot, d1: r.top) }
        if zones.contains(1) || zones.contains(2) { addQuad(zp, g, f0: 1.0 / 3.0, f1: 2.0 / 3.0, d0: r.bot, d1: r.top) }
        if zones.contains(3) { addQuad(zp, g, f0: 2.0 / 3.0, f1: 1, d0: r.bot, d1: r.top) }
        zoneLayer.path = zp

        // ホールドの帯 (判定ラインより手前はいつも隠す)
        let hIdle = CGMutablePath()
        let hActive = CGMutablePath()
        let hw = sideWidth / 2 * 1.0              // 帯の太さ (始点の棒と同じ幅)
        for h in source.holds {
            let active = holdActive(h, at: viewTime, zones: zones)
            let d0 = max(depth(h.t0), 0)
            let d1 = min(depth(h.t1), r.top)
            if d1 <= d0 { continue }
            let f = Self.laneFrac(h.lane)
            addQuad(active ? hActive : hIdle, g, f0: f - hw, f1: f + hw, d0: d0, d1: d1)
        }
        holdIdleLayer.path = hIdle
        holdActiveLayer.path = hActive

        // スライドの帯 (区間ごとの台形。判定ラインより手前はいつも隠す)
        let sIdle = CGMutablePath()
        let sActive = CGMutablePath()
        for s in source.slides {
            guard let firstP = s.pts.first, let lastP = s.pts.last else { continue }
            if depth(lastP.t) < r.bot || depth(firstP.t) > r.top { continue }
            let active = slideActive(s, at: viewTime, zones: zones)
            let path = active ? sActive : sIdle
            let lo = viewTime
            let hi = viewTime + r.top / depthSpeed
            for k in 0..<(s.pts.count - 1) {
                let a = s.pts[k]
                let b = s.pts[k + 1]
                if b.t <= a.t || b.t < lo || a.t > hi { continue }
                let fa0 = Self.laneFrac(a.lane)
                let fb0 = Self.laneFrac(b.lane)
                let ta = max(a.t, lo)
                let tb = min(b.t, hi)
                if tb <= ta { continue }
                let fa = fa0 + (fb0 - fa0) * (ta - a.t) / (b.t - a.t)
                let fb = fa0 + (fb0 - fa0) * (tb - a.t) / (b.t - a.t)
                let da = depth(ta)
                let db = depth(tb)
                path.move(to: CGPoint(x: g.x(fa - hw, da), y: g.y(da)))
                path.addLine(to: CGPoint(x: g.x(fa + hw, da), y: g.y(da)))
                path.addLine(to: CGPoint(x: g.x(fb + hw, db), y: g.y(db)))
                path.addLine(to: CGPoint(x: g.x(fb - hw, db), y: g.y(db)))
                path.closeSubpath()
            }
        }
        slideIdleLayer.path = sIdle
        slideActiveLayer.path = sActive

        // 同時押しの線
        let sims = CGMutablePath()
        for sim in source.sims {
            let d = depth(sim.t)
            if d < -0.02 || d > r.top { continue }
            sims.move(to: CGPoint(x: g.x(Self.laneFrac(sim.a), d), y: g.y(d)))
            sims.addLine(to: CGPoint(x: g.x(Self.laneFrac(sim.b), d), y: g.y(d)))
        }
        simLayer.path = sims
    }

    private func renderNotes() {
        let g = geo()
        let r = depthRange
        let notes = game.notes
        let tLo = viewTime + r.bot / depthSpeed - 0.05
        let tHi = viewTime + r.top / depthSpeed + 0.05
        // 画面に入る最初のノーツを二分探索 (ノーツは時刻順)
        var lo = 0
        var hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].t < tLo { lo = mid + 1 } else { hi = mid }
        }
        let tapP = CGMutablePath()
        let headP = CGMutablePath()
        let redP = CGMutablePath()
        let wipeP = CGMutablePath()
        var i = lo
        while i < notes.count && notes[i].t <= tHi {
            let n = notes[i]
            i += 1
            if n.type == 5 { continue }
            // 取ったノーツは消す。ただしワイプは本家と同じく、判定ラインに来るまで流れ続ける (早く押しても、すぐには消えない)
            if n.done && !(n.type == 4 && viewTime < n.t) { continue }
            let d = depth(n.t)
            let f = Self.laneFrac(n.lane)
            switch n.type {
            case 2:
                addQuad(headP, g, f0: f - sideWidth / 2, f1: f + sideWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            case 3:
                addQuad(redP, g, f0: f - tapWidth / 2, f1: f + tapWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            case 4:
                addQuad(wipeP, g, f0: f - sideWidth / 2, f1: f + sideWidth / 2, d0: d - wipeDepth / 2, d1: d + wipeDepth / 2)
            default:
                addQuad(tapP, g, f0: f - tapWidth / 2, f1: f + tapWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            }
        }
        tapLayer.path = tapP
        headLayer.path = headP
        redLayer.path = redP
        wipeLayer.path = wipeP
    }

    /// 文字は、値が変わったときだけ書き換える (毎フレーム文字を作り直すと重い)
    private func renderHUD() {
        let score = game.score
        if score != shownScore {
            shownScore = score
            scoreLabel.text = String(format: "SCORE %07ld", score)
        }
        let counts = "P+ \(game.perfectPlus)  P \(game.perfect)  G \(game.great)  M \(game.miss)"
        if counts != shownCounts {
            shownCounts = counts
            countsLabel.text = counts
        }
        if game.combo != shownCombo {
            shownCombo = game.combo
            comboLabel.text = game.combo > 0 ? "\(game.combo)" : ""
        }

        var key = ""
        if let j = game.lastJudge, viewTime - game.lastJudgeAt < 0.6 {
            key = "\(j)-\(game.lastJudgeAt)-\(game.lastEarly.map { $0 ? "e" : "l" } ?? "")"
            if key != shownJudgeKey {
                switch j {
                case .perfectPlus:
                    judgeLabel.text = "PERFECT"
                    judgeLabel.textColor = UIColor(red: 0.55, green: 1, blue: 1, alpha: 1)
                case .perfect:
                    judgeLabel.text = "PERFECT"
                    judgeLabel.textColor = UIColor(red: 1, green: 0.9, blue: 0.4, alpha: 1)
                case .great:
                    judgeLabel.text = "GREAT"
                    judgeLabel.textColor = UIColor(red: 0.5, green: 1, blue: 0.5, alpha: 1)
                case .miss:
                    judgeLabel.text = "MISS"
                    judgeLabel.textColor = UIColor(white: 0.7, alpha: 1)
                }
                if let e = game.lastEarly, j == .perfect || j == .great {
                    earlyLabel.text = e ? "EARLY" : "LATE"
                    earlyLabel.textColor = e ? UIColor(red: 0.4, green: 0.7, blue: 1, alpha: 1) : UIColor(red: 1, green: 0.5, blue: 0.4, alpha: 1)
                } else {
                    earlyLabel.text = ""
                }
            }
        }
        if key != shownJudgeKey {
            shownJudgeKey = key
            if key.isEmpty {
                judgeLabel.text = ""
                earlyLabel.text = ""
            }
        }

        let count = viewTime < startAt ? Int(ceil(startAt - viewTime)) : 0
        if count != shownCount {
            shownCount = count
            countLabel.text = count > 0 ? "\(count)" : ""
        }

        let finished = viewTime > source.endTime + 1.5
        if finished != shownResult {
            shownResult = finished
            resultLabel.isHidden = !finished
            if finished {
                resultLabel.text = "RESULT\n\n" + String(format: "SCORE %07ld", game.score)
                    + "\n\nPERFECT+ \(game.perfectPlus)  PERFECT \(game.perfect)  GREAT \(game.great)  MISS \(game.miss)"
                    + "\nMAX COMBO \(game.maxCombo) / \(game.total)"
            }
        }
    }
}

struct BeatrixPlayRepresentable: UIViewRepresentable {
    let launch: BeatrixPlayLaunch
    let session: GameSession

    func makeUIView(context: Context) -> BeatrixGameView {
        BeatrixGameView(launch: launch, session: session)
    }

    func updateUIView(_ uiView: BeatrixGameView, context: Context) {}
}

/// フルスクリーンで出す、びーとり式のテストプレイ (右上の II → 終了 でエディタに戻る)
struct BeatrixPlayScreen: View {
    let launch: BeatrixPlayLaunch
    /// 終了したとき。引数は PAUSE で変えた offset (変えていなければ元の値)
    let onClose: (Int?) -> Void
    @StateObject private var session = GameSession()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            BeatrixPlayRepresentable(launch: launch, session: session)
                .ignoresSafeArea()
            if !session.paused {
                Button { session.pause() } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 72, height: 72)
                        .background(Color(white: 0.12, opacity: 0.9))
                        .padding(14)
                }
            }
            if session.paused {
                PauseOverlay(session: session)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .bottom)
        .onAppear {
            session.paused = false
            let s = session
            let close = onClose
            s.quit = { [weak s] in close(s?.chartOffsetRaw) }
        }
    }
}
