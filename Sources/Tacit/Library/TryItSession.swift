import SwiftUI
import TacitCore

/// Task 7: the Try-It session — a ~10s live window, opened from a gesture's detail card, where the
/// clutch is bypassed for THAT gesture only (spec plan Ruling 3: entirely via the existing preview
/// pipeline — `TacitEngine.previewCandidate`, `ArbitrationEngine` untouched). Shows a checkmark
/// verdict the instant the gesture registers, or a coaching hint on timeout.
///
/// Deliberately reads `engine.previewCandidate` rather than owning any detection of its own:
/// `CardDetailView.performToPreviewSection`'s `PerformToPreviewStrip` is ALREADY mounted for the
/// card's entire lifetime and is the one place that flips `engine.isPreviewActive` — this overlay
/// only ever observes the stream that produces, never toggles it. That includes the momentary-
/// gesture case (a tap/swipe firing on a single ~66ms frame): `PipelineCore`'s 0.6s preview latch
/// (see its doc comment) keeps `previewCandidate` reporting that fire for 0.6s afterward, which is
/// what makes a single-frame candidate catchable by a UI-side observer at all — this view leans on
/// that existing mechanism rather than re-implementing any latching itself.
struct TryItSessionOverlay: View {
    var entry: CatalogEntry
    @ObservedObject var engine: TacitEngine
    /// Called for every dismissal path (Esc, click-outside cancel, and the post-verdict auto-close
    /// alike) — `CardDetailView.dismissTryIt()` is the only thing that decides HOW that dismissal
    /// animates; this view has no opinion of its own about entrance/exit timing beyond the verdict
    /// crossfade below.
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Verdict: Equatable {
        case waiting
        case registered
        case timedOut
    }

    @State private var verdict: Verdict = .waiting
    /// Bumped by "Try Again" to restart the `.task(id:)` below with a clean 10s window — `.task`
    /// automatically cancels the previous run and starts a fresh one when its `id` changes, so this
    /// is the only piece of state a retry has to touch.
    @State private var sessionToken = UUID()
    /// The countdown ring's zero point for the CURRENT `sessionToken`, reset at the top of every
    /// `.task(id:)` run (including retries). UI-only timing (this file lives in the app target, not
    /// TacitCore) — matched-to-frame recognition timestamps are untouched by this.
    @State private var startedAt = Date()
    @State private var autoCloseTask: Task<Void, Never>?

    private static let sessionDuration: TimeInterval = 10
    private static let registeredAutoCloseDelay: Duration = .milliseconds(1200)

    var body: some View {
        ZStack {
            // Click-outside cancel: only the background catches this tap. The foreground panel
            // below swallows its own taps (see its `.onTapGesture {}`) so a click ON the panel
            // never falls through to this dismiss.
            Rectangle()
                .fill(.regularMaterial)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    GesturePreviewView(entry: entry, mode: .loop)
                        .frame(width: 108, height: 108)

                    LiveGestureStrip(entry: entry, engine: engine)
                        .frame(maxWidth: .infinity)
                }

                statusArea
            }
            .padding(20)
            .contentShape(Rectangle())
            .onTapGesture {}
        }
        .onExitCommand(perform: onDismiss)
        .task(id: sessionToken) {
            startedAt = Date()
            verdict = .waiting
            // Cover the case where the user is already mid-gesture the instant the session opens
            // (e.g. re-entering via "Try Again" while still holding the pose from the last
            // attempt) — don't wait for the next `previewCandidate` change to notice a match that
            // already holds true right now. The same immediate check also means a MOMENTARY
            // gesture (tap/swipe) that just fired can still register here off `PipelineCore`'s
            // still-live 0.6s preview latch, if the session is dismissed and reopened (via "Try
            // Again") within that window — an accepted false positive, always in the user's favor
            // (an undeserved success, never an undeserved failure), so left unguarded.
            checkMatch(engine.previewCandidate)
            try? await Task.sleep(for: .seconds(Self.sessionDuration))
            guard !Task.isCancelled, verdict == .waiting else { return }
            verdict = .timedOut
        }
        .onChange(of: engine.previewCandidate) { _, candidate in
            checkMatch(candidate)
        }
        .onDisappear {
            autoCloseTask?.cancel()
            autoCloseTask = nil
        }
    }

    private func checkMatch(_ candidate: GestureCandidate?) {
        guard verdict == .waiting, candidate?.gesture == entry.id else { return }
        verdict = .registered
        autoCloseTask?.cancel()
        autoCloseTask = Task {
            try? await Task.sleep(for: Self.registeredAutoCloseDelay)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        Group {
            switch verdict {
            case .waiting:
                waitingRow
            case .registered:
                registeredRow
            case .timedOut:
                timedOutColumn
            }
        }
        // Spec plan brief: "standardUI, Reduce Motion crossfade" — the curve is always
        // `TacitMotion.standardUI` (never dropped to instant via `.respecting`, unlike most of
        // this app's animations); what Reduce Motion changes is the TRANSITION shape below, from a
        // small scale-in bloom to a plain opacity crossfade.
        .animation(TacitMotion.standardUI, value: verdict)
    }

    private var waitingRow: some View {
        HStack(spacing: 10) {
            countdownRing
            Text("Perform \(entry.displayName) to try it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    private var registeredRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TacitColors.accent)
            Text("Registered.")
                .font(.callout.weight(.semibold))
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
    }

    private var timedOutColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Didn't catch it.")
                .font(.callout.weight(.semibold))
            Text(entry.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                sessionToken = UUID()
            }
            .buttonStyle(TacitButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    /// A quiet, secondary 10s countdown — real elapsed time via `TimelineView`, not a manually
    /// ticked `@State` counter (no per-frame state writes, and it self-corrects if this view ever
    /// stalls). Reduce Motion drops the redraw rate from a smooth sweep to a once-a-second tick —
    /// still legibly counting down, just without the continuous incidental motion.
    private var countdownRing: some View {
        TimelineView(.periodic(from: startedAt, by: reduceMotion ? 1 : 1.0 / 12.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let remaining = max(0, 1 - elapsed / Self.sessionDuration)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)
        }
        .accessibilityHidden(true)
    }
}
