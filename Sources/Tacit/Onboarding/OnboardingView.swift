import AppKit
import ApplicationServices
import SwiftUI
import TacitCore

/// Four-step first-launch onboarding (spec §3.7 / §7): camera → accessibility → learn the clutch →
/// first binding. Shown exactly once (`UserDefaults` key `onboardedDefaultsKey`), opened by
/// `TacitApp`'s `MenuBarLabel` via `openWindow(id: "onboarding")` on first launch — see that
/// view's doc comment for the launch-time mechanism. Every step is individually skippable (spec
/// §3.7: "each step skippable; app degrades gracefully").
///
/// Step transitions are the spec's asymmetric move (insertion trailing / removal leading) on
/// `TacitMotion.standardUI`, collapsing to a crossfade under Reduce Motion — driven by an explicit
/// `withAnimation` in `advance()` rather than a passive `.animation(value:)`, so the direction is
/// deliberate (always "forward") rather than whatever `AnyTransition` would infer from a bare
/// state diff.
struct OnboardingView: View {
    @ObservedObject var engine: TacitEngine
    @ObservedObject var store: MappingStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: OnboardingStep = .camera

    /// The one `UserDefaults` key gating whether this window is opened automatically at launch.
    /// Set `true` both when onboarding is actually finished (Step 4's buttons) AND when the window
    /// is dismissed any other way (`onDisappear` below) — per the brief: "set true when finished
    /// OR dismissed" — so closing the window via its titlebar button also counts as "done with
    /// onboarding," never reopening it uninvited on a later launch.
    static let onboardedDefaultsKey = "tacit.onboarded"

    private static let size = CGSize(width: 480, height: 520)

