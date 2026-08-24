import SwiftUI
import TacitCore

/// The specimen card, grown (spec §5's "Card detail... expands from the card, context preserved,
/// no navigation push"). Shares `SpecimenCard`'s chrome and copy helpers so the same object reads
/// as itself at a larger size, not a different screen: same corner radius, same material fill,
/// same constellation (traveling via `matchedGeometryEffect`, larger), same metadata/binding
/// copy — plus the editorial paragraph, the action binder, and the perform-to-preview mount point.
struct CardDetailView: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore
    // `@ObservedObject`, not a plain `var`: Task 19's perform-to-preview needs this view to
    // re-render on `engine.previewCandidate` (lights the constellation below) and `engine.glyphState`
    // (the strip's paused affordance) changes.
    @ObservedObject var engine: TacitEngine
    var namespace: Namespace.ID
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConstellationRenderer(
                    frame: entry.cannedFrame,
                    lineWidth: 1.5,
                    // Task 19: "lights up" while the user is actually performing this card's
                    // gesture right now, per `engine.previewCandidate` (arbitration-bypassing, only
                    // non-nil while the preview strip below is mounted). Accent is sanctioned here —
                    // this constellation lighting up while its gesture is held IS armed/active
                    // semantics, the one use `TacitColors.accent` exists for.
                    color: isPreviewMatched ? TacitColors.accent : .primary,
                    fitToJoints: true
                )
                .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: isPreviewMatched)
                // `isSource: false`: `SpecimenCard`'s constellation is the persisting source for
                // this id (see its doc comment); this is the target that animates to/from it.
                .tacitMatchedGeometry(
                    id: "\(entry.id.rawValue)-constellation",
                    in: namespace,
                    enabled: !reduceMotion,
                    isSource: false
                )
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
        .frame(maxWidth: 440)
        .frame(minHeight: 320, maxHeight: 560)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        // `isSource: false` — see `SpecimenCard`'s matching comment: the grid card is the app's
        // one persisting source of geometry for this id; this container is always the target.
        .tacitMatchedGeometry(id: entry.id.rawValue, in: namespace, enabled: !reduceMotion, isSource: false)
        .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
    }

    // MARK: - Action binder (Task 18)

    /// The four-way action binder (spec §5: "keystroke recorder, app picker, URL field with
    /// validation, Shortcut picker") — `ActionBinderView` in `ActionBinders.swift`. Hidden
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

                ActionBinderView(entry: entry, store: store)
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
        Button("Done", action: onDone)
            .buttonStyle(TacitButtonStyle())
            .keyboardShortcut(.defaultAction)
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
struct PerformToPreviewStrip: View {
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
            engine.isPreviewActive = true
            handleFrameChange(engine.latestFrame)
        }
        .onDisappear {
            engine.isPreviewActive = false
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
