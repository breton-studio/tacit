import SwiftUI
import TacitCore

/// Editorial copy shared between the compact `SpecimenCard` and its grown-up `CardDetailView` —
/// factored out so the two surfaces can never say something different about the same gesture.
enum SpecimenCopy {
    /// "Static · Low fatigue · Medium FP" — the quiet tabular metadata line (spec §5's "comfort
    /// tier, false-positive risk, static/dynamic... set in small tabular type").
    static func metadataLine(for entry: CatalogEntry) -> String {
        let kind: String
        switch entry.kind {
        case .staticPose: kind = "Static"
        case .dynamic: kind = "Dynamic"
        case .twoHand: kind = "Two-hand"
        }
        return "\(kind) · \(entry.comfort) · \(entry.falsePositiveRisk) FP"
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

    /// "fires → ⌘C" when enabled and bound to an action; "not bound" (quiet) otherwise. Reserved
    /// gestures are handled separately by `reservedCopy` — callers should check `isReserved` first.
    static func bindingLine(for binding: GestureBinding) -> (text: String, isSecondary: Bool) {
        if binding.enabled, let action = binding.action {
            return ("fires → \(action.summary)", false)
        }
        return ("not bound", true)
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

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .frame(height: 96)
            .frame(maxWidth: .infinity)

            Text(entry.displayName)
                .font(.headline)
                .lineLimit(1)

            Text(SpecimenCopy.metadataLine(for: entry))
                .font(.caption)
                .tracking(0.4)
                .textCase(.uppercase)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)

            bindingLine

            if !entry.isReserved {
                Toggle("Enabled", isOn: enabledBinding)
                    .toggleStyle(TacitToggleStyle())
            }
        }
        .padding(16)
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
        // The card stays in the tree at opacity 0 while expanded (so it keeps anchoring the
        // matched-geometry source above) — it must not still act like a visible, tappable card:
        // no hit-testing, no keyboard focus, and hidden from VoiceOver so assistive tech doesn't
        // land on an invisible duplicate of the (now-visible) detail view.
        .allowsHitTesting(!isExpanded)
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
    }

    @ViewBuilder
    private var bindingLine: some View {
        if entry.isReserved {
            Text(SpecimenCopy.reservedCopy(for: entry.id))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let (text, isSecondary) = SpecimenCopy.bindingLine(for: store.binding(for: entry.id))
            Text(text)
                .font(.callout)
                .foregroundStyle(isSecondary ? .secondary : .primary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.binding(for: entry.id).enabled },
            set: { newValue in
                var updated = store.binding(for: entry.id)
                updated.enabled = newValue
                store.setBinding(updated, for: entry.id)
            }
        )
    }
}
