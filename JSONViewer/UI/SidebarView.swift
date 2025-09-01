import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel

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
    }
}