import AppKit

/// Brings a `Window(_:id:)` scene to the front and makes it key after `openWindow(id:)` is
/// called — SwiftUI's `openWindow` only *requests* the scene; it doesn't activate the app or
/// guarantee the resulting `NSWindow` is ordered above other apps' windows (Task: summoned
/// windows, e.g. Library from the menu-bar popover, were appearing behind whatever else was
/// focused). Used from `PopoverView` (Library) and `TacitApp` (onboarding) — both one-line call
/// sites right after their `openWindow(id:)`.
enum WindowActivator {
    /// - Parameters:
    ///   - id: the `Window` scene's `id`, matched against `NSWindow.identifier` first.
    ///   - title: fallback match (the scene's title, e.g. "Tacit Library") for the case where
    ///     SwiftUI hasn't stamped `identifier` the way we expect — belt-and-suspenders since this
    ///     couldn't be verified by launching the app (lead relaunches from `main`).
    @MainActor
    static func bringToFront(id: String, title: String) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // The target window may not exist yet (first `openWindow` for a scene materializes it
        // asynchronously) or may not yet be key, so look it up on the next run-loop turn rather
        // than synchronously right after `openWindow` returns.
        DispatchQueue.main.async {
            let window = NSApp.windows.first { $0.identifier?.rawValue == id }
                ?? NSApp.windows.first { $0.title == title }
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
