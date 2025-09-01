import Foundation

final class WindowRegistry {
    static let shared = WindowRegistry()

    private var weakBoxes: [WeakBox] = []

    private struct WeakBox {
        weak var viewModel: AppViewModel?
    }

    func register(_ vm: AppViewModel) {
        cleanup()
        weakBoxes.append(WeakBox(viewModel: vm))
    }

    func unregister(_ vm: AppViewModel) {
        weakBoxes.removeAll { $0.viewModel === vm || $0.viewModel == nil }
    }

    func firstIdleViewModel() -> AppViewModel? {
        cleanup()
        return weakBoxes.compactMap { $0.viewModel }.first { $0.mode == .none && $0.fileURL == nil }
    }

    private func cleanup() {
        weakBoxes.removeAll { $0.viewModel == nil }
    }
}