import SwiftUI

/// The toolbar filter menu (shown as a popover): search across file metadata,
/// narrow to a day or date range, and pick which file types, cameras, and
/// lenses to show. Standard controls throughout — TextField, DatePicker, Toggle.
struct FilterView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search across filename, camera, lens, type, capture date.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name, camera, lens…", text: $store.filter.searchText)
                    .textFieldStyle(.plain)
                if !store.filter.searchText.isEmpty {
                    Button {
                        store.filter.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            Divider()

            // Date taken: one day (from == to) or a range.
            Toggle("Date taken", isOn: dateEnabledBinding)
                .font(.subheadline.weight(.semibold))
            if store.filter.dateEnabled {
                DatePicker(
                    "From",
                    selection: $store.filter.dateFrom,
                    in: dateFromLimits,
                    displayedComponents: .date
                )
                DatePicker(
                    "To",
                    selection: $store.filter.dateTo,
                    in: dateToLimits,
                    displayedComponents: .date
                )
            }

            Divider()

            // File types actually present in this folder.
            Text("File types")
                .font(.subheadline.weight(.semibold))
            ForEach(store.availableTypes, id: \.self) { type in
                Toggle(isOn: exclusionBinding(type, \.excludedTypes)) {
                    labeledCount(type, store.typeCounts[type, default: 0])
                }
            }

            // Camera / lens sections appear only when the folder actually
            // mixes more than one — a single value can't be filtered on.
            if store.availableCameras.count > 1 {
                Divider()
                Text("Camera")
                    .font(.subheadline.weight(.semibold))
                ForEach(store.availableCameras, id: \.self) { camera in
                    Toggle(isOn: exclusionBinding(camera, \.excludedCameras)) {
                        labeledCount(camera, store.cameraCounts[camera, default: 0])
                    }
                }
            }

            if store.availableLenses.count > 1 {
                Divider()
                Text("Lens")
                    .font(.subheadline.weight(.semibold))
                ForEach(store.availableLenses, id: \.self) { lens in
                    Toggle(isOn: exclusionBinding(lens, \.excludedLenses)) {
                        labeledCount(lens, store.lensCounts[lens, default: 0])
                    }
                }
            }

            Divider()

            HStack {
                Text("Showing \(store.visibleIndices.count) of \(store.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Reset") {
                    store.filter = PhotoFilter()
                }
                .disabled(!store.filter.isActive)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Bindings

    /// Turning the date filter on seeds From/To with the session's actual
    /// date span, so the pickers start somewhere meaningful.
    private var dateEnabledBinding: Binding<Bool> {
        Binding {
            store.filter.dateEnabled
        } set: { on in
            var f = store.filter
            f.dateEnabled = on
            if on, let range = store.captureDateRange {
                f.dateFrom = range.lowerBound
                f.dateTo = range.upperBound
            }
            store.filter = f
        }
    }

    /// Keep From ≤ To so an empty range can't be picked.
    private var dateFromLimits: ClosedRange<Date> {
        .distantPast...store.filter.dateTo
    }
    private var dateToLimits: ClosedRange<Date> {
        store.filter.dateFrom...Date.distantFuture
    }

    /// One binding shape for all three exclusion sets (types, cameras, lenses):
    /// the toggle is on when the label is *not* excluded.
    private func exclusionBinding(_ label: String, _ set: WritableKeyPath<PhotoFilter, Set<String>>) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: set].contains(label)
        } set: { on in
            if on {
                store.filter[keyPath: set].remove(label)
            } else {
                store.filter[keyPath: set].insert(label)
            }
        }
    }

    private func labeledCount(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
