import SwiftUI
import TacitCore

/// The `MenuBarExtra` popover content (spec §3.7 / §7): header with live glyph + state line,
/// master toggle, pause, launch-at-login, warning row, "Open Library", and quit. Weightless
/// surface per spec §4.4 — `.ultraThinMaterial`, hairlines, no opaque slabs.
struct PopoverView<Engine: EngineUIState>: View {
    @ObservedObject var engine: Engine
    @EnvironmentObject private var fixtureRecorder: FixtureRecorder

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isOptionKeyDown = false
    @State private var fixtureLabel = ""

    #if DEBUG
    /// Manual-verification-only: fires a fake `HUDController.show` from the ⌥-debug section
    /// (brief step 3/5). Deliberately kept separate from `engine.hudController` — Task 21 wired
    /// that one to real gesture fires; this one stays a standalone instance purely for eyeballing
    /// HUD motion by hand, without needing a live camera/gesture to trigger it.
    @State private var hudController = HUDController()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            pauseButton
            latchRow

            hairline

            hudToggleRow
            debugViewToggleRow
            requiresClutchToggleRow
            LaunchAtLoginToggleRow()

            if let warning = engine.warning {
                hairline
                warningRow(warning)
            }

            if isOptionKeyDown {
                hairline
                fixtureDebugSection
                #if DEBUG
                hairline
                hudDebugSection
                #endif
            }

            hairline

