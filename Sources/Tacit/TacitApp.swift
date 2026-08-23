import SwiftUI
import TacitCore

@main
struct TacitApp: App {
    /// The real capture → detection → classification → arbitration pipeline (Task 11). Owns its
    /// own `FixtureRecorder` (below), fed live frames per `TacitEngine`'s concurrency doc comment.
    @StateObject private var engine = TacitEngine()
    /// The persistent gesture→action mapping store (spec §3.6): one app-lifetime instance, shared
    /// by the Library window so every specimen card's toggle/binding reads and writes the same
    /// `mappings.json` — and, once Task 18/20 wire up real dispatch, the same store the
    /// arbitration/dispatch path will read from.
    @StateObject private var mappingStore = MappingStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
                .environmentObject(engine.recorder)
        } label: {
            // The label (unlike the popover content) is realized immediately at launch, not
            // lazily on first open — see `MenuBarLabel`'s doc comment for why the launch-time work
            // (starting the engine, wiring the mapping store, opening onboarding) lives there.
            MenuBarLabel(engine: engine, mappingStore: mappingStore)
        }
        .menuBarExtraStyle(.window)

        Window("Tacit Library", id: "library") {
            LibraryWindow(store: mappingStore, engine: engine)
        }

        // Task 20: shown on first launch only, opened programmatically by `MenuBarLabel` (below)
        // via `openWindow(id: "onboarding")` — NOT shown automatically just by being declared
        // here. `UserDefaults` key `OnboardingView.onboardedDefaultsKey` ("tacit.onboarded") is
        // what actually gates that one-time open.
        Window("Welcome to Tacit", id: "onboarding") {
            OnboardingView(engine: engine, store: mappingStore)
        }
        .windowResizability(.contentSize)
    }
}

/// The `MenuBarExtra` label's content. Extracted into its own view (rather than left inline in
/// `TacitApp.body`) so it can read `\.openWindow` — that environment key is only available inside
/// a `View`, not on the `App` conformer itself — and so its `onAppear` has one place to do every
/// piece of launch-time, run-exactly-once setup:
///   1. `engine.start()` — begins the capture → detection → arbitration pipeline.
///   2. `engine.attachMappingStore(mappingStore)` — wires spec §6's Accessibility-warning
///      derivation (Task 20) to the live bindings.
///   3. On first launch only (`tacit.onboarded` not yet set), `openWindow(id: "onboarding")`.
/// All three calls are idempotent on the callee side, so a re-invocation of this `onAppear` (e.g.
/// from an unrelated re-render) is harmless.
private struct MenuBarLabel: View {
    @ObservedObject var engine: TacitEngine
    var mappingStore: MappingStore

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarGlyphImageCache.shared.image(for: engine.glyphState))
            .onAppear {
                engine.start()
                engine.attachMappingStore(mappingStore)
                if !UserDefaults.standard.bool(forKey: OnboardingView.onboardedDefaultsKey) {
                    openWindow(id: "onboarding")
                }
            }
    }
}
