import SwiftUI

struct CommandBarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case jq = "JQ"
        case ai = "AI"
        var id: String { rawValue }
    }

    @Binding var mode: Mode
    @Binding var text: String

    var placeholder: String
    var onRun: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 90)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .onSubmit { onRun() }

            Button(action: onRun) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
        .padding(.bottom, 10)
        .padding(.horizontal, 14)
    }
}