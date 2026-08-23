import SwiftUI

@main
struct TacitApp: App {
    #if DEBUG
    /// Manual-verification stand-in that cycles glyph states — see `StubEngine`. Task 11 replaces
    /// this with the real `TacitEngine`.
    @StateObject private var engine = StubEngine()
    #else
    @StateObject private var engine = PlaceholderEngine()
    #endif

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
        } label: {
            Image(nsImage: MenuBarGlyphImageCache.shared.image(for: engine.glyphState))
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
