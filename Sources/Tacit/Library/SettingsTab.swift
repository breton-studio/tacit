import AVFoundation
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Camera")
                    cameraPickerRow
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
            Picker("", selection: $engine.cameraID) {
                Text("Default").tag(String?.none)
                ForEach(cameraDevices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(String?(device.uniqueID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        .frame(minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
    }

    /// `AVCaptureDevice.DiscoverySession` over the three device types the brief calls for: the
    /// built-in wide-angle camera (present on every Mac with a camera), `.external` (USB/UVC
    /// webcams — this is also how most Continuity Camera setups enumerate day to day), and
    /// `.continuityCamera` itself (a dedicated device type since macOS 14, for a paired iPhone
    /// used as a webcam). `position: .unspecified` so a front/back-facing distinction — meaningless
    /// for a desk webcam — never excludes a device. Recomputed on every access rather than cached:
    /// the Settings tab is not a hot path, and this keeps a freshly plugged-in/unplugged device
    /// current without wiring a separate `AVCaptureDevice.wasConnectedNotification` observer.
    private var cameraDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
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
