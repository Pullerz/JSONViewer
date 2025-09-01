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

    enum ContentPresentation {
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
        jsonlRows = []
        jsonlIndex = nil
        jsonlRowCount = 0
        selectedRowID = nil
        isLoading = false
        statusMessage = nil
        searchText = ""
        indexingProgress = nil
        previewCache.removeAllObjects()
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

        if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            do {
                let pretty = try JSONPrettyPrinter.pretty(data: data)
                prettyJSON = pretty
                currentTreeRoot = try? JSONTreeBuilder.build(from: data)
                presentation = .tree
                mode = .json
                statusMessage = "Pasted JSON"
                return
            } catch {
                // fall through
            }
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
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let pretty = try JSONPrettyPrinter.pretty(data: data)
                prettyJSON = pretty
                currentTreeRoot = try? JSONTreeBuilder.build(from: data)
                presentation = .tree
                mode = .json
                statusMessage = "Loaded JSON (\(formattedByteCount(data.count)))"
                return
            } catch {
                statusMessage = "Failed to load JSON"
                return
            }
        }

        // JSONL path: build index in background for scalability
        mode = .jsonl
        statusMessage = "Indexing JSONL…"
        let index = JSONLIndex(url: url)
        jsonlIndex = index
        indexingProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try index.build { progress in
                    Task { @MainActor in
                        self?.indexingProgress = progress
                        self?.statusMessage = "Indexing… \(Int(progress * 100))%"
                    }
                }
                await MainActor.run {
                    self?.jsonlRowCount = index.lineCount
                    self?.statusMessage = "Indexed \(index.lineCount) rows"
                    if self?.selectedRowID == nil && index.lineCount > 0 {
                        self?.selectedRowID = 0
                    }
                }
                await self?.updateTreeForSelectedRow()
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

        if let index = jsonlIndex {
            // File-backed: read on demand
            let raw = (try? index.readLine(at: id, maxBytes: nil)) ?? ""
            let data = raw.data(using: .utf8) ?? Data()
            prettyJSON = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
            currentTreeRoot = try? JSONTreeBuilder.build(from: data)
            presentation = .tree
            return true
        } else {
            // Pasted JSONL
            guard let row = selectedRow else { return false }
            let raw = row.raw
            let data = raw.data(using: .utf8) ?? Data()
            prettyJSON = (try? JSONPrettyPrinter.pretty(data: data)) ?? raw
            currentTreeRoot = try? JSONTreeBuilder.build(from: data)
            presentation = .tree
            return true
        }
    }

    func didSelectTreeNode(_ node: JSONTreeNode) {
        inspectorPath = node.path.isEmpty ? "(root)" : node.path
        inspectorValueText = node.asJSONString()
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

    private func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}