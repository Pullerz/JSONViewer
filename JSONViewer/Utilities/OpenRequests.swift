import Foundation

@MainActor
final class OpenRequests {
    static let shared = OpenRequests()
    private var queue: [URL] = []

    func add(_ urls: [URL]) {
        queue.append(contentsOf: urls)
    }

    var pendingCount: Int { queue.count }

    func deliverNext(to vm: AppViewModel) -> URL? {
        guard !queue.isEmpty else { return nil }
        let url = queue.removeFirst()
        vm.loadFile(url: url)
        return url
    }

    func drain(into vm: AppViewModel, openWindow: (String) -> Void) {
        // Try to fill the current VM first; if it's not idle, open a new window and let that VM drain.
        while !queue.isEmpty {
            if vm.mode == .none && vm.fileURL == nil {
                _ = deliverNext(to: vm)
            } else {
                openWindow("main")
                break
            }
        }
    }
}