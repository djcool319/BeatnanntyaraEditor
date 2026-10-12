import SwiftUI

@main
struct MalodySlideEditorApp: App {
    // iPhone の画面の向き (横 / 縦) を切り替えるため (PhoneLayout.swift)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
