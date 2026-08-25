import SwiftUI
import TacitCore

/// The specimen card, grown (spec §5's "Card detail... expands from the card, context preserved,
/// no navigation push"). Shares `SpecimenCard`'s chrome and copy helpers so the same object reads
/// as itself at a larger size, not a different screen: same corner radius, same material fill,
/// same constellation (crossfaded, larger — see the hero postmortem in `SpecimenCard`'s body for
/// why this is no longer a `matchedGeometryEffect` morph), same metadata/binding copy — plus the
/// editorial paragraph, the action binder, and the perform-to-preview mount point.
///
/// 2026-08-24 Library detail sheet fix: this view is centered by its caller
/// (`LibraryWindow.detailOverlay`) rather than by traveling from the grid card's position, and
/// enters/exits with a plain scale+fade (`TacitMotion.standardUI` in, `hudOut` out — exits faster
/// than entrances per spec §4). See `LibraryWindow.swift` for why: a persistent `matchedGeometryEffect`
/// pairing with the always-mounted grid card pinned this view to the small card's frame instead of
/// animating out to its own size — "prefer reliability over cleverness" per the design-eng lens.
struct CardDetailView: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore
    // `@ObservedObject`, not a plain `var`: Task 19's perform-to-preview needs this view to
    // re-render on `engine.previewCandidate` (lights the constellation below) and `engine.glyphState`
    // (the strip's paused affordance) changes.
    @ObservedObject var engine: TacitEngine
    var onDone: () -> Void
    /// The tallest this card is allowed to get — `LibraryWindow.detailOverlay` passes
    /// `window height − 96` so the card never collides with the window's edges regardless of how
    /// tall the window is resized to; content beyond this scrolls (the outer `ScrollView` below).
    /// Defaults to a sane value for previews/tests that don't go through that overlay.
    var maxHeight: CGFloat = 560

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Task 7: whether the Try-It session overlay is showing. Set only via `startTryIt()`/
    /// `dismissTryIt()` below so every transition into/out of it plays the deliberate
    /// entrance/exit pair those two methods wrap it in (spec §4 binding: exits faster than
    /// entrances).
    @State private var isTryItActive = false

    /// 2026-08-24 fix ("choosing Switch App and clicking Done kept the old binding"): which Action
    /// Type segment `ActionBinderView` is currently showing, lifted here (rather than kept as that
    /// view's own private state) so `handleDone()` below can flush a no-further-input kind
    /// (`.switchApp`/`.focusTextInput`) that somehow never committed — belt-and-braces on top of
    /// those binders' own onAppear-commit fix in `ActionBinders.swift`. Initialized in `init` below
    /// from the entry's CURRENT binding, exactly as `ActionBinderView`'s own `@State` used to be.
    @State private var selectedActionKind: ActionKind

    private static let cornerRadius: CGFloat = 20
    private static let width: CGFloat = 520

    init(
        entry: CatalogEntry,
        store: MappingStore,
        engine: TacitEngine,
        onDone: @escaping () -> Void,
        maxHeight: CGFloat = 560
    ) {
        self.entry = entry
        self.store = store
        self.engine = engine
        self.onDone = onDone
        self.maxHeight = maxHeight
        _selectedActionKind = State(initialValue: ActionKind(matching: store.binding(for: entry.id).action))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Task 6: the hero always loops its preview (Ruling 4 — "Detail hero loops
                // always"). Until Task 8's assets exist, `GesturePreviewView` falls back to
                // exactly the `ConstellationRenderer` this replaced, including the
                // previewCandidate accent-lighting behavior below, so the fallback path (verified
                // by NOT bundling assets yet) renders identically to before this type existed.
                //
                ZStack {
                    // `constellationColor` preserves the exact previewCandidate accent-lighting
                    // behavior this replaced (only reachable today via the constellation
                    // fallback, since no `.mov`/`.png` assets are bundled yet — Task 8).
                    GesturePreviewView(
                        entry: entry,
                        mode: .loop,
                        constellationColor: isPreviewMatched ? TacitColors.accent : .primary,
                        // Finding 3 (M4 fix wave): the Try-It overlay mounts its own copy of this
                        // same `.loop` preview; without this the hero keeps decoding underneath it
                        // for the whole session, for no visible benefit (it's fully covered by the
                        // overlay's `regularMaterial`). Pausing rather than unmounting means
                        // resuming on dismiss doesn't flash back to the poster.
                        isSuspended: isTryItActive
                    )
                    .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: isPreviewMatched)
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.displayName)
                        .font(.title2.weight(.semibold))

                    metadataBlock

                    bindingLine
                }

                if !entry.isReserved {
                    Toggle("Enabled", isOn: enabledBinding)
                        .toggleStyle(TacitToggleStyle())
                        .disabled(store.binding(for: entry.id).action == nil)
                }

                Text(entry.editorial)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.5)

                actionBinderSection

                performToPreviewSection

                doneButton
            }
            .padding(20)
        }
        .frame(width: Self.width)
        .frame(minHeight: 320, maxHeight: maxHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        // Task 7: the Try-It session overlay, layered ABOVE the scroll content but placed before
        // `.clipShape` below so it's clipped to the exact same rounded rect as the card itself —
        // "inside the expanded card" per the brief, not a separate floating panel. Content behind
        // it (including `performToPreviewSection`'s `PerformToPreviewStrip`) stays mounted the
        // whole time — see `PerformToPreviewStrip`'s doc comment for why that matters.
        .overlay {
            if isTryItActive {
                TryItSessionOverlay(entry: entry, engine: engine, onDismiss: dismissTryIt)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
    }

    /// Shows the Try-It overlay (spec §4 binding: entrances play `TacitMotion.standardUI`).
    private func startTryIt() {
        withAnimation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI)) {
            isTryItActive = true
        }
    }

    /// Every dismissal path — Esc, click-outside, and the overlay's own post-verdict auto-close —
    /// routes through this one method, so every exit plays the SAME quicker animation (spec §4
    /// binding: "exits faster than entrances" — `hudOut`'s 0.16s easeOut vs. `standardUI`'s 0.25s
    /// spring above).
    private func dismissTryIt() {
        withAnimation(TacitMotion.respecting(reduceMotion, TacitMotion.hudOut)) {
            isTryItActive = false
        }
    }

    // MARK: - Action binder (Task 18)

    /// The action binder (spec §5: "keystroke recorder, app picker, URL field with
    /// validation, Shortcut picker"; M3 Task 10 added a fifth segment, focus-input) —
    /// `ActionBinderView` in `ActionBinders.swift`. Hidden
    /// entirely for reserved entries: `looseFist`/`openPalm` are never user-bindable
    /// (`MappingStore.setBinding` no-ops for them too), and `bindingLine` above already shows
    /// their reserved copy ("Reserved — arms Tacit" / "Reserved — disarms"), so this section would
    /// have nothing truthful to offer.
    @ViewBuilder
    private var actionBinderSection: some View {
        if !entry.isReserved {
            VStack(alignment: .leading, spacing: 8) {
                Text("Action")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                ActionBinderView(entry: entry, store: store, selectedKind: $selectedActionKind)
            }
        }
    }

    // MARK: - Perform-to-preview (Task 19)

    /// A live camera strip + skeleton overlay driven by `engine.latestFrame`, lighting the LARGE
    /// constellation above when the user actually performs this gesture (spec §5: "teaching and
    /// testing in one move") — Cooper's collapse of thinking and making: you learn a gesture by
    /// doing it, with instant feedback.
    private var performToPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            PerformToPreviewStrip(entry: entry, engine: engine)

            // Task 7 fix round (Medium finding): `.palmPush`/`.wave`/`.twoHandFrame` have no
            // detector anywhere in `TacitCore` (production or preview) — a Try-It session for one
            // of them would always time out no matter how well the user performs it, reading as
            // user error rather than a missing feature. Show honest, quiet copy instead of a
            // button that can never succeed; the strip above still just never lights for these,
            // same as before.
            if entry.isDetectorBacked {
                // The timed, verdict-bearing session — distinct from the strip above, which just
                // ambiently lights up while the card is open. Hidden while the overlay is already
                // showing rather than merely disabled, since a disabled full-width row would
                // otherwise sit uselessly behind the overlay it triggers.
                if !isTryItActive {
                    Button("Try It", action: startTryIt)
                        .buttonStyle(TacitButtonStyle())
                }
            } else {
                Text("Recognition for this gesture is still in the works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Whether the currently-performed gesture (arbitration-bypassing, live) matches this card's
    /// own `entry.id` — the "lights up" condition for the large constellation above.
    private var isPreviewMatched: Bool {
        engine.previewCandidate?.gesture == entry.id
    }

    // MARK: - Rows

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(SpecimenCopy.kindLabel(for: entry))
            Text(SpecimenCopy.ergonomicsLine(for: entry))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var bindingLine: some View {
        if entry.isReserved {
            Text(SpecimenCopy.reservedCopy(for: entry.id))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let summary = store.binding(for: entry.id).configuredActionSummary {
            Text(summary)
                .font(.callout)
        } else {
            Text("Choose an action below before enabling this gesture.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var doneButton: some View {
        Button("Done", action: handleDone)
            .buttonStyle(TacitButtonStyle())
            .keyboardShortcut(.defaultAction)
    }

    /// 2026-08-24 fix: belt-and-braces on top of `SwitchAppBinder`/`FocusTextInputBinder`'s own
    /// onAppear-commit fix (`ActionBinders.swift`) — flushes a no-further-input Type selection that
    /// somehow never made it into `store` before collapsing the card, so Done can never silently
    /// drop a remap. `.switchApp` falls back to `.next` here (this path should only ever be a
    /// no-op; the binder's own onAppear is what actually knows the currently-displayed direction).
    private func handleDone() {
        flushPendingActionTypeIfNeeded()
        onDone()
    }

    private func flushPendingActionTypeIfNeeded() {
        guard !entry.isReserved else { return }
        switch selectedActionKind {
        case .switchApp:
            guard case .switchApp = store.binding(for: entry.id).action else {
                store.setBinding(GestureBinding(enabled: true, action: .switchApp(.next)), for: entry.id)
                return
            }
        case .focusTextInput:
            guard case .focusTextInput = store.binding(for: entry.id).action else {
                store.setBinding(GestureBinding(enabled: true, action: .focusTextInput), for: entry.id)
                return
            }
        case .keystroke, .launchApp, .openURL, .runShortcut:
            break
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.binding(for: entry.id).enabled },
            set: { newValue in
                guard case .update(let updated) = store.binding(for: entry.id).enableRequest(newValue) else {
                    return
                }
                store.setBinding(updated, for: entry.id)
            }
        )
    }
}

/// Task 19's live constellation strip: a fixed-height, quiet region that tracks the user's hand in
/// real time (`engine.latestFrame`) while this card's detail is open. `engine.isPreviewActive` is
/// flipped on the instant this strip mounts and off the instant it unmounts (which also happens
/// when the card detail itself closes, since `LibraryWindow.detailOverlay` tears the whole
/// `CardDetailView` down along with it) — see `TacitEngine.isPreviewActive`'s doc comment for what
/// that toggles pipeline-side.
///
/// Not `private` (Task 20): `OnboardingView`'s "Learn the Clutch" step reuses this exact view —
/// passing `GestureCatalog.entry(for: .looseFist)` as `entry` — rather than duplicating the strip's
/// live-tracking/paused/out-of-frame-guidance logic for a second call site.
///
/// Deliberately a thin wrapper around `LiveGestureStrip` (Task 7) rather than owning the rendering
/// itself: this is the ONE view allowed to touch `engine.isPreviewActive`, so any second on-screen
/// copy of the live strip — Task 7's `TryItSessionOverlay` shows one side-by-side with the preview
/// loop — has to go through `LiveGestureStrip` directly instead of a second `PerformToPreviewStrip`.
/// Two independently-mounted `PerformToPreviewStrip`s would each flip the SAME shared flag on their
/// own appear/disappear; whichever one unmounts first (e.g. the Try-It overlay closing while this
/// section is still on screen behind it) would wrongly turn preview mode off out from under the
/// other, silently killing `engine.previewCandidate` for the rest of the card's lifetime.
struct PerformToPreviewStrip: View {
    var entry: CatalogEntry
    @ObservedObject var engine: TacitEngine

    var body: some View {
        LiveGestureStrip(entry: entry, engine: engine)
            .onAppear { engine.isPreviewActive = true }
            .onDisappear { engine.isPreviewActive = false }
    }
}

/// The rendering-only half of the live strip — identical chrome and behavior to what
/// `PerformToPreviewStrip` showed before Task 7 (paused/live content, out-of-frame guidance), but
/// with NO side effect on `engine.isPreviewActive`. See `PerformToPreviewStrip`'s doc comment for
/// why that side effect has exactly one owner.
struct LiveGestureStrip: View {
    var entry: CatalogEntry
    @ObservedObject var engine: TacitEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True once `engine.latestFrame` has been continuously nil for >1s while the strip is
    /// mounted — shows the "Show your hand to the camera." guidance (requirement 3). Reset to
    /// `false` the instant a frame arrives.
    @State private var showGuidance = false
    private static let noFrameGuidanceDelay: Duration = .seconds(1)
    @State private var guidanceTask: Task<Void, Never>?

    private static let stripHeight: CGFloat = 120
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.06))

            if engine.glyphState == .paused {
                pausedContent
            } else {
                liveContent
            }
        }
        .frame(height: Self.stripHeight)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onAppear {
            handleFrameChange(engine.latestFrame)
        }
        .onDisappear {
            guidanceTask?.cancel()
            guidanceTask = nil
        }
        .onChange(of: engine.latestFrame) { _, newFrame in
            handleFrameChange(newFrame)
        }
    }

    /// The actual live strip: the tracked skeleton (position-preserving — `fitToJoints: false`,
    /// per the Task 8 ruling that "where is my hand" matters here — smoothed with the
    /// Reduce-Motion-exempt `TacitMotion.liveTracking`), plus the out-of-frame guidance text.
    @ViewBuilder
    private var liveContent: some View {
        ZStack {
            if let frame = engine.latestFrame {
                ConstellationRenderer(
                    frame: frame,
                    lineWidth: 1.5,
                    color: .secondary,
                    fitToJoints: false
                )
                .padding(12)
                // Essential, user-driven state ("where is my hand right now") — applied
                // unconditionally, NOT via `TacitMotion.respecting(reduceMotion, ...)`: spec §4's
                // motion table keeps this on even under Reduce Motion.
                .animation(TacitMotion.liveTracking, value: frame)
            }

            if showGuidance {
                Text("Show your hand to the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Capture paused/unavailable (requirement 5): no live claim — the canned frame, dimmed, plus
    /// plain-verb copy explaining why nothing is tracking.
    private var pausedContent: some View {
        ZStack {
            ConstellationRenderer(
                frame: entry.cannedFrame,
                lineWidth: 1.5,
                color: Color.secondary.opacity(0.35),
                fitToJoints: true
            )
            .padding(12)

            Text("Tacit is paused.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Starts (or cancels) the >1s out-of-frame guidance timer. A frame arriving clears
    /// `showGuidance` immediately; frames going away starts a fresh 1s countdown (any earlier
    /// countdown is cancelled first, so a brief flicker in/out of frame doesn't accumulate).
    private func handleFrameChange(_ frame: LandmarkFrame?) {
        guidanceTask?.cancel()
        guard frame == nil else {
            showGuidance = false
            return
        }
        guidanceTask = Task {
            try? await Task.sleep(for: Self.noFrameGuidanceDelay)
            guard !Task.isCancelled else { return }
            showGuidance = true
        }
    }
}
