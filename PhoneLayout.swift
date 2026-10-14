import SwiftUI
import UIKit

// MARK: - iPhone 対応
//
// エディタの見た目は、本家 (iPad) の画面から測った大きさ (pt) で作ってある。iPhone ではそのままだと画面に入りきらないので、
//   ・iPhone のときだけ、iPad くらいの大きさの「仮の画面」で作って、画面に合わせて全体を縮めて表示する
//     (短いほうの辺が 640pt になるように縮める。横画面なら高さ 640pt、縦画面なら幅 640pt の画面として作る)
//   ・ノッチ / ダイナミックアイランド / ホームバーにかからないよう、安全な範囲 (safe area) の中に収める
//   ・画面の向きは「横」と「縦」を切り替えられる (iPhone だけ。SETTING と起動画面から。次回も残る)
// iPad は今までどおり (何も変えない)。

enum PhoneLayout {
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// iPhone で作る「仮の画面」の短いほうの辺 (pt)
    static let virtualShortSide: CGFloat = 640

    /// いちばん手前のウィンドウの safe area (ノッチ・ホームバーの分)
    static func windowInsets() -> UIEdgeInsets {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return (windows.first { $0.isKeyWindow } ?? windows.first)?.safeAreaInsets ?? .zero
    }
}

/// iPhone のときだけ、中身を「仮の画面」の大きさで作って縮めて表示する。iPad ではそのまま
struct PhoneScaled<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if PhoneLayout.isPhone {
            GeometryReader { geo in
                let ins = PhoneLayout.windowInsets()
                let w = max(1, geo.size.width - ins.left - ins.right)
                let h = max(1, geo.size.height - ins.top - ins.bottom)
                let s = min(1, min(w, h) / PhoneLayout.virtualShortSide)
                ZStack(alignment: .topLeading) {
                    Color.black
                    // 中身は safe area を持たない入れ物 (ZeroSafeAreaHost) に入れる。
                    // SwiftUI のままだと、仮の画面がノッチ・ホームバーの位置にかかっている分だけ中身が勝手に広がって、
                    // 右のボタン列や下の帯が、見えない位置 (縮めた範囲の外) にはみ出してしまうため
                    ZeroSafeAreaHost(content: AnyView(content))
                        .frame(width: w / s, height: h / s)
                        .scaleEffect(s, anchor: .topLeading)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .clipped()
                        .offset(x: ins.left, y: ins.top)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        } else {
            content
        }
    }
}

/// safe area (ノッチ・ホームバーの分の余白) を一切持たない入れ物。中身はいつも、もらった大きさぴったりで並ぶ
struct ZeroSafeAreaHost: UIViewControllerRepresentable {
    let content: AnyView

    func makeUIViewController(context: Context) -> ZeroSafeAreaHostingController {
        let hc = ZeroSafeAreaHostingController(rootView: content)
        hc.view.backgroundColor = .black
        return hc
    }

    func updateUIViewController(_ hc: ZeroSafeAreaHostingController, context: Context) {
        hc.rootView = content
    }
}

final class ZeroSafeAreaHostingController: UIHostingController<AnyView> {
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// iOS 16.0〜16.3 (safeAreaRegions が無い) では、受け取った余白と同じだけマイナスの余白を足して打ち消す
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if #available(iOS 16.4, *) { return }
        let parent = view.safeAreaInsets
        let add = additionalSafeAreaInsets
        let base = UIEdgeInsets(top: parent.top - add.top, left: parent.left - add.left,
                                bottom: parent.bottom - add.bottom, right: parent.right - add.right)
        let want = UIEdgeInsets(top: -base.top, left: -base.left, bottom: -base.bottom, right: -base.right)
        if want != add { additionalSafeAreaInsets = want }
    }
}

// MARK: - 画面の向き (iPhone だけ)

final class AppOrientation {
    static let key = "phone.portrait"

    /// 今許している向き (AppDelegate が iOS に返す)
    static var mask: UIInterfaceOrientationMask = initialMask()

    static var isPortrait: Bool {
        PhoneLayout.isPhone && UserDefaults.standard.bool(forKey: key)
    }

    private static func initialMask() -> UIInterfaceOrientationMask {
        if !PhoneLayout.isPhone { return .landscape }
        return UserDefaults.standard.bool(forKey: key) ? .portrait : .landscape
    }

    /// iPhone の向きを切り替える (portrait: true で縦画面)
    static func set(portrait: Bool) {
        guard PhoneLayout.isPhone else { return }
        UserDefaults.standard.set(portrait, forKey: key)
        mask = portrait ? .portrait : .landscape
        if #available(iOS 16.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows {
                    w.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
                ws.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            }
        } else {
            // iOS 15: 向きを直接指定して、回し直してもらう
            let o: UIInterfaceOrientation = portrait ? .portrait : .landscapeRight
            UIDevice.current.setValue(o.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

/// 「横画面 / 縦画面」の切り替えボタン (iPhone のときだけ出す)
struct PhoneOrientationPicker: View {
    @State private var portrait = AppOrientation.isPortrait

    var body: some View {
        if PhoneLayout.isPhone {
            HStack(spacing: 8) {
                Text("画面の向き (iPhone)")
                    .foregroundColor(.white)
                choice("横画面", selected: !portrait) { portrait = false; AppOrientation.set(portrait: false) }
                choice("縦画面", selected: portrait) { portrait = true; AppOrientation.set(portrait: true) }
            }
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(selected ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(selected ? Color(red: 0.4, green: 0.85, blue: 1) : Color.clear)
                .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}
