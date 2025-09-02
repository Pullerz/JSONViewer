import SwiftUI

struct PreviewFieldsPickerView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool

    @State private var candidates: [String] = []
    @State private var selected: Set<String> = []
    @State private var search: String = ""
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(16)
        .onAppear {
            selected = Set(viewModel.currentSidebarPreviewFields())
            Task {
                isLoading = true
                let paths = await viewModel.collectCandidatePreviewPaths()
                await MainActor.run {
                    self.candidates = paths
                    self.isLoading = false
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Row Preview Fields", systemImage: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose which JSON fields to show for each JSONL row in the sidebar.")
                .foregroundStyle(.secondary)
                .font(.callout)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter fields…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))

            if isLoading {
                VStack(alignment: .center) {
                    ProgressView().padding(.top, 24)
                    Text("Scanning document for fields…")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                Text("No fields found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                let filtered = filteredCandidates
                List {
                    ForEach(filtered, id: \.self) { path in
                        Toggle(isOn: Binding(
                            get: { selected.contains(path) },
                            set: { on in
                                if on { selected.insert(path) } else { selected.remove(path) }
                            })
                        ) {
                            Text(path.isEmpty ? "(root)" : path)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .frame(minHeight: 320)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                selected.removeAll()
            } label: {
                Label("Select None", systemImage: "minus.circle")
            }
            Button {
                selected.formUnion(filteredCandidates)
            } label: {
                Label("Select All Shown", systemImage: "checkmark.circle")
            }
            Spacer()
            Button {
                // Persist and refresh previews
                let list = candidates.filter { selected.contains($0) }
                viewModel.setSidebarPreviewFields(list)
                isPresented = false
            } label: {
                Text("Apply")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading)
        }
    }

    private var filteredCandidates: [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}