import SwiftUI

struct AIPreferences: View {
    @AppStorage("openai_api_key") private var apiKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI")
                .font(.system(size: 22, weight: .semibold))

            HStack(alignment: .center, spacing: 12) {
                Text("OpenAI API Key")
                    .frame(width: 120, alignment: .trailing)
                    .foregroundStyle(.secondary)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            Text("Stored locally. If empty, the app will fall back to the OPENAI_API_KEY environment variable. Required for AI mode.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(24)
    }
}