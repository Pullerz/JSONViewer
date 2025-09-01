import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // Try to use an idle window if available
            if let vm = WindowRegistry.shared.firstIdleViewModel() {
                DispatchQueue.main.async {
                    vm.loadFile(url: url)
                }
            } else {
                // Create a new window and load the URL shortly after
                NSApp.sendAction(#selector(NSApplication.newWindow(_:)), to: nil, from: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let vm = WindowRegistry.shared.firstIdleViewModel() {
                        vm.loadFile(url: url)
                    }
                }
            }
        }
    }
}
#endif