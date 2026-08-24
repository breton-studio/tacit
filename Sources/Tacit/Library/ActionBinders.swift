import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import TacitCore
import UniformTypeIdentifiers

/// Task 18: the action binder mounted in `CardDetailView`'s "ACTION" region (never for
/// reserved entries — that whole region stays hidden there; see
/// `CardDetailView.actionBinderSection`). A segmented picker of `ActionKind` — five segments as
/// of M3 Task 10's `.focusTextInput` addition (see `ActionKind` below) — defaulting to whichever
/// kind the entry's current binding already uses (keystroke if unbound),
/// with that kind's binder body underneath.
///
/// Switching segments never touches `store` — it only changes which binder is SHOWN. Nothing is
/// written until a binder's own capture/Save actually commits, so browsing the other four
/// segments can never accidentally clear an existing binding (brief requirement 3).
struct ActionBinderView: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    @State private var selectedKind: ActionKind
    /// Task 20 (spec §6): whether Accessibility is currently trusted, polled while this view is
    /// visible so `accessibilityNotice` below reflects a grant/revoke made in System Settings
    /// without requiring the card to be closed and reopened. `AXIsProcessTrusted()` has no
    /// publisher of its own — UI-layer polling is the documented approach (see
    /// `OnboardingView`'s Accessibility step for the same pattern).
    @State private var isAccessibilityTrusted = AXIsProcessTrusted()
    @State private var accessibilityPollTask: Task<Void, Never>?

    init(entry: CatalogEntry, store: MappingStore) {
        self.entry = entry
        self.store = store
        _selectedKind = State(initialValue: ActionKind(matching: store.binding(for: entry.id).action))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action type", selection: $selectedKind) {
                ForEach(ActionKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: 44)

            currentBindingRow

            accessibilityNotice

            switch selectedKind {
            case .keystroke:
                KeystrokeBinder(entry: entry, store: store)
            case .launchApp:
                AppBinder(entry: entry, store: store)
            case .openURL:
                URLBinder(entry: entry, store: store)
            case .runShortcut:
                ShortcutBinder(entry: entry, store: store)
            case .focusTextInput:
                FocusTextInputBinder(entry: entry, store: store)
            }
        }
        .onAppear { startAccessibilityPolling() }
        .onDisappear {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
        }
    }

    /// The configured action stays visible regardless of which segment is open. Enabled state is
    /// reported separately so a disabled-but-configured gesture never masquerades as unbound.
    @ViewBuilder
    private var currentBindingRow: some View {
        if let action = store.binding(for: entry.id).action {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(action.summary)
                    .font(.callout)
                Spacer(minLength: 8)
                Text(store.binding(for: entry.id).enabled ? "Enabled" : "Off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Spec §6 / Task 20 requirement 3: when the CURRENT (stored) binding is a keystroke and
    /// Accessibility isn't trusted, a quiet one-line notice + re-grant button — regardless of
    /// which action-kind segment happens to be selected right now, since the binding that will
    /// actually fire is the stored one, not whatever the picker is previewing.
    @ViewBuilder
    private var accessibilityNotice: some View {
        if isKeystrokeBound, !isAccessibilityTrusted {
            HStack(spacing: 8) {
                Text("Keystroke actions need Accessibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Grant Access…") { requestAccessibilityAccess() }
                    .buttonStyle(TacitButtonStyle())
                    .frame(width: 140)
            }
        }
    }

    /// M3 Task 9: generalized to `requiresAccessibility` (rather than pattern-matching `.keystroke`
    /// specifically) so a `.holdKeystroke` binding — which needs Accessibility exactly the same
    /// way — also surfaces this notice.
    private var isKeystrokeBound: Bool {
        store.binding(for: entry.id).action?.requiresAccessibility ?? false
    }

    private func requestAccessibilityAccess() {
        AccessibilityPermission.requestPromptIfNeeded()
    }

    private func startAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task {
            while !Task.isCancelled {
                isAccessibilityTrusted = AXIsProcessTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// The five bindable action kinds, in the brief's fixed order. Distinct from `TacitAction` itself
/// so the segmented picker has something to select over before any action value exists yet.
private enum ActionKind: CaseIterable, Identifiable, Hashable {
    case keystroke, launchApp, openURL, runShortcut, focusTextInput

    var id: Self { self }

    var label: String {
        switch self {
        case .keystroke: "Keystroke"
        case .launchApp: "Open App"
        case .openURL: "Open URL"
        case .runShortcut: "Run Shortcut"
        case .focusTextInput: "Focus Input"
        }
    }

    /// The kind matching an existing action, or `.keystroke` for `nil` (brief: "keystroke if
    /// none"). `.holdKeystroke` and `.toggleKeystroke` also map to `.keystroke` here — M3 Task 11
    /// / workhorse-remap Task 5 gave that segment a Press / Hold / Toggle delivery picker (see
    /// `KeystrokeBinder`) rather than separate segments, so a `.holdKeystroke` or `.toggleKeystroke`
    /// binding is shown, edited, and re-recorded right there, with the matching segment already
    /// selected; `KeystrokeBinder.currentChord` recognizes all three cases.
    /// M3 Task 10: `.focusTextInput` gets its own dedicated fifth segment instead, since it's a
    /// fully first-class bindable action with no chord to share — see `FocusTextInputBinder`
    /// below.
    init(matching action: TacitAction?) {
        switch action {
        case .none, .keystroke, .holdKeystroke, .toggleKeystroke: self = .keystroke
        case .launchApp: self = .launchApp
        case .openURL: self = .openURL
        case .runShortcut: self = .runShortcut
        case .focusTextInput: self = .focusTextInput
        }
    }
}

// MARK: - Keystroke

/// The three ways a recorded chord can be delivered — one segment each. `init(action:)` reads the
/// mode back out of an existing binding so re-opening a card shows the right segment selected.
private enum KeystrokeMode: CaseIterable, Identifiable, Hashable {
    case press, hold, toggle

    var id: Self { self }

    var label: String {
        switch self {
        case .press: "Press"
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }

    init(action: TacitAction?) {
        switch action {
        case .holdKeystroke: self = .hold
        case .toggleKeystroke: self = .toggle
        default: self = .press
        }
    }

    func action(for chord: KeyChord) -> TacitAction {
        switch self {
        case .press: .keystroke(chord)
        case .hold: .holdKeystroke(chord)
        case .toggle: .toggleKeystroke(chord)
        }
    }
}

/// Records the next keydown as the gesture's keystroke action. Uses a LOCAL event monitor —
/// the card detail window is key while this is visible, so a local monitor sees the keydown
/// without requiring Accessibility permission (that permission only gates actually *posting* a
/// synthetic keystroke later, at dispatch time — see `TacitAction.requiresAccessibility`).
///
/// workhorse-remap Task 5: also carries the Press / Hold / Toggle delivery picker; this segment
/// is the only place `.holdKeystroke` and `.toggleKeystroke` are bindable from the UI — the
/// recorder itself is unchanged (it still just captures a `KeyChord`); the picker only decides
/// which `TacitAction` case wraps that chord when it's saved. Recording a NEW chord always saves
/// under the picker's CURRENT selection (so switching the segment after recording, with no
/// further keypress, does nothing until the next record — nothing written until a capture
/// actually commits).
private struct KeystrokeBinder: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Initialized from the entry's CURRENT binding so re-opening a card with an existing
    /// `.holdKeystroke` or `.toggleKeystroke` binding shows the matching segment already selected.
    @State private var mode: KeystrokeMode

    init(entry: CatalogEntry, store: MappingStore) {
        self.entry = entry
        self.store = store
        _mode = State(initialValue: KeystrokeMode(action: store.binding(for: entry.id).action))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentChord?.display ?? "No shortcut recorded")
                .font(.callout)
                .foregroundStyle(currentChord == nil ? .secondary : .primary)

            Picker("Delivery", selection: $mode) {
                ForEach(KeystrokeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minHeight: 44)

            Button(isRecording ? "Press keys…" : "Record Shortcut") {
                startRecording()
            }
            .buttonStyle(TacitButtonStyle())
            .disabled(isRecording)
        }
        // Belt-and-suspenders against a leaked monitor: also torn down if this binder itself
        // disappears mid-capture (segment switched away, card closed) while a monitor is live.
        .onDisappear { removeMonitor() }
    }

    /// The chord behind the CURRENT binding, whichever of the three keystroke actions it is —
    /// `.holdKeystroke` and `.toggleKeystroke` read here too so an existing hold or toggle binding
    /// shows its recorded chord instead of "No shortcut recorded" just because this text happens
    /// to live in the same segment as the plain-press case.
    private var currentChord: KeyChord? {
        switch store.binding(for: entry.id).action {
        case .keystroke(let chord), .holdKeystroke(let chord), .toggleKeystroke(let chord):
            return chord
        default:
            return nil
        }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { removeMonitor() }
            // Esc cancels without saving — matched before building/saving a chord.
            guard event.keyCode != 53 else { return nil }
            let chord = KeyChord(keyCode: event.keyCode, modifiers: modifiers(from: event.modifierFlags))
            let action = mode.action(for: chord)
            store.setBinding(GestureBinding(enabled: true, action: action), for: entry.id)
            return nil // swallow — this keydown is input to the recorder, not to the app
        }
    }

    /// Always called exactly once per capture/cancel, plus defensively on disappear — never
    /// leaves a registered monitor behind.
    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> KeyChord.Modifiers {
        var mods: KeyChord.Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
    }
}

// MARK: - Open App

private struct AppBinder: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentDisplayName.map { "Open \($0)" } ?? "No app chosen")
                .font(.callout)
                .foregroundStyle(currentDisplayName == nil ? .secondary : .primary)

            Button("Choose App…") { chooseApp() }
                .buttonStyle(TacitButtonStyle())

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentDisplayName: String? {
        if case .launchApp(_, let displayName) = store.binding(for: entry.id).action {
            return displayName
        }
        return nil
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            errorMessage = "That app has no bundle identifier."
            return
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
        errorMessage = nil
        store.setBinding(
            GestureBinding(enabled: true, action: .launchApp(bundleID: bundleID, displayName: displayName)),
            for: entry.id
        )
    }
}

// MARK: - Open URL

private struct URLBinder: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    @State private var urlString = ""
    @State private var hasEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("superwhisper://record", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .onChange(of: urlString) { hasEdited = true }

            if hasEdited && !isValid {
                Text("Needs a scheme, like superwhisper://record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save") { save() }
                .buttonStyle(TacitButtonStyle())
                .disabled(!isValid)
        }
        .onAppear { prefill() }
    }

    private var isValid: Bool {
        ActionValidation.validateURL(urlString)
    }

    private func prefill() {
        if case .openURL(let string) = store.binding(for: entry.id).action {
            urlString = string
        }
    }

    private func save() {
        guard isValid else { return }
        store.setBinding(GestureBinding(enabled: true, action: .openURL(urlString)), for: entry.id)
    }
}

