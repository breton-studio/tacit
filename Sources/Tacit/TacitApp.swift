import SwiftUI

@main
struct TacitApp: App {
    /// The real capture → detection → classification → arbitration pipeline (Task 11). Owns its
    /// own `FixtureRecorder` (below), fed live frames per `TacitEngine`'s concurrency doc comment.
    @StateObject private var engine = TacitEngine()

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
            LibraryPlaceholderView()
        }
    }
}

/// M1 placeholder for the Library window (spec §5's "specimen book" arrives in M2). Polished
/// anyway, per brief: centered constellation, quiet type, generous spacing — not a bare
/// "not implemented yet" label.
private struct LibraryPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ConstellationRenderer(
                frame: MenuBarGlyph.fistFrame,
                lineWidth: 1.5,
                color: .secondary,
                fitToJoints: true
            )
            .frame(width: 120, height: 120)
            .opacity(0.6)

            Text("The Library arrives in M2.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(.background)
    }
}
