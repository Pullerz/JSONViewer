import SwiftUI

struct InspectorView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                Button {
                    #if os(macOS)
                    if !viewModel.inspectorValueText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.inspectorValueText, forType: .string)
                    }
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .help("Copy value")
            }

            if viewModel.inspectorPath.isEmpty {
                Text("Click a value in the main view to inspect it.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.inspectorPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        Text(viewModel.inspectorValueText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer()
            }
        }
        .padding()
    }
}