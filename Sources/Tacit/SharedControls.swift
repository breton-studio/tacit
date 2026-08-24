import SwiftUI

extension View {
    /// A `matchedGeometryEffect` that can be switched off entirely — used by the Library window's
    /// card ↔ detail expansion (spec §4: Reduce Motion → crossfade, not a geometry morph). This
    /// SDK's `matchedGeometryEffect` has no `isEnabled` parameter of its own, so disabling it means
    /// not applying the modifier at all, which this wraps as one call site.
    ///
    /// `isSource` is forwarded straight through and defaults to `true` (matching
    /// `matchedGeometryEffect`'s own default) — see `SpecimenCard`/`CardDetailView` for the
    /// "persisting source" convention this app standardizes on: the grid card (which never
    /// actually leaves the view tree — it just goes to `opacity 0` while expanded) is always
    /// `isSource: true`; the detail overlay is always `isSource: false`. Docs for
    /// `matchedGeometryEffect` call out that two co-existing views both defaulting to
    /// `isSource: true` for the same id resolve to "last one added wins" — insertion-order
    /// dependent, not something call sites should rely on. Picking one persisting source and one
    /// following target removes that ambiguity entirely.
    @ViewBuilder
    func tacitMatchedGeometry(
        id: some Hashable, in namespace: Namespace.ID, enabled: Bool, isSource: Bool = true
    ) -> some View {
        if enabled {
            self.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

/// Custom press feedback (spec §4.6 / §4 motion table): every pressable control scales to 0.97 on
/// press using `TacitMotion.pressFeedback`, honoring Reduce Motion. Also enforces the ≥44pt
/// hit-target floor.
///
/// Shared across the popover (`PopoverView`) and the Library window (`Sources/Tacit/Library`) —
/// extracted here rather than duplicated so every pressable control in the app answers to the
/// exact same feel.
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

/// A quiet, left-aligned row for frequent utility actions in the popover and for the card's
/// action doorway. Unlike `TacitButtonStyle`, it does not center or noticeably shrink the whole
/// row; the only treatment is a near-monochrome pressed surface using the existing press token.
struct TacitUtilityRowButtonStyle: ButtonStyle {
    var showsRestingSurface = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.07 : (showsRestingSurface ? 0.035 : 0)
                        )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
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
///
/// Shared across the popover and the Library window's specimen cards (each card's enable toggle).
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
                .tint(Color.primary)
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
