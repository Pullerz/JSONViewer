import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppShellView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    #if os(macOS)
    @State private var nsWindow: NSWindow?
    #endif
    @Environment(\.openWindow) private var openWindow

    private var displayText: String {
        viewModel.prettyJSON
    }

    private var windowTitle: String {
        viewModel.fileURL?.lastPathComponent ?? "JSONViewer"
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
                    JSONTreeView(viewModel: viewModel, root: viewModel.currentTreeRoot) { node in
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
                .help("Open JSON/JSONL… (⌘O)")

                Button {
                    pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Paste JSON/JSONL from clipboard (⌘V)")

                Picker("", selection: $viewModel.presentation) {
                    Image(systemName: "text.alignleft").tag(AppViewModel.ContentPresentation.text)
                    Image(systemName: "list.bullet.indent").tag(AppViewModel.ContentPresentation.tree)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Toggle between raw text and tree")

                

                if viewModel.fileURL != nil {
                    Button {
                        if let url = viewModel.fileURL { revealInFinder(url) }
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .help("Reveal file in Finder")
                }

                Button {
                    viewModel.clear()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .help("Clear current document")
            }
        }
        .onDrop(of: [UTType.json.identifier, UTType.plainText.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .frame(minWidth: 1024, minHeight: 700)
        .focusedSceneValue(\.appViewModel, viewModel)
        #if os(macOS)
        .background(HostingWindowAccessor { win in
            nsWindow = win
            // Apply initial title and proxy icon once the window is available
            nsWindow?.titleVisibility = .visible
            nsWindow?.representedURL = viewModel.fileURL
            nsWindow?.title = windowTitle
            // Ensure no text field is focused by default so Cmd+V pastes into the viewer.
            nsWindow?.makeFirstResponder(nil)
            WindowRegistry.shared.register(viewModel)
        })
        .onAppear {
            OpenWindowBridge.shared.openWindowHandler = { id in
                openWindow(id: id)
            }
            // Ensure no UI element steals focus on first launch so Cmd+V pastes into viewer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                nsWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            WindowRegistry.shared.unregister(viewModel)
        }
        .onChange(of: viewModel.fileURL) { newURL in
            // Keep title and proxy icon in sync with the current file
            nsWindow?.titleVisibility = .visible
            nsWindow?.representedURL = newURL
            nsWindow?.title = windowTitle
        }
        #endif
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

    private func revealInFinder(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}