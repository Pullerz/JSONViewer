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
    @Published var lastUpdatedAt: Date?

    // Command bar
    @Published var commandMode: CommandBarView.Mode = .jq
    @Published var commandText: String = ""
    @Published var aiStatus: String = ""

    // AI conversation
    struct AIMessage: Identifiable, Hashable {
        let id = UUID()
        let role: String // "user" | "assistant"
        let text: String
        let date: Date = Date()
    }
    @Published var aiMessages: [AIMessage] = []
    @Published var aiStreamingText: String? = nil
    @Published var aiIsStreaming: Bool = false
    private var aiStreamTask: Task<Void, Never>?

    // Sidebar (JSONL) search
    @Published var sidebarFilteredRowIDs: [Int]? = nil
    private var sidebarSearchTask: Task<Void, Never>?

    // Row preview fields preference change token (used by views to refresh preview tasks)
    @Published var previewFieldsChangeToken: Int = 0
    private var lastPreviewFieldsKey: String = ""

    // Work management
    private var currentComputeTask: Task<Void, Never>?
    private var fileWatcher: FileWatcher?
    private var fileChangeDebounce: Task<Void, Never>?
    #if os(macOS)
    private var securityScopedURL: URL?
    #endif

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
        lastPreviewFieldsKey = ""
        previewFieldsChangeToken = 0
        currentComputeTask?.cancel()
        currentComputeTask = nil
        fileChangeDebounce?.cancel()
        fileChangeDebounce = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        lastUpdatedAt = nil
        #if os(macOS)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        #endif
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
        lastUpdatedAt = Date()
        await updateTreeForSelectedRow()
    }

    func loadFile(url: URL) {
        clear()
        fileURL = url
        #if os(macOS)
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
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
                        self?.lastUpdatedAt = Date()
                    }
                }, onUpdate: { count in
                    Task { @MainActor in
                        guard let self else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.jsonlRowCount = count
                        }
                        self.lastUpdatedAt = Date()
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
                    self?.lastUpdatedAt = Date()
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
        // Resolve user preference for preview fields (comma-separated, optional dot-paths)
        let prefRaw = (UserDefaults.standard.string(forKey: "sidebarPreviewFields") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefKey = prefRaw.lowercased()

        // Invalidate cache when preference changes
        if prefKey != lastPreviewFieldsKey {
            lastPreviewFieldsKey = prefKey
            previewCache.removeAllObjects()
            previewFieldsChangeToken &+= 1
        }

        if let cached = previewCache.object(forKey: NSNumber(value: row)) {
            completion(cached as String)
            return
        }

        let fields: [String] = prefRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Pasted JSONL (no index)
        guard let index = jsonlIndex else {
            if let item = jsonlRows.first(where: { $0.id == row }) {
                if fields.isEmpty {
                    // Default behavior
                    let preview = item.preview
                    previewCache.setObject(preview as NSString, forKey: NSNumber(value: row))
                    completion(preview)
                } else {
                    DispatchQueue.global(qos: .utility).async {
                        let computed = Self.computePreview(fromRaw: item.raw, fields: fields)
                        let result = computed ?? String(item.raw.prefix(160))
                        self.previewCache.setObject(result as NSString, forKey: NSNumber(value: row))
                        DispatchQueue.main.async { completion(result) }
                    }
                }
            } else {
                completion("")
            }
            return
        }

        // File-backed JSONL
        DispatchQueue.global(qos: .utility).async {
            if fields.isEmpty {
                let text = (try? index.readLine(at: row, maxBytes: 200)) ?? ""
                let preview = String(text.prefix(160))
                self.previewCache.setObject(preview as NSString, forKey: NSNumber(value: row))
                DispatchQueue.main.async { completion(preview) }
            } else {
                let raw = (try? index.readLine(at: row, maxBytes: nil)) ?? ""
                let computed = Self.computePreview(fromRaw: raw, fields: fields)
                let result = computed ?? String(raw.prefix(160))
                self.previewCache.setObject(result as NSString, forKey: NSNumber(value: row))
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    // Build a preview string from specific fields in a JSON object.
    // - fields: comma-separated tokenized into an array; supports dot-paths and array indices.
    private static func computePreview(fromRaw raw: String, fields: [String]) -> String? {
        guard !fields.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [] ) else { return nil }
        var parts: [String] = []
        for f in fields {
            let path = f.split(separator: ".").map(String.init)
            if let v = valueForKeyPath(path, in: obj), let s = stringForPreviewValue(v) {
                parts.append(s)
            }
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }

    private static func valueForKeyPath(_ path: [String], in object: Any) -> Any? {
        var current: Any? = object
        for token in path {
            guard let c = current else { return nil }
            if let dict = c as? [String: Any] {
                current = dict[token]
            } else if let arr = c as? [Any], let idx = Int(token), idx >= 0, idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    private static func stringForPreviewValue(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        if value is NSNull { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let d = try? JSONSerialization.data(withJSONObject: value, options: []),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return nil
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
                            self?.lastUpdatedAt = Date()
                        }
                    })
                    await MainActor.run {
                        // Rebuild current row view if one is selected
                        Task { _ = await self?.updateTreeForSelectedRow() }
                        self?.lastUpdatedAt = Date()
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

    // MARK: - Sidebar filtering for file-backed JSONL

    func runSidebarSearch() {
        sidebarSearchTask?.cancel()
        guard mode == .jsonl, let index = jsonlIndex else {
            sidebarFilteredRowIDs = nil
            return
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            sidebarFilteredRowIDs = nil
            return
        }
        let query = q.lowercased()
        let total = index.lineCount

        sidebarSearchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var matches: [Int] = []
            var lastPublish = CFAbsoluteTimeGetCurrent()
            for i in 0..<total {
                if Task.isCancelled { return }
                let line = (try? index.readLine(at: i, maxBytes: 4096)) ?? ""
                if line.range(of: query, options: .caseInsensitive) != nil {
                    matches.append(i)
                }
                // Throttle UI updates to ~10 per second
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastPublish > 0.1 {
                    lastPublish = now
                    await MainActor.run {
                        if self?.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query {
                            self?.sidebarFilteredRowIDs = matches
                        }
                    }
                }
            }
            await MainActor.run {
                if self?.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query {
                    self?.sidebarFilteredRowIDs = matches
                }
            }
        }
    }

    func cancelSidebarSearch() {
        sidebarSearchTask?.cancel()
        sidebarSearchTask = nil
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Preview fields management

    func setSidebarPreviewFields(_ fields: [String]) {
        let joined = fields.joined(separator: ",")
        UserDefaults.standard.set(joined, forKey: "sidebarPreviewFields")
        let prefKey = joined.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefKey != lastPreviewFieldsKey {
            lastPreviewFieldsKey = prefKey
            previewCache.removeAllObjects()
            previewFieldsChangeToken &+= 1
        }
    }

    func currentSidebarPreviewFields() -> [String] {
        let raw = UserDefaults.standard.string(forKey: "sidebarPreviewFields") ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func collectCandidatePreviewPaths(limitLines: Int = 200, maxDepth: Int = 4) async -> [String] {
        var paths = Set<String>()

        func addPaths(from any: Any, base: String, depth: Int) {
            if depth > maxDepth { return }
            if let dict = any as? [String: Any] {
                for (k, v) in dict {
                    let path = base.isEmpty ? k : "\(base).\(k)"
                    paths.insert(path)
                    addPaths(from: v, base: path, depth: depth + 1)
                }
            } else if let arr = any as? [Any], let first = arr.first {
                // Sample first element of the array
                let idxPath = base.isEmpty ? "0" : "\(base).0"
                addPaths(from: first, base: idxPath, depth: depth + 1)
            }
        }

        if mode == .jsonl {
            if let index = jsonlIndex {
                let total = index.lineCount
                let count = min(limitLines, total)
                for i in 0..<count {
                    if let line = try? index.readLine(at: i, maxBytes: 8192), let data = line.data(using: .utf8) {
                        if let obj = try? JSONSerialization.jsonObject(with: data) {
                            addPaths(from: obj, base: "", depth: 0)
                            if paths.count > 400 { break }
                        }
                    }
                }
            } else {
                // Pasted JSONL
                for row in jsonlRows.prefix(limitLines) {
                    if let data = row.raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
                        addPaths(from: obj, base: "", depth: 0)
                        if paths.count > 400 { break }
                    }
                }
            }
        } else if mode == .json, let root = currentTreeRoot {
            // If a plain JSON doc is open, propose paths from the tree to allow preconfiguration
            func collectFromTree(_ node: JSONTreeNode) {
                paths.insert(node.path)
                node.children?.forEach(collectFromTree)
            }
            collectFromTree(root)
        }

        let sorted = paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Array(sorted.prefix(500))
    }

    // MARK: - Command Bar Actions

    func runJQ(filter: String) {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        statusMessage = "Running jq…"
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let (data, kind) = try await self.currentDocumentDataForJQ()
                let result = try JQRunner.run(filter: trimmed, input: data, kind: kind)
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let outData = output.data(using: .utf8) ?? Data()
                let tree = try? JSONTreeBuilder.build(from: outData)
                let pretty = (try? JSONPrettyPrinter.pretty(data: outData)) ?? output
                await MainActor.run {
                    self.prettyJSON = pretty
                    self.currentTreeRoot = tree
                    self.presentation = tree == nil ? .text : .tree
                    self.isLoading = false
                    self.statusMessage = "jq: \(trimmed)"
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.statusMessage = "jq error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func currentDocumentDataForJQ() throws -> (Data, JQInputKind) {
        switch mode {
        case .json:
            let json = currentTreeRoot?.asJSONString() ?? prettyJSON
            return (json.data(using: .utf8) ?? Data(), .json)
        case .jsonl:
            if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                return (data, .jsonlSlurped)
            } else {
                let text = jsonlRows.map { $0.raw }.joined(separator: "\n")
                return (text.data(using: .utf8) ?? Data(), .jsonlSlurped)
            }
        case .none:
            return (Data(), .json)
        }
    }

    func writeCurrentDocumentToTmp() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prism-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let name = "doc-\(UUID().uuidString.prefix(8))"
        let ext = (mode == .jsonl) ? "jsonl" : "json"
        let url = tmp.appendingPathComponent("\(name).\(ext)")
        switch mode {
        case .json:
            let json = currentTreeRoot?.asJSONString() ?? prettyJSON
            try json.data(using: .utf8)?.write(to: url)
        case .jsonl:
            if let f = fileURL, FileManager.default.fileExists(atPath: f.path) {
                let data = try Data(contentsOf: f, options: [.mappedIfSafe])
                try data.write(to: url)
            } else {
                let text = jsonlRows.map { $0.raw }.joined(separator: "\n")
                try text.data(using: .utf8)?.write(to: url)
            }
        case .none:
            try Data().write(to: url)
        }
        return url
    }

    func runAI(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let apiKey = OpenAIClient.loadAPIKeyFromDefaultsOrEnv() else {
            statusMessage = "Missing OpenAI API key (set in Preferences > AI or OPENAI_API_KEY env var)."
            // Surface this in the AI sidebar so it's obvious why nothing streamed.
            aiMessages.append(AIMessage(role: "assistant", text: "Missing OpenAI API key. Open Preferences → AI and paste your key, or set the OPENAI_API_KEY environment variable in your run scheme."))
            aiIsStreaming = false
            aiStreamingText = nil
            return
        }

        aiMessages.append(AIMessage(role: "user", text: trimmed))
        aiStreamingText = ""
        aiIsStreaming = true
        aiStatus = "Thinking…"
        isLoading = true

        aiStreamTask?.cancel()
        aiStreamTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let systemPrompt = await Self.agentSystemPrompt()
            let tools = await Self.toolSchemas()

            do {
                try await OpenAIStreamClient.streamCreateResponse(
                    config: .init(apiKey: apiKey, model: "gpt-5", systemPrompt: systemPrompt),
                    userText: trimmed,
                    tools: tools
                ) { event in
                    Task { @MainActor in
                        switch event {
                        case .textDelta(let t):
                            self.aiStreamingText = (self.aiStreamingText ?? "") + t
                        case .requiresAction(let responseId, let calls):
                            // Execute tools locally, then stream the continuation
                            self.statusMessage = "AI using tools…"
                            #if DEBUG
                            print("[AI] requiresAction: responseId=\(responseId), calls=\(calls.map { $0.name })")
                            #endif
                            Task.detached(priority: .userInitiated) { [weak self] in
                                guard let self else { return }
                                var outputs: [OpenAIClient.ToolOutput] = []
                                for call in calls {
                                    #if DEBUG
                                    print("[AI] running tool:", call.name)
                                    if call.argumentsJSON.count < 300 {
                                        print("[AI] tool args:", call.argumentsJSON)
                                    } else {
                                        print("[AI] tool args (trunc):", String(call.argumentsJSON.prefix(300)) + "…")
                                    }
                                    #endif
                                    if call.name == "run_jq" {
                                        if let json = call.argumentsJSON.data(using: .utf8),
                                           let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                                           let filter = dict["filter"] as? String {
                                            do {
                                                let (data, kind) = try await self.currentDocumentDataForJQ()
                                                let result = try JQRunner.run(filter: filter, input: data, kind: kind)
                                                let output = result.stdout
                                                outputs.append(.init(toolCallId: call.id, output: output))
                                                #if DEBUG
                                                print("[AI] jq stdout len:", output.count)
                                                #endif
                                                let outData = output.data(using: .utf8) ?? Data()
                                                let tree = try? JSONTreeBuilder.build(from: outData)
                                                let pretty = (try? JSONPrettyPrinter.pretty(data: outData)) ?? output
                                                await MainActor.run {
                                                    self.prettyJSON = pretty
                                                    self.currentTreeRoot = tree
                                                    self.presentation = tree == nil ? .text : .tree
                                                }
                                            } catch {
                                                outputs.append(.init(toolCallId: call.id, output: "{\"error\":\"\(error.localizedDescription)\"}"))
                                                #if DEBUG
                                                print("[AI] jq error:", error.localizedDescription)
                                                #endif
                                            }
                                        } else {
                                            #if DEBUG
                                            print("[AI] run_jq missing/invalid filter argument")
                                            #endif
                                        }
                                    } else if call.name == "run_python" {
                                        if let json = call.argumentsJSON.data(using: .utf8),
                                           let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                                           let code = dict["code"] as? String {
                                            do {
                                                let inputURL = try await self.writeCurrentDocumentToTmp()
                                                let result = try PythonRunner.run(code: code, inputPath: inputURL)
                                                let desc: [String: Any] = [
                                                    "stdout": result.stdout,
                                                    "stderr": result.stderr,
                                                    "output_files": result.outputFiles.map { $0.path }
                                                ]
                                                let outputJSON = String(data: try JSONSerialization.data(withJSONObject: desc), encoding: .utf8) ?? "{}"
                                                outputs.append(.init(toolCallId: call.id, output: outputJSON))
                                                #if DEBUG
                                                print("[AI] python stdout len:", result.stdout.count, "stderr len:", result.stderr.count, "files:", result.outputFiles.count)
                                                #endif
                                            } catch {
                                                outputs.append(.init(toolCallId: call.id, output: "{\"error\":\"\(error.localizedDescription)\"}"))
                                                #if DEBUG
                                                print("[AI] python error:", error.localizedDescription)
                                                #endif
                                            }
                                        } else {
                                            #if DEBUG
                                            print("[AI] run_python missing/invalid code argument")
                                            #endif
                                        }
                                    } else {
                                        #if DEBUG
                                        print("[AI] unknown tool:", call.name)
                                        #endif
                                    }
                                }
                                do {
                                    // Start second stream (continuation) visibly
                                    await MainActor.run {
                                        self.aiIsStreaming = true
                                        if self.aiStreamingText == nil { self.aiStreamingText = "" }
                                        self.aiStatus = "Using tools…"
                                    }
                                    #if DEBUG
                                    print("[AI] submitting tool outputs count:", outputs.count, "responseId:", responseId)
                                    #endif
                                    try await OpenAIStreamClient.streamSubmitToolOutputs(
                                        apiKey: apiKey,
                                        responseId: responseId,
                                        toolOutputs: outputs
                                    ) { evt in
                                        Task { @MainActor in
                                            switch evt {
                                            case .textDelta(let txt):
                                                #if DEBUG
                                                print("[AI] submit stream textDelta len:", txt.count)
                                                #endif
                                                self.aiStreamingText = (self.aiStreamingText ?? "") + txt
                                            case .completed:
                                                #if DEBUG
                                                print("[AI] submit stream completed")
                                                #endif
                                                if let text = self.aiStreamingText, !text.isEmpty {
                                                    self.aiMessages.append(AIMessage(role: "assistant", text: text))
                                                }
                                                self.aiStreamingText = nil
                                                self.aiIsStreaming = false
                                                self.isLoading = false
                                                self.aiStatus = ""
                                            case .requiresAction:
                                                // Nested tool calls not handled in this first version.
                                                self.statusMessage = "AI requested nested tools; unsupported in this version."
                                                #if DEBUG
                                                print("[AI] nested requiresAction received (not handled)")
                                                #endif
                                            }
                                        }
                                    }
                                } catch {
                                    await MainActor.run {
                                        self.statusMessage = "AI tool submit error: \(error.localizedDescription)"
                                        self.aiMessages.append(AIMessage(role: "assistant", text: "AI tool submit error: \(error.localizedDescription)"))
                                        self.aiIsStreaming = false
                                        self.aiStreamingText = nil
                                        self.isLoading = false
                                        self.aiStatus = ""
                                    }
                                    #if DEBUG
                                    print("[AI] submit error:", error.localizedDescription)
                                    #endif
                                }
                            }
                        case .completed:
                            if let text = self.aiStreamingText, !text.isEmpty {
                                self.aiMessages.append(AIMessage(role: "assistant", text: text))
                            }
                            self.aiStreamingText = nil
                            self.aiIsStreaming = false
                            self.isLoading = false
                            self.aiStatus = ""
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "AI error: \(error.localizedDescription)"
                    self.aiMessages.append(AIMessage(role: "assistant", text: "AI error: \(error.localizedDescription)"))
                    self.aiIsStreaming = false
                    self.aiStreamingText = nil
                    self.isLoading = false
                    self.aiStatus = ""
                }
            }
        }
    }

    func cancelAIStream() {
        aiStreamTask?.cancel()
        aiIsStreaming = false
        aiStreamingText = nil
        aiStatus = "Stopped"
        isLoading = false
    }

    func clearAIConversation() {
        aiMessages.removeAll()
        aiStreamingText = nil
        aiStatus = ""
    }

    private static func agentSystemPrompt() -> String {
        """
        You are Prism's data assistant embedded in a macOS JSON/JSONL viewer.
        You can:
        - run_jq(filter): run a jq program on the CURRENT document (JSON or JSONL). For JSONL, assume input is slurped (-s) into an array of objects. Return the jq output text to the user.
        - run_python(code): Run a short Python 3 script against a temporary COPY of the current document located at a path passed as argv[1]; a writable output directory path is provided as argv[2]. Your script should read argv[1] and print results to stdout. If you save files to argv[2], they will be surfaced back to the user.

        Always prefer run_jq for filtering/transforming JSON and JSONL. Use run_python for more complex transformations.
        Never modify the original file; operate only on provided temp paths.
        Respond concisely.
        """
    }

    private static func toolSchemas() -> [[String: Any]] {
        // Responses API expects top-level "name" for tools. Keep JSON Schema under "parameters".
        let runJQ: [String: Any] = [
            "type": "function",
            "name": "run_jq",
            "description": "Run a jq filter on the current document (JSON or slurped JSONL). Returns jq output text.",
            "parameters": [
                "type": "object",
                "properties": [
                    "filter": ["type": "string", "description": "jq filter, e.g. .items | length"]
                ],
                "required": ["filter"]
            ]
        ]
        let runPy: [String: Any] = [
            "type": "function",
            "name": "run_python",
            "description": "Execute Python 3 code on a temp copy of the current document. Read argv[1]; write optional outputs to argv[2]; print results to stdout.",
            "parameters": [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "Python 3 script source code"]
                ],
                "required": ["code"]
            ]
        ]
        return [runJQ, runPy]
    }
}