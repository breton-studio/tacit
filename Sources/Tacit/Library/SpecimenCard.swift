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
    var isExpanded: Bool
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPressed = false

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 332
    @ScaledMetric(relativeTo: .body) private var titleSlotHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .callout) private var metadataSlotHeight: CGFloat = 52

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Postmortem (2026-08-24, Library detail sheet fix): this container USED to carry a
            // `matchedGeometryEffect` pairing it with `CardDetailView`'s hero, on the theory that
            // keeping this card mounted (at opacity 0, never removed from the tree — see
            // `.opacity(isExpanded ? 0 : 1)` below) would let the detail's copy "travel" from here.
            // In practice `matchedGeometryEffect`'s non-source view doesn't just borrow the
            // source's frame as a transition starting point — it keeps adopting the source's frame
            // continuously for as long as BOTH views coexist in the tree. Because this card never
            // actually leaves the tree (by design, so hide/show can stay symmetric), the detail's
            // hero stayed permanently pinned to this small grid frame instead of animating out to
            // the detail's real size. Per the design-eng lens (prefer reliability over cleverness),
            // the hero now just crossfades — no geometry pairing with the grid card at all.
            ZStack {
                GesturePreviewView(entry: entry, mode: .playOnHover)
            }
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
        // Press feedback for the tap that opens the detail sheet (spec §4.5's `pressFeedback`
        // token, the standard 0.97 scale every pressable in the app answers with) — distinct
        // from `isHovered`'s hairline-only brightening above, which stays scale-free by the
        // frequency gate (browsing the grid is frequent; a `.simultaneousGesture` here doesn't
        // compete with that hover state or with `onTapGesture`/nested controls below, it only
        // answers "something in this card was just pressed").
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(TacitMotion.respecting(reduceMotion, TacitMotion.pressFeedback), value: isPressed)
        // Symmetric hide/show: this card and `CardDetailView` never cross-fade against each
        // other directly (see the hero postmortem above — the two used to be paired via
        // `matchedGeometryEffect`, which is why the card had to stay mounted-but-invisible rather
        // than actually leave the tree). It still stays mounted at opacity 0 rather than being
        // removed, so `AppearingCard`'s first-appearance stagger state and this card's own
        // `isHovered`/focus state survive the detail sheet opening and closing — but the pairing
        // that opacity's `isExpanded` toggle serves now is just "one visible copy at a time",
        // not a geometry anchor.
        .opacity(isExpanded ? 0 : 1)
        .accessibilityHidden(isExpanded)
        .onHover { hovering in
            withAnimation(TacitMotion.respecting(reduceMotion, TacitMotion.pressFeedback)) {
                isHovered = hovering
            }
        }
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
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
        // but is genuinely untappable, unhoverable, and unfocusable while its detail is open,
        // independent of what else is drawn on top of it.
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
