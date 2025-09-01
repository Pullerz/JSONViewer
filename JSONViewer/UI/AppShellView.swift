import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppShellView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private var displayText: String {
        viewModel.prettyJSON
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            Group {
                switch viewModel.presentation {
                case .text:
                    JSONTextView(text: displayText, isLoading: viewModel.isLoading, status: viewModel.statusMessage) {
                        viewModel.copyDisplayedText()
                    }
                case .tree:
                    JSONTreeView(root: viewModel.currentTreeRoot) { node in
                        viewModel.didSelectTreeNode(node)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
            .animation(.easeInOut(duration: 0.2), value: viewModel.presentation)
            .navigationSplitViewColumnWidth(min: 420, ideal: 680, max: .infinity)
        } detail: {
            InspectorView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
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

                Picker("", selection: $viewModel.presentation) {
                    Image(systemName: "text.alignleft").tag(AppViewModel.ContentPresentation.text)
                    Image(systemName: "list.bullet.indent").tag(AppViewModel.ContentPresentation.tree)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)

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
        .frame(minWidth: 1024, minHeight: 700)
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