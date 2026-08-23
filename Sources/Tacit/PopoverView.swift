import ServiceManagement
import SwiftUI

/// Custom press feedback (spec §4.6 / §4 motion table): every pressable control in the popover
/// scales to 0.97 on press using `TacitMotion.pressFeedback`, honoring Reduce Motion. Also
/// enforces the ≥44pt hit-target floor.
struct TacitButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(
                TacitMotion.respecting(reduceMotion, TacitMotion.pressFeedback),
                value: configuration.isPressed
            )
    }
}

/// Custom toggle style mirroring `TacitButtonStyle`'s approach: macOS's native `.switch` style
/// only treats the switch control itself as tappable, and doesn't reliably widen that hit area
/// just because an outer `.frame`/`.contentShape` says the row is taller — so this style's
/// `makeBody` owns the full-row layout (label + switch) itself, applies `.contentShape(Rectangle())`
/// to the WHOLE row, and toggles on any tap within it. The inner `.switch`-styled `Toggle` is kept
/// purely for its visual (`.allowsHitTesting(false)`) — one hit target, one place state changes.
struct TacitToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isOnBinding = Binding(
            get: { configuration.isOn },
            set: { configuration.isOn = $0 }
        )
        return HStack {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: isOnBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI)) {
                configuration.isOn.toggle()
            }
        }
    }
}

/// The `MenuBarExtra` popover content (spec §3.7 / §7): header with live glyph + state line,
/// master toggle, pause, launch-at-login, warning row, "Open Library", and quit. Weightless
/// surface per spec §4.4 — `.ultraThinMaterial`, hairlines, no opaque slabs.
struct PopoverView<Engine: EngineUIState>: View {
    @ObservedObject var engine: Engine

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginErrorMessage: String?

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

            hairline

            openLibraryButton
            quitButton
        }
        .padding(16)
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .animation(TacitMotion.respecting(reduceMotion, TacitMotion.standardUI), value: engine.warning)
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
        Toggle(isOn: $engine.isEnabled) {
            Text(engine.isEnabled ? "Tacit is watching" : "Paused")
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
