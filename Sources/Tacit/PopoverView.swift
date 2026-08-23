import ServiceManagement
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

    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginErrorMessage: String?

    @State private var isOptionKeyDown = false
    @State private var fixtureLabel = ""

    #if DEBUG
    /// Manual-verification-only: fires a fake `HUDController.show` from the ⌥-debug section
    /// (brief step 3/5). Never wired to the real engine — Task 21 does that.
    @State private var hudController = HUDController()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            hairline

            masterToggleRow
            pauseButton
            launchAtLoginRow

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
        .padding(16)
        .frame(width: 280)
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
        HStack(spacing: 10) {
            MenuBarGlyphView(state: engine.glyphState, size: 26)
            Text(stateLine)
                .font(.body.weight(.medium))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
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

    private var masterToggleRow: some View {
        // Label text tracks `glyphState`, not `isEnabled` directly: `isEnabled` stays `true`
        // during a `pause(for:)` (e.g. "Pause for an Hour"), and this row must still read
        // "Paused" — matching the header — rather than disagreeing with it. The toggle itself
        // stays bound to `isEnabled`, which is the only thing it's meant to control.
        Toggle(isOn: $engine.isEnabled) {
            Text(engine.glyphState == .paused ? "Paused" : "Tacit is watching")
        }
        .toggleStyle(TacitToggleStyle())
    }

    private var pauseButton: some View {
        Button("Pause for an Hour") {
            engine.pause(for: 3600)
        }
        .buttonStyle(TacitButtonStyle())
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: launchAtLoginBinding) {
                Text("Launch at Login")
            }
            .toggleStyle(TacitToggleStyle())

            if let launchAtLoginErrorMessage {
                Text(launchAtLoginErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
        Button("Open Library") {
            openWindow(id: "library")
        }
        .buttonStyle(TacitButtonStyle())
    }

    private var quitButton: some View {
        Button("Quit Tacit") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(TacitButtonStyle())
        .keyboardShortcut("q")
    }

    private var hairline: some View {
        Divider().opacity(0.5)
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

    // MARK: - Launch at Login

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginErrorMessage = nil
        } catch {
            // Revert the toggle and show a one-line message, per brief.
            launchAtLoginErrorMessage = "Couldn't update Login Items."
        }
        // Reflect the system's actual status either way — `register()`/`unregister()` can
        // silently no-op (e.g. already in the requested state) as well as throw.
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
