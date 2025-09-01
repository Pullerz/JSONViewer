import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppShellView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private var displayText: String {
        switch viewModel.mode {
        case .json:
            return viewModel.prettyJSON
        case .jsonl:
            return viewModel.selectedRow?.pretty ?? viewModel.selectedRow?.raw ?? "Select a row to view its JSON."
        case .none:
            return "Open or paste JSON / JSONL to get started."
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
        } content: {
            JSONTextView(text: displayText, isLoading: viewModel.isLoading, status: viewModel.statusMessage) {
                viewModel.copyDisplayedText()
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
        } detail: {
            InspectorView(viewModel: viewModel)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openFile()
                } label: {
                    Label("Open", systemImage: "folder")
                }

                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }

                Button {
                    viewModel.clear()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        }
        .onDrop(of: [UTType.json.identifier, UTType.plainText.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func openFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.json]
        if let jsonl = UTType(filenameExtension: "jsonl") {
            types.append(jsonl)
        }
        types.append(.plainText)
        panel.allowedContentTypes = types
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadFile(url: url)
            }
        }
        #endif
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        if let text = NSPasteboard.general.string(forType: .string) {
            viewModel.handlePaste(text: text)
        }
        #endif
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        viewModel.loadFile(url: url)
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        viewModel.handlePaste(text: text)
                    }
                }
            }
            return true
        }
        return false
    }
}