import SwiftUI

struct JSONTextView: View {
    let text: String
    let isLoading: Bool
    let status: String?
    var onCopy: () -> Void

    @State private var highlighted: AttributedString?

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
        DispatchQueue.global(qos: .userInitiated).async {
            let result = JSONSyntaxHighlighter.highlight(text)
            DispatchQueue.main.async {
                self.highlighted = result
            }
        }
    }
}