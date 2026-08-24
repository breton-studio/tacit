import SwiftUI
import TacitCore

/// The Library window — the "gesture specimen book" (spec §5). Three tiers, each a section of
/// `SpecimenCard`s in an adaptive grid; clicking a card expands it in place into
/// `CardDetailView` via one shared `@Namespace`, so the card — and specifically its constellation
/// — visibly travels rather than remounting somewhere else (object permanence).
struct LibraryWindow: View {
    @ObservedObject var store: MappingStore
    @ObservedObject var engine: TacitEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var cardNamespace

    @State private var expandedGesture: GestureID?
    /// Cards that have already played their first-appearance stagger once. Owned here (not by
    /// each card) because `LazyVGrid` cells can be torn down and re-materialized while scrolling —
    /// without this, scrolling a card off-screen and back would replay its "first appearance."
    @State private var appearedIDs: Set<GestureID> = []

    private static let tierOrder: [GestureTier] = [.workhorse, .occasional, .deliberate]
    private static let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16, alignment: .top)]

    /// M3 Task 7: the window became a two-tab `TabView` — "Gestures" (this file's original,
    /// unchanged specimen-grid content, now `gesturesTab` below) and "Settings"
    /// (`Sources/Tacit/Library/SettingsTab.swift`, new). Quiet macOS style: plain text tab items,
    /// no icons, default `TabView` chrome — nothing here reaches for a custom tab bar.
    ///
    /// The `.frame(minWidth:minHeight:)` that used to sit directly on the specimen-grid
    /// `ScrollView` moved up to the `TabView` itself, since it now has to size BOTH tabs, not just
    /// the grid; `gesturesTab` keeps its own `.background`/`.overlay`/`.onExitCommand` exactly as
    /// before. Everything the stagger/expand behavior depends on — `cardNamespace`,
    /// `expandedGesture`, `appearedIDs` — is unchanged `@State`/`@Namespace` on this same
    /// `LibraryWindow`, so it survives this re-parenting: those are owned by the view that hosts
    /// the `TabView`, not by a tab's content, and SwiftUI preserves a parent's `@State` across its
    /// children being shown/hidden by tab selection.
    var body: some View {
        TabView {
            gesturesTab
                .tabItem { Text("Gestures") }

            SettingsTab(engine: engine)
                .tabItem { Text("Settings") }
        }
        .frame(minWidth: 720, minHeight: 640)
    }

    // MARK: - Gestures tab (unchanged content, just re-parented under the TabView above)

    private var gesturesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(Self.tierOrder, id: \.self) { tier in
                    section(for: tier)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .overlay { detailOverlay }
        .onExitCommand {
            if expandedGesture != nil { collapse() }
        }
    }

    // MARK: - Sections

    private func section(for tier: GestureTier) -> some View {
        let entries = GestureCatalog.entries(in: tier)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(for: tier)

            LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AppearingCard(
                        index: index,
                        hasAppearedBefore: appearedIDs.contains(entry.id),
                        reduceMotion: reduceMotion,
                        markAppeared: { appearedIDs.insert(entry.id) }
                    ) {
                        SpecimenCard(
                            entry: entry,
                            store: store,
                            namespace: cardNamespace,
                            isExpanded: expandedGesture == entry.id,
                            onTap: { expand(entry.id) }
                        )
                    }
                }
            }
        }
    }

    private func sectionHeader(for tier: GestureTier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tierDisplayName(tier))
                .font(.title3.weight(.semibold))
            if let note = GestureCatalog.tierEditorial[tier] {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tierDisplayName(_ tier: GestureTier) -> String {
        switch tier {
        case .workhorse: "Workhorses"
        case .occasional: "Occasional"
        case .deliberate: "Deliberate"
        }
    }

    // MARK: - Detail overlay

    @ViewBuilder
    private var detailOverlay: some View {
        if let expandedGesture {
            let entry = GestureCatalog.entry(for: expandedGesture)
            ZStack {
                // The scrim: the grid dims slightly behind the expanded card, via material — never
                // an opaque black slab (spec §4.4).
                Rectangle()
                    .fill(.thinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { collapse() }

                CardDetailView(
                    entry: entry,
                    store: store,
                    engine: engine,
                    namespace: cardNamespace,
                    onDone: collapse
                )
                .padding(32)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Expand / collapse

    private func expand(_ id: GestureID) {
        withAnimation(TacitMotion.standardUI) {
            expandedGesture = id
        }
    }

    private func collapse() {
        withAnimation(TacitMotion.standardUI) {
            expandedGesture = nil
        }
    }
}

/// Wraps one grid cell with the first-appearance stagger (spec §4 motion table, "Card grid first
/// appearance"): opacity 0→1 + translateY 8→0 on `TacitMotion.cardAppear` (200 ms ease-out), delayed
/// `30 ms × index` capped at 300 ms. Reduce Motion drops the stagger delay (all cards fade
/// together, no travel) but keeps the fade itself.
private struct AppearingCard<Content: View>: View {
    var index: Int
    var hasAppearedBefore: Bool
    var reduceMotion: Bool
    var markAppeared: () -> Void
    var content: Content

    init(
        index: Int,
        hasAppearedBefore: Bool,
        reduceMotion: Bool,
        markAppeared: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.index = index
        self.hasAppearedBefore = hasAppearedBefore
        self.reduceMotion = reduceMotion
        self.markAppeared = markAppeared
        self.content = content()
    }

    @State private var appeared = false

    var body: some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                guard !hasAppearedBefore else {
                    appeared = true
                    return
                }
                markAppeared()
                let delay = reduceMotion ? 0 : min(Double(index) * 0.03, 0.3)
                withAnimation(TacitMotion.cardAppear.delay(delay)) {
                    appeared = true
                }
            }
    }
}
