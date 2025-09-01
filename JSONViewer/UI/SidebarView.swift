import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var previews: [Int: String] = [:]

    private var filteredRows: [AppViewModel.JSONLRow] {
        if viewModel.searchText.isEmpty { return viewModel.jsonlRows }
        return viewModel.jsonlRows.filter { row in
            row.preview.localizedCaseInsensitiveContains(viewModel.searchText) || row.raw.localizedCaseInsensitiveContains(viewModel.searchText)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search", text: $viewModel.searchText)
            }
            .textFieldStyle(.roundedBorder)
            .padding([.top, .horizontal])

            Group {
                switch viewModel.mode {
                case .jsonl:
                    if let index = viewModel.jsonlIndex {
                        // File-backed, virtualized list
                        List(selection: $viewModel.selectedRowID) {
                            ForEach(0..<viewModel.jsonlRowCount, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Row \(i)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Text(previews[i] ?? "Loading…")
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(2)
                                }
                                .task(id: i) {
                                    if previews[i] == nil {
                                        viewModel.preview(for: i) { text in
                                            previews[i] = text
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if let progress = viewModel.indexingProgress, progress < 1.0 {
                                ProgressView(value: progress)
                                    .padding(.horizontal)
                                    .padding(.bottom, 6)
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
                            }
                        }
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
        .onChange(of: viewModel.selectedRowID) { _ in
            Task { _ = await viewModel.updateTreeForSelectedRow() }
        }
    }
}