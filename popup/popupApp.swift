import SwiftUI

@main
struct popupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            ContentView()
        }
    }
}
