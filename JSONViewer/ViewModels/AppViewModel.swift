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

    struct JSONLRow: Identifiable, Hashable {
        let id: Int
        let preview: String
        let raw: String
        let pretty: String?
    }

    @Published var mode: Mode = .none

    @Published var fileURL: URL?
    @Published var prettyJSON: String = ""

    // JSONL
    @Published var jsonlRows: [JSONLRow] = []
    @Published var selectedRowID: Int?
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var searchText: String = ""

    var selectedRow: JSONLRow? {
        guard let id = selectedRowID else { return nil }
        return jsonlRows.first(where: { $0.id == id })
    }

    func clear() {
        mode = .none
        fileURL = nil
        prettyJSON = ""
        jsonlRows = []
        selectedRowID = nil
        isLoading = false
        statusMessage = nil
        searchText = ""
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

        if let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            do {
                let pretty = try JSONPrettyPrinter.pretty(data: data)
                prettyJSON = pretty
                mode = .json
                statusMessage = "Pasted JSON"
                return
            } catch {
                // fall through
            }
        }

        let rawLines = text.split(whereSeparator: \.isNewline).map(String.init)
        var rows: [JSONLRow] = []
        rows.reserveCapacity(min(1000, rawLines.count))
        var idx = 0
        for line in rawLines.prefix(1000) {
            let pretty = try? JSONPrettyPrinter.pretty(text: String(line))
            let preview = (pretty ?? line).prefix(160)
            rows.append(JSONLRow(id: idx, preview: String(preview), raw: String(line), pretty: pretty))
            idx += 1
        }
        jsonlRows = rows
        mode = .jsonl
        statusMessage = "Pasted JSONL (\(rows.count) rows shown)"
        selectedRowID = rows.first?.id
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
                mode = .json
                statusMessage = "Loaded JSON (\(formattedByteCount(data.count)))"
                return
            } catch {
                statusMessage = "Failed to load JSON"
                return
            }
        }

        // Try JSONL
        do {
            let reader = try JSONLIncrementalReader(url: url)
            let lines = try reader.firstLines(limit: 1000)
            var rows: [JSONLRow] = []
            rows.reserveCapacity(lines.count)
            for (i, raw) in lines.enumerated() {
                let pretty = try? JSONPrettyPrinter.pretty(text: raw)
                let preview = (pretty ?? raw).prefix(160)
                rows.append(JSONLRow(id: i, preview: String(preview), raw: raw, pretty: pretty))
            }
            jsonlRows = rows
            mode = .jsonl
            statusMessage = "Loaded JSONL preview (\(rows.count) rows)"
            selectedRowID = rows.first?.id
        } catch {
            // As a fallback, attempt JSON
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let pretty = try JSONPrettyPrinter.pretty(data: data)
                prettyJSON = pretty
                mode = .json
                statusMessage = "Loaded as JSON"
            } catch {
                mode = .none
                statusMessage = "Unsupported file"
            }
        }
    }

    func copyDisplayedText() {
        #if os(macOS)
        let text: String
        switch mode {
        case .json:
            text = prettyJSON
        case .jsonl:
            text = selectedRow?.pretty ?? selectedRow?.raw ?? ""
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