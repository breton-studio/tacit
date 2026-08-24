import SwiftUI
import TacitCore

@main
struct TacitApp: App {
    /// The real capture → detection → classification → arbitration → dispatch pipeline (Task 11,
    /// closed end-to-end in Task 21). Owns its own `FixtureRecorder` (below, fed live frames per
    /// `TacitEngine`'s concurrency doc comment) AND — per Task 21's single-store unification — the
    /// app's one `MappingStore` instance (`engine.mappingStore`): the Library window and
    /// onboarding below are handed that exact object rather than a second instance of their own,
    /// so every specimen card's toggle/binding reads and writes the same `mappings.json` the
    /// dispatch path reads from.
    @StateObject private var engine = TacitEngine()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
                .environmentObject(engine.recorder)
        } label: {
            // The label (unlike the popover content) is realized immediately at launch, not
            // lazily on first open — see `MenuBarLabel`'s doc comment for why the launch-time work
            // (starting the engine, opening onboarding) lives there.
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("Tacit Library", id: "library") {
            LibraryWindow(store: engine.mappingStore, engine: engine)
        }

        // Task 20: shown on first launch only, opened programmatically by `MenuBarLabel` (below)
        // via `openWindow(id: "onboarding")` — NOT shown automatically just by being declared
        // here. `UserDefaults` key `OnboardingView.onboardedDefaultsKey` ("tacit.onboarded") is
        // what actually gates that one-time open.
        Window("Welcome to Tacit", id: "onboarding") {
            OnboardingView(engine: engine, store: engine.mappingStore)
        }
        .windowResizability(.contentSize)
    }
}

/// The `MenuBarExtra` label's content. Extracted into its own view (rather than left inline in
/// `TacitApp.body`) so it can read `\.openWindow` — that environment key is only available inside
/// a `View`, not on the `App` conformer itself — and so its `onAppear` has one place to do every
/// piece of launch-time, run-exactly-once setup:
///   1. `engine.start()` — begins the capture → detection → arbitration → dispatch pipeline (also
///      wires spec §6's Accessibility-warning derivation internally now — see `TacitEngine.init`).
///   2. `LaunchAtLoginDefault.configureIfNeeded()` — Task 21's R5: registers Tacit as a login item
///      by default on a fresh install only.
///   3. On first launch only (`tacit.onboarded` not yet set), `openWindow(id: "onboarding")`.
/// All three calls are idempotent on the callee side, so a re-invocation of this `onAppear` (e.g.
/// from an unrelated re-render) is harmless.
private struct MenuBarLabel: View {
    @ObservedObject var engine: TacitEngine

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarGlyphImageCache.shared.image(for: engine.glyphState))
            .onAppear {
                engine.start()
                LaunchAtLoginDefault.configureIfNeeded()
                if !UserDefaults.standard.bool(forKey: OnboardingView.onboardedDefaultsKey) {
                    openWindow(id: "onboarding")
                    WindowActivator.bringToFront(id: "onboarding", title: "Welcome to Tacit")
                }
            }
    }
}
