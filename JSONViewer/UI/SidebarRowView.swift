import SwiftUI

struct SidebarRowView: View {
    @ObservedObject var viewModel: AppViewModel
    let id: Int

    @State private var previewText: String = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Row \(id)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(previewText)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onAppear {
            viewModel.preview(for: id) { text in
                // Only update if still showing the same id (cells may be reused)
                previewText = text
            }
        }
    }
}