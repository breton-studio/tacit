import AppKit
import SwiftUI
import TacitCore

/// The four states the menu bar glyph (and popover header) can be in. Mirrors, at UI-consumption
/// granularity, the union of `CaptureState` (Task 6) and `ArbitrationState` (Task 5): the real
/// `TacitEngine` (Task 11) is expected to derive this from those two.
enum GlyphState: Equatable {
    case paused, watching, armed, fired
}

/// The observable surface `TacitEngine` (`Sources/Tacit/TacitEngine.swift`) conforms to, keeping
/// the menu bar glyph and popover UI decoupled from the engine's concrete type.
@MainActor
protocol EngineUIState: ObservableObject {
    /// Drives the menu bar glyph and popover header state line.
    var glyphState: GlyphState { get }
    /// Master toggle: "Tacit is watching" vs "Paused".
    var isEnabled: Bool { get set }
    /// Final-review finding I1: whether the HUD confirmation panel shows on a fire (glyph feedback
    /// keeps working either way — see `TacitEngine.applyDispatchOutcome`).
    var isHUDEnabled: Bool { get set }
    /// Gesture debug view toggle (popover "Show gesture debug view" row): shows/hides
    /// `TacitEngine.debugPanelController`'s floating panel. See `TacitEngine.isDebugViewEnabled`.
    var isDebugViewEnabled: Bool { get set }
    /// Low light / permission rows, etc. `nil` means no warning to show.
    var warning: String? { get }
    /// The chord a `.toggleKeystroke` currently has held down, or `nil` when nothing is latched.
    /// Drives the popover's "Holding <key> · Release" row (workhorse-remap Task 5).
    var latchedChord: KeyChord? { get }
    /// "Pause for an Hour" — pause detection for `duration` seconds, then resume.
    func pause(for duration: TimeInterval)
    /// Popover "Release" row: forces the current latch (if any) off.
    func releaseLatch()
}

// `StubEngine` (manual-verification stand-in cycling glyph states) and `PlaceholderEngine`
// (release-build stand-in) lived here through Task 10, ahead of the real `TacitEngine` (Task 11).
// Both are gone now that `TacitEngine` (Sources/Tacit/TacitEngine.swift) is wired into
// `TacitApp` in every build configuration; neither had any remaining reference (no
// `#Preview`/`PreviewProvider` used either), so there was nothing left for them to stand in for.

/// The app's one accent color (spec §4.1): used solely for the armed/active semantic, never for
/// decoration. Funneled through this single constant so it stays swappable in one place — once an
/// asset catalog exists, adding a "TacitAccent" color set there is picked up automatically with no
/// call-site changes; until then it computes a fallback.
enum TacitColors {
    static let accent: Color = {
        if let named = NSColor(named: "TacitAccent") {
            return Color(named)
        }
        return .orange
    }()
}

/// The menu bar glyph's identity: Lucide's `hand`/`hand-fist` icons (`LucideGlyphs.swift`), not
/// the HUD/Library's constellation line-art — a deliberate, user-requested exception to the
/// spec's "constellation identity in the menu bar" rule. The constellation imagery is unchanged
/// everywhere else (HUD, Library, popover body).
enum MenuBarGlyph {
    /// The stroke/fill color the glyph renders in for a given state (spec §3.7 / §4):
    /// *paused* hollow (secondary, 40% opacity), *watching* full line-art in `.primary`,
    /// *armed*/*fired* accent-filled.
    static func color(for state: GlyphState) -> Color {
        switch state {
        case .paused: Color.secondary.opacity(0.4)
        case .watching: .primary
        case .armed, .fired: TacitColors.accent
        }
    }

    /// Template images (paused/watching) let AppKit tint the glyph to match the menu bar's
    /// current appearance (light/dark, dark menu bar, etc); armed/fired render in the accent
    /// color itself, so they must NOT be treated as a template mask.
    static func isTemplate(for state: GlyphState) -> Bool {
        state == .paused || state == .watching
    }
}

/// Renders and caches the `NSImage` `MenuBarExtra` uses as its label icon, one per `GlyphState`,
/// re-rendering only when the state actually changes — never per frame, never per SwiftUI
/// invalidation. `NSStatusItem` images can't be mid-spring-animated, so `.fired` is approximated
/// here by the plain `.armed` image; the real scale pulse (1→1.06→1, `TacitMotion.armedPulse`)
/// only plays in the popover header, where SwiftUI can actually animate it.
@MainActor
final class MenuBarGlyphImageCache {
    static let shared = MenuBarGlyphImageCache()

    private var cache: [GlyphState: NSImage] = [:]

    func image(for state: GlyphState) -> NSImage {
        let cacheKey: GlyphState = state == .fired ? .armed : state
        if let cached = cache[cacheKey] { return cached }
        let image = render(cacheKey)
        cache[cacheKey] = image
        return image
    }

    private func render(_ state: GlyphState) -> NSImage {
        let content = LucideMenuBarIcon(state: state, size: 18)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2  // retina-sharp glyph at menu bar size
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = MenuBarGlyph.isTemplate(for: state)
        return image
    }
}

/// SwiftUI presentation of the Lucide glyph for the popover header, where (unlike the menu bar
/// label) SwiftUI CAN animate: this is where the `.fired` scale pulse actually plays.
struct MenuBarGlyphView: View {
    var state: GlyphState
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        LucideMenuBarIcon(state: state, size: size)
            .scaleEffect(pulseScale)
        .onChange(of: state) { _, newValue in
            guard newValue == .fired else { return }
            pulse()
        }
    }

    /// Scale 1 → 1.06 → 1 with `armedPulse`, then rendering falls back to plain `.armed` visuals
    /// (the caller is expected to move `state` from `.fired` back to `.armed` shortly after firing;
    /// this view only owns the transient scale, not the state transition itself).
    private func pulse() {
        guard let animation = TacitMotion.respecting(reduceMotion, TacitMotion.armedPulse) else {
            // Reduce Motion: the glyph's own state label change ("Fired ✓") communicates the
            // event; no motion is required (spec §4.6 / motion spec table: "none (glyph state
            // change suffices)").
            return
        }
        withAnimation(animation) { pulseScale = 1.06 }
        Task {
            // The scale-up leg must finish before the scale-down leg starts; `TacitMotion` is the
            // single source of truth for that duration (see `armedPulseDuration`'s doc comment).
            try? await Task.sleep(for: .seconds(TacitMotion.armedPulseDuration))
            withAnimation(animation) { pulseScale = 1.0 }
        }
    }
}
