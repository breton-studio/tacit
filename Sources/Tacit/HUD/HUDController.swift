import AppKit
import SwiftUI
import TacitCore

/// What the HUD is currently showing: a fired gesture (constellation + "<name> → <action>" line),
/// or an error (message only, no constellation — spec §4's HUD table + brief's error variant).
enum HUDContent {
    case gesture(displayName: String, actionSummary: String, frame: LandmarkFrame)
    case error(message: String)
}

/// The HUD's animatable state, observed by `HUDView`. `HUDController` is the only writer; every
/// write goes through an explicit `withAnimation(TacitMotion.…)` (or an instant assignment for
/// Reduce Motion) so the exact spec §4 values land on the exact spec §4 tokens.
@MainActor
final class HUDState: ObservableObject {
    @Published fileprivate(set) var content: HUDContent = .gesture(displayName: "", actionSummary: "", frame: .empty)
    @Published fileprivate(set) var opacity: Double = 0
    @Published fileprivate(set) var scale: CGFloat = 0.97
    @Published fileprivate(set) var translateY: CGFloat = 6
    @Published fileprivate(set) var drawProgress: Double = 0
}

private extension LandmarkFrame {
    static let empty = LandmarkFrame(timestamp: 0, joints: [:], handedness: .unknown)
}

/// Orchestrates the quiet, auto-dismissing confirmation panel that appears when a gesture fires
/// (spec §4 motion table's four HUD rows, binding). One `NSPanel` instance is created lazily and
/// reused for the app's lifetime — never destroyed/recreated per `show()` — so retargeting a
/// visible HUD never produces an overlapping second panel.
///
/// Not wired into `TacitEngine` yet (Task 21 does that); this task only builds the panel + view
/// and a DEBUG-only manual test hook in the popover.
@MainActor
final class HUDController {
    /// The visible chip's fixed size, deliberately — this is "system-volume-HUD territory"
    /// (brief): a small constant-size floating panel, not something that reflows to fit arbitrary
    /// copy. The error variant reuses the exact same surface per brief ("same surface, message
    /// only"). Must match `HUDView.chipSize`.
    private static let chipSize = HUDView.chipSize
    /// Extra margin around the chip in the actual `NSPanel`/`NSHostingView` canvas: `HUDView`'s
    /// soft shadow needs room to bleed past the chip's edges, and an `NSHostingView` clips its
    /// SwiftUI content to its own bounds — so the panel is sized larger than the chip, which is
    /// then centered inside it (see `ensurePanel`), rather than sized to exactly hug the chip.
    private static let shadowMargin: CGFloat = 40
    private static let panelSize = NSSize(
        width: chipSize.width + shadowMargin * 2,
        height: chipSize.height + shadowMargin * 2
    )
    /// How far the visible chip's bottom edge sits above the main screen's bottom edge.
    private static let bottomInset: CGFloat = 140

    let state = HUDState()

    private var panel: NSPanel?
    private var dwellTask: Task<Void, Never>?
    /// True once the panel has been ordered front and not yet actually ordered out — covers
    /// "entering", "resting/dwelling", AND "mid-out-animation" (the panel is still on screen with
    /// partial opacity). A `show()`/`showError()` arriving during any of those must retarget in
    /// place, never tear down and re-enter from scratch.
    private var isPanelOnScreen = false
    /// Identifies the most recent `present()` call. A dismiss's completion only actually orders
    /// the panel out if it's still current — otherwise a retarget arrived while the out-animation
    /// was in flight and superseded it.
    private var currentToken = UUID()

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shows (or retargets) the HUD for a fired gesture. `frame` is the live event's landmark
    /// data if the caller has it; `nil` falls back to that gesture's own canned frame (the same
    /// `CannedFrames` single source the specimen-book cards use), so the HUD shows the fired
    /// gesture's actual pose even without a live frame, rather than a generic fist.
    func show(gesture: GestureID, actionSummary: String, frame: LandmarkFrame?) {
        let entry = GestureCatalog.entry(for: gesture)
        present(
            .gesture(
                displayName: entry.displayName,
                actionSummary: actionSummary,
                frame: frame ?? entry.cannedFrame
            )
        )
    }

    /// Shows (or retargets) the HUD's error variant: same surface, message only, no constellation.
    func showError(_ message: String) {
        present(.error(message: message))
    }

    // MARK: - Presentation

    private func present(_ content: HUDContent) {
        ensurePanel()
        dwellTask?.cancel()
        currentToken = UUID()
        let token = currentToken

        state.content = content
        positionPanel()  // recomputed on every show, per brief — the main screen may have changed

        if isPanelOnScreen {
            retarget()
        } else {
            panel?.orderFrontRegardless()
            isPanelOnScreen = true
            enterFresh()
        }

        scheduleDismiss(token: token)
    }

    /// First appearance from fully hidden: opacity 0→1, scale 0.97→1, translateY 6→0 on `hudIn`,
    /// concurrent with the constellation's wrist-outward draw-on on `hudConstellationDrawOn`.
    ///
    /// Reduce Motion (spec §4: "opacity fade only, full stroke immediately"): the fade itself
    /// still plays — only opacity is a real semantic-content change here, everything else is
    /// decorative movement — so `scale`/`translateY`'s PRE-animation values are set to their
    /// already-final targets (no delta for `withAnimation` to animate), and `drawProgress` jumps
    /// straight to 1 outside any animation block, before the panel is even shown.
    private func enterFresh() {
        state.opacity = 0
        state.scale = reduceMotion ? 1 : 0.97
        state.translateY = reduceMotion ? 0 : 6
        state.drawProgress = reduceMotion ? 1 : 0

        withAnimation(TacitMotion.hudIn) {
            state.opacity = 1
            state.scale = 1
            state.translateY = 0
        }
        if !reduceMotion {
            withAnimation(TacitMotion.hudConstellationDrawOn) {
                state.drawProgress = 1
            }
        }
    }

    /// Already on screen (dwelling, or mid-out-animation): animate back to the fully-shown rest
    /// state in place via `hudIn` — an interruptible, value-driven spring, so a HUD fading out
    /// smoothly reverses rather than snapping through zero opacity. Content is already swapped by
    /// `present()`; the constellation is already fully drawn (no re-draw-on for a retarget,
    /// regardless of Reduce Motion).
    private func retarget() {
        state.drawProgress = 1

        withAnimation(TacitMotion.hudIn) {
            state.opacity = 1
            // Under Reduce Motion these are already at 1/0 (dismiss's reduce-motion path never
            // moves them), so this is a no-op delta — only opacity's fade actually animates.
            state.scale = 1
            state.translateY = 0
        }
    }

    private func scheduleDismiss(token: UUID) {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TacitMotion.hudDwell))
            guard let self, !Task.isCancelled, self.currentToken == token else { return }
            self.dismiss(token: token)
        }
    }

    /// HUD out: opacity 1→0, scale →0.98 on `hudOut`, in place (no translateY). Reduce Motion
    /// (spec §4: "opacity fade"): the fade still plays on `hudOut`; only the scale shrink is
    /// suppressed (target stays 1, i.e. no delta to animate).
    private func dismiss(token: UUID) {
        guard let panel else { return }

        withAnimation(TacitMotion.hudOut, completionCriteria: .logicallyComplete) {
            state.opacity = 0
            state.scale = reduceMotion ? 1 : 0.98
        } completion: { [weak self] in
            guard let self, self.currentToken == token else { return }  // superseded by a retarget
            self.isPanelOnScreen = false
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        // `HUDPanelCanvas` centers the fixed-size chip within the full (larger) panel canvas —
        // see `shadowMargin`'s doc comment — so the chip's shadow isn't clipped at the edges.
        let hostingView = NSHostingView(rootView: HUDPanelCanvas(state: state))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the SwiftUI surface (HUDView) carries its own shadow.
        panel.contentView = hostingView

        self.panel = panel
    }

    /// The visible chip centered horizontally, its bottom edge `bottomInset` pt above the main
    /// screen's bottom edge — recomputed on every `show()`/`showError()` for whichever screen is
    /// currently main. The panel itself is `shadowMargin` pt bigger than the chip on every side
    /// (see that constant's doc comment), so its origin is offset inward by that margin.
    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let origin = NSPoint(
            x: screenFrame.midX - Self.panelSize.width / 2,
            y: screenFrame.minY + Self.bottomInset - Self.shadowMargin
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }
}

/// Centers the fixed-size chip within the panel's full (larger) canvas so `HUDView`'s shadow has
/// room to render past the chip's edges without the `NSHostingView`'s bounds clipping it.
private struct HUDPanelCanvas: View {
    @ObservedObject var state: HUDState

    var body: some View {
        ZStack {
            Color.clear
            HUDView(state: state)
        }
    }
}
