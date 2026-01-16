import SwiftUI

private struct JSONTreeRowComputation {
    static func nodeMatches(_ node: JSONTreeNode, query: String) -> Bool {
        if query.isEmpty { return true }
        let text = "\(node.displayKey) \(node.previewValue) \(node.path)".lowercased()
        return text.contains(query)
    }

    static func ancestorPathsForMatches(root: JSONTreeNode, query: String) -> Set<String> {
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

    static func buildRows(root: JSONTreeNode,
                          query: String,
                          expandedPaths: Set<String>) -> [(node: JSONTreeNode, depth: Int)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let autoExpand = ancestorPathsForMatches(root: root, query: q)
        let expansionSet = expandedPaths.union(autoExpand)

        var rows: [(JSONTreeNode, Int)] = []
        func walk(_ node: JSONTreeNode, depth: Int) {
            rows.append((node, depth))
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
            return rows.filter { item in
                nodeMatches(item.0, query: q) || autoExpand.contains(item.0.path)
            }
        }
    }
}

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

    // MARK: - Row computation (off-main-thread)

    private func recomputeRows(searchDriven: Bool) {
        guard let root else {
            cachedRows = []
            lastRootId = nil
            return
        }

        let query = viewModel.treeSearchQuery
        let expanded = viewModel.expandedPaths

        #if DEBUG
        let rootIdDescription = root.id.uuidString
        print("[Tree] recomputeRows(searchDriven: \(searchDriven)) start, rootId=\(rootIdDescription), selectedRowID=\(String(describing: viewModel.selectedRowID))")
        #endif

        queryDebounce?.cancel()
        queryDebounce = Task.detached(priority: .userInitiated) {
            if searchDriven {
                // Small debounce so rapid typing doesn't recompute the whole tree on every keystroke.
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if Task.isCancelled { return }

            let tuples = JSONTreeRowComputation.buildRows(root: root, query: query, expandedPaths: expanded)
            if Task.isCancelled { return }

            await MainActor.run {
                cachedRows = tuples.map { RowItem(node: $0.node, depth: $0.depth) }
                lastRootId = root.id
                lastQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                lastExpanded = expanded
                #if DEBUG
                let firstPreview: String
                if let first = cachedRows.first {
                    firstPreview = "\(first.node.displayKey): \(String(first.node.previewValue.prefix(80)))"
                } else {
                    firstPreview = "<no rows>"
                }
                print("[Tree] recomputeRows applied, rootId=\(root.id.uuidString), rows=\(cachedRows.count), first=\(firstPreview)")
                #endif
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
                                .onSubmit {
                                    // Release focus on Enter
                                    findFocused = false
                                }
                        }
                        #if os(macOS)
                        .onExitCommand {
                            // Release focus on Escape
                            findFocused = false
                        }
                        #endif
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
                    // Recompute rows when the shared query changes (debounced, off-main-thread).
                    recomputeRows(searchDriven: true)
                }
                .onChange(of: viewModel.expandedPaths) { _ in
                    recomputeRows(searchDriven: false)
                }
                .onAppear {
                    // Do not focus search by default
                    findFocused = false
                    // Build rows for current query
                    #if DEBUG
                    if let r = root {
                        print("[Tree] onAppear with rootId=\\(r.id.uuidString), selectedRowID=\\(String(describing: viewModel.selectedRowID))")
                    } else {
                        print("[Tree] onAppear with no root")
                    }
                    #endif
                    recomputeRows(searchDriven: false)
                }
                .onDisappear {
                    queryDebounce?.cancel()
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
        HStack(alignment: .center, spacing: 4) {
            // Indentation
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            // Chevron toggle with large hit area
            if node.children != nil {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Align with disclosure space
                Color.clear.frame(width: 28, height: 1)
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