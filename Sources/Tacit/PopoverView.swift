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

            hairline

            hudToggleRow
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

    private var pauseButton: some View {
        Button {
            engine.pause(for: 3600)
        } label: {
            HStack(spacing: 8) {
                Text("Pause for an hour")
                Spacer(minLength: 8)
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.body)
        }
        .buttonStyle(TacitUtilityRowButtonStyle(showsRestingSurface: false))
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
