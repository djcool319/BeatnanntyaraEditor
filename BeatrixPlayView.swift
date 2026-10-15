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
    let offsetRaw: Int            // 譜面の offset (JSON の値。ms)
    let title: String
    let difficulty: BeatrixDifficulty
    let level: Double             // LEVEL (Lv の表示用)
    var artist: String = ""       // 作曲者 (曲名の下に小さく)
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
    private let tapDepth = 0.04             // 本家の画面収録で測った厚み (棒の下の暗い縁を含む)
    private let wipeDepth = 0.034
    // ------------------------

    private let source: BxPlayChart
    private var game: BxGame
    private let audio: GameAudio?
    private let session: GameSession
    private let startAt: Double
    private let songTitle: String
    private let difficulty: BeatrixDifficulty
    private let level: Double
    private let artist: String
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
    // ノーツの下側の暗い縁 (厚み)
    private let tapShadow = CAShapeLayer()
    private let headShadow = CAShapeLayer()
    private let redShadow = CAShapeLayer()
    private let wipeShadow = CAShapeLayer()
    // 背景
    private let bgGradient = CAGradientLayer()
    private let bgLines = CAShapeLayer()
    private let bgRing = CAShapeLayer()
    // 左上の帯とゲージ
    private let scoreBar = CAShapeLayer()
    private let titlePanel = CAShapeLayer()
    private let diffTag = CAShapeLayer()
    private let rankDiamond = CAShapeLayer()
    private let gaugeBack = CALayer()
    private let gaugeFill = CALayer()
    private var gaugeRect = CGRect.zero

    // 文字
    private let scoreLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let diffLabel = UILabel()
    private let reachLabel = UILabel()          // 「到達可能」
    private let rankLabel = UILabel()           // AP / FC / SS ...
    private let comboLabel = UILabel()
    private let judgeView = UIImageView()       // PERFECT!! などの文字 (画像)
    private let lyricLabel = UILabel()          // 歌詞 (判定ラインの少し上に、小さく)
    private var shownLyric = ""
    private let earlyLabel = UILabel()
    private let countLabel = UILabel()
    private let resultLabel = UILabel()
    private var shownScore = -1
    private var shownCombo = -1
    private var shownRank = ""
    private var shownGauge = -1
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
        self.artist = launch.artist
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
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull()]   // アニメーションさせない
            layer.addSublayer(l)
        }
        // 背景 (本家: 紺がかった暗い灰色に、細い三角形の網目と、レーンの後ろの大きな輪)
        bgGradient.colors = [UIColor(red: 0.125, green: 0.13, blue: 0.165, alpha: 1).cgColor,
                             UIColor(red: 0.075, green: 0.08, blue: 0.105, alpha: 1).cgColor]
        bgGradient.startPoint = CGPoint(x: 0.5, y: 0)
        bgGradient.endPoint = CGPoint(x: 0.5, y: 1)
        bgGradient.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer.addSublayer(bgGradient)
        add(bgLines, fill: nil, stroke: UIColor(white: 1, alpha: 0.075), width: 1.2)
        add(bgRing, fill: nil, stroke: UIColor(white: 1, alpha: 0.045), width: 20)
        // レーン
        add(floorLayer, fill: UIColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 0.93))
        add(partFillLayer, fill: UIColor(white: 1, alpha: 0.05))
        add(partEdgeLayer, fill: UIColor(white: 0.93, alpha: 1))
        add(beatLayer, fill: nil, stroke: UIColor(white: 1, alpha: 0.13), width: 1.4)
        add(edgeLayer, fill: nil, stroke: UIColor(white: 0.88, alpha: 1), width: 2.5)
        add(dividerLayer, fill: nil, stroke: UIColor(white: 1, alpha: 0.3), width: 1.4)
        add(zoneLayer, fill: UIColor(white: 1, alpha: 0.06))                                         // 押しているレーンは少し明るい灰色
        // ホールド / スライドの帯 (本家: くすんだ青紫。押さえている間は明るく)
        add(holdIdleLayer, fill: UIColor(red: 0.36, green: 0.42, blue: 0.74, alpha: 0.9))
        add(holdActiveLayer, fill: UIColor(red: 0.47, green: 0.58, blue: 1.0, alpha: 1))
        add(slideIdleLayer, fill: UIColor(red: 0.36, green: 0.42, blue: 0.74, alpha: 0.9))
        add(slideActiveLayer, fill: UIColor(red: 0.47, green: 0.58, blue: 1.0, alpha: 1))
        add(simLayer, fill: nil, stroke: UIColor(white: 0.85, alpha: 0.75), width: 2)
        // ノーツ (本家: 角の丸い棒。下側に少し暗い縁があって、厚みがあるように見える)
        add(tapShadow, fill: UIColor(red: 0.72, green: 0.73, blue: 0.78, alpha: 1))
        add(tapLayer, fill: .white)
        add(headShadow, fill: UIColor(red: 0.35, green: 0.6, blue: 0.85, alpha: 1))
        add(headLayer, fill: UIColor(red: 0.55, green: 0.8, blue: 1.0, alpha: 1))
        add(redShadow, fill: UIColor(red: 0.6, green: 0.08, blue: 0.14, alpha: 1))
        add(redLayer, fill: UIColor(red: 0.93, green: 0.2, blue: 0.27, alpha: 1))
        add(wipeShadow, fill: UIColor(red: 0.72, green: 0.68, blue: 0.12, alpha: 1))
        add(wipeLayer, fill: UIColor(red: 0.95, green: 0.93, blue: 0.24, alpha: 1))
        add(judgeLayer, fill: UIColor(red: 0.93, green: 0.07, blue: 0.93, alpha: 1))
        effectHost.actions = ["sublayers": NSNull()]
        layer.addSublayer(effectHost)          // タッチエフェクト (判定ラインより上に重ねる)
        // 左上の帯 (SCORE / 曲名 / 難易度) と、到達可能のゲージ
        for l in [scoreBar, titlePanel, diffTag, rankDiamond] {
            l.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
            layer.addSublayer(l)
        }
        scoreBar.fillColor = UIColor(white: 0.91, alpha: 1).cgColor
        titlePanel.fillColor = UIColor(white: 0.155, alpha: 0.94).cgColor
        diffTag.fillColor = difficulty.uiColor.cgColor
        rankDiamond.fillColor = UIColor(white: 0.12, alpha: 0.85).cgColor
        gaugeBack.backgroundColor = UIColor(white: 0.3, alpha: 1).cgColor
        gaugeFill.backgroundColor = UIColor(red: 0.62, green: 0.92, blue: 0.6, alpha: 1).cgColor
        for l in [gaugeBack, gaugeFill] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            layer.addSublayer(l)
        }
    }

    /// 角の丸い太字 (本家の UI の文字に近い)
    static func roundedFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
        return base
    }

    private func setupLabels() {
        titleLabel.textColor = .white
        titleLabel.text = songTitle
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        artistLabel.textColor = UIColor(white: 1, alpha: 0.9)
        artistLabel.text = artist
        diffLabel.textColor = .white
        diffLabel.text = difficulty.label + " Lv." + Beatrix.lvRank(level)
        reachLabel.text = "到達可能"
        reachLabel.textAlignment = .center
        rankLabel.textAlignment = .center
        comboLabel.textColor = UIColor(white: 0.47, alpha: 0.92)
        comboLabel.textAlignment = .center
        judgeView.contentMode = .center
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
        lyricLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        lyricLabel.textColor = UIColor(white: 1, alpha: 0.92)
        lyricLabel.textAlignment = .center
        lyricLabel.adjustsFontSizeToFitWidth = true
        lyricLabel.minimumScaleFactor = 0.6
        lyricLabel.layer.shadowColor = UIColor.black.cgColor
        lyricLabel.layer.shadowOpacity = 0.9
        lyricLabel.layer.shadowRadius = 3
        lyricLabel.layer.shadowOffset = .zero
        for v in [lyricLabel, scoreLabel, titleLabel, artistLabel, diffLabel, reachLabel, rankLabel,
                  comboLabel, judgeView, earlyLabel, countLabel, resultLabel] as [UIView] {
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
    }

    /// 縁取りの付いた文字
    private static func outlined(_ text: String, font: UIFont, color: UIColor, stroke: UIColor, width: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .strokeColor: stroke, .strokeWidth: -width
        ])
    }

    /// 判定の文字 (本家: 丸い太字に、横向きのグラデーションと、右下へ伸びる厚み)。画面の大きさごとに作って取っておく
    private var judgeImages: [String: UIImage] = [:]
    private var judgeImagesHeight: CGFloat = 0

    private func judgeImage(_ j: BxJudge) -> UIImage? {
        let h = bounds.height
        if h <= 0 { return nil }
        if judgeImagesHeight != h {
            judgeImages = [:]
            judgeImagesHeight = h
        }
        let key: String
        switch j {
        case .perfectPlus: key = "pp"
        case .perfect: key = "p"
        case .great: key = "g"
        case .miss: key = "m"
        }
        if let img = judgeImages[key] { return img }
        let text: String
        let colors: [UIColor]
        let depthColor: UIColor
        switch j {
        case .perfectPlus:
            text = "PERFECT!!"
            colors = [UIColor(red: 0.6, green: 0.94, blue: 1, alpha: 1), UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 1),
                      UIColor(red: 0.93, green: 0.68, blue: 0.95, alpha: 1)]
            depthColor = UIColor(red: 0.42, green: 0.46, blue: 0.56, alpha: 1)
        case .perfect:
            text = "PERFECT!"
            colors = [UIColor(red: 0.75, green: 0.9, blue: 1, alpha: 1), UIColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1),
                      UIColor(red: 0.88, green: 0.78, blue: 0.95, alpha: 1)]
            depthColor = UIColor(red: 0.42, green: 0.46, blue: 0.56, alpha: 1)
        case .great:
            text = "GREAT"
            colors = [UIColor(red: 1, green: 0.85, blue: 0.45, alpha: 1), UIColor(red: 1, green: 0.95, blue: 0.85, alpha: 1),
                      UIColor(red: 1, green: 0.62, blue: 0.82, alpha: 1)]
            depthColor = UIColor(red: 0.55, green: 0.42, blue: 0.4, alpha: 1)
        case .miss:
            text = "MISS"
            colors = [UIColor(white: 0.72, alpha: 1), UIColor(white: 0.72, alpha: 1)]
            depthColor = UIColor(white: 0.36, alpha: 1)
        }
        let font = Self.roundedFont(h * 0.105, .heavy)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .kern: h * 0.003]
        let ts = (text as NSString).size(withAttributes: attr)
        let depth = max(2, (h * 0.006).rounded())
        let size = CGSize(width: ceil(ts.width + depth + 4), height: ceil(ts.height + depth + 4))
        // 文字の形 (白) を先に作って、グラデーションの型抜きに使う
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        let mask = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            (text as NSString).draw(at: CGPoint(x: 2, y: 2), withAttributes: attr)
        }
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            // 厚み: 右下へ少しずつずらして、暗い色で重ねる
            var dattr = attr
            dattr[.foregroundColor] = depthColor
            var k = depth
            while k >= 1 {
                (text as NSString).draw(at: CGPoint(x: 2 + k * 0.5, y: 2 + k), withAttributes: dattr)
                k -= 1
            }
            // 表: 横向きのグラデーション
            guard let cg = mask.cgImage,
                  let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map { $0.cgColor } as CFArray,
                                        locations: colors.count == 3 ? [0, 0.5, 1] : [0, 1]) else { return }
            c.saveGState()
            c.translateBy(x: 0, y: size.height)
            c.scaleBy(x: 1, y: -1)
            c.clip(to: CGRect(origin: .zero, size: size), mask: cg)
            c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: 0), options: [])
            c.restoreGState()
        }
        judgeImages[key] = img
        return img
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

    // MARK: タッチエフェクト (シンプル)
    //   白タップ・始点: やわらかい水色の光の玉 / 赤タップ: 赤 / ワイプ: 横に長いやわらかい光 / 判定点: 小さな白い光
    //   GREAT: ピンク (控えめ) / 早い MISS: 灰色の光の玉だけ。遅い MISS・見逃しは出さない

    private func spawnEffect(type: Int, lane: Int, judge: BxJudge, early: Bool?) {
        guard bounds.width > 0 else { return }
        let cyan = UIColor(red: 0.12, green: 0.96, blue: 0.96, alpha: 1)
        var color: UIColor
        switch judge {
        case .perfectPlus, .perfect:
            switch type {
            case 3: color = UIColor(red: 1.0, green: 0.25, blue: 0.35, alpha: 1)
            case 4: color = UIColor(red: 1.0, green: 0.96, blue: 0.5, alpha: 1)
            default: color = cyan
            }
        case .great:
            color = UIColor(red: 1.0, green: 0.55, blue: 0.85, alpha: 1)
        case .miss:
            guard early == true else { return }
            color = UIColor(white: 0.6, alpha: 1)
        }
        let g = geo()
        let third = g.halfJ * 2 / 3
        let center = CGPoint(x: g.x(Self.laneFrac(lane), 0), y: g.judgeY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var made: [CALayer] = []

        func radial(_ w: CGFloat, _ h: CGFloat, _ colors: [UIColor], _ locs: [NSNumber]) -> CAGradientLayer {
            let l = CAGradientLayer()
            l.type = .radial
            l.colors = colors.map { $0.cgColor }
            l.locations = locs
            l.startPoint = CGPoint(x: 0.5, y: 0.5)
            l.endPoint = CGPoint(x: 1, y: 1)
            l.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            l.position = center
            effectHost.addSublayer(l)
            made.append(l)
            return l
        }

        if type == 4 && judge != .miss {
            // ワイプ: 横に長い、やわらかい光
            let l = radial(third * 1.4, third * 0.4,
                           [UIColor(white: 1, alpha: 0.85), color.withAlphaComponent(0.5), color.withAlphaComponent(0)],
                           [0, 0.45, 1])
            fade(l, scaleFrom: 0.9, to: 1.1, duration: 0.25)
        } else if type == 5 {
            let r = third * 0.15
            let l = radial(r * 2, r * 2, [UIColor(white: 1, alpha: 0.7), UIColor(white: 1, alpha: 0)], [0, 1])
            fade(l, scaleFrom: 0.9, to: 1.05, duration: 0.2)
        } else {
            // タップ: やわらかい光の玉だけ (シンプルに)
            let R = third * 0.3
            let glow = radial(R * 2, R * 2,
                              [UIColor(white: 1, alpha: 0.8), color.withAlphaComponent(0.55), color.withAlphaComponent(0)],
                              [0, 0.4, 1])
            fade(glow, scaleFrom: 0.85, to: 1.1, duration: judge == .miss ? 0.18 : 0.25)
        }
        CATransaction.commit()

        // 終わったら消す (アニメーションより少しあと)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
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
        for l in [bgLines, bgRing, floorLayer, partFillLayer, partEdgeLayer, beatLayer, edgeLayer, dividerLayer, zoneLayer,
                  holdIdleLayer, holdActiveLayer, slideIdleLayer, slideActiveLayer, simLayer,
                  tapShadow, tapLayer, headShadow, headLayer, redShadow, redLayer, wipeShadow, wipeLayer, judgeLayer,
                  scoreBar, titlePanel, diffTag, rankDiamond] {
            l.frame = bounds
        }
        bgGradient.frame = bounds
        effectHost.frame = bounds

        // 左上の帯。大きさは本家の画面収録 (1920 × 1440) から測った値を、画面の高さに合わせて縮めたもの
        let u = h / 1440
        func poly(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }
        scoreBar.path = poly([CGPoint(x: 0, y: 40 * u), CGPoint(x: 615 * u, y: 40 * u),
                              CGPoint(x: 560 * u, y: 90 * u), CGPoint(x: 0, y: 90 * u)])
        scoreLabel.frame = CGRect(x: 12 * u, y: 40 * u, width: 560 * u, height: 50 * u)
        titlePanel.path = poly([CGPoint(x: 0, y: 90 * u), CGPoint(x: 560 * u, y: 90 * u),
                                CGPoint(x: 425 * u, y: 225 * u), CGPoint(x: 0, y: 225 * u)])
        titleLabel.font = Self.roundedFont(50 * u, .heavy)
        titleLabel.frame = CGRect(x: 16 * u, y: 100 * u, width: 470 * u, height: 66 * u)
        artistLabel.font = UIFont.systemFont(ofSize: 25 * u, weight: .medium)
        artistLabel.frame = CGRect(x: 16 * u, y: 170 * u, width: 400 * u, height: 36 * u)
        diffLabel.font = Self.roundedFont(31 * u, .heavy)
        let diffW = ceil(diffLabel.sizeThatFits(CGSize(width: 2000, height: 100)).width)
        let tagR = max(330 * u, 16 * u + diffW + 50 * u)
        diffTag.path = poly([CGPoint(x: 0, y: 225 * u), CGPoint(x: tagR, y: 225 * u),
                             CGPoint(x: tagR - 65 * u, y: 272 * u), CGPoint(x: 0, y: 272 * u)])
        diffLabel.frame = CGRect(x: 16 * u, y: 225 * u, width: diffW + 4, height: 47 * u)
        gaugeRect = CGRect(x: 20 * u, y: 276 * u, width: 46 * u, height: 634 * u)
        gaugeBack.frame = gaugeRect
        reachLabel.attributedText = Self.outlined("到達可能", font: UIFont.systemFont(ofSize: 24 * u, weight: .heavy),
                                                  color: .white, stroke: UIColor(white: 0.1, alpha: 1), width: 3)
        reachLabel.frame = CGRect(x: 103 * u, y: 286 * u, width: 160 * u, height: 36 * u)
        let rc = CGPoint(x: 183 * u, y: 368 * u)
        let rh = 72 * u
        rankDiamond.path = poly([CGPoint(x: rc.x, y: rc.y - rh), CGPoint(x: rc.x + rh, y: rc.y),
                                 CGPoint(x: rc.x, y: rc.y + rh), CGPoint(x: rc.x - rh, y: rc.y)])
        rankLabel.frame = CGRect(x: rc.x - rh, y: rc.y - rh * 0.6, width: rh * 2, height: rh * 1.2)
        shownRank = ""
        shownScore = -1
        shownGauge = -1

        let g = geo()
        // コンボ (本家: 大きな灰色の数字) と判定の文字 (本家: PERFECT!! など)
        comboLabel.font = Self.roundedFont(h * 0.14, .heavy)
        comboLabel.frame = CGRect(x: 0, y: h * 0.57 - h * 0.09, width: w, height: h * 0.18)
        judgeView.frame = CGRect(x: 0, y: h * 0.71 - h * 0.08, width: w, height: h * 0.16)
        shownJudgeKey = ""
        earlyLabel.font = Self.roundedFont(h * 0.026, .heavy)
        earlyLabel.frame = CGRect(x: 0, y: h * 0.785, width: w, height: h * 0.035)
        countLabel.frame = CGRect(x: 0, y: h * 0.22, width: w, height: 70)
        // 歌詞: 判定ラインのすぐ上 (レーンの幅の中)
        lyricLabel.frame = CGRect(x: g.midX - g.halfJ, y: g.judgeY - 38, width: g.halfJ * 2, height: 24)
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
        // エディタと同じ offset (JSON の値 ms だけ、ノーツを曲に対して後ろへ)。
        // エディタの内部の offsetMs と同じ向き: 譜面時刻 t の音 = 曲の t + offset/1000 秒目
        // (SETTING の「再生の補正」も同じく引く。エディタの再生と同じずれ方にする)
        // さらに「テストプレイの補正」(初期値 -30ms = ノーツを 30ms 早める。エディタでノーツ音ぴったりの譜面が、プレイでちょうどよく感じる分)
        let off = -Double((session.chartOffsetRaw ?? 0) - Beatrix.playbackCorrectionMs) / Beatrix.offsetSampleRate
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
        // オートのときは、全部のボタンを押さえている扱い (ホールド / スライドの帯が光る・「しゅ〜」が鳴る)
        let zones: Set<Int> = session.autoPlay ? [0, 1, 2, 3] : Set(touchZones.values)
        if session.autoPlay {
            game.auto(to: t)
        } else {
            for z in zones { game.hold(zone: z, at: t) }
        }
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

    /// 奥行き。ソフラン (speeds) は「流れた量」pos で、ノーツ個別の速さ (speeds_each) は sp の倍率で入れる
    private func depth(_ t: Double, _ sp: Double = 1) -> Double {
        (source.pos(t) - nowPos) * depthSpeed * sp + visualShift
    }
    /// 今の「流れた量」(フレームの最初に 1 回だけ計算する)
    private var nowPos = 0.0

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
        let w = bounds.width
        let h = bounds.height
        // 背景の網目: 少しずらした格子の点を、横・縦・斜めにつないだ三角形 (毎回同じ形になるよう、決まった乱数で)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(seed >> 11) / Double(1 << 53))
        }
        let cols = 7
        let rows = 5
        var pts: [[CGPoint]] = []
        for j in 0...rows {
            var row: [CGPoint] = []
            for i in 0...cols {
                let x = (CGFloat(i) + (i == 0 || i == cols ? 0 : rnd() * 0.7 - 0.35)) * w / CGFloat(cols)
                let y = (CGFloat(j) + (j == 0 || j == rows ? 0 : rnd() * 0.7 - 0.35)) * h / CGFloat(rows)
                row.append(CGPoint(x: x, y: y))
            }
            pts.append(row)
        }
        let net = CGMutablePath()
        for j in 0...rows {
            for i in 0...cols {
                let p = pts[j][i]
                if i < cols { net.move(to: p); net.addLine(to: pts[j][i + 1]) }
                if j < rows { net.move(to: p); net.addLine(to: pts[j + 1][i]) }
                if i < cols && j < rows {
                    net.move(to: (i + j) % 2 == 0 ? p : pts[j][i + 1])
                    net.addLine(to: (i + j) % 2 == 0 ? pts[j + 1][i + 1] : pts[j + 1][i])
                }
            }
        }
        bgLines.path = net
        // レーンの後ろの大きな輪
        let ringR = h * 0.5
        bgRing.lineWidth = h * 0.025
        bgRing.path = CGPath(ellipseIn: CGRect(x: w / 2 - ringR, y: h * 0.4 - ringR, width: ringR * 2, height: ringR * 2), transform: nil)

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
        addQuad(judge, g, f0: -0.005, f1: 1.005, d0: -0.007, d1: 0.007)
        judgeLayer.path = judge
    }

    // MARK: 毎フレームの描画

    private func renderFrame() {
        guard bounds.width > 0 else { return }
        nowPos = source.pos(viewTime)
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
        // オートのときは帯を光らせるため全部押さえている扱い。ただしレーンの光は、触っているところだけ
        let zones: Set<Int> = session.autoPlay ? [0, 1, 2, 3] : Set(touchZones.values)
        let touchedZones = Set(touchZones.values)

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
        if touchedZones.contains(0) { addQuad(zp, g, f0: 0, f1: 1.0 / 3.0, d0: r.bot, d1: r.top) }
        if touchedZones.contains(1) || touchedZones.contains(2) { addQuad(zp, g, f0: 1.0 / 3.0, f1: 2.0 / 3.0, d0: r.bot, d1: r.top) }
        if touchedZones.contains(3) { addQuad(zp, g, f0: 2.0 / 3.0, f1: 1, d0: r.bot, d1: r.top) }
        zoneLayer.path = zp

        // ホールドの帯 (判定ラインより手前はいつも隠す)
        let hIdle = CGMutablePath()
        let hActive = CGMutablePath()
        let hw = sideWidth / 2 * 1.0              // 帯の太さ (始点の棒と同じ幅)
        for h in source.holds {
            if !bxVisible(at: viewTime, showFrom: h.showFrom, hideFrom: h.hideFrom, blink: h.blink) { continue }      // 出現前 / 消えたあと / 点滅で消えている
            let active = holdActive(h, at: viewTime, zones: zones)
            let d0 = max(depth(h.t0, h.sp), 0)
            let d1 = min(depth(h.t1, h.sp), r.top)
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
            if lastP.t < viewTime { continue }
            if !bxVisible(at: viewTime, showFrom: s.showFrom, hideFrom: s.hideFrom, blink: s.blink) { continue }      // 出現前 / 消えたあと / 点滅で消えている
            if depth(firstP.t, s.sp) > r.top && depth(lastP.t, s.sp) > r.top { continue }
            let active = slideActive(s, at: viewTime, zones: zones)
            let path = active ? sActive : sIdle
            let lo = viewTime
            for k in 0..<(s.pts.count - 1) {
                let a = s.pts[k]
                let b = s.pts[k + 1]
                if b.t <= a.t || b.t < lo { continue }
                let fa0 = Self.laneFrac(a.lane)
                let fb0 = Self.laneFrac(b.lane)
                let ta = max(a.t, lo)
                let tb = b.t
                if tb <= ta { continue }
                // ソフランの変わり目で区切る (区切りの中では、奥行きは時刻に比例する)
                var cuts = [ta]
                for sc in source.scroll where sc.t > ta && sc.t < tb { cuts.append(sc.t) }
                cuts.append(tb)
                for c in 0..<(cuts.count - 1) {
                    var t0 = cuts[c]
                    var t1 = cuts[c + 1]
                    var d0 = depth(t0, s.sp)
                    var d1 = depth(t1, s.sp)
                    if d0 > r.top && d1 > r.top { continue }
                    // 画面の奥 (r.top) より先は切る
                    if d1 > r.top && d1 != d0 {
                        let u = (r.top - d0) / (d1 - d0)
                        t1 = t0 + (t1 - t0) * u
                        d1 = r.top
                    } else if d0 > r.top && d1 != d0 {
                        let u = (r.top - d0) / (d1 - d0)
                        t0 = t0 + (t1 - t0) * u
                        d0 = r.top
                    }
                    let fa = fa0 + (fb0 - fa0) * (t0 - a.t) / (b.t - a.t)
                    let fb = fa0 + (fb0 - fa0) * (t1 - a.t) / (b.t - a.t)
                    path.move(to: CGPoint(x: g.x(fa - hw, d0), y: g.y(d0)))
                    path.addLine(to: CGPoint(x: g.x(fa + hw, d0), y: g.y(d0)))
                    path.addLine(to: CGPoint(x: g.x(fb + hw, d1), y: g.y(d1)))
                    path.addLine(to: CGPoint(x: g.x(fb - hw, d1), y: g.y(d1)))
                    path.closeSubpath()
                }
            }
        }
        slideIdleLayer.path = sIdle
        slideActiveLayer.path = sActive

        // 同時押しの線
        let sims = CGMutablePath()
        let gn = game.notes
        func noteVisible(_ i: Int) -> Bool {
            guard i < gn.count else { return false }
            let n = gn[i]
            if !bxVisible(at: viewTime, showFrom: n.showFrom, hideFrom: n.hideFrom, blink: n.blink) { return false }
            return !n.done || (n.type == 4 && viewTime < n.t)
        }
        for sim in source.sims {
            if !noteVisible(sim.ia) || !noteVisible(sim.ib) { continue }      // つないでいるノーツが見えないときは線も出さない
            let d = depth(sim.t, sim.sp)
            if d < -0.02 || d > r.top { continue }
            sims.move(to: CGPoint(x: g.x(Self.laneFrac(sim.a), d), y: g.y(d)))
            sims.addLine(to: CGPoint(x: g.x(Self.laneFrac(sim.b), d), y: g.y(d)))
        }
        simLayer.path = sims
    }

    /// ノーツ 1 つ (本家: 角の丸い棒)。奥行き d0〜d1 の範囲を画面の四角にして、両端を丸くする。
    /// 下側の少し暗い縁 (厚み) は shadow に、表は main に入れる
    private func addPill(_ main: CGMutablePath, _ shadow: CGMutablePath, _ g: Geo, f0: Double, f1: Double, d0: Double, d1: Double) {
        let yb = g.y(d0)
        let yt = g.y(d1)
        let hh = yb - yt
        if hh < 0.5 { return }
        let dm = (d0 + d1) / 2
        let xl = g.x(f0, dm)
        let xr = g.x(f1, dm)
        let ww = xr - xl
        if ww < 1 { return }
        func pill(_ rect: CGRect) -> CGPath {
            let ch = min(rect.height / 2, rect.width / 2)
            let cw = min(rect.height * 0.8, rect.width / 2)
            return CGPath(roundedRect: rect, cornerWidth: cw, cornerHeight: ch, transform: nil)
        }
        shadow.addPath(pill(CGRect(x: xl, y: yt, width: ww, height: hh)))
        main.addPath(pill(CGRect(x: xl, y: yt, width: ww, height: hh * 0.8)))
    }

    private func renderNotes() {
        let g = geo()
        let r = depthRange
        let notes = game.notes
        // ソフランがあると「画面に入る時刻の範囲」が決まらないので、少し前から最後まで見て、奥行きで画面の外を飛ばす
        // (見逃したノーツは、本家と同じく判定ラインを過ぎても流れ続けるので、少し長めに前から見る)
        let tLo = viewTime - 2.0
        // 画面に入る最初のノーツを二分探索 (ノーツは時刻順)
        var lo = 0
        var hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].t < tLo { lo = mid + 1 } else { hi = mid }
        }
        let tapP = CGMutablePath(), tapS = CGMutablePath()
        let headP = CGMutablePath(), headS = CGMutablePath()
        let redP = CGMutablePath(), redS = CGMutablePath()
        let wipeP = CGMutablePath(), wipeS = CGMutablePath()
        var i = lo
        while i < notes.count {
            let n = notes[i]
            i += 1
            if n.type == 5 { continue }
            // 取ったノーツは消す。ただしワイプは本家と同じく、判定ラインに来るまで流れ続ける (早く押しても、すぐには消えない)。
            // 見逃したノーツは、本家と同じく判定ラインを過ぎてもそのまま流れていく
            if n.done && !n.missed && !(n.type == 4 && viewTime < n.t) { continue }
            if !bxVisible(at: viewTime, showFrom: n.showFrom, hideFrom: n.hideFrom, blink: n.blink) { continue }      // 出現前 / 消えたあと / 点滅で消えている
            let d = depth(n.t, n.sp)
            if d < r.bot - 0.1 || d > r.top + 0.1 { continue }
            let f = Self.laneFrac(n.lane)
            switch n.type {
            case 2:
                addPill(headP, headS, g, f0: f - sideWidth / 2, f1: f + sideWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            case 3:
                addPill(redP, redS, g, f0: f - tapWidth / 2, f1: f + tapWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            case 4:
                addPill(wipeP, wipeS, g, f0: f - sideWidth / 2, f1: f + sideWidth / 2, d0: d - wipeDepth / 2, d1: d + wipeDepth / 2)
            default:
                addPill(tapP, tapS, g, f0: f - tapWidth / 2, f1: f + tapWidth / 2, d0: d - tapDepth / 2, d1: d + tapDepth / 2)
            }
        }
        tapLayer.path = tapP
        tapShadow.path = tapS
        headLayer.path = headP
        headShadow.path = headS
        redLayer.path = redP
        redShadow.path = redS
        wipeLayer.path = wipeP
        wipeShadow.path = wipeS
    }

    /// 文字は、値が変わったときだけ書き換える (毎フレーム文字を作り直すと重い)
    private func renderHUD() {
        // 歌詞 (重なっているときは、あとから始まるほう)
        var lyric = ""
        for l in source.lyrics where l.start <= viewTime && viewTime < l.end { lyric = l.text }
        if lyric != shownLyric {
            shownLyric = lyric
            lyricLabel.text = lyric
        }
        let u = bounds.height / 1440
        let score = game.score
        if score != shownScore {
            shownScore = score
            scoreLabel.attributedText = Self.outlined("SCORE \(score)", font: Self.roundedFont(44 * u, .heavy),
                                                      color: UIColor(white: 0.45, alpha: 1), stroke: .white, width: 4)
        }
        // 左のゲージ (到達可能なスコア。減った分は上から灰色になる) と、到達可能なランク
        let frac = game.clearGauge
        if Int(frac * 1000) != shownGauge {
            shownGauge = Int(frac * 1000)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let fh = gaugeRect.height * CGFloat(frac)
            gaugeFill.frame = CGRect(x: gaugeRect.minX, y: gaugeRect.maxY - fh, width: gaugeRect.width, height: fh)
            CATransaction.commit()
        }
        let rank = game.achievableRank
        if rank != shownRank {
            shownRank = rank
            let color: UIColor
            switch rank {
            case "AP+", "AP": color = UIColor(red: 0.5, green: 1, blue: 1, alpha: 1)
            case "SS", "S": color = UIColor(red: 1, green: 0.85, blue: 0.35, alpha: 1)
            case "AA", "A": color = UIColor(red: 1, green: 0.6, blue: 0.75, alpha: 1)
            default: color = UIColor(white: 0.92, alpha: 1)
            }
            rankLabel.attributedText = Self.outlined(rank, font: Self.roundedFont((rank.count >= 3 ? 50 : 66) * u, .heavy),
                                                     color: color, stroke: UIColor(white: 0.08, alpha: 1), width: 3)
            let gold = rank == "SS" || rank == "S"
            rankDiamond.strokeColor = gold ? UIColor(red: 1, green: 0.82, blue: 0.3, alpha: 1).cgColor : nil
            rankDiamond.lineWidth = gold ? max(1.5, 4 * u) : 0
        }
        if game.combo != shownCombo {
            shownCombo = game.combo
            comboLabel.text = game.combo > 0 ? "\(game.combo)" : ""
        }

        var key = ""
        if let j = game.lastJudge, viewTime - game.lastJudgeAt < 0.6 {
            key = "\(j)-\(game.lastJudgeAt)-\(game.lastEarly.map { $0 ? "e" : "l" } ?? "")"
            if key != shownJudgeKey {
                judgeView.image = judgeImage(j)
                if let e = game.lastEarly, j == .perfect || j == .great {
                    earlyLabel.text = e ? "FAST" : "SLOW"
                    earlyLabel.textColor = e ? UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1) : UIColor(red: 1, green: 0.55, blue: 0.45, alpha: 1)
                } else {
                    earlyLabel.text = ""
                }
            }
        }
        if key != shownJudgeKey {
            shownJudgeKey = key
            if key.isEmpty {
                judgeView.image = nil
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
                let sc = game.score
                resultLabel.text = "RESULT\n\n" + "SCORE \(sc)  \(BxGame.rank(of: sc))" + (sc >= 900_000 ? "  CLEAR" : "  FAILED")
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
                // 右上の II (本家: 暗い四角に白い太い 2 本線。大きさは画面の高さに合わせる)
                GeometryReader { geo in
                    let u = geo.size.height / 1440
                    Button { session.pause() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10 * u)
                                .fill(Color(white: 0.13, opacity: 0.85))
                            HStack(spacing: 26 * u) {
                                Rectangle().fill(Color.white).frame(width: 32 * u, height: 88 * u)
                                Rectangle().fill(Color.white).frame(width: 32 * u, height: 88 * u)
                            }
                        }
                        .frame(width: 150 * u, height: 160 * u)
                    }
                    .buttonStyle(.plain)
                    .position(x: geo.size.width - 85 * u, y: 80 * u)
                }
                .ignoresSafeArea()
            }
            if session.paused {
                PauseOverlay(session: session)
            }
        }
        .statusBarHidden(true)
        .compatHideSystemOverlays()
        .compatDeferBottomGestures()
        .onAppear {
            session.paused = false
            let s = session
            let close = onClose
            s.quit = { [weak s] in close(s?.chartOffsetRaw) }
        }
    }
}
