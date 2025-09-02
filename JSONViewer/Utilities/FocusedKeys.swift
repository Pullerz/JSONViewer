import SwiftUI

struct AppViewModelFocusedKey: FocusedValueKey {
    typealias Value = AppViewModel
}

extension FocusedValues {
    var appViewModel: AppViewModel? {
        get { self[AppViewModelFocusedKey.self] }
        set { self[AppViewModelFocusedKey.self] = newValue }
    }
}