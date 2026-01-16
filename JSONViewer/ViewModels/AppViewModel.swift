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
    private let previewSemaphore = DispatchSemaphore(value: 4)

    @Published var selectedRowID: Int? {
        didSet {
            // Only drive JSONL recomputation off selection changes when in JSONL mode.
            guard mode == .jsonl, selectedRowID != oldValue else { return }

            // CRITICAL: Capture the value NOW, before the Task starts.
            // Reading self.selectedRowID inside the Task creates a race condition
            // where rapid clicks cause the wrong row to be displayed.
            let capturedID = selectedRowID
            selectionVersion += 1
            let capturedVersion = selectionVersion

            #if DEBUG
            print("[JSONL] selectedRowID didSet: id=\(String(describing: capturedID)), version=\(capturedVersion), old=\(String(describing: oldValue))")
            #endif

            // Cancel any in-flight task immediately
            currentComputeTask?.cancel()

            Task { [weak self] in
                guard let self else { return }

                // Check if this is still the latest selection before doing expensive work
                guard self.selectionVersion == capturedVersion else {
                    #if DEBUG
                    print("[JSONL] skipping stale selection version=\(capturedVersion), current=\(self.selectionVersion)")
                    #endif
                    return
                }

                #if DEBUG
                print("[JSONL] selectedRowID didSet Task: updateTreeForSelectedRow(selectedID: \(String(describing: capturedID)), version=\(capturedVersion))")
                #endif
                _ = await self.updateTreeForSelectedRow(selectedID: capturedID, selectionVersion: capturedVersion)
            }
        }
    }

    // Version counter to track selection ordering and prevent out-of-order updates
    private var selectionVersion: Int = 0
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var searchText: String = ""
    @Published var indexingProgress: Double?
    @Published var lastUpdatedAt: Date?
    
    // Original JSON document data (for restoring full view after jq filters)
    private var originalJSONData: Data? = nil
    
    init() {
        // Prevent unbounded memory growth while scrolling many rows.
        // Increased from 5000 to 10000 to reduce repeated file reads for large files,
        // since we now have FileHandle pooling that makes reads much cheaper.
        previewCache.countLimit = 10000
        // Also set a memory limit to avoid excessive memory usage (50MB max)
        previewCache.totalCostLimit = 50 * 1024 * 1024
    }
    
    // Command bar (jq filter)
    @Published var commandText: String = ""

    // Sidebar (JSONL) search
    @Published var sidebarFilteredRowIDs: [Int]? = nil
    private var sidebarSearchTask: Task<Void, Never>?
    private var sidebarSearchDebounce: Task<Void, Never>? = nil

    // Work management
    private var currentComputeTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var fileWatcher: FileWatcher?
    private var fileChangeDebounce: Task<Void, Never>?
    private var inspectorSelectionID: Int = 0
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
        currentComputeTask?.cancel()
        currentComputeTask = nil
        indexTask?.cancel()
        indexTask = nil
        fileChangeDebounce?.cancel()
        fileChangeDebounce = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        lastUpdatedAt = nil
        sidebarSearchTask?.cancel()
        sidebarSearchTask = nil
        sidebarSearchDebounce?.cancel()
        sidebarSearchDebounce = nil
        inspectorSelectionID = 0
        originalJSONData = nil
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
                    self.originalJSONData = data
                    if self.expandedPaths.isEmpty { self.expandedPaths.insert("") }
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
                            self.originalJSONData = data
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
        jsonlRowCount = 0
        indexTask?.cancel()
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try index.build(progress: { progress in
                    Task { @MainActor in
                        self?.indexingProgress = progress
                        self?.statusMessage = "Indexing… \(Int(progress * 100))%"
                    }
                }, onUpdate: { count in
                    // Only update the row count during indexing - don't trigger tree builds
                    // Tree will be built once at the end when indexing completes
                    Task { @MainActor in
                        self?.jsonlRowCount = count
                    }
                }, shouldCancel: { Task.isCancelled })

                // Indexing complete - now select row 0 and build the tree ONCE
                await MainActor.run {
                    guard let self else { return }
                    #if DEBUG
                    print("[JSONL] index build completed: lineCount=\(index.lineCount)")
                    #endif
                    self.jsonlRowCount = index.lineCount
                    self.statusMessage = "Indexed \(index.lineCount) rows"
                    self.lastUpdatedAt = Date()
                    self.indexingProgress = nil

                    // Auto-select first row and build tree only after indexing is fully complete
                    if self.selectedRowID == nil && index.lineCount > 0 {
                        self.selectedRowID = 0
                    } else if self.selectedRowID != nil {
                        // Refresh tree for already-selected row
                        Task { _ = await self.updateTreeForSelectedRow() }
                    }
                }
            } catch {
                // Treat cancellation as non-fatal (likely caused by quick file close/open or replacement)
                if (error as? CancellationError) == nil {
                    await MainActor.run {
                        #if DEBUG
                        print("[JSONL] index build failed: \(error.localizedDescription)")
                        #endif
                        self?.statusMessage = "Failed to index JSONL"
                    }
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
            self.previewSemaphore.wait()
            defer { self.previewSemaphore.signal() }
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
        // Forward to the explicit-id variant using the current selection.
        // Capture the current version for external callers (e.g., file refresh).
        return await updateTreeForSelectedRow(selectedID: selectedRowID, selectionVersion: selectionVersion)
    }

    // Explicit-id variant used by views to avoid any timing race on reading selectedRowID.
    // The selectionVersion parameter allows callers to pass the version at the time of selection,
    // preventing out-of-order updates when rapid selections occur.
    @discardableResult
    func updateTreeForSelectedRow(selectedID: Int?, selectionVersion startVersion: Int) async -> Bool {
        #if DEBUG
        print("[JSONL] updateTreeForSelectedRow(entry): selectedID=\(String(describing: selectedID)), version=\(startVersion), mode=\(mode)")
        #endif
        // Only valid for JSONL mode with a concrete selection
        guard mode == .jsonl, let id = selectedID else {
            #if DEBUG
            print("[JSONL] updateTreeForSelectedRow: early-exit (mode=\(mode), selectedID=\(String(describing: selectedID)))")
            #endif
            return false
        }

        // Early exit if selection has already changed
        guard selectionVersion == startVersion else {
            #if DEBUG
            print("[JSONL] updateTreeForSelectedRow: stale version \(startVersion), current \(selectionVersion)")
            #endif
            return false
        }

        // Cancel any in-flight compute and start a fresh one for the current selection
        if currentComputeTask != nil {
            #if DEBUG
            print("[JSONL] updateTreeForSelectedRow: cancelling previous compute task for id=\(id)")
            #endif
        }
        currentComputeTask?.cancel()

        // File-backed JSONL
        if let index = jsonlIndex {
            // Only proceed if the line slice is available (during indexing this may be false)
            let hasSlice = index.sliceRange(forLine: id) != nil
            #if DEBUG
            print("[JSONL] updateTreeForSelectedRow(file-backed): id=\(id), version=\(startVersion), hasSlice=\(hasSlice), rowCount=\(jsonlRowCount)")
            #endif
            guard hasSlice else { return false }

            let selectionAtStart = id
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                #if DEBUG
                print("[JSONL] compute task started for id=\(selectionAtStart), version=\(startVersion)")
                #endif

                // Check version before I/O
                guard let self else { return }
                if Task.isCancelled { return }
                guard await self.selectionVersion == startVersion else {
                    #if DEBUG
                    print("[JSONL] compute task aborting (pre-IO): stale version \(startVersion)")
                    #endif
                    return
                }

                let raw = (try? index.readLine(at: selectionAtStart, maxBytes: nil)) ?? ""
                #if DEBUG
                print("[JSONL] readLine completed for id=\(selectionAtStart), rawLength=\(raw.count)")
                #endif

                // Check version after I/O
                if Task.isCancelled { return }
                guard await self.selectionVersion == startVersion else {
                    #if DEBUG
                    print("[JSONL] compute task aborting (post-IO): stale version \(startVersion)")
                    #endif
                    return
                }

                let data = raw.data(using: .utf8) ?? Data()
                let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
                let tree = try? JSONTreeBuilder.build(from: data)

                await MainActor.run {
                    let currentSel = self.selectedRowID
                    let currentVersion = self.selectionVersion
                    let isModeJSONL = self.mode == .jsonl
                    let sameIndex = self.jsonlIndex === index
                    let notCancelled = !Task.isCancelled
                    #if DEBUG
                    print("[JSONL] compute task finishing for id=\(selectionAtStart): currentSel=\(String(describing: currentSel)), version=\(startVersion)/\(currentVersion), notCancelled=\(notCancelled), isModeJSONL=\(isModeJSONL), sameIndex=\(sameIndex)")
                    #endif
                    // Drop stale results: only apply if selection, version, and index are still current
                    guard notCancelled,
                          isModeJSONL,
                          currentVersion == startVersion,
                          currentSel == selectionAtStart,
                          sameIndex else { return }

                    self.prettyJSON = pretty
                    self.currentTreeRoot = tree
                    self.presentation = .tree
                    if self.expandedPaths.isEmpty { self.expandedPaths.insert("") }
                    #if DEBUG
                    let snippet = pretty.replacingOccurrences(of: "\n", with: " ")
                    let preview = String(snippet.prefix(120))
                    print("[JSONL] applied tree for id=\(selectionAtStart), preview=\(preview)")
                    #endif
                }
            }
            return true
        }

        // Pasted JSONL
        guard let row = selectedRow else {
            #if DEBUG
            print("[JSONL] updateTreeForSelectedRow(pasted): no selectedRow for id=\(id)")
            #endif
            return false
        }
        let raw = row.raw
        let selectionAtStart = id
        currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
            #if DEBUG
            print("[JSONL] compute task started (pasted) for id=\(selectionAtStart), version=\(startVersion)")
            #endif

            guard let self else { return }
            if Task.isCancelled { return }

            // Check version before expensive work
            guard await self.selectionVersion == startVersion else {
                #if DEBUG
                print("[JSONL] compute task aborting (pasted pre-compute): stale version \(startVersion)")
                #endif
                return
            }

            let data = raw.data(using: .utf8) ?? Data()
            let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
            let tree = try? JSONTreeBuilder.build(from: data)

            await MainActor.run {
                let currentSel = self.selectedRowID
                let currentVersion = self.selectionVersion
                let isModeJSONL = self.mode == .jsonl
                let isFileBacked = self.jsonlIndex != nil
                let notCancelled = !Task.isCancelled
                #if DEBUG
                print("[JSONL] compute task finishing (pasted) for id=\(selectionAtStart): currentSel=\(String(describing: currentSel)), version=\(startVersion)/\(currentVersion), notCancelled=\(notCancelled), isModeJSONL=\(isModeJSONL), isFileBacked=\(isFileBacked)")
                #endif
                // Drop stale results: only apply if selection is still the same and we're still in JSONL paste mode
                guard notCancelled,
                      isModeJSONL,
                      currentVersion == startVersion,
                      !isFileBacked,
                      currentSel == selectionAtStart else { return }

                self.prettyJSON = pretty
                self.currentTreeRoot = tree
                self.presentation = .tree
                if self.expandedPaths.isEmpty { self.expandedPaths.insert("") }
                #if DEBUG
                print("[JSONL] applied tree (pasted) for id=\(selectionAtStart)")
                #endif
            }
        }
        return true
    }

    func didSelectTreeNode(_ node: JSONTreeNode) {
        inspectorPath = node.path.isEmpty ? "(root)" : node.path
        inspectorSelectionID &+= 1
        let selectionID = inspectorSelectionID
        #if DEBUG
        print("[Inspector] didSelectTreeNode: path=\(inspectorPath), selectionID=\(selectionID), isScalar=\(node.scalar != nil)")
        #endif

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
            // For large objects/arrays, compute the JSON text off the main actor and
            // truncate very deep structures to keep the UI responsive.
            inspectorValueText = "Loading…"
            let nodeSnapshot = node
            Task.detached(priority: .userInitiated) { [weak self] in
                #if DEBUG
                print("[Inspector] task started: selectionID=\(selectionID), path=\(nodeSnapshot.path)")
                #endif
                let text = nodeSnapshot.asJSONString(limit: 200_000)
                #if DEBUG
                print("[Inspector] task finished compute: selectionID=\(selectionID), textLength=\(text.count)")
                #endif
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    #if DEBUG
                    print("[Inspector] main apply check: currentSelectionID=\(self.inspectorSelectionID), taskSelectionID=\(selectionID), inspectorPath=\(self.inspectorPath)")
                    #endif
                    // Only apply the result if the selection hasn't changed.
                    guard self.inspectorSelectionID == selectionID else {
                        #if DEBUG
                        print("[Inspector] skipping stale inspector update for selectionID=\(selectionID)")
                        #endif
                        return
                    }
                    self.inspectorValueText = text
                    #if DEBUG
                    print("[Inspector] applied inspector text for selectionID=\(selectionID)")
                    #endif
                }
            }
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        #endif
    }

    func copyDisplayedText() {
        #if os(macOS)
        let text: String
        switch mode {
        case .json, .jsonl:
            // Always use the pretty-printed representation for copy to keep this fast,
            // regardless of whether the user is in text or tree presentation.
            text = prettyJSON
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
                            self.originalJSONData = data
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
            indexTask?.cancel()
            indexTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try index.refresh(progress: { _ in }, onUpdate: { count in
                        Task { @MainActor in
                            self?.jsonlRowCount = count
                            self?.lastUpdatedAt = Date()
                        }
                    }, shouldCancel: { Task.isCancelled })
                    await MainActor.run {
                        // Clear any stale previews because the entire file was re-indexed
                        self?.previewCache.removeAllObjects()
                        // Ensure selection is valid for the new row count
                        if let count = self?.jsonlRowCount {
                            if let sel = self?.selectedRowID, sel >= count {
                                self?.selectedRowID = count > 0 ? 0 : nil
                            }
                        }
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

    func runSidebarSearchDebounced() {
        sidebarSearchDebounce?.cancel()
        sidebarSearchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            runSidebarSearch()
        }
    }

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
            if let data = originalJSONData {
                return (data, .json)
            } else {
                // Fall back to the pretty-printed text representation rather than
                // rebuilding from the tree to avoid walking very large structures.
                let data = prettyJSON.data(using: .utf8) ?? Data()
                return (data, .json)
            }
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

    func clearJQFilter() {
        switch mode {
        case .json:
            guard let data = originalJSONData else { return }
            isLoading = false
            statusMessage = nil
            currentComputeTask?.cancel()
            currentComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
                let pretty = (try? JSONPrettyPrinter.pretty(data: data)) ?? (String(data: data, encoding: .utf8) ?? "")
                let tree = try? JSONTreeBuilder.build(from: data)
                await MainActor.run {
                    guard let self else { return }
                    self.prettyJSON = pretty
                    self.currentTreeRoot = tree
                    self.presentation = .tree
                    if self.expandedPaths.isEmpty { self.expandedPaths.insert("") }
                }
            }
        case .jsonl:
            isLoading = false
            statusMessage = nil
            Task {
                _ = await self.updateTreeForSelectedRow()
            }
        case .none:
            break
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
            if let data = originalJSONData {
                try data.write(to: url)
            } else {
                let data = prettyJSON.data(using: .utf8) ?? Data()
                try data.write(to: url)
            }
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

}