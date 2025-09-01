import SwiftUI

struct PreferencesView: View {
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            AppearancePreferences()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag(0)
        }
        .padding(.top, 8)
    }
}

private struct AppearancePreferences: View {
    @AppStorage("themePreference") private var themePreference: String = "system"

    private struct ThemeOption: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    private let options: [ThemeOption] = [
        .init(id: "system", title: "System", systemImage: "circle.lefthalf.filled"),
        .init(id: "light", title: "Light", systemImage: "sun.max"),
        .init(id: "dark", title: "Dark", systemImage: "moon")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.system(size: 22, weight: .semibold))

            HStack(alignment: .center, spacing: 12) {
                Text("Theme")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle(.secondary)

                Picker("Theme", selection: $themePreference) {
                    ForEach(options) { opt in
                        Label(opt.title, systemImage: opt.systemImage).tag(opt.id)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
            }

            Spacer()
        }
        .padding(24)
    }
}