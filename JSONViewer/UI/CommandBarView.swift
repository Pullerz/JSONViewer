import SwiftUI

struct CommandBarView: View {
    @Binding var text: String

    var placeholder: String
    var onRun: () -> Void
    var onResignFocus: (() -> Void)? = nil

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.system(size: 14, weight: .medium))

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($isTextFieldFocused)
                .onSubmit {
                    onRun()
                    // Release focus after submitting so user can interact with the rest of the app
                    isTextFieldFocused = false
                    onResignFocus?()
                }

            Button(action: {
                onRun()
                isTextFieldFocused = false
                onResignFocus?()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 10)
        .padding(.horizontal, 14)
        #if os(macOS)
        .onExitCommand {
            // Handle Escape key to release focus
            isTextFieldFocused = false
            onResignFocus?()
        }
        #endif
    }
}