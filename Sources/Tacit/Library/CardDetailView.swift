import SwiftUI
import TacitCore

/// The specimen card, grown (spec §5's "Card detail... expands from the card, context preserved,
/// no navigation push"). Shares `SpecimenCard`'s chrome and copy helpers so the same object reads
/// as itself at a larger size, not a different screen: same corner radius, same material fill,
/// same constellation (traveling via `matchedGeometryEffect`, larger), same metadata/binding
/// copy — plus the editorial paragraph, the action binder, and the perform-to-preview mount point.
struct CardDetailView: View {
    var entry: CatalogEntry
    @ObservedObject var store: MappingStore
    var engine: TacitEngine
    var namespace: Namespace.ID
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConstellationRenderer(
                    frame: entry.cannedFrame,
                    lineWidth: 1.5,
                    color: .primary,
                    fitToJoints: true
                )
                .tacitMatchedGeometry(
                    id: "\(entry.id.rawValue)-constellation",
                    in: namespace,
                    enabled: !reduceMotion
                )
                .frame(height: 160)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.displayName)
                        .font(.title2.weight(.semibold))

                    Text(SpecimenCopy.metadataLine(for: entry))
                        .font(.caption)
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)

                    bindingLine
                }

                if !entry.isReserved {
                    Toggle("Enabled", isOn: enabledBinding)
                        .toggleStyle(TacitToggleStyle())
                }

                Text(entry.editorial)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.5)

                actionBinderSection

                performToPreviewSection

                doneButton
            }
            .padding(20)
        }
        .frame(maxWidth: 440)
        .frame(minHeight: 320, maxHeight: 560)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .tacitMatchedGeometry(id: entry.id.rawValue, in: namespace, enabled: !reduceMotion)
        .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
    }

    // MARK: - Action binder (Task 18 mount point)

    /// Task 18 fills this region in with the real four-way action binder (spec §5: "keystroke
    /// recorder, app picker, URL field with validation, Shortcut picker"). Left as a clearly
    /// marked, disabled stub for now — this task only owns the container it lives in.
    private var actionBinderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTION")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // MARK: Task 18 mount point — action binder (keystroke / app / URL / Shortcut)
            Menu("Choose an action…") {}
                .disabled(true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    // MARK: - Perform-to-preview (Task 19 mount point)

    /// Task 19 fills this region in with a live camera strip + skeleton overlay driven by
    /// `engine.latestFrame`, lighting up when the user actually performs this gesture (spec §5:
    /// "teaching and testing in one move"). Left empty and clearly marked; `engine` is threaded
    /// through this view already so Task 19 has it in hand.
    private var performToPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRY IT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // MARK: Task 19 mount point — perform-to-preview (live skeleton, engine.latestFrame)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 72)
                .overlay {
                    Text("Perform-to-preview arrives later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Rows

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

    private var doneButton: some View {
        Button("Done", action: onDone)
            .buttonStyle(TacitButtonStyle())
            .keyboardShortcut(.defaultAction)
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
