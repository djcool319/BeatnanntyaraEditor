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
