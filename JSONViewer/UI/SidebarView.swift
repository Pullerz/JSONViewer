import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var lastRowCount: Int = 0
    @State private var isAtBottom: Bool = false
    @State private var showFieldFilters: Bool = true

    private var filteredRows: [AppViewModel.JSONLRow] {
        // Pasted-mode filtering
        let q = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = viewModel.selectedFieldFilters
        return viewModel.jsonlRows.filter { row in
            // Text match
            let textOK = q.isEmpty || row.preview.localizedCaseInsensitiveContains(q) || row.raw.localizedCaseInsensitiveContains(q)
            if !textOK { return false }
            if selected.isEmpty { return true }
            guard let data = row.raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Fallback heuristic
                for k in selected {
                    if row.raw.range(of: "\"\(k)\":") == nil { return false }
                }
                return true
            }
            for k in selected {
                if obj[k] == nil { return false }
            }
            return true
        }
    }

    private func relativeUpdatedString() -> String? {
        guard let date = viewModel.lastUpdatedAt else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func footerPill() -> some View {
        let count = (viewModel.jsonlIndex != nil) ? viewModel.jsonlRowCount : viewModel.jsonlRows.count
        HStack(spacing: 6) {
            Text("\(count) rows")
            if let rel = relativeUpdatedString() {
                Text("· updated \(rel)")
            }
        }
        .font(.caption)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func fieldFilterView() -> some View {
        if viewModel.mode == .jsonl {
            let items = viewModel.availableFields.sorted { a, b in
                if a.value == b.value { return a.key < b.key }
                return a.value > b.value
            }
            if !items.isEmpty {
                DisclosureGroup(isExpanded: $showFieldFilters) {
                    // Limit height to keep sidebar compact
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items, id: \.key) { kv in
                                let key = kv.key
                                let count = kv.value
                                Toggle(isOn: Binding<Bool>(
                                    get: { viewModel.selectedFieldFilters.contains(key) },
                                    set: { on in
                                        if on { viewModel.selectedFieldFilters.insert(key) }
                                        else { viewModel.selectedFieldFilters.remove(key) }
                                        // Trigger filtering for file-backed
                                        if viewModel.jsonlIndex != nil {
                                            viewModel.runSidebarFilterDebounced()
                                        }
                                    }
                                )) {
                                    HStack {
                                        Text(key)
                                        Spacer()
                                        Text("\(count)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 160)
                } label: {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("Filter by fields")
                        Spacer()
                        if !viewModel.selectedFieldFilters.isEmpty {
                            Text("\(viewModel.selectedFieldFilters.count) selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Styled, integrated search field matching tree viewer
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Field filters (dynamic)
            fieldFilterView()

            Group {
                switch viewModel.mode {
                case .jsonl:
                    if viewModel.jsonlIndex != nil {
                        // File-backed, virtualized list
                        ScrollViewReader { proxy in
                            List(selection: $viewModel.selectedRowID) {
                                if let filtered = viewModel.sidebarFilteredRowIDs {
                                    ForEach(filtered, id: \.self) { i in
                                        SidebarRowView(viewModel: viewModel, id: i)
                                            .id(i)
                                            .onAppear {
                                                if let last = filtered.last, i == last { isAtBottom = true }
                                            }
                                            .onDisappear {
                                                if let last = filtered.last, i == last { isAtBottom = false }
                                            }
                                    }
                                } else {
                                    ForEach(0..<viewModel.jsonlRowCount, id: \.self) { i in
                                        SidebarRowView(viewModel: viewModel, id: i)
                                            .id(i)
                                            .onAppear {
                                                if i == viewModel.jsonlRowCount - 1 { isAtBottom = true }
                                            }
                                            .onDisappear {
                                                if i == viewModel.jsonlRowCount - 1 { isAtBottom = false }
                                            }
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .onChange(of: viewModel.jsonlRowCount) { newCount in
                                // If user had last row selected, keep them pinned to bottom (only when not filtering)
                                if viewModel.sidebarFilteredRowIDs == nil {
                                    let shouldPin = viewModel.selectedRowID == lastRowCount - 1
                                    lastRowCount = newCount
                                    if shouldPin && newCount > 0 {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            VStack(spacing: 6) {
                                if let progress = viewModel.indexingProgress, progress < 1.0 {
                                    ProgressView(value: progress)
                                        .padding(.horizontal)
                                }
                                if !isAtBottom && (viewModel.jsonlRowCount > 0 || !viewModel.jsonlRows.isEmpty) {
                                    footerPill()
                                }
                            }
                        }
                    } else {
                        // Pasted JSONL (limited rows)
                        List(selection: $viewModel.selectedRowID) {
                            ForEach(filteredRows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Row \(row.id)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Text(row.preview)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onAppear {
                                    if let last = filteredRows.last?.id, row.id == last { isAtBottom = true }
                                }
                                .onDisappear {
                                    if let last = filteredRows.last?.id, row.id == last { isAtBottom = false }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .overlay(alignment: .bottom) { if !isAtBottom && !filteredRows.isEmpty { footerPill() } }
                    }
                case .json:
                    VStack(spacing: 6) {
                        Text("JSON Document")
                            .font(.headline)
                        Text("Use the right panel to copy or open a new file.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .none:
                    VStack(spacing: 6) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No Document")
                            .font(.headline)
                        Text("Open a file or paste JSON/JSONL to begin.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
        }
        .onAppear {
            lastRowCount = viewModel.jsonlRowCount
        }
        .onChange(of: viewModel.searchText) { _ in
            if viewModel.jsonlIndex != nil {
                viewModel.runSidebarFilterDebounced()
            } else {
                // Pasted mode uses local filtering; nothing to compute
            }
        }
        .onChange(of: viewModel.selectedFieldFilters) { _ in
            if viewModel.jsonlIndex != nil {
                viewModel.runSidebarFilterDebounced()
            }
        }
        .onChange(of: viewModel.jsonlRowCount) { _ in
            if viewModel.jsonlIndex != nil && (!viewModel.searchText.isEmpty || !viewModel.selectedFieldFilters.isEmpty) {
                // Re-run filter when new rows arrive, but debounce to avoid thrashing during indexing
                viewModel.runSidebarFilterDebounced()
            }
        }
        .onChange(of: viewModel.selectedRowID) { _ in
            Task { _ = await viewModel.updateTreeForSelectedRow() }
        }
    }
}