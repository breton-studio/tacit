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
            // lazily on first open — this is the one reliable place to kick off `engine.start()`
            // exactly once. `start()` is idempotent, so even a re-render triggering `onAppear`
            // again would be harmless.
            Image(nsImage: MenuBarGlyphImageCache.shared.image(for: engine.glyphState))
                .onAppear { engine.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Tacit Library", id: "library") {
            LibraryWindow(store: mappingStore, engine: engine)
        }
    }
}
