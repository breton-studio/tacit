import SwiftUI
import TacitCore

/// Editorial copy shared between the compact `SpecimenCard` and its grown-up `CardDetailView` —
/// factored out so the two surfaces can never say something different about the same gesture.
enum SpecimenCopy {
    /// A plain-language gesture kind, kept separate from the ergonomic sentence so every card gets
    /// the same two-line metadata slot without relying on punctuation as layout.
    static func kindLabel(for entry: CatalogEntry) -> String {
        switch entry.kind {
        case .staticPose: "Static"
        case .dynamic: "Dynamic"
        case .twoHand: "Two-hand"
        }
    }

    static func ergonomicsLine(for entry: CatalogEntry) -> String {
        "\(entry.comfort), \(entry.falsePositiveRisk.lowercased()) risk"
    }

    /// The two reserved gestures never show a binding line — they show what they do for the
    /// system instead. Only `looseFist`/`openPalm` are reserved (`GestureCatalogTests` guards
    /// this invariant), so this is exhaustive without needing a `default`.
    static func reservedCopy(for id: GestureID) -> String {
        switch id {
        case .looseFist: "Reserved — arms Tacit"
        case .openPalm: "Reserved — disarms"
        default: "Reserved"
        }
    }

    static func reservedActionName(for id: GestureID) -> String {
        switch id {
        case .looseFist: "Arms Tacit"
        case .openPalm: "Disarms Tacit"
        default: "System reserved"
        }
    }

}

/// The specimen book's unit of interface (spec §5): a gesture's constellation, name, quiet
/// ergonomic metadata, current binding summary, and (for bindable gestures) an enable toggle.
///
/// Card chrome is a quiet material fill with a hairline border in continuous corners; hovering
/// only brightens the hairline (no lift, no scale — spec §4's frequency gate: browsing this grid
/// is a frequent action, so its feedback stays minimal).
struct SpecimenCard: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore
    var namespace: Namespace.ID
    var isExpanded: Bool
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 332
    @ScaledMetric(relativeTo: .body) private var titleSlotHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .callout) private var metadataSlotHeight: CGFloat = 52

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConstellationRenderer(
                frame: entry.cannedFrame,
                lineWidth: 1.5,
                color: .primary,
                fitToJoints: true
            )
            // `isSource: true` (the default, spelled out here to document the choice): the grid
            // card is the app's one persisting source of geometry for this id — it never leaves
            // the view tree (see `.opacity(isExpanded ? 0 : 1)` below), so it's always available to
            // anchor the transition. `CardDetailView`'s matching constellation is the target
            // (`isSource: false`). Without picking a side, two co-existing `isSource: true` views
            // resolve to "last one added wins" per `matchedGeometryEffect`'s own docs — order-
            // dependent, not something to lean on.
            .tacitMatchedGeometry(
                id: "\(entry.id.rawValue)-constellation",
                in: namespace,
                enabled: !reduceMotion,
                isSource: true
            )
            .frame(height: 88)
            .frame(maxWidth: .infinity)

            Text(entry.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .frame(height: titleSlotHeight, alignment: .topLeading)

            metadataBlock

            actionRow

            if !entry.isReserved {
                Toggle("Enabled", isOn: enabledBinding)
                    .toggleStyle(TacitToggleStyle())
                    .frame(height: 44)
            } else {
                reservedStateRow
            }
        }
        .padding(16)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .opacity(isExpanded ? 0 : 1)
        // Same persisting-source convention as the constellation above: the grid card is always
        // the source, `CardDetailView`'s container is always the target (`isSource: false`).
        .tacitMatchedGeometry(id: entry.id.rawValue, in: namespace, enabled: !reduceMotion, isSource: true)
        .accessibilityHidden(isExpanded)
        .onHover { hovering in
            withAnimation(TacitMotion.respecting(reduceMotion, TacitMotion.pressFeedback)) {
                isHovered = hovering
            }
        }
        .onTapGesture(perform: onTap)
        // Keyboard accessibility floor (spec §4.6): the card itself — not just its enable toggle —
        // must be reachable by Tab and activatable without a mouse. `.focusable()` gives it a
        // system focus ring; Return/Space open detail the same way a click does. The nested toggle
        // row's own `.onTapGesture` (`TacitToggleStyle`) still wins hit-testing within its own
        // bounds, so this doesn't intercept toggle taps. Not focusable while expanded/hidden, so
        // Tab can't land on the invisible card underneath the detail view.
        .focusable(!isExpanded)
        .onKeyPress(.return) { onTap(); return .handled }
        .onKeyPress(.space) { onTap(); return .handled }
        // Not `.accessibilityElement(children: .combine)`: combining would swallow the enable
        // toggle into one opaque element, making it unreachable on its own for VoiceOver users.
        // This keeps every child (name, metadata, toggle) individually accessible while still
        // exposing "open detail" as the container's own default action.
        .accessibilityAction(.default, onTap)
        // Placed AFTER every interactive modifier above (onHover, onTapGesture, focusable,
        // onKeyPress) rather than before them: `allowsHitTesting` only blocks hit-testing for
        // modifiers applied BEFORE it in the chain, so putting it earlier left the tap gesture
        // reachable in principle (only the detail overlay's z-order was saving it). As the
        // outermost modifier, it's a self-contained guard — the card stays mounted at opacity 0
        // (to keep anchoring the matched-geometry source above) but is genuinely untappable,
        // unhoverable, and unfocusable while its detail is open, independent of what else is
        // drawn on top of it.
        .allowsHitTesting(!isExpanded)
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(SpecimenCopy.kindLabel(for: entry))
                .lineLimit(1)
            Text(SpecimenCopy.ergonomicsLine(for: entry))
                .lineLimit(2)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: metadataSlotHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var actionRow: some View {
        if entry.isReserved {
            HStack(spacing: 8) {
                Text("System action")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(SpecimenCopy.reservedActionName(for: entry.id))
                    .lineLimit(1)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        } else {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Text("Action")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(store.binding(for: entry.id).configuredActionSummary ?? "Set action…")
                        .lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .font(.callout)
            }
            .buttonStyle(TacitUtilityRowButtonStyle())
            .accessibilityLabel(actionAccessibilityLabel)
        }
    }

    private var reservedStateRow: some View {
        HStack(spacing: 8) {
            Text("Always enabled")
            Spacer(minLength: 8)
            Image(systemName: "lock.fill")
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var actionAccessibilityLabel: String {
        if let summary = store.binding(for: entry.id).configuredActionSummary {
            return "Action: \(summary). Edit action."
        }
        return "Set action"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.binding(for: entry.id).enabled },
            set: { newValue in
                switch store.binding(for: entry.id).enableRequest(newValue) {
                case .update(let updated):
                    store.setBinding(updated, for: entry.id)
                case .configureAction:
                    onTap()
                }
            }
        )
    }
}
