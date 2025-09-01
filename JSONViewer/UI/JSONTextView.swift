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
                VStack(spacing: 6) {
                    Text(status ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Nothing to display yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
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
}