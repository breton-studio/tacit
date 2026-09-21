import SwiftUI
import TacitCore

/// The Library window's "Settings" tab (spec §5: "Settings that aren't gesture-specific — camera
/// picker, launch at login, HUD on/off, arbitration sensitivity global trim — live in a compact
/// Settings tab in the same window"). M3 Task 7.
///
/// Four rows, quiet macOS style (plain-verb labels, `TacitToggleStyle`/system `Picker`s, ≥44 pt
/// targets): a camera picker and the sensitivity segmented control are NEW here; "Launch at
/// Login" and "Show confirmations" are RELOCATED from being popover-exclusive. Both relocated
/// rows are single-source-of-truth reuses, not copies: `LaunchAtLoginToggleRow` (shared with
/// `PopoverView` — see `SharedControls.swift`) owns the one `SMAppService.mainApp` read/write
/// path, and the HUD toggle below binds directly to the exact same `engine.isHUDEnabled`
/// `@Published` property `PopoverView.hudToggleRow` binds to. Flipping either toggle here or in
/// the popover is indistinguishable to the rest of the app — there is no second, divergent copy
/// of either setting.
struct SettingsTab: View {
    @ObservedObject var engine: TacitEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Camera")
                    cameraPickerRow
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Keyboard gestures")
                    keyboardHomeToggleRow
                    keyboardCalibrationRow
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Controller hand")
                    modifierHandToggleRow
                    controllerHandRow
                    modifierHandStatusRow
                    Text("Lightly pinch to engage. Move sideways to pan or scroll; move toward or away from the camera to zoom. Quick thumb taps switch apps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Sensitivity")
                    sensitivityRow
                    Text("How readily Tacit starts and continues recognizing a gesture. Most people should leave this on Standard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Clutch")
                    requiresClutchRow
                    Text("Off: gestures fire as soon as they're recognized. On: hold a loose fist first, then gesture.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                }

                hairline

                LaunchAtLoginToggleRow()
                hudToggleRow
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    // MARK: - Camera picker

    /// Persists the selection under `"tacit.cameraID"` (via `engine.cameraID`'s own `didSet` —
    /// see `TacitEngine.swift`) and switches the live capture session on every change
    /// (`CaptureEngine.switchCamera(to:)`, called from that same `didSet`). This row never talks
    /// to `CaptureEngine` directly; `engine.cameraID` is the one binding surface.
    private var cameraPickerRow: some View {
        HStack(spacing: 8) {
            Text("Use this camera")
                .font(.body)
            Spacer(minLength: 8)
            CameraPicker(selection: $engine.cameraID)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Keyboard-home calibration

    private var keyboardHomeToggleRow: some View {
        Toggle(isOn: $engine.isKeyboardHomeEnabled) {
            Text("Enable keyboard-home gestures")
                .font(.body)
        }
        .toggleStyle(TacitToggleStyle())
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .onChange(of: engine.isKeyboardHomeEnabled) { _, enabled in
            if enabled && engine.activeKeyboardCalibrationProfile == nil {
                openCalibration()
            }
        }
    }

    private var keyboardCalibrationRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(keyboardHomeStatus)
                    .font(.body)
                Text(engine.activeCameraName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(
                engine.activeKeyboardCalibrationProfile == nil
                    ? "Calibrate…"
                    : "Recalibrate…",
                action: openCalibration
            )
            .buttonStyle(TacitButtonStyle())
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .onChange(of: engine.cameraID) { _, _ in
            if (engine.isKeyboardHomeEnabled || engine.isModifierHandEnabled)
                && engine.activeKeyboardCalibrationProfile == nil {
                openCalibration()
            }
        }
    }

    private var keyboardHomeStatus: String {
        guard engine.activeKeyboardCalibrationProfile != nil else {
            return "Calibration required"
        }
        guard engine.isKeyboardHomeEnabled else { return "Calibrated" }

        switch engine.keyboardLiftState {
        case .unavailable: return "Calibrated · waiting for camera"
        case .resting: return "Live · hands resting"
        case .leftLifted: return "Live · left hand lifted"
        case .rightLifted: return "Live · right hand lifted"
        case .bothLifted: return "Live · both hands lifted"
        }
    }

    private func openCalibration() {
        openWindow(id: "keyboard-calibration")
        WindowActivator.bringToFront(
            id: "keyboard-calibration",
            title: "Keyboard Gesture Calibration"
        )
    }

    // MARK: - Modifier hand

    private var modifierHandToggleRow: some View {
        Toggle(isOn: $engine.isModifierHandEnabled) {
            Text("Enable resting-hand controller")
                .font(.body)
        }
        .toggleStyle(TacitToggleStyle())
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .onChange(of: engine.isModifierHandEnabled) { _, enabled in
            if enabled && engine.activeModifierHandProfile == nil {
                openCalibration()
            }
        }
    }

    private var controllerHandRow: some View {
        HStack(spacing: 8) {
            Text("Use this hand")
                .font(.body)
            Spacer(minLength: 8)
            Picker("", selection: $engine.controllerHand) {
                ForEach(ControllerHand.allCases, id: \.self) { hand in
                    Text(hand.displayName).tag(hand)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var modifierHandStatusRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(modifierHandStatus)
                    .font(.body)
                Text("Uses this camera's keyboard calibration")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(
                engine.activeModifierHandProfile == nil ? "Calibrate…" : "Recalibrate…",
                action: openCalibration
            )
            .buttonStyle(TacitButtonStyle())
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var modifierHandStatus: String {
        guard engine.activeModifierHandProfile != nil else { return "Calibration required" }
        guard engine.isModifierHandEnabled else { return "Calibrated" }
        switch engine.modifierHandState {
        case .unavailable: return "Calibrated · waiting for camera"
        case .outsideZone: return "Live · hand outside its zone"
        case .ready: return "Live · ready"
        case .engaged: return "Live · engaged"
        }
    }

    // MARK: - Sensitivity

    /// Drives `engine.sensitivity`'s `didSet` (persists `"tacit.sensitivity"` and calls
    /// `PipelineCore.setSensitivity(_:)` through the same actor path low light already uses — see
    /// `TacitEngine.swift`'s doc comments on `sensitivity` and `PipelineCore.recomputeTuning()`).
    private var sensitivityRow: some View {
        Picker("", selection: $engine.sensitivity) {
            Text("Relaxed").tag(SensitivityTrim.relaxed)
            Text("Standard").tag(SensitivityTrim.standard)
            Text("Eager").tag(SensitivityTrim.eager)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Clutch

    /// Clutch-optional setting (2026-08-24 product ruling): identical row/binding to
    /// `PopoverView.requiresClutchToggleRow` — see `TacitEngine.requiresClutch`.
    private var requiresClutchRow: some View {
        Toggle(isOn: $engine.requiresClutch) {
            Text("Require clutch (fist to arm)")
                .font(.body)
        }
        .toggleStyle(TacitToggleStyle())
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Relocated toggles

    /// Finding I1 (spec §4), relocated: lets users disable the HUD confirmation panel while
    /// keeping glyph feedback. Identical row to `PopoverView.hudToggleRow`, bound to the identical
    /// property — see this file's header doc comment.
    private var hudToggleRow: some View {
        Toggle(isOn: $engine.isHUDEnabled) {
            Text("Show confirmations")
                .font(.body)
        }
        .toggleStyle(TacitToggleStyle())
        .padding(.horizontal, 10)
    }

    // MARK: - Chrome

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }

    private var hairline: some View {
        Divider()
            .opacity(0.45)
    }
}
