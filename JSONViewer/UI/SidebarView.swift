import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var lastRowCount: Int = 0
    @State private var isAtBottom: Bool = false
    // Local search text so typing doesn't publish through AppViewModel each keystroke
    @State private var sidebarSearchLocal: String = ""
    @State private var sidebarSearchCommitDebounce: Task<Void, Never>? = nil

    private var filteredRows: [AppViewModel.JSONLRow] {
        if viewModel.searchText.isEmpty { return viewModel.jsonlRows }
        return viewModel.jsonlRows.filter { row in
            row.preview.localizedCaseInsensitiveContains(viewModel.searchText) || row.raw.localizedCaseInsensitiveContains(viewModel.searchText)
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

    var body: some View {
        VStack(spacing: 10) {
            // Styled, integrated search field matching tree viewer
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $sidebarSearchLocal)
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
            sidebarSearchLocal = viewModel.searchText
        }
        .onChange(of: sidebarSearchLocal) { newVal in
            // Debounce committing to the shared model to avoid global re-renders per keystroke
            sidebarSearchCommitDebounce?.cancel()
            sidebarSearchCommitDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                viewModel.searchText = newVal
            }
        }
        .onChange(of: viewModel.searchText) { _ in
            if sidebarSearchLocal != viewModel.searchText {
                sidebarSearchLocal = viewModel.searchText
            }
            if viewModel.jsonlIndex != nil {
                viewModel.runSidebarSearchDebounced()
            } else {
                viewModel.sidebarFilteredRowIDs = nil
            }
        }
        .onChange(of: viewModel.jsonlRowCount) { _ in
            if viewModel.jsonlIndex != nil && !viewModel.searchText.isEmpty {
                viewModel.runSidebarSearch()
            }
        }
        .onChange(of: viewModel.selectedRowID) { _ in
            Task { _ = await viewModel.updateTreeForSelectedRow() }
        }
    }
}