            openLibraryButton
            quitButton
        }
        .padding(12)
        .frame(width: 272)
        .background(.ultraThinMaterial)
        .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: engine.warning)
        .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: engine.latchedChord)
        // Debug-only reveal, no animation magic number needed: an instant show/hide while ⌥ is
        // held reads as "peeking behind a panel," not as a UI transition worth tokenizing.
        .onModifierKeysChanged(mask: .option) { _, newModifiers in
            isOptionKeyDown = newModifiers.contains(.option)
        }
    }

    // MARK: - Rows

    private var header: some View {
        Toggle(isOn: $engine.isEnabled) {
            HStack(spacing: 10) {
                MenuBarGlyphView(state: engine.glyphState, size: 26)
                Text(stateLine)
                    .font(.body.weight(.semibold))
            }
        }
        .toggleStyle(TacitToggleStyle())
        .accessibilityLabel("Tacit is \(stateLine.lowercased())")
        .frame(minHeight: 52)
    }

    /// Plain verbs, per brief: "Watching" / "Paused" / "Armed" / "Fired ✓".
    private var stateLine: String {
        switch engine.glyphState {
        case .paused: "Paused"
        case .watching: "Watching"
        case .armed: "Armed"
        case .fired: "Fired ✓"
        }
    }

    /// State-aware, not a `Toggle` (plain verbs, spec §4): reads "Pause for an hour" with a clock
    /// glyph normally, and swaps in place to "Resume" with the remaining time once
    /// `engine.userPauseEndsAt` is set — same row, same action slot, no separate control appearing.
    /// `TimelineView(.everyMinute)` recomputes the remaining-time text on the minute without a
    /// manual timer (brief: per-second precision isn't needed here).
    private var pauseButton: some View {
        TimelineView(.everyMinute) { _ in
            Button {
                if engine.userPauseEndsAt != nil {
                    engine.resumeFromUserPause()
                } else {
                    engine.pause(for: 3600)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(engine.userPauseEndsAt != nil ? "Resume" : "Pause for an hour")
                    Spacer(minLength: 8)
                    if let remaining = remainingPauseText {
                        Text(remaining)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .font(.body)
            }
            .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
            .frame(minHeight: 44)
            .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: engine.userPauseEndsAt)
        }
    }

    /// e.g. "52 min" — `nil` once fewer than a minute remains or no user pause is active, at which
    /// point the row falls back to the clock glyph rather than showing "0 min".
    private var remainingPauseText: String? {
        guard let endsAt = engine.userPauseEndsAt else { return nil }
        let minutes = Int(endsAt.timeIntervalSinceNow / 60)
        guard minutes > 0 else { return nil }
        return "\(minutes) min"
    }

    /// Shown only while a `.toggleKeystroke` chord is latched down — the always-visible way out
    /// of a hands-free dictation latch (spec §6: never a silent held key). Plain verb, one accent
    /// use is NOT warranted here (this is a state row, not the armed state).
    @ViewBuilder
    private var latchRow: some View {
        if let chord = engine.latchedChord {
            Button {
                engine.releaseLatch()
            } label: {
                HStack {
                    Text("Holding \(chord.display)")
                    Spacer()
                    Text("Release")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
            .frame(minHeight: 44)
        }
    }

    /// Finding I1 (spec §4): lets users disable the HUD confirmation panel while keeping glyph
    /// feedback — `TacitEngine.applyDispatchOutcome` is what actually honors this.
    private var hudToggleRow: some View {
        Toggle(isOn: $engine.isHUDEnabled) {
            Text("Show confirmations")
                .font(.body)
        }
        .toggleStyle(TacitToggleStyle())
        .padding(.horizontal, 10)
    }

    /// Toggles `TacitEngine.debugPanelController`'s floating picture-in-picture panel — shows the
    /// live constellation, raw classifier reading, and clutch phase so a user can tune their
    /// hand/camera against what Tacit is actually seeing.
    private var debugViewToggleRow: some View {
        Toggle("Show gesture debug view", isOn: $engine.isDebugViewEnabled)
            .toggleStyle(TacitToggleStyle())
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
    }

    /// Clutch-optional setting (2026-08-24 product ruling): off by default — gestures fire the
    /// moment they're recognized, at a stricter confidence floor, with no fist hold gating them.
    /// See `TacitEngine.requiresClutch`.
    private var requiresClutchToggleRow: some View {
        Toggle("Require clutch (fist to arm)", isOn: $engine.requiresClutch)
            .toggleStyle(TacitToggleStyle())
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
    }

    private func warningRow(_ warning: String) -> some View {
        // Status row only — informational, never gesture imagery (spec §4.2).
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(warning)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    private var openLibraryButton: some View {
        Button {
            openWindow(id: "library")
        } label: {
            HStack(spacing: 8) {
                Text("Open Library")
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.body)
        }
        .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit Tacit")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
        .keyboardShortcut("q")
    }

    private var hairline: some View {
        Divider()
            .opacity(0.45)
            .padding(.vertical, 6)
    }

    // MARK: - Fixture debug section (⌥-revealed)

    /// Hidden by default; shown only while ⌥ is held, per brief. Lets a developer record a
    /// labeled `LandmarkFrame` clip to `~/Documents/TacitFixtures/` without any product-facing
    /// affordance. The recorder itself is a passive sink (see `FixtureRecorder`) — Task 11's
    /// engine is what will actually feed it frames via `append(_:)`; this section only drives
    /// `start(seconds:label:)` and reflects its published state.
    private var fixtureDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fixture Recorder")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("Label", text: $fixtureLabel)
                .textFieldStyle(.roundedBorder)
                .disabled(fixtureRecorder.isRecording)

            Button(recordButtonTitle(seconds: 10)) {
                fixtureRecorder.start(seconds: 10, label: fixtureLabel)
            }
            .buttonStyle(TacitButtonStyle())
            .disabled(fixtureRecorder.isRecording)

            // Secondary, longer clip: the negative fixtures (typing, conversation) need real
            // sustained activity, not a single 10 s snippet.
            Button(recordButtonTitle(seconds: 60)) {
                fixtureRecorder.start(seconds: 60, label: fixtureLabel)
            }
            .buttonStyle(TacitButtonStyle())
            .disabled(fixtureRecorder.isRecording)

            if let lastError = fixtureRecorder.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recordButtonTitle(seconds: Int) -> String {
        fixtureRecorder.isRecording ? "Recording… \(fixtureRecorder.remainingSeconds) s" : "Record \(seconds) s"
    }

    #if DEBUG
    /// Fires a fake gesture event through `HUDController` so the HUD's motion (spec §4) can be
    /// eyeballed without waiting on Task 21's real `TacitEngine` wiring.
    private var hudDebugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HUD")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Button("Test HUD") {
                hudController.show(gesture: .victory, actionSummary: "⌃Tab", frame: nil)
            }
            .buttonStyle(TacitButtonStyle())
        }
    }
    #endif
}
