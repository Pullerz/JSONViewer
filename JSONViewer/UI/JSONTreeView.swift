import SwiftUI

struct JSONTreeView: View {
    @ObservedObject var viewModel: AppViewModel
    let root: JSONTreeNode?
    var onSelect: (JSONTreeNode) -> Void
    @FocusState private var findFocused: Bool

    // Cache heavy rows computation so arbitrary AppViewModel changes (e.g. typing in AI/JQ)
    // don't trigger an expensive full-tree traversal on every keystroke.
    @State private var cachedRows: [RowItem] = []
    @State private var lastRootId: UUID? = nil
    @State private var lastQuery: String = ""
    @State private var lastExpanded: Set<String> = []
    @State private var queryDebounce: Task<Void, Never>? = nil

    private struct RowItem: Identifiable, Hashable {
        let id: UUID = UUID()
        let node: JSONTreeNode
        let depth: Int
    }

    private func nodeMatches(_ node: JSONTreeNode, query: String) -> Bool {
        if query.isEmpty { return true }
        let text = "\(node.displayKey) \(node.previewValue) \(node.path)".lowercased()
        return text.contains(query)
    }

    private func ancestorPathsForMatches(root: JSONTreeNode, query: String) -> Set<String> {
        var result: Set<String> = []
        guard !query.isEmpty else { return result }
        let q = query.lowercased()

        func dfs(_ node: JSONTreeNode, ancestors: [String]) -> Bool {
            var matched = nodeMatches(node, query: q)
            if let children = node.children {
                let newAncestors = ancestors + [node.path]
                for c in children {
                    let childMatched = dfs(c, ancestors: newAncestors)
                    matched = matched || childMatched
                }
            }
            if matched {
                for p in ancestors { result.insert(p) }
            }
            return matched
        }

        _ = dfs(root, ancestors: [])
        return result
    }

    private func recomputeRows() {
        guard let root else {
            cachedRows = []
            lastRootId = nil
            return
        }
        let q = viewModel.treeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let autoExpand = ancestorPathsForMatches(root: root, query: q)
        let expansionSet = viewModel.expandedPaths.union(autoExpand)

        var rows: [RowItem] = []
        func walk(_ node: JSONTreeNode, depth: Int) {
            rows.append(RowItem(node: node, depth: depth))
            if let children = node.children, expansionSet.contains(node.path) {
                for c in children {
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)

        if q.isEmpty {
            cachedRows = rows
        } else {
            cachedRows = rows.filter { item in
                nodeMatches(item.node, query: q) || autoExpand.contains(item.node.path)
            }
        }
        lastRootId = root.id
        lastQuery = q
        lastExpanded = viewModel.expandedPaths
    }

    private func toggle(_ node: JSONTreeNode) {
        if viewModel.expandedPaths.contains(node.path) {
            viewModel.expandedPaths.remove(node.path)
        } else {
            viewModel.expandedPaths.insert(node.path)
        }
    }

    var body: some View {
        Group {
            if let _ = root {
                VStack(spacing: 10) {
                    // In-view toolbar with find + expand/collapse, styled as a capsule group
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Find in tree", text: $viewModel.treeSearchQuery)
                                .textFieldStyle(.plain)
                                .focused($findFocused)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                        Spacer(minLength: 8)

                        // Compact icon group for expand/collapse (explicitly sized; won't collapse under layout compression)
                        HStack(spacing: 10) {
                            Button {
                                viewModel.expandAll()
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("Expand All")

                            Button {
                                viewModel.collapseAll()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("Collapse All")
                        }
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(cachedRows) { item in
                                JSONTreeRowView(
                                    node: item.node,
                                    depth: item.depth,
                                    isExpanded: viewModel.expandedPaths.contains(item.node.path),
                                    onToggle: { toggle(item.node) }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(item.node)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .padding(.top, 2)
                    }
                }
                .onChange(of: viewModel.treeFindFocusToken) { _ in
                    findFocused = true
                }
                .onChange(of: viewModel.treeSearchQuery) { _ in
                    // Debounce heavy search recomputation to keep typing fluid on large trees.
                    queryDebounce?.cancel()
                    queryDebounce = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        recomputeRows()
                    }
                }
                .onChange(of: viewModel.expandedPaths) { _ in
                    recomputeRows()
                }
                .onChange(of: root?.id) { _ in
                    recomputeRows()
                }
                .onAppear {
                    // Do not focus search by default
                    findFocused = false
                    // Ensure root has an entry to control expansion
                    if viewModel.expandedPaths.isEmpty {
                        viewModel.expandedPaths.insert("")
                    }
                    recomputeRows()
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No content")
                        .font(.headline)
                    Text("Open or paste JSON to view structure.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct JSONTreeRowView: View {
    let node: JSONTreeNode
    let depth: Int
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Indentation
            Color.clear.frame(width: CGFloat(depth) * 14, height: 0)

            if node.children != nil {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: []) // allows quick toggle when focused
            } else {
                // Align with disclosure space
                Color.clear.frame(width: 14, height: 0)
            }

            Text(node.displayKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .leading)

            if node.isLeaf {
                Text(node.previewValue)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(node.children?.first?.key?.hasPrefix("[") == true ? "[…]" : "{…}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}