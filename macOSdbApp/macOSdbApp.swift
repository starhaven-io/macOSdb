import SwiftUI

struct MacOSdbApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 1_000, height: 700)
    }
}
