import SwiftUI

struct InspectorView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch viewModel.mode {
            case .json:
                Text("Inspector")
                    .font(.headline)
                Text("Click a value to see details here. (Coming soon)")
                    .foregroundStyle(.secondary)
            case .jsonl:
                if let row = viewModel.selectedRow {
                    Text("Row \(row.id)")
                        .font(.headline)
                    Divider()
                    Text(row.pretty ?? row.raw)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("No Row Selected")
                        .font(.headline)
                    Text("Select a row in the sidebar.")
                        .foregroundStyle(.secondary)
                }
            case .none:
                Text("Inspector")
                    .font(.headline)
                Text("Open or paste a document.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}