import SwiftUI

@main
struct TacitApp: App {
    var body: some Scene {
        MenuBarExtra("Tacit", systemImage: "circle.dotted") {
            Text("Tacit 0.1.0")
            Divider()
            Button("Quit Tacit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
