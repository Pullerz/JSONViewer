import SwiftUI

struct JSONTextView: View {
    let text: String
    let isLoading: Bool
    let status: String?
    var onCopy: () -> Void

    @State private var highlighted: AttributedString?
    @State private var highlightTask: Task<Void, Never>?
    private let highlightLimit = 250_000 // bytes

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
            }

            if text.isEmpty && !isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(status ?? "Ready")
                        .font(.headline)
                    Text("Open a file or paste JSON/JSONL to get started.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let isLarge = text.utf8.count > highlightLimit
                Group {
                    if isLarge {
                        // Use performant AppKit text view for large content
                        #if os(macOS)
                        CodeTextView(text: text)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        #else
                        ScrollView {
                            Text(text)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        #endif
                    } else {
                        ScrollView {
                            Group {
                                if let highlighted {
                                    Text(highlighted)
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    Text(text)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .onAppear { updateHighlight() }
                        .onChange(of: text) { _ in updateHighlight() }
                    }
                }
            }

            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .padding(8)
            .help("Copy displayed text")
        }
    }

    private func updateHighlight() {
        highlightTask?.cancel()
        let size = text.utf8.count
        if size > highlightLimit {
            highlighted = nil
            return
        }
        let currentText = text
        let limit = highlightLimit
        highlightTask = Task.detached(priority: .userInitiated) {
            let result = JSONSyntaxHighlighter.highlight(currentText, limit: limit)
            await MainActor.run {
                self.highlighted = result
            }
        }
    }
}