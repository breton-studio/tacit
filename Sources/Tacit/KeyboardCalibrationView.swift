import SwiftUI
import TacitCore

@MainActor
final class KeyboardCalibrationViewModel: ObservableObject {
    enum Step: Equatable {
        case introduction
        case readyTyping
        case recordingTyping
        case readyLeft
        case recordingLeft
        case readyRight
        case recordingRight
        case evaluating
        case success
        case failure(String)
    }

    @Published private(set) var step: Step = .introduction
    @Published private(set) var secondsRemaining = 0

    private let engine: TacitEngine
    private var cameraID: String?
    private var cameraName = ""
    private var cameraDeviceType = ""
    private var typing: [[LandmarkFrame]] = []
    private var leftLift: [[LandmarkFrame]] = []
    private var rightLift: [[LandmarkFrame]] = []
    private var phaseTask: Task<Void, Never>?

    static let secondsPerPhase = 6

    init(engine: TacitEngine) {
        self.engine = engine
    }

    deinit { phaseTask?.cancel() }

    var title: String {
        switch step {
        case .introduction: "Keyboard gesture calibration"
        case .readyTyping, .recordingTyping: "Type normally"
        case .readyLeft, .recordingLeft: "Lift your left hand"
        case .readyRight, .recordingRight: "Lift your right hand"
        case .evaluating: "Checking the signal"
        case .success: "Calibration complete"
        case .failure: "Adjust and try again"
        }
    }

    var guidance: String {
        switch step {
        case .introduction:
            "Tacit will learn this camera's keyboard framing. Keep both forearms supported and leave the other hand resting when one hand is lifted."
        case .readyTyping:
            "Place both hands on home row. When recording starts, type naturally with both hands."
        case .recordingTyping:
            "Keep typing naturally."
        case .readyLeft:
            "Leave your right hand resting. Lift your left hand 2–5 cm above home row and hold it there."
        case .recordingLeft:
            "Hold the left hand above home row; keep the right hand down."
        case .readyRight:
            "Leave your left hand resting. Lift your right hand 2–5 cm above home row and hold it there."
        case .recordingRight:
            "Hold the right hand above home row; keep the left hand down."
        case .evaluating:
            "Comparing each lifted hand against your typing baseline."
        case .success:
            "This camera now has its own calibration profile. You can rerun this experience from Settings at any time."
        case .failure(let message):
            message
        }
    }

    var primaryTitle: String {
        switch step {
        case .introduction: "Begin"
        case .readyTyping, .readyLeft, .readyRight: "Record"
        case .recordingTyping, .recordingLeft, .recordingRight, .evaluating: "Recording…"
        case .success: "Done"
        case .failure: "Try Again"
        }
    }

    var isRecording: Bool {
        switch step {
        case .recordingTyping, .recordingLeft, .recordingRight: true
        default: false
        }
    }

    var primaryDisabled: Bool { isRecording || step == .evaluating }

    func prepare() {
        engine.start()
        engine.setKeyboardCalibrationActive(true)
        if step == .success || isRecording || step == .evaluating { return }
        if case .failure = step { return }
        step = .introduction
    }

    func ingest(_ frames: [LandmarkFrame]) {
        guard !frames.isEmpty else { return }
        switch step {
        case .recordingTyping: typing.append(frames)
        case .recordingLeft: leftLift.append(frames)
        case .recordingRight: rightLift.append(frames)
        default: break
        }
    }

    func performPrimary() {
        switch step {
        case .introduction:
            beginSession()
        case .readyTyping:
            record(.typing)
        case .readyLeft:
            record(.left)
        case .readyRight:
            record(.right)
        case .failure:
            beginSession()
        default:
            break
        }
    }

    func cancel() {
        phaseTask?.cancel()
        phaseTask = nil
        engine.setKeyboardCalibrationActive(false)
    }

    private enum Phase { case typing, left, right }

    private func beginSession() {
        guard let activeID = engine.activeCameraUniqueID else {
            step = .failure("No active camera is available.")
            return
        }
        cameraID = activeID
        cameraName = engine.activeCameraName
        cameraDeviceType = engine.activeCameraDeviceType
        typing.removeAll(keepingCapacity: true)
        leftLift.removeAll(keepingCapacity: true)
        rightLift.removeAll(keepingCapacity: true)
        secondsRemaining = 0
        step = .readyTyping
    }

    private func record(_ phase: Phase) {
        guard engine.activeCameraUniqueID == cameraID else {
            step = .failure("The active camera changed. Start calibration again for the new camera.")
            return
        }

        switch phase {
        case .typing: step = .recordingTyping
        case .left: step = .recordingLeft
        case .right: step = .recordingRight
        }
        secondsRemaining = Self.secondsPerPhase
        phaseTask?.cancel()
        phaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: Self.secondsPerPhase, through: 1, by: -1) {
                self.secondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            self.secondsRemaining = 0
            self.finish(phase)
        }
    }

    private func finish(_ phase: Phase) {
        switch phase {
        case .typing: step = .readyLeft
        case .left: step = .readyRight
        case .right: evaluate()
        }
    }

    private func evaluate() {
        guard let cameraID else {
            step = .failure("No camera identity was recorded.")
            return
        }
        step = .evaluating
        let input = KeyboardCalibrationInput(
            cameraID: cameraID,
            cameraName: cameraName,
            cameraDeviceType: cameraDeviceType,
            typing: typing,
            leftLift: leftLift,
            rightLift: rightLift
        )
        switch KeyboardHomeCalibrator.derive(from: input) {
        case .success(let profile):
            if engine.installKeyboardCalibrationProfile(profile) {
                step = .success
            } else {
                step = .failure("The calibration passed but could not be saved. Your previous profile is unchanged.")
            }
        case .failure(let failure):
            step = .failure(message(for: failure))
        }
    }

    private func message(for failure: KeyboardCalibrationFailure) -> String {
        switch failure {
        case .insufficientTypingFrames:
            "Tacit could not see both hands consistently while typing. Adjust the camera so the whole keyboard is visible."
        case .insufficientTargetVisibility(let side, let rate):
            "Tacit saw the \(side.rawValue) lifted hand clearly in \(Int((rate * 100).rounded()))% of frames; 80% is required. Adjust the camera or lighting and retry."
        case .insufficientSeparation(let side, let auc):
            "The \(side.rawValue) lift was too similar to typing (separation \(String(format: "%.2f", auc)); 0.90 required). Lift slightly higher and retry."
        case .ambiguousHandMapping:
            "Tacit could not distinguish the left-hand lift from the right-hand lift. Keep the other hand resting and retry."
        }
    }
}

struct KeyboardCalibrationView: View {
    @ObservedObject var engine: TacitEngine
    @StateObject private var model: KeyboardCalibrationViewModel

    @Environment(\.dismissWindow) private var dismissWindow

    init(engine: TacitEngine) {
        self.engine = engine
        _model = StateObject(wrappedValue: KeyboardCalibrationViewModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: model.isRecording ? "camera.viewfinder" : "keyboard")
                .font(.system(size: 42))
                .foregroundStyle(model.isRecording ? Color.accentColor : .secondary)

            VStack(spacing: 8) {
                Text(model.title)
                    .font(.title2.weight(.semibold))
                Text(engine.activeCameraName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(model.guidance)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRecording {
                ProgressView(
                    value: Double(KeyboardCalibrationViewModel.secondsPerPhase - model.secondsRemaining),
                    total: Double(KeyboardCalibrationViewModel.secondsPerPhase)
                )
                Text("\(model.secondsRemaining)s")
                    .font(.system(.title3, design: .monospaced))
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button(model.step == .success ? "Close" : "Cancel") {
                    model.cancel()
                    dismissWindow()
                }
                .buttonStyle(TacitButtonStyle())

                if model.step != .success {
                    Button(model.primaryTitle) { model.performPrimary() }
                        .buttonStyle(TacitButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.primaryDisabled)
                }
            }
        }
        .padding(32)
        .frame(width: 500, height: 460)
        .background(.background)
        .onAppear { model.prepare() }
        .onDisappear { model.cancel() }
        .onReceive(engine.$latestFrames) { model.ingest($0) }
    }
}
