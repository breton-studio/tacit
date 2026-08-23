import AppKit
import SwiftUI
import TacitCore

/// The four states the menu bar glyph (and popover header) can be in. Mirrors, at UI-consumption
/// granularity, the union of `CaptureState` (Task 6) and `ArbitrationState` (Task 5): the real
/// `TacitEngine` (Task 11) is expected to derive this from those two.
enum GlyphState: Equatable {
    case paused, watching, armed, fired
}

/// The observable surface Task 11's `TacitEngine` will conform to. Defined here, ahead of that
/// engine's existence, so this task's UI (menu bar glyph + popover) can be built and manually
/// verified against a stand-in (`StubEngine`, below) without waiting on capture/detection/
/// arbitration wiring.
@MainActor
protocol EngineUIState: ObservableObject {
    /// Drives the menu bar glyph and popover header state line.
    var glyphState: GlyphState { get }
    /// Master toggle: "Tacit is watching" vs "Paused".
    var isEnabled: Bool { get set }
    /// Low light / permission rows, etc. `nil` means no warning to show.
    var warning: String? { get }
    /// "Pause for an Hour" — pause detection for `duration` seconds, then resume.
    func pause(for duration: TimeInterval)
}

#if DEBUG
/// Manual-verification-only stand-in for `EngineUIState`, cycling through all four glyph states
/// on a timer. Used solely to exercise the menu bar glyph and popover by eye (state transitions,
/// Reduce Motion, launch-at-login) before Task 11's real `TacitEngine` exists. Compiled out of
/// release builds by `#if DEBUG`.
@MainActor
final class StubEngine: ObservableObject, EngineUIState {
    @Published private(set) var glyphState: GlyphState = .watching
    @Published var isEnabled: Bool = true
    @Published private(set) var warning: String? = nil

    /// `nonisolated(unsafe)`: only ever written from `init` (main actor) and read in `deinit`,
    /// which runs nonisolated by language rule even though this class is `@MainActor` — `Timer`
    /// isn't `Sendable`, so a plain isolated stored property can't be touched from `deinit`.
    private nonisolated(unsafe) var timer: Timer?
    /// Dwells briefly on `.fired` (like a real gesture fire) between longer holds so the pulse is
    /// easy to catch by eye.
    private let cycle: [GlyphState] = [.watching, .armed, .fired, .armed, .watching, .paused]
    private var index = 0

    init() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        index = (index + 1) % cycle.count
        glyphState = cycle[index]
    }

    func pause(for duration: TimeInterval) {
        glyphState = .paused
        isEnabled = false
        // Stub only: a real resume-after-`duration` timer is Task 11's responsibility.
    }

    deinit {
        timer?.invalidate()
    }
}
#endif

/// Always-available (all build configurations) stand-in for `EngineUIState`, used until Task 11
/// wires in the real `TacitEngine`. Unlike `StubEngine` above (DEBUG-only, cycles states for
/// manual glyph verification), this makes no attempt to simulate activity — a fixed `.paused`
/// state — so the popover has a concrete `EngineUIState` to bind to in release builds too.
@MainActor
final class PlaceholderEngine: ObservableObject, EngineUIState {
    @Published private(set) var glyphState: GlyphState = .paused
    // Matches `glyphState == .paused` above — a release build must not show a "Paused" header
    // next to a "Tacit is watching" master toggle.
    @Published var isEnabled: Bool = false
    @Published private(set) var warning: String? = nil

    func pause(for duration: TimeInterval) {
        glyphState = .paused
        isEnabled = false
    }
}

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

/// The menu bar glyph's identity image: a canned loose-fist `LandmarkFrame`, hand-tuned (in the
/// same proportions Vision reports for a resting fist — wrist low-center, fingers curled with
/// tips pulled in near the palm center, thumb tucked to the side) so it reads unambiguously as a
/// fist in line-art at 18×18. All 21 joints are present (none omitted), each at confidence 0.9 —
/// there is no "missing joint" degraded-state gap in the glyph itself.
enum MenuBarGlyph {
    static let fistFrame: LandmarkFrame = {
        func jp(_ x: Double, _ y: Double) -> JointPoint { JointPoint(x: x, y: y, confidence: 0.9) }
        // Hand-tuned so the joints' own bounding box is close to square (~0.22 × 0.19) rather
        // than wide-and-flat: at 18×18 with `fitToJoints`, a near-square bbox reads as a compact
        // fist blob instead of a splayed hand. Wrist low-center; MCP knuckle row fanning up from
        // it; each finger's PIP/DIP/tip curled back and pulled in toward a shared point just above
        // the knuckle row (how Vision actually reports a fist — folded fingers read as ABOVE the
        // MCP row, not below it); thumb tucked to the side, clear of the curled tips.
        let joints: [HandJoint: JointPoint] = [
            .wrist: jp(0.50, 0.16),

            .thumbCMC: jp(0.44, 0.19), .thumbMP: jp(0.40, 0.22), .thumbIP: jp(0.39, 0.20), .thumbTip: jp(0.38, 0.18),

            .indexMCP: jp(0.42, 0.30), .indexPIP: jp(0.49, 0.33), .indexDIP: jp(0.49, 0.315), .indexTip: jp(0.49, 0.30),
            .middleMCP: jp(0.48, 0.30), .middlePIP: jp(0.505, 0.35), .middleDIP: jp(0.505, 0.335), .middleTip: jp(0.505, 0.32),
            .ringMCP: jp(0.54, 0.30), .ringPIP: jp(0.52, 0.33), .ringDIP: jp(0.52, 0.315), .ringTip: jp(0.52, 0.30),
            .littleMCP: jp(0.60, 0.30), .littlePIP: jp(0.535, 0.31), .littleDIP: jp(0.535, 0.295), .littleTip: jp(0.535, 0.28),
        ]
        return LandmarkFrame(timestamp: 0, joints: joints, handedness: .right)
    }()

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
        let content = ConstellationRenderer(
            frame: MenuBarGlyph.fistFrame,
            lineWidth: 1.5,
            color: MenuBarGlyph.color(for: state),
            fitToJoints: true
        )
        .frame(width: 18, height: 18)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2  // retina-sharp glyph at menu bar size
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = MenuBarGlyph.isTemplate(for: state)
        return image
    }
}

/// SwiftUI presentation of the constellation glyph for the popover header, where (unlike the
/// menu bar label) SwiftUI CAN animate: this is where the `.fired` scale pulse actually plays.
struct MenuBarGlyphView: View {
    var state: GlyphState
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ConstellationRenderer(
            frame: MenuBarGlyph.fistFrame,
            lineWidth: 1.5,
            color: MenuBarGlyph.color(for: state),
            fitToJoints: true
        )
        .frame(width: size, height: size)
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
