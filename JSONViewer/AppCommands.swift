import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct AppCommands: Commands {
    @FocusedValue(\.appViewModel) var viewModel: AppViewModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open…") {
                openFile()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        // Provide default Paste (Cmd+V) that pastes JSON into the focused window when not editing text.
        CommandGroup(before: .pasteboard) {
            Button("Paste") {
                pasteFromClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(isTextInputFocused())
            
            Button("Paste JSON") {
                pasteFromClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }

    private func isTextInputFocused() -> Bool {
        #if os(macOS)
        if let window = NSApp.keyWindow, let responder = window.firstResponder {
            if responder is NSTextView { return true }
            if responder is NSTextField { return true }
            if let editor = window.fieldEditor(false, for: nil), responder === editor { return true }
        }
        #endif
        return false
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        guard let text = NSPasteboard.general.string(forType: .string), let vm = viewModel else { return }
        vm.handlePaste(text: text)
        #endif
    }

    private func openFile() {
        #if os(macOS)
        guard let vm = viewModel else { return }
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
                vm.loadFile(url: url)
            }
        }
        #endif
    }
}