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

    private var visibleRows: [RowItem] {
        guard let root else { return [] }
        var rows: [RowItem] = []
        func walk(_ node: JSONTreeNode, depth: Int) {
            rows.append(RowItem(node: node, depth: depth))
            if let children = node.children, viewModel.expandedPaths.contains(node.path) {
                for c in children {
                    walk(c, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        if viewModel.treeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rows
        } else {
            let q = viewModel.treeSearchQuery.lowercased()
            return rows.filter { item in
                let text = "\(item.node.displayKey) \(item.node.previewValue) \(item.node.path)".lowercased()
                return text.contains(q)
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
                VStack(spacing: 8) {
                    // In-view toolbar with find + expand/collapse, styled as a capsule group
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Find in tree", text: $viewModel.treeSearchQuery)
                                .textFieldStyle(.plain)
                                .focused($findFocused)
                                .onChange(of: viewModel.treeSearchQuery) { _ in
                                    // Defer expansion to next runloop to avoid state-during-update warnings
                                    DispatchQueue.main.async {
                                        viewModel.expandForSearchIfNeeded()
                                    }
                                }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                        Spacer(minLength: 6)

                        Button("Expand All") {
                            viewModel.expandAll()
                        }
                        .controlSize(.small)

                        Button("Collapse All") {
                            viewModel.collapseAll()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal)

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
                        .padding()
                    }
                }
                .onChange(of: viewModel.treeFindFocusToken) { _ in
                    findFocused = true
                }
                .onAppear {
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