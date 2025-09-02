import Foundation

final class JSONLIndex {
    let url: URL
    private(set) var offsets: [UInt64] = [0] // start offsets for each line
    private(set) var fileSize: UInt64 = 0

    private let chunkSize = 8 * 1024 * 1024
    private let newline: UInt8 = 0x0A
    private let scanQueue = DispatchQueue(label: "com.prism.jsonlindex.scan", qos: .utility)
    private let scanQueueKey = DispatchSpecificKey<Void>()

    init(url: URL) {
        self.url = url
        scanQueue.setSpecific(key: scanQueueKey, value: ())
    }

    private func syncOnScanQueue<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            return try block()
        } else {
            return try scanQueue.sync(execute: block)
        }
    }

    // Build index progressively, reporting progress and current lineCount after each chunk.
    // The shouldCancel closure allows callers (Tasks) to request early exit during file save bursts.
    func build(progress: ((Double) -> Void)? = nil,
               onUpdate: ((Int) -> Void)? = nil,
               shouldCancel: (() -> Bool)? = nil) throws {
        try scanQueue.sync {
            @inline(__always) func cancelled() -> Bool {
                return shouldCancel?() ?? false
            }

            if cancelled() { throw CancellationError() }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

            offsets = [0]
            var position: UInt64 = 0
            while true {
                if cancelled() { throw CancellationError() }

                try handle.seek(toOffset: position)
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }

                if cancelled() { throw CancellationError() }

                chunk.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<chunk.count {
                        if base.advanced(by: i).pointee == newline {
                            let nextOffset = position + UInt64(i) + 1
                            offsets.append(nextOffset)
                        }
                    }
                }

                position += UInt64(chunk.count)
                progress?(fileSize > 0 ? Double(position) / Double(fileSize) : 0)
                onUpdate?(lineCount)
                if chunk.count < chunkSize { break }
            }

            if cancelled() { throw CancellationError() }

            // Ensure EOF offset is present for final line slicing
            if offsets.last != fileSize {
                offsets.append(fileSize)
            }
            progress?(1.0)
            onUpdate?(lineCount)
        }
    }

    // Refresh the index for file changes. Always rebuild to avoid duplicating rows when files are rewritten.
    func refresh(progress: ((Double) -> Void)? = nil,
                 onUpdate: ((Int) -> Void)? = nil,
                 shouldCancel: (() -> Bool)? = nil) throws {
        try build(progress: progress, onUpdate: onUpdate, shouldCancel: shouldCancel)
    }

    var lineCount: Int {
        syncOnScanQueue { max(0, offsets.count - 1) }
    }

    func sliceRange(forLine index: Int) -> Range<UInt64>? {
        return syncOnScanQueue {
            guard index >= 0 && index + 1 < offsets.count else { return nil }
            let start = offsets[index]
            let end = offsets[index + 1]
            guard start <= end else { return nil }
            return start..<end
        }
    }

    func readLine(at index: Int, maxBytes: Int? = nil) throws -> String? {
        guard let range = sliceRange(forLine: index) else { return nil }
        let length = range.upperBound - range.lowerBound
        let toRead = maxBytes.map { min(UInt64($0), length) } ?? length
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: range.lowerBound)
        let data = try handle.read(upToCount: Int(toRead)) ?? Data()
        // Strip trailing newline if present
        let trimmed: Data
        if data.last == newline {
            trimmed = data.dropLast()
        } else {
            trimmed = data
        }
        return String(data: trimmed, encoding: .utf8)
    }
}