import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            OpenRequests.shared.add(urls)
            while OpenRequests.shared.pendingCount > 0 {
                if let vm = WindowRegistry.shared.firstIdleViewModel() {
                    _ = OpenRequests.shared.deliverNext(to: vm)
                } else {
                    // Ask SwiftUI to open a new window; if the bridge isn't ready yet,
                    // AppShellView will drain the queue on appear.
                    OpenWindowBridge.shared.openWindowHandler?("main")
                    break
                }
            }
        }
    }

    // Some launch paths still deliver these legacy variants.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        application(sender, open: filenames.map { URL(fileURLWithPath: $0) })
    }
}
#endif