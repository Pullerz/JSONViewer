import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct HostingWindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    final class Coordinator {
        var didProvideWindow = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window, context.coordinator.didProvideWindow == false {
                context.coordinator.didProvideWindow = true
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Provide the window only once to avoid state mutation during updates
        if let window = nsView.window, context.coordinator.didProvideWindow == false {
            context.coordinator.didProvideWindow = true
            callback(window)
        }
    }
}
#endif