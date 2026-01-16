import Foundation
import Accelerate

final class JSONLIndex {
    let url: URL
    private(set) var offsets: [UInt64] = [0] // start offsets for each line
    private(set) var fileSize: UInt64 = 0

    private let newline: UInt8 = 0x0A
    private let scanQueue = DispatchQueue(label: "com.prism.jsonlindex.scan", qos: .userInitiated)
    private let scanQueueKey = DispatchSpecificKey<Void>()

    // FileHandle pooling to avoid opening/closing a new handle for every read operation.
    // This dramatically improves performance when scrolling through large JSONL files.
    private var cachedReadHandle: FileHandle?
    private var readHandleUseCount: Int = 0
    private let readHandleLock = NSLock()
    private let maxHandleUses = 1000 // Reopen handle periodically to avoid stale file state

    init(url: URL) {
        self.url = url
        scanQueue.setSpecific(key: scanQueueKey, value: ())
    }

    deinit {
        invalidateReadHandle()
    }

    /// Invalidate the cached read handle. Call when the file is refreshed/reloaded.
    func invalidateReadHandle() {
        readHandleLock.lock()
        defer { readHandleLock.unlock() }
        try? cachedReadHandle?.close()
        cachedReadHandle = nil
        readHandleUseCount = 0
    }


    private func syncOnScanQueue<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: scanQueueKey) != nil {
            return try block()
        } else {
            return try scanQueue.sync(execute: block)
        }
    }

    // Build index using parallel scanning with SIMD acceleration.
    // Splits file into chunks and scans them concurrently on all available cores.
    func build(progress: ((Double) -> Void)? = nil,
               onUpdate: ((Int) -> Void)? = nil,
               shouldCancel: (() -> Bool)? = nil) throws {
        try scanQueue.sync {
            @inline(__always) func cancelled() -> Bool {
                return shouldCancel?() ?? false
            }

            if cancelled() { throw CancellationError() }

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

            if fileSize == 0 {
                offsets = [0]
                progress?(1.0)
                onUpdate?(0)
                return
            }

            // Use memory-mapped file for zero-copy access
            let data = try Data(contentsOf: url, options: [.alwaysMapped])
            let count = data.count

            if cancelled() { throw CancellationError() }

            // Determine number of parallel chunks based on CPU cores
            let coreCount = ProcessInfo.processInfo.activeProcessorCount
            let chunkCount = min(coreCount, max(1, count / (1024 * 1024))) // At least 1MB per chunk
            let chunkSize = (count + chunkCount - 1) / chunkCount

            // Each chunk will collect its own offsets
            var chunkOffsets: [[UInt64]] = Array(repeating: [], count: chunkCount)
            var completedChunks = 0
            let progressLock = NSLock()

            progress?(0.0)

            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                // Scan chunks in parallel
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                    if cancelled() { return }

                    let start = chunkIndex * chunkSize
                    let end = min(start + chunkSize, count)
                    var localOffsets: [UInt64] = []
                    localOffsets.reserveCapacity((end - start) / 200) // Estimate

                    // SIMD-accelerated newline scanning using 16-byte vectors
                    var i = start
                    let newlineVec = SIMD16<UInt8>(repeating: newline)

                    // Process 16 bytes at a time with SIMD
                    while i + 16 <= end {
                        let vec = SIMD16<UInt8>(
                            base[i], base[i+1], base[i+2], base[i+3],
                            base[i+4], base[i+5], base[i+6], base[i+7],
                            base[i+8], base[i+9], base[i+10], base[i+11],
                            base[i+12], base[i+13], base[i+14], base[i+15]
                        )
                        let matches = vec .== newlineVec

                        // Check each lane for matches
                        if matches[0] { localOffsets.append(UInt64(i + 1)) }
                        if matches[1] { localOffsets.append(UInt64(i + 2)) }
                        if matches[2] { localOffsets.append(UInt64(i + 3)) }
                        if matches[3] { localOffsets.append(UInt64(i + 4)) }
                        if matches[4] { localOffsets.append(UInt64(i + 5)) }
                        if matches[5] { localOffsets.append(UInt64(i + 6)) }
                        if matches[6] { localOffsets.append(UInt64(i + 7)) }
                        if matches[7] { localOffsets.append(UInt64(i + 8)) }
                        if matches[8] { localOffsets.append(UInt64(i + 9)) }
                        if matches[9] { localOffsets.append(UInt64(i + 10)) }
                        if matches[10] { localOffsets.append(UInt64(i + 11)) }
                        if matches[11] { localOffsets.append(UInt64(i + 12)) }
                        if matches[12] { localOffsets.append(UInt64(i + 13)) }
                        if matches[13] { localOffsets.append(UInt64(i + 14)) }
                        if matches[14] { localOffsets.append(UInt64(i + 15)) }
                        if matches[15] { localOffsets.append(UInt64(i + 16)) }

                        i += 16
                    }

                    // Handle remaining bytes
                    while i < end {
                        if base[i] == newline {
                            localOffsets.append(UInt64(i + 1))
                        }
                        i += 1
                    }

                    chunkOffsets[chunkIndex] = localOffsets

                    // Update progress
                    progressLock.lock()
                    completedChunks += 1
                    let prog = Double(completedChunks) / Double(chunkCount)
                    progressLock.unlock()
                    progress?(prog)
                }
            }

            if cancelled() { throw CancellationError() }

            // Merge all chunk offsets (already sorted since chunks are sequential)
            var totalCount = 1 // Start with offset 0
            for chunk in chunkOffsets {
                totalCount += chunk.count
            }

            offsets = [0]
            offsets.reserveCapacity(totalCount + 1)
            for chunk in chunkOffsets {
                offsets.append(contentsOf: chunk)
            }

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
        // Invalidate any cached read handle since the file content has changed
        invalidateReadHandle()
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

        // Use the pooled handle with synchronized seek+read to avoid concurrent seeks interfering.
        // This is MUCH faster than opening/closing a new FileHandle for every read.
        readHandleLock.lock()
        let data: Data
        do {
            let handle = try acquireReadHandleUnlocked()
            try handle.seek(toOffset: range.lowerBound)
            data = try handle.read(upToCount: Int(toRead)) ?? Data()
            readHandleLock.unlock()
        } catch {
            readHandleLock.unlock()
            throw error
        }

        // Strip trailing newline if present
        let trimmed: Data
        if data.last == newline {
            trimmed = data.dropLast()
        } else {
            trimmed = data
        }
        return String(data: trimmed, encoding: .utf8)
    }

    /// Internal unlocked version - caller must hold readHandleLock
    private func acquireReadHandleUnlocked() throws -> FileHandle {
        // Reuse existing handle if under the use limit
        if let handle = cachedReadHandle, readHandleUseCount < maxHandleUses {
            readHandleUseCount += 1
            return handle
        }

        // Close old handle if exists
        try? cachedReadHandle?.close()

        // Open fresh handle
        let handle = try FileHandle(forReadingFrom: url)
        cachedReadHandle = handle
        readHandleUseCount = 1
        return handle
    }
}