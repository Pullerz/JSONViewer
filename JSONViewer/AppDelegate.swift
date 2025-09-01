import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                if let vm = WindowRegistry.shared.firstIdleViewModel() {
                    vm.loadFile(url: url)
                } else {
                    // Ask SwiftUI to open a new window for our WindowGroup
                    OpenWindowBridge.shared.openWindowHandler?("main")
                    // After the scene paints, load into the new idle VM
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        Task { @MainActor in
                            if let vm = WindowRegistry.shared.firstIdleViewModel() {
                                vm.loadFile(url: url)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif