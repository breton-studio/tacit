import AppKit
import SwiftUI
import TacitCore

/// Observable state driving `GestureDebugView` — mirrors the `HUDController`/`HUDState` split:
/// `GestureDebugPanelController` is the only writer, the SwiftUI view only ever reads.
@MainActor
final class GestureDebugState: ObservableObject {
    @Published fileprivate(set) var snapshot: GestureDebugSnapshot?
}

/// Owns the floating picture-in-picture panel showing Tacit's live gesture reading — the debugging
/// feature requested after a clutch that flickered `arming → disarmed` ten times before arming,
/// then misfired on gestures the user never meant to make. Toggled from the popover
/// ("Show gesture debug view", `TacitEngine.isDebugViewEnabled`); wired up in `TacitEngine.init`
/// exactly like `hudController` is constructed there — one instance, owned by the engine, driven
/// by its published state.
///
/// One `NSPanel`, created lazily on first show and reused for the app's lifetime (never destroyed/
/// recreated) — like `HUDController`'s panel, except here VISIBILITY itself is what toggles, not a
/// per-fire dwell/dismiss. Non-activating (never steals focus or the frontmost app) but, unlike the
/// HUD, user-draggable (`isMovableByWindowBackground`) and persists across every Space and
/// full-screen app (`collectionBehavior`) — the whole point is to leave it up on screen while the
/// user works elsewhere and tunes their hand/camera against it.
@MainActor
final class GestureDebugPanelController: NSObject {
    let state = GestureDebugState()
    weak var engine: TacitEngine?
    // Supplied by the scene-backed menu bar label; this panel has no SwiftUI scene environment.
    var openWindow: ((String) -> Void)?

    private static let panelSize = NSSize(width: 260, height: 320)
    private static let screenMargin: CGFloat = 16
    private static let frameDefaultsKey = "tacit.debugViewFrame"

    private var panel: NSPanel?

    /// Called by `TacitEngine` on every `debugSnapshot` change (see the `$debugSnapshot` sink wired
    /// in `TacitEngine.init`) — a plain `@Published` value write, cheap regardless of whether the
    /// panel is currently visible; SwiftUI only actually re-renders while the panel's
    /// `NSHostingView` is on screen.
    func update(_ snapshot: GestureDebugSnapshot?) {
        state.snapshot = snapshot
    }

    /// Shows or hides the panel, creating it (and positioning it) on first show. Hiding never
    /// destroys the panel — its frame (and so the user's chosen position/size) survives being
    /// toggled off and back on, exactly like a normal window.
    func setVisible(_ visible: Bool) {
        if visible {
            ensurePanel()
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hostingView = GestureDebugHostingView(rootView: GestureDebugView(state: state))
        hostingView.makeContextMenu = { [weak self] in self?.makeContextMenu() }
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.delegate = self

        applyPersistedOrInitialFrame(to: panel)

        self.panel = panel
    }

    /// Restores a previously-persisted frame (`tacit.debugViewFrame`, written by
    /// `windowDidMove`/`windowDidResize` below) if one exists and is non-degenerate; otherwise
    /// positions the panel bottom-right of the main screen, 16pt margins on both edges, per spec.
    private func applyPersistedOrInitialFrame(to panel: NSPanel) {
        if let stored = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let frame = NSRectFromString(stored)
            if frame.width >= 100, frame.height >= 100 {
                panel.setFrame(frame, display: false)
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.maxX - Self.panelSize.width - Self.screenMargin,
            y: screenFrame.minY + Self.screenMargin
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }

    private func persistFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Open Library…", action: #selector(showLibrary))
        add("Calibrate Camera…", action: #selector(showCalibration))
        menu.addItem(.separator())
        let paused = engine?.isEnabled == false || engine?.userPauseEndsAt != nil
        add(paused ? "Resume Gestures" : "Pause Gestures for an Hour", action: #selector(togglePause))
        add("Hide Gesture Preview", action: #selector(hidePreview))
        menu.addItem(.separator())
        add("Quit Tacit", action: #selector(quit))
        return menu
    }

    @objc private func showLibrary() {
        openWindow?("library")
        WindowActivator.bringToFront(id: "library", title: "Tacit Library")
    }

    @objc private func showCalibration() {
        openWindow?("keyboard-calibration")
        WindowActivator.bringToFront(id: "keyboard-calibration", title: "Keyboard Gesture Calibration")
    }

    @objc private func togglePause() {
        guard let engine else { return }
        if !engine.isEnabled {
            engine.isEnabled = true
        } else if engine.userPauseEndsAt != nil {
            engine.resumeFromUserPause()
        } else {
            engine.pause(for: 3600)
        }
    }

    @objc private func hidePreview() { engine?.isDebugViewEnabled = false }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Keep the floating panel draggable while accepting right-clicks across its entire surface.
private final class GestureDebugHostingView: NSHostingView<GestureDebugView> {
    var makeContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

extension GestureDebugPanelController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidResize(_ notification: Notification) { persistFrame() }
}

/// The debug panel's SwiftUI surface. Same materials as `HUDView.surface` (spec §4.4: weightless,
/// system material, hairline border, near-monochrome) — the ONE accent use is the "Armed" clutch
/// line, matching spec §4's "one accent only for armed/active state." System font throughout,
/// tabular numerals (`.monospacedDigit()`) on every changing number so the rows don't jitter in
/// width frame to frame.
struct GestureDebugView: View {
    @ObservedObject var state: GestureDebugState

    private let cornerRadius: CGFloat = 14
    private let constellationSize: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            constellation
            Divider().opacity(0.45)
            readingRow
            clutchRow
            lastFiredRow
            statusRow
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 260, height: 320, alignment: .top)
        .background(surface)
        .animation(TacitMotion.standardUI, value: state.snapshot)
    }

    @ViewBuilder
    private var constellation: some View {
        ZStack {
            if let frame = state.snapshot?.frame, state.snapshot?.handDetected == true {
                ConstellationRenderer(frame: frame, lineWidth: 1.5, color: .primary, fitToJoints: true)
            } else {
                Text("No hand")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: constellationSize)
    }

    private var readingRow: some View {
        row(label: "Reading") {
            HStack(spacing: 4) {
                Text(readingName)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(readingConfidence)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readingName: String {
        guard let candidate = state.snapshot?.staticCandidate else { return "—" }
        return GestureCatalog.entry(for: candidate.gesture).displayName
    }

    private var readingConfidence: String {
        guard let candidate = state.snapshot?.staticCandidate else { return "—" }
        return String(format: "%.2f", candidate.confidence)
    }

    private var clutchRow: some View {
        row(label: "Clutch") {
            HStack(spacing: 4) {
                Text(clutchText)
                    .monospacedDigit()
                    .foregroundStyle(isArmed ? TacitColors.accent : .primary)
                Spacer(minLength: 0)
            }
        }
    }

    private var isArmed: Bool {
        // Clutch-optional setting: while `requiresClutch` is `false`, arbitration is ALWAYS
        // `.armed` — so this must NOT read as "armed" for accent-coloring purposes here, or the
        // "Off" text below would be accent-highlighted for no reason (nothing is currently armed
        // in any meaningful sense; the clutch is simply turned off as a setting).
        guard state.snapshot?.requiresClutch == true else { return false }
        guard case .armed = state.snapshot?.arbitration else { return false }
        return true
    }

    private var clutchText: String {
        guard let snapshot = state.snapshot else { return "—" }
        guard snapshot.requiresClutch else { return "Off" }
        switch snapshot.arbitration {
        case .disarmed:
            return "Disarmed"
        case .arming(let progress):
            return "Arming \(progressBar(progress)) \(String(format: "%.2f", progress))"
        case .armed(let windowEndsAt):
            let remaining = max(0, windowEndsAt - snapshot.timestamp)
            return "Armed · \(String(format: "%.1f", remaining))s left"
        }
    }

    /// A plain 4-segment text bar (`▮▮▮░`) — no imagery, no extra color, just filled-vs-empty
    /// glyphs at the caller's chosen text color (never the accent by itself; `clutchRow` applies
    /// the accent to the whole line only while `.armed`).
    private func progressBar(_ progress: Double) -> String {
        let segments = 4
        let filled = min(segments, max(0, Int((progress * Double(segments)).rounded())))
        return String(repeating: "▮", count: filled) + String(repeating: "░", count: segments - filled)
    }

    private var lastFiredRow: some View {
        row(label: "Last fired") {
            Text(lastFiredText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var lastFiredText: String {
        guard let snapshot = state.snapshot,
              let gesture = snapshot.lastFired,
              let firedAt = snapshot.lastFiredAt
        else { return "—" }
        let name = GestureCatalog.entry(for: gesture).displayName
        let secondsAgo = max(0, snapshot.timestamp - firedAt)
        return "\(name) · \(String(format: "%.1f", secondsAgo))s ago"
    }

    /// Low light / Accessibility status: shown only when actually problematic (spec: "only when
    /// problematic") — a clean session shows neither line at all, not a reassuring "OK" state.
    @ViewBuilder
    private var statusRow: some View {
        if let snapshot = state.snapshot, snapshot.isLowLight || !snapshot.isAccessibilityTrusted {
            VStack(alignment: .leading, spacing: 2) {
                if snapshot.isLowLight {
                    statusLine(icon: "moon", text: "Low light")
                }
                if !snapshot.isAccessibilityTrusted {
                    statusLine(icon: "lock", text: "Accessibility not trusted")
                }
            }
        }
    }

    private func statusLine(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func row(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .font(.callout)
        }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}
