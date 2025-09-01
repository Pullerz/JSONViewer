import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppShellView: View {
    @StateObject private var viewModel = AppViewModel()
        #if os(macOS)
    @State private var nsWindow: NSWindow?
    #endif
    @State private var isInspectorVisible: Bool = false
    @Environment(\.openWindow) private var openWindow

    private var displayText: String {
        viewModel.prettyJSON
    }

    private var windowTitle: String {
        viewModel.fileURL?.lastPathComponent ?? "Prism"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    switch viewModel.presentation {
                    case .text:
                        JSONTextView(text: displayText, isLoading: viewModel.isLoading, status: viewModel.statusMessage) {
                            viewModel.copyDisplayedText()
                        }
                    case .tree:
                        JSONTreeView(viewModel: viewModel, root: viewModel.currentTreeRoot) { node in
                            viewModel.didSelectTreeNode(node)
                            withAnimation { isInspectorVisible = true }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.mode)
                .animation(.easeInOut(duration: 0.2), value: viewModel.presentation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isInspectorVisible {
                    Divider()
                    InspectorView(viewModel: viewModel)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 520)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 680, max: .infinity)
            .navigationTitle(viewModel.fileURL?.lastPathComponent ?? "Prism")
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

                Button {
                    withAnimation {
                        isInspectorVisible.toggle()
                    }
                } label: {
                    Label(isInspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(isInspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")

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
        .onDrop(of: [UTType.json.identifier, UTType.plainText.identifier, UTType.fileURL.identifier, UTType.url.identifier, UTType.item.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .frame(minWidth: 1024, minHeight: 700)
        .focusedSceneValue(\.appViewModel, viewModel)
        .onChange(of: viewModel.inspectorPath) { newPath in
            if !newPath.isEmpty {
                withAnimation { isInspectorVisible = true }
            }
        }
        #if os(macOS)
        .background(HostingWindowAccessor { win in
            nsWindow = win
            // Show native title (file name when available)
            nsWindow?.titleVisibility = .visible
            nsWindow?.representedURL = viewModel.fileURL
            nsWindow?.title = viewModel.fileURL?.lastPathComponent ?? "Prism"
            // Ensure no text field is focused by default so Cmd+V pastes into the viewer.
            nsWindow?.makeFirstResponder(nil)
            WindowRegistry.shared.register(viewModel)
        })
        .onAppear {
            OpenWindowBridge.shared.openWindowHandler = { id in
                openWindow(id: id)
            }
            // Drain any pending open requests queued by the AppDelegate (e.g., Dock drops).
            OpenRequests.shared.drain(into: viewModel) { id in
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
            nsWindow?.title = newURL?.lastPathComponent ?? "Prism"
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
        // Prefer file URLs (dragging from Finder)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
               provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
               provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            DispatchQueue.main.async {
                                viewModel.loadFile(url: url)
                            }
                        }
                    }
                    return true
                } else {
                    // As a fallback, ask for a file representation and convert to URL
                    _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _, _ in
                        if let url {
                            DispatchQueue.main.async {
                                viewModel.loadFile(url: url)
                            }
                        }
                    }
                    return true
                }
            }
        }
        // Fallback: raw text drop
        for provider in providers {
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
        }
        return false
    }

    private func revealInFinder(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}