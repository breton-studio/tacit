import AppKit
import SwiftUI
import TacitCore

@MainActor
private final class ModifierStatusModel: ObservableObject {
    @Published var state: ModifierHandState = .unavailable
    @Published var hand: ControllerHand = .left
}

private struct ModifierStatusView: View {
    @ObservedObject var model: ModifierStatusModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.state == .engaged ? Color.accentColor : Color.secondary.opacity(0.75))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .padding(16)
    }

    private var label: String {
        switch model.state {
        case .ready: "\(model.hand.displayName) hand ready"
        case .engaged: "Controller engaged"
        case .outsideZone: "Move \(model.hand.rawValue) hand to its zone"
        case .unavailable: "Controller unavailable"
        }
    }
}

/// A quiet, non-activating status chip. It remains visible for ready/engaged states so the user
/// can tell whether motion will be interpreted before moving the hand.
@MainActor
final class ModifierStatusController {
    private let model = ModifierStatusModel()
    private var panel: NSPanel?

    func update(state: ModifierHandState, hand: ControllerHand, enabled: Bool) {
        if model.state != state { model.state = state }
        if model.hand != hand { model.hand = hand }
        guard enabled, state == .ready || state == .engaged else {
            panel?.orderOut(nil)
            return
        }
        ensurePanel()
        if panel?.isVisible != true {
            positionPanel()
            panel?.orderFrontRegardless()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 230, height: 66)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ModifierStatusView(model: model).frame(width: size.width, height: size.height))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.minX + 22, y: frame.minY + 22))
    }
}
