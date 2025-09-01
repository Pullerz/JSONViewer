import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppCommands: Commands {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some Commands {
        CommandGroup(before: .pasteboard) {
            Button("Paste JSON") {
                pasteFromClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Open…") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        if let text = NSPasteboard.general.string(forType: .string) {
            viewModel.handlePaste(text: text)
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
}