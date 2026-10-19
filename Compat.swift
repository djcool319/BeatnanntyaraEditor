import SwiftUI
import UIKit

// MARK: - iOS 15 でも動かすための置き換え
//   iOS 16 から使える機能は、iOS 16 以上のときだけ使う (iOS 15 では何もしない)

extension View {
    /// ホームバーなどを隠す (iOS 16 以上)
    @ViewBuilder
    func compatHideSystemOverlays() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }

    /// 画面の下端からのスワイプを、1 回目はアプリに渡す (iOS 16 以上)
    @ViewBuilder
    func compatDeferBottomGestures() -> some View {
        if #available(iOS 16.0, *) {
            self.defersSystemGestures(on: .bottom)
        } else {
            self
        }
    }

    /// スクロールでキーボードを閉じる (iOS 16 以上)
    @ViewBuilder
    func compatScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

// MARK: - 文字を入れるダイアログ (iOS 15 でも入力欄が出るように、UIKit の UIAlertController で出す)
//   SwiftUI の .alert に TextField を入れる書き方は iOS 16 から。iOS 15 では入力欄が出ず、キーボードも出ない

enum TextPrompt {
    struct Action {
        let title: String
        var style: UIAlertAction.Style = .default
        let handler: (String) -> Void
    }

    static func show(title: String, message: String?, placeholder: String, text: String,
                     keyboard: UIKeyboardType = .default, actions: [Action]) {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.placeholder = placeholder
            tf.text = text
            tf.keyboardType = keyboard
            tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
        }
        for a in actions {
            ac.addAction(UIAlertAction(title: a.title, style: a.style) { _ in
                a.handler(ac.textFields?.first?.text ?? "")
            })
        }
        topViewController()?.present(ac, animated: true)
    }

    /// いちばん手前に出ている画面
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var vc = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

// MARK: - 選ぶだけのダイアログ (UIKit の UIAlertController で出す)
//   iOS 15 では、Menu の項目を押した直後に SwiftUI の confirmationDialog を出そうとしても出ない (メニューが閉じる途中のため)。
//   そこで UIKit のダイアログを、メニューが閉じ終わるのを少し待ってから出す

enum ChoicePrompt {
    struct Action {
        let title: String
        var style: UIAlertAction.Style = .default
        let handler: () -> Void
    }

    static func show(title: String, message: String?, actions: [Action], delay: Double = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for a in actions {
                ac.addAction(UIAlertAction(title: a.title, style: a.style) { _ in a.handler() })
            }
            TextPrompt.topViewController()?.present(ac, animated: true)
        }
    }
}
