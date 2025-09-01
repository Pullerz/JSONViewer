import SwiftUI

struct JSONTreeView: View {
    @ObservedObject var viewModel: AppViewModel
    let root: JSONTreeNode?
    var onSelect: (JSONTreeNode) -> Void
    @FocusState private var findFocused: Bool

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

    private var visibleRows: [RowItem] {
        guard let root else { return [] }
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
            return rows
        } else {
            // Filter out branches unrelated to matches, but keep ancestors (autoExpand)
            return rows.filter { item in
                nodeMatches(item.node, query: q) || autoExpand.contains(item.node.path)
            }
        }
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

                        HStack(spacing: 8) {
                            Button("Expand All") {
                                viewModel.expandAll()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.accentColor)

                            Button("Collapse All") {
                                viewModel.collapseAll()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleRows) { item in
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
                .onAppear {
                    // Do not focus search by default
                    findFocused = false
                    // Ensure root has an entry to control expansion
                    if viewModel.expandedPaths.isEmpty {
                        viewModel.expandedPaths.insert("")
                    }
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