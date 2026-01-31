import SwiftUI

struct SidebarRowView: View {
    @ObservedObject var viewModel: AppViewModel
    let id: Int

    @State private var previewText: String = "Loading…"
    // Guards against async preview callbacks updating a cell after it's been reused for another id.
    @State private var requestToken = UUID()
    // Task for debounced preview request - cancelled if row scrolls away before firing
    @State private var previewTask: Task<Void, Never>?

    private func requestPreview() {
        // Invalidate any in-flight callback for a previous id
        let token = UUID()
        requestToken = token
        previewText = "Loading…"

        // Cancel any pending debounced request
        previewTask?.cancel()

        // Debounce the preview request to skip rows that scroll by quickly.
        // This dramatically reduces FileHandle operations during fast scrolling.
        previewTask = Task {
            // Short delay - if user is scrolling fast, this row will disappear
            // before the delay completes and the request will be cancelled
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms

            // Check if still valid after delay
            guard !Task.isCancelled, token == requestToken else { return }

            viewModel.preview(for: id) { text in
                // Apply only if this response corresponds to the most recent request for this cell
                if token == requestToken {
                    previewText = text
                }
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
            // Cancel pending request and invalidate callbacks as the cell is leaving the screen
            previewTask?.cancel()
            previewTask = nil
            requestToken = UUID()
        }
    }
}