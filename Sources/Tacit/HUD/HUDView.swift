import SwiftUI
import TacitCore

/// The HUD's SwiftUI surface (spec §4.4: weightless transient surface — system material, hairline
/// border, soft shadow, never an opaque slab). All motion is driven externally by `HUDController`
/// writing to `state`; this view just renders whatever `state` currently says.
struct HUDView: View {
    @ObservedObject var state: HUDState

    /// The visible chip's size — must match `HUDController.chipSize` (the controller centers this
    /// exact size within its larger, transparent panel canvas so the shadow below has room to
    /// bleed past the chip's edges without the `NSHostingView`'s bounds clipping it).
    static let chipSize = CGSize(width: 220, height: 120)

    private let cornerRadius: CGFloat = 14
    private let constellationSize: CGFloat = 56

    var body: some View {
        content
            .padding(16)
            .frame(width: Self.chipSize.width, height: Self.chipSize.height)
            .background(surface)
            .opacity(state.opacity)
            .scaleEffect(state.scale)
            .offset(y: state.translateY)
    }

    @ViewBuilder
    private var content: some View {
        switch state.content {
        case let .gesture(displayName, actionSummary, frame):
            VStack(spacing: 10) {
                ConstellationRenderer(
                    frame: frame,
                    lineWidth: 1.5,
                    color: .primary,
                    drawProgress: state.drawProgress,
                    fitToJoints: true
                )
                .frame(width: constellationSize, height: constellationSize)

                summaryLine(displayName: displayName, actionSummary: actionSummary)
            }

        case let .error(message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    /// "<displayName> → <actionSummary>", e.g. "Victory → ⌃Tab" — primary color for the gesture
    /// name, secondary for the arrow and action (spec: one quiet line).
    private func summaryLine(displayName: String, actionSummary: String) -> some View {
        HStack(spacing: 4) {
            Text(displayName)
                .foregroundStyle(.primary)
            Text("→")
                .foregroundStyle(.secondary)
            Text(actionSummary)
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
