import SwiftUI

struct JSONTextView: View {
    let text: String
    let isLoading: Bool
    let status: String?
    var onCopy: () -> Void

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
}