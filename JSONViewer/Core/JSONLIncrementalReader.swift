import Foundation

final class JSONLIncrementalReader {
    private let handle: FileHandle

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func firstLines(limit: Int, maxBytes: Int = 16 * 1024 * 1024) throws -> [String] {
        var lines: [String] = []
        var buffer = Data()
        let newline = Data([0x0A])
        let chunkSize = 64 * 1024
        var readBytes = 0

        while lines.count < limit {
            if readBytes >= maxBytes { break }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            readBytes += chunk.count
            buffer.append(chunk)

            while let range = buffer.firstRange(of: newline) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                if let str = String(data: lineData, encoding: .utf8) {
                    lines.append(str.removingCarriageReturn())
                } else {
                    lines.append("")
                }
                buffer.removeSubrange(0..<range.upperBound)
                if lines.count >= limit { break }
            }
        }

        if !buffer.isEmpty && lines.count < limit {
            if let str = String(data: buffer, encoding: .utf8) {
                lines.append(str.removingCarriageReturn())
            }
        }

        return lines
    }
}

private extension String {
    func removingCarriageReturn() -> String {
        if hasSuffix("\r") {
            return String(dropLast())
        }
        return self
    }
}