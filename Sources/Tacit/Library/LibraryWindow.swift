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
    /// each card) because the card grid's row/column chunking (see `cardGrid(entries:)`) is
    /// recomputed whenever `contentWidth` changes (a window resize crossing a column-count
    /// breakpoint), which re-chunks entries into different rows and gives the outer `ForEach`
    /// fresh row identities — tearing down and rebuilding the `AppearingCard`s inside. Without
    /// this hoisted set, that rebuild would replay the "first appearance" stagger on resize;
    /// `AppearingCard` checks it in `onAppear` and skips straight to `appeared = true` when a
    /// card has already played its entrance once.
    @State private var appearedIDs: Set<GestureID> = []
    /// Measured width of the grid content (post-padding), used to eagerly chunk each tier's
    /// entries into fixed-width rows — see the crash postmortem on `cardGrid(entries:)` below.
    /// Seeded with the window's default content width (`720` minWidth − 24pt padding × 2) so the
    /// very first layout pass, before `GeometryReader` reports back, already renders roughly the
    /// right column count instead of collapsing to a single column and re-flowing a frame later.
    @State private var contentWidth: CGFloat = 720 - 2 * 24

    private static let tierOrder: [GestureTier] = [.workhorse, .occasional, .deliberate]
    private static let cardMinWidth: CGFloat = 200
    private static let gridSpacing: CGFloat = 16

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
            // Measures the grid's available width (post-padding) so `cardGrid(entries:)` can
            // chunk cards into fixed-width rows eagerly instead of relying on `LazyVGrid`'s
            // adaptive columns — see the crash postmortem there. A passive `.background` reader
            // (rather than making `GeometryReader` the container) so it never fights this
            // `VStack` for its own size.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in
                            contentWidth = newWidth
                        }
                }
            }
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
            cardGrid(entries: entries)
        }
    }

    /// Non-lazy stand-in for `LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))])`.
    ///
    /// Postmortem (2026-08-24 crash): `LazyVGrid` defers building each cell's content until
    /// SwiftUI actually needs to lay it out — and that can happen outside the normal main-actor
    /// render cycle. An Accessibility client (Wispr Flow, on its Fn hotkey) walked this window's
    /// accessibility tree; SwiftUICore resolved that walk down into the lazy grid's
    /// `ForEachChild.updateValue()` on a background `com.apple.root.default-qos.cooperative`
    /// thread, which invoked this file's `ForEach` content closure there. That closure captures
    /// `store` (@MainActor `MappingStore`), `expandedGesture`, `appearedIDs`, and `expand(_:)`
    /// (a `View` method, @MainActor in this SDK) — so building it off the main actor tripped a
    /// runtime isolation check (`_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail`,
    /// `EXC_BREAKPOINT`) and crashed the app.
    ///
    /// The fix is to never let a lazy container decide *when* the cell closures run: build every
    /// cell eagerly during `body`, which SwiftUI always evaluates on the main actor. With only
    /// ~23 cards total across all three tiers, eager construction is effectively free, so there's
    /// no real laziness being given up. Row/column chunking replicates `.adaptive(minimum:)`'s
    /// math by hand using the measured `contentWidth` (see `gesturesTab`).
    private func cardGrid(entries: [CatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: Self.gridSpacing) {
            ForEach(rows(for: entries), id: \.self) { row in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    ForEach(row, id: \.self) { index in
                        let entry = entries[index]
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
                        .frame(width: cardWidth, alignment: .topLeading)
                    }
                }
            }
        }
    }

    /// How many `cardMinWidth`-or-wider columns fit in the measured `contentWidth`, matching
    /// `GridItem(.adaptive(minimum:))`'s own column-count formula.
    private var columnCount: Int {
        max(1, Int((contentWidth + Self.gridSpacing) / (Self.cardMinWidth + Self.gridSpacing)))
    }

    /// Each column's width when `columnCount` columns evenly split `contentWidth`, matching what
    /// `.adaptive(minimum:)` would hand each cell.
    private var cardWidth: CGFloat {
        let totalSpacing = CGFloat(columnCount - 1) * Self.gridSpacing
        return max(Self.cardMinWidth, (contentWidth - totalSpacing) / CGFloat(columnCount))
    }

    /// Chunks `entries`' indices into rows of `columnCount`, preserving catalog order — the same
    /// left-to-right, top-to-bottom fill order `LazyVGrid` used.
    private func rows(for entries: [CatalogEntry]) -> [[Int]] {
        guard !entries.isEmpty else { return [] }
        return stride(from: 0, to: entries.count, by: columnCount).map { start in
            Array(start..<min(start + columnCount, entries.count))
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
