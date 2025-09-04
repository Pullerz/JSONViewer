import SwiftUI

struct SidebarRowView: View {
    @ObservedObject var viewModel: AppViewModel
    let id: Int

    @State private var previewText: String = "Loading…"
    // Guards against async preview callbacks updating a cell after it's been reused for another id.
    @State private var requestToken = UUID()

    private func requestPreview() {
        // Invalidate any in-flight callback for a previous id
        let token = UUID()
        requestToken = token
        previewText = "Loading…"
        viewModel.preview(for: id) { text in
            // Apply only if this response corresponds to the most recent request for this cell
            if token == requestToken {
                previewText = text
            }
        }
    }

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
            requestPreview()
        }
        .onDisappear {
            // Invalidate callbacks as the cell is leaving the screen
            requestToken = UUID()
        }
    }
}