    var body: some View {
        ZStack {
            switch step {
            case .camera:
                CameraStepView(engine: engine, onAdvance: advance, onSkip: advance)
                    .transition(stepTransition)
            case .accessibility:
                AccessibilityStepView(onAdvance: advance, onSkip: advance)
                    .transition(stepTransition)
            case .clutch:
                ClutchStepView(engine: engine, onAdvance: advance, onSkip: advance)
                    .transition(stepTransition)
            case .firstBinding:
                FirstBindingStepView(store: store, onOpenLibrary: openLibraryAndFinish, onDone: finish)
                    .transition(stepTransition)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.background)
        .onDisappear {
            UserDefaults.standard.set(true, forKey: Self.onboardedDefaultsKey)
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        // Animate unconditionally (per code review fix): only `stepTransition`'s TYPE varies with
        // Reduce Motion (move vs. crossfade) — same precedent as `LibraryWindow.expand`/`collapse`
        // and this file's own `ClutchStepView` "Armed." text swap. Gating the animation itself
        // behind `.respecting` here would have made the Reduce Motion `.opacity` transition jump-cut
        // instead of actually crossfading, defeating the point of choosing that transition.
        withAnimation(TacitMotion.standardUI) {
            step = next
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.onboardedDefaultsKey)
        dismissWindow()
    }

    private func openLibraryAndFinish() {
        openWindow(id: "library")
        finish()
    }
}

/// The four steps, in fixed order — `rawValue` doubles as both `advance()`'s "next step" arithmetic
/// and the step-dots index below.
private enum OnboardingStep: Int, CaseIterable {
    case camera, accessibility, clutch, firstBinding
}

// MARK: - Shared chrome

/// Common layout for every step: a row of step-progress dots, a title, the step's own content, and
/// a bottom button row the step supplies itself (steps 1–3 are primary+secondary/"Skip"; step 4 is
/// two co-equal finishing actions — different enough that a fixed primary/secondary shape would be
/// the wrong abstraction).
private struct OnboardingStepChrome<Content: View, Buttons: View>: View {
    var title: String
    var stepIndex: Int
    var content: Content
    var buttons: Buttons

    init(
        title: String,
        stepIndex: Int,
        @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.title = title
        self.stepIndex = stepIndex
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(spacing: 20) {
            stepDots
                .padding(.top, 8)

            Text(title)
                .font(.title2.weight(.semibold))

            content
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                buttons
            }
        }
        .padding(28)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<OnboardingStep.allCases.count, id: \.self) { index in
                Circle()
                    .fill(index == stepIndex ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The "Skip" button shared by steps 1–3, plus a primary action button — factored out so every
/// step's button row reads the same way and answers to the same 44pt/keyboard floor via
/// `TacitButtonStyle`.
private struct PrimarySkipButtons: View {
    var primaryTitle: String
    var primaryAction: () -> Void
    var onSkip: () -> Void

    var body: some View {
        Button("Skip", action: onSkip)
            .buttonStyle(TacitButtonStyle())
        Button(primaryTitle, action: primaryAction)
            .buttonStyle(TacitButtonStyle())
            .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Step 1: Camera

/// Copy explains on-device processing (reusing the `Info.plist` promise verbatim); "Allow Camera"
/// triggers `engine.start()`, which is what actually shows the system permission prompt (via
/// `CaptureEngine.start()`); auto-advances the instant `engine.glyphState` leaves `.paused` — which
/// only happens once capture is genuinely running (see `TacitEngine.restingGlyphState()`), so a
/// denial (capture stays `.unavailable` → glyph stays `.paused`) never falsely advances. Checked
/// both on appear (permission already granted from an earlier session) and on every
/// `glyphState` change thereafter — no polling needed since `TacitEngine` is already `@Published`.
///
/// macOS never re-prompts once denied (code review fix): while `engine.isCameraUnavailable`, the
/// "Allow Camera" button — which would silently do nothing — is swapped for a one-line explanation
/// plus a button straight to System Settings' Camera privacy pane. "Skip" stays available either way.
private struct CameraStepView: View {
    @ObservedObject var engine: TacitEngine
    var onAdvance: () -> Void
    var onSkip: () -> Void

    var body: some View {
        OnboardingStepChrome(title: "Camera", stepIndex: 0) {
            VStack(spacing: 16) {
                Image(systemName: "camera")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text(
                    "Tacit reads hand gestures from your camera. Frames are processed on this Mac "
                        + "and never stored or sent anywhere."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                if engine.isCameraUnavailable {
                    Text("Camera access was denied. Open System Settings → Privacy & Security → Camera.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        } buttons: {
            PrimarySkipButtons(
                primaryTitle: engine.isCameraUnavailable ? "Open System Settings" : "Allow Camera",
                primaryAction: engine.isCameraUnavailable ? openSystemSettings : { engine.start() },
                onSkip: onSkip
            )
        }
        .onAppear { checkAdvance() }
        .onChange(of: engine.glyphState) { _, _ in checkAdvance() }
    }

    private func checkAdvance() {
        guard engine.glyphState != .paused else { return }
        onAdvance()
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Step 2: Accessibility

/// Copy explains this powers keystroke actions only; "Grant Access" calls
/// `AXIsProcessTrustedWithOptions` with the prompt option (spec §7); skippable, with the plain
/// consequence always visible (not just after tapping Skip) so the choice is informed either way.
/// Auto-advances once `AXIsProcessTrusted()` flips true — polled every second (per brief: "UI-layer
/// polling is fine") since the OS gives no publisher for this.
private struct AccessibilityStepView: View {
    var onAdvance: () -> Void
    var onSkip: () -> Void

    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        OnboardingStepChrome(title: "Accessibility", stepIndex: 1) {
            VStack(spacing: 16) {
                Image(systemName: "keyboard")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("Accessibility access lets Tacit send the keystrokes behind your bound gestures — nothing else.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Keystroke actions stay off until granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            PrimarySkipButtons(primaryTitle: "Grant Access", primaryAction: requestAccess, onSkip: onSkip)
        }
        .onAppear { startPolling() }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func requestAccess() {
        AccessibilityPermission.requestPromptIfNeeded()
    }

    private func startPolling() {
        if AXIsProcessTrusted() {
            onAdvance()
            return
        }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    onAdvance()
                    return
                }
            }
        }
    }
}

// MARK: - Step 3: Learn the clutch

/// Reuses `PerformToPreviewStrip` (extracted from `CardDetailView`, Task 20) with the `looseFist`
/// catalog entry — the exact same live-tracking/paused/out-of-frame-guidance component the Library
/// uses, rather than a second implementation. The FIRST time `engine.glyphState` becomes `.armed`
/// while this step is visible, plays the signature moment (spec §4: one of exactly two places the
/// `signature` motion budget is spent) — a loose-fist constellation draw-on plus an accent bloom —
/// then a beat, then auto-advances. Reduce Motion collapses the whole moment to a fade plus the
/// literal word "Armed."
private struct ClutchStepView: View {
    @ObservedObject var engine: TacitEngine
    var onAdvance: () -> Void
    var onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasArmed = false
    /// The constellation+bloom container's own opacity — this is what actually "reveals" the
    /// signature moment, and (per the same always-animate-opacity convention `HUDController` uses
    /// for its enter/dismiss) is animated on `TacitMotion.signature` REGARDLESS of Reduce Motion.
    /// `drawProgress`/`bloomOpacity` are the decorative pieces layered on top of that reveal, and
    /// are the ones actually suppressed under Reduce Motion.
    @State private var revealOpacity: Double = 0
    @State private var drawProgress: Double = 0
    @State private var bloomOpacity: Double = 0

    private static let clutchEntry = GestureCatalog.entry(for: .looseFist)

    var body: some View {
        OnboardingStepChrome(title: "Learn the Clutch", stepIndex: 2) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(TacitColors.accent.opacity(0.35))
                        .frame(width: 140, height: 140)
                        .opacity(bloomOpacity)
                        .blur(radius: 14)

                    ConstellationRenderer(
                        frame: Self.clutchEntry.cannedFrame,
                        lineWidth: 1.5,
                        color: TacitColors.accent,
                        drawProgress: drawProgress,
                        fitToJoints: true
                    )
                    .frame(width: 140, height: 140)
                }
                .frame(height: 150)
                .opacity(revealOpacity)

                Group {
                    if hasArmed {
                        Text("Armed.")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(TacitColors.accent)
                    } else {
                        Text("Rest your forearm. Make a loose fist and hold.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                // Not gated by `.respecting`: per spec §4's own Reduce Motion column for this row
                // ("fade + 'Armed.' text"), the text swap is itself the reduced-motion stand-in for
                // the signature moment, so its opacity crossfade — unlike `drawProgress`/
                // `bloomOpacity` above — keeps animating even with Reduce Motion on.
                .animation(TacitMotion.standardUI, value: hasArmed)

                PerformToPreviewStrip(entry: Self.clutchEntry, engine: engine)
            }
        } buttons: {
            // No separate primary button here (unlike steps 1–2): this step's "primary action"
            // is performing the gesture itself, not clicking anything — arming auto-advances on
            // its own (`playSignature()`). "Skip" is the only button, matching the brief's "each
            // step skippable" without inventing a second control that would just duplicate it.
            Button("Skip", action: onSkip)
                .buttonStyle(TacitButtonStyle())
        }
        .onAppear {
            // Symmetric with Steps 1 and 2's own on-appear checks (permission/state already
            // satisfied before the step is even seen): if the clutch is already `.armed` by the
            // time this step mounts (e.g. the user re-armed it while lingering on an earlier step,
            // or capture state settles before SwiftUI finishes mounting), the ONLY other trigger —
            // `onChange`, which fires on a TRANSITION — would never fire, silently stalling the
            // step until the window is closed some other way.
            guard engine.glyphState == .armed, !hasArmed else { return }
            playSignature()
        }
        .onChange(of: engine.glyphState) { _, newValue in
            guard newValue == .armed, !hasArmed else { return }
            playSignature()
        }
    }

    /// The signature moment (spec §4 motion table, "Onboarding clutch success" row): constellation
    /// draw-on (`drawProgress` 0→1) + accent bloom, `TacitMotion.signature` (450 ms spring).
    ///
    /// Mirrors `HUDController.enterFresh`'s Reduce Motion convention: the animation TOKEN never
    /// changes, only which state deltas are non-zero going into it. `drawProgress`/`bloomOpacity`
    /// are pre-set to their Reduce Motion targets (full stroke already drawn, no bloom) BEFORE the
    /// animated block, so they carry no delta to animate; `revealOpacity` always has a real 0→1
    /// delta, so it's the one thing that keeps animating under Reduce Motion — landing exactly on
    /// spec's "fade + 'Armed.' text" for this row.
    private func playSignature() {
        hasArmed = true
        drawProgress = reduceMotion ? 1 : 0
        bloomOpacity = 0

        withAnimation(TacitMotion.signature) {
            revealOpacity = 1
            if !reduceMotion {
                drawProgress = 1
                bloomOpacity = 1
            }
        }

        Task {
            try? await Task.sleep(for: TacitMotion.onboardingClutchAdvanceDelay)
            onAdvance()
        }
    }
}

// MARK: - Step 4: First binding

/// Compact list of the enabled starter defaults, read live from `MappingStore`/`GestureCatalog` —
/// never hardcoded copy, so a future change to the defaults (or a user who rebinds one before ever
/// seeing this screen) is reflected accurately. "Open the Library" opens the Library window AND
/// finishes onboarding; "Done" just finishes.
private struct FirstBindingStepView: View {
    @ObservedObject var store: MappingStore
    var onOpenLibrary: () -> Void
    var onDone: () -> Void

    var body: some View {
        OnboardingStepChrome(title: "Your First Bindings", stepIndex: 3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("These gestures are ready to use right away.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                ForEach(starterEntries, id: \.id) { entry in
                    HStack(spacing: 12) {
                        ConstellationRenderer(
                            frame: entry.cannedFrame,
                            lineWidth: 1.2,
                            color: .primary,
                            fitToJoints: true
                        )
                        .frame(width: 32, height: 32)

                        Text(rowText(for: entry))
                            .font(.callout)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                }
            }
        } buttons: {
            Button("Done", action: onDone)
                .buttonStyle(TacitButtonStyle())
            Button("Open the Library", action: onOpenLibrary)
                .buttonStyle(TacitButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The six enabled starter defaults (spec §3.6), in catalog order — read live from `store`
    /// rather than assumed, so this list can never drift from what's actually bound.
    private var starterEntries: [CatalogEntry] {
        GestureCatalog.entries.filter { !$0.isReserved && store.binding(for: $0.id).enabled }
    }

    /// "Thumb–Index Tap fires ⌘C" — plain-verb, built from live `TacitAction.summary`.
    private func rowText(for entry: CatalogEntry) -> String {
        guard let action = store.binding(for: entry.id).action else { return entry.displayName }
        return "\(entry.displayName) fires \(action.summary)"
    }
}
