import SwiftUI
import Foundation

@MainActor
final class TabsViewModel: ObservableObject {
    @Published var tabs: [AppViewModel]
    @Published var selectedIndex: Int

    init() {
        let initial = AppViewModel()
        self.tabs = [initial]
        self.selectedIndex = 0
    }

    var selected: AppViewModel {
        tabs[selectedIndex]
    }

    @discardableResult
    func newTab() -> AppViewModel {
        let vm = AppViewModel()
        tabs.append(vm)
        selectedIndex = tabs.count - 1
        return vm
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            _ = newTab()
        } else if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
    }

    var titles: [String] {
        tabs.map { $0.fileURL?.lastPathComponent ?? "Untitled" }
    }
}