// MARK: - Run Shortcut

private struct ShortcutBinder: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    @State private var shortcutNames: [String] = []
    @State private var isLoading = true
    @State private var selectedShortcut: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .onAppear { prefill() }
        .task { await loadShortcuts() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Text("Looking for Shortcuts…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if shortcutNames.isEmpty {
            Text("No Shortcuts found. Make one in the Shortcuts app.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Picker("Shortcut", selection: $selectedShortcut) {
                Text("Choose a Shortcut…").tag(String?.none)
                ForEach(shortcutNames, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            .frame(minHeight: 44)

            Button("Save") { save() }
                .buttonStyle(TacitButtonStyle())
                .disabled(selectedShortcut == nil)
        }
    }

    private func prefill() {
        if case .runShortcut(let name) = store.binding(for: entry.id).action {
            selectedShortcut = name
        }
    }

    /// Runs `/usr/bin/shortcuts list` off the main thread (`Task.detached`) so a slow or hung
    /// Shortcuts daemon can never stall the UI, then parses stdout into one name per line.
    /// Any failure (missing binary, non-zero exit, empty output) just falls through to the
    /// empty state — never a crash, never a hang.
    private func loadShortcuts() async {
        let names = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return [String]()
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return [String]() }

            let output = String(data: data, encoding: .utf8) ?? ""
            return output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value

        shortcutNames = names
        isLoading = false
    }

    private func save() {
        guard let selectedShortcut else { return }
        store.setBinding(GestureBinding(enabled: true, action: .runShortcut(name: selectedShortcut)), for: entry.id)
    }
}

// MARK: - Focus Input (M3 Task 10)

/// No configuration to capture — unlike the other four binders, `.focusTextInput` carries no
/// associated value, so this is just a quiet one-line description plus a Save button that
/// commits the fixed action value directly.
private struct FocusTextInputBinder: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finds and focuses the main text field of the app you're using.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Save") { save() }
                .buttonStyle(TacitButtonStyle())
        }
    }

    private func save() {
        store.setBinding(GestureBinding(enabled: true, action: .focusTextInput), for: entry.id)
    }
}
