import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppViewModel: ObservableObject {

    enum Mode {
        case none
        case json
        case jsonl
    }

    enum ContentPresentation: Hashable {
        case text
        case tree
    }

    struct JSONLRow: Identifiable, Hashable {
        let id: Int
        let preview: String
        let raw: String
        let pretty: String?
    }

    @Published var mode: Mode = .none
    @Published var presentation: ContentPresentation = .tree

    @Published var fileURL: URL?
    @Published var prettyJSON: String = ""

    // JSON tree
    @Published var currentTreeRoot: JSONTreeNode?
    @Published var inspectorPath: String = ""
    @Published var inspectorValueText: String = ""

    // Tree presentation state
    @Published var expandedPaths: Set<String> = []
    @Published var treeSearchQuery: String = ""
    @Published var treeFindFocusToken: Int = 0

    // JSONL (pasted)
    @Published var jsonlRows: [JSONLRow] = []

    // JSONL (file-backed)
    var jsonlIndex: JSONLIndex?
    @Published var jsonlRowCount: Int = 0
    private let previewCache = NSCache<NSNumber, NSString>()

    @Published var selectedRowID: Int?
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var searchText: String = ""
    @Published var indexingProgress: Double?

    // Work management
    private var currentComputeTask: Task<Void, Never>?
    private var fileWatcher: FileWatcher?
    private var fileChangeDebounce: Task<Void, Never>?

    var selectedRow: JSONLRow? {
        guard let id = selectedRowID else { return nil }
        return jsonlRows.first(where: { $0.id == id })
    }

    func clear() {
        mode = .none
        presentation = .tree
        fileURL = nil
        prettyJSON = ""
        currentTreeRoot = nil
        inspectorPath = ""
        inspectorValueText = ""
        expandedPaths.removeAll()
        treeSearchQuery = ""
        jsonlRows = []
        jsonlIndex = nil
        jsonlRowCount = 0
        selectedRowID = nil
        isLoading = false
        statusMessage = nil
        searchText = ""
        indexingProgress = nil
        previewCache.removeAllObjects()
        currentComputeTask?.cancel()
        currentComputeTask = nil
        fileChangeDebounce?.cancel()
        fileChangeDebounce = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    func handlePaste(text: String) {
        clear()
        Task {
            await loadFromPasted(text: text)
        }
    }

    private func loadFromPasted(text: String) async {
        isLoading = true
        defer { isLoading = false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[" {
            currentComputeTask?.cancel()
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let data = trimmed.data(using: .utf8) else { return }
                let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? (String(data: data, encoding: .utf8) ?? "")
                let tree = try? JSONTreeBuilder.build(from: data)
                await MainActor.run {
                    guard let self else { return }
                    self.prettyJSON = pretty
                    self.currentTreeRoot = tree
                    self.presentation = .tree
                    self.mode = .json
                    self.statusMessage = "Pasted JSON"
                }
            }
            return
        }

        // Treat as JSONL: do not pretty-print all lines to keep paste fast
        let rawLines = text.split(whereSeparator: \.isNewline).map(String.init)
        var rows: [JSONLRow] = []
        rows.reserveCapacity(min(1000, rawLines.count))
        var idx = 0
        for line in rawLines.prefix(1000) {
            let preview = String(line.prefix(160))
            rows.append(JSONLRow(id: idx, preview: preview, raw: String(line), pretty: nil))
            idx += 1
        }
        jsonlRows = rows
        mode = .jsonl
        statusMessage = "Pasted JSONL (\(rows.count) rows shown)"
        selectedRowID = rows.first?.id
        await updateTreeForSelectedRow()
    }

    func loadFile(url: URL) {
        clear()
        fileURL = url
        startWatchingFile(url)
        Task {
            await loadFromFile()
        }
    }

    private func loadFromFile() async {
        guard let url = fileURL else { return }
        isLoading = true
        defer { isLoading = false }

        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            currentComputeTask?.cancel()
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? (String(data: data, encoding: .utf8) ?? "")
                    let tree = try? JSONTreeBuilder.build(from: data)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.prettyJSON = pretty
                            self.currentTreeRoot = tree
                            self.presentation = .tree
                            self.mode = .json
                            self.statusMessage = "Loaded JSON (\(self.formattedByteCount(data.count)))"
                            if self.expandedPaths.isEmpty { self.expandedPaths.insert("") } // default expand root
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "Failed to load JSON"
                    }
                }
            }
            return
        }

        // JSONL path: build index in background for scalability
        mode = .jsonl
        statusMessage = "Indexing JSONL…"
        let index = JSONLIndex(url: url)
        jsonlIndex = index
        indexingProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try index.build(progress: { progress in
                    Task { @MainActor in
                        self?.indexingProgress = progress
                        self?.statusMessage = "Indexing… \(Int(progress * 100))%"
                    }
                }, onUpdate: { count in
                    Task { @MainActor in
                        guard let self else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.jsonlRowCount = count
                        }
                        if self.selectedRowID == nil && count > 0 {
                            self.selectedRowID = 0
                            Task { _ = await self.updateTreeForSelectedRow() }
                        } else if let sel = self.selectedRowID, sel < count {
                            // If the selected row becomes available during indexing, update view
                            Task { _ = await self.updateTreeForSelectedRow() }
                        }
                    }
                })
                await MainActor.run {
                    self?.statusMessage = "Indexed \(index.lineCount) rows"
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Failed to index JSONL"
                }
            }
        }
    }

    // MARK: - JSONL utility

    func preview(for row: Int, completion: @escaping (String) -> Void) {
        if let cached = previewCache.object(forKey: NSNumber(value: row)) {
            completion(cached as String)
            return
        }

        guard let index = jsonlIndex else {
            // Fallback to pasted rows array
            if let item = jsonlRows.first(where: { $0.id == row }) {
                completion(item.preview)
            } else {
                completion("")
            }
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let text = (try? index.readLine(at: row, maxBytes: 200)) ?? ""
            let preview = String(text.prefix(160))
            self.previewCache.setObject(preview as NSString, forKey: NSNumber(value: row))
            DispatchQueue.main.async {
                completion(preview)
            }
        }
    }

    @discardableResult
    func updateTreeForSelectedRow() async -> Bool {
        guard mode == .jsonl, let id = selectedRowID else { return false }

        currentComputeTask?.cancel()
        guard let index = jsonlIndex else {
            // Pasted JSONL
            guard let row = selectedRow else { return false }
            let raw = row.raw
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                let data = raw.data(using: .utf8) ?? Data()
                let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
                let tree = try? JSONTreeBuilder.build(from: data)
                await MainActor.run {
                    guard let self else { return }
                    self.prettyJSON = pretty
                    self.currentTreeRoot = tree
                    self.presentation = .tree
                }
            }
            return true
        }

        // File-backed: only proceed if line slice is available
        guard let _ = index.sliceRange(forLine: id) else {
            return false
        }

        currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let raw = (try? index.readLine(at: id, maxBytes: nil)) ?? ""
            let data = raw.data(using: .utf8) ?? Data()
            let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
            let tree = try? JSONTreeBuilder.build(from: data)
            await MainActor.run {
                guard let self else { return }
                self.prettyJSON = pretty
                self.currentTreeRoot = tree
                self.presentation = .tree
                if self.expandedPaths.isEmpty { self.expandedPaths.insert("") }
            }
        }
        return true
    }

    func didSelectTreeNode(_ node: JSONTreeNode) {
        inspectorPath = node.path.isEmpty ? "(root)" : node.path
        if let scalar = node.scalar {
            switch scalar {
            case .string(let s):
                inspectorValueText = s // unquoted
            case .number(let d):
                inspectorValueText = String(d)
            case .bool(let b):
                inspectorValueText = b ? "true" : "false"
            case .null:
                inspectorValueText = "null"
            }
        } else {
            inspectorValueText = node.asJSONString()
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        #endif
    }

    func copyDisplayedText() {
        #if os(macOS)
        let text: String
        switch mode {
        case .json:
            text = presentation == .text ? prettyJSON : (currentTreeRoot?.asJSONString() ?? prettyJSON)
        case .jsonl:
            text = presentation == .text ? prettyJSON : (currentTreeRoot?.asJSONString() ?? prettyJSON)
        case .none:
            text = ""
        }
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #endif
    }

    private func startWatchingFile(_ url: URL) {
        fileWatcher?.cancel()
        fileWatcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in
                self?.debouncedFileChanged()
            }
        }
    }

    private func debouncedFileChanged() {
        fileChangeDebounce?.cancel()
        fileChangeDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms debounce
            await handleFileChanged()
        }
    }

    private func handleFileChanged() async {
        guard let url = fileURL else { return }
        switch mode {
        case .json:
            currentComputeTask?.cancel()
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? (String(data: data, encoding: .utf8) ?? "")
                    let tree = try? JSONTreeBuilder.build(from: data)
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            self.prettyJSON = pretty
                            self.currentTreeRoot = tree
                        }
                        // If inspector path refers to a node, refresh its value too
                        self.refreshInspectorFromCurrentPath()
                    }
                } catch {
                    // Ignore transient errors during writes
                }
            }
        case .jsonl:
            guard let index = jsonlIndex else { return }
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try index.refresh(progress: { _ in }, onUpdate: { count in
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                self?.jsonlRowCount = count
                            }
                        }
                    })
                    await MainActor.run {
                        // Rebuild current row view if one is selected
                        Task { _ = await self?.updateTreeForSelectedRow() }
                    }
                } catch {
                    // ignore transient errors
                }
            }
        case .none:
            break
        }
    }

    private func refreshInspectorFromCurrentPath() {
        guard !inspectorPath.isEmpty, let root = currentTreeRoot else { return }
        if let node = root.find(byPath: inspectorPath == "(root)" ? "" : inspectorPath) {
            didSelectTreeNode(node) // will set value text without quotes for strings
        }
    }

    func expandAll() {
        guard let root = currentTreeRoot else { return }
        var set: Set<String> = []
        func collect(_ node: JSONTreeNode) {
            if node.children != nil {
                set.insert(node.path)
                node.children?.forEach(collect)
            }
        }
        collect(root)
        expandedPaths = set
    }

    func collapseAll() {
        expandedPaths.removeAll()
    }

    func focusTreeFind() {
        treeFindFocusToken &+= 1
    }

    func expandForSearchIfNeeded() {
        guard let root = currentTreeRoot else { return }
        let q = treeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let query = q.lowercased()
        var set = expandedPaths
        func traverse(_ node: JSONTreeNode, ancestors: [String]) {
            let match = node.displayKey.lowercased().contains(query) ||
                        node.previewValue.lowercased().contains(query) ||
                        node.path.lowercased().contains(query)
            if match {
                for a in ancestors { set.insert(a) }
            }
            if let children = node.children {
                let newAncestors = ancestors + [node.path]
                for c in children {
                    traverse(c, ancestors: newAncestors)
                }
            }
        }
        traverse(root, ancestors: [])
        expandedPaths = set
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}