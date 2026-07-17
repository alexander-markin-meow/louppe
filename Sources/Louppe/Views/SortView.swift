import SwiftUI

/// The toolbar sort popover, styled after FilterView: pick a sort key and a
/// direction, and choose whether the visible list divides into groups.
/// It only reorders what's shown and never touches ratings.
struct SortView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Sort by") {
                keyRow("Date taken", .captureDate)
                keyRow("Name", .name)
                keyRow("Subfolder", .subfolder, disabled: store.availableSubfolders.count <= 1)
                keyRow("File type", .fileType)
                keyRow("Camera", .camera)
                keyRow("Lens", .lens)
                keyRow("Aperture", .aperture, disabled: store.apertureRange == nil)
                keyRow("Shutter speed", .shutterSpeed, disabled: store.shutterRange == nil)
                keyRow("ISO", .iso, disabled: store.isoRange == nil)
            }

            Divider()

            section("Order") {
                orderRow(store.sort.key.ascendingLabel, ascending: true)
                orderRow(store.sort.key.descendingLabel, ascending: false)
            }

            Divider()

            section("Groups") {
                Toggle("Divide into groups", isOn: $store.isGroupingEnabled)
                    .toggleStyle(.checkbox)
                    // Name sorting never divides: every file name is unique.
                    .disabled(store.sort.key == .name)
                    .opacity(store.sort.key == .name ? 0.4 : 1)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func keyRow(_ label: String, _ key: PhotoSort.Key, disabled: Bool = false) -> some View {
        checkRow(label, isSelected: store.sort.key == key, disabled: disabled) {
            store.sort.key = key
        }
    }

    private func orderRow(_ label: String, ascending: Bool) -> some View {
        checkRow(label, isSelected: store.sort.ascending == ascending, disabled: false) {
            store.sort.ascending = ascending
        }
    }

    /// A menu-like row: reserved checkmark column so labels stay aligned,
    /// whole width clickable.
    private func checkRow(
        _ label: String,
        isSelected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, alignment: .leading)
                    .opacity(isSelected ? 1 : 0)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
