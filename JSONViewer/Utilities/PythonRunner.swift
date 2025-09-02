import Foundation

struct PythonRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        let outputFiles: [URL]
    }

    enum PyError: Error, LocalizedError {
        case notFound
        case failed(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "python3 not found. Install with Xcode Command Line Tools or Homebrew."
            case .failed(let status, let stderr): return "python3 failed (\(status)): \(stderr)"
            }
        }
    }

    static func findPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/env") {
            return "/usr/bin/env"
        }
        return nil
    }

    static func run(code: String, inputPath: URL) throws -> Result {
        guard let exe = findPython() else { throw PyError.notFound }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prism-python", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let scriptURL = tmpDir.appendingPathComponent("script-\(UUID().uuidString.prefix(8)).py")
        try code.data(using: .utf8)?.write(to: scriptURL)

        let outDir = tmpDir.appendingPathComponent("outputs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let proc = Process()
        var args: [String]
        if exe.hasSuffix("/env") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            args = ["python3", scriptURL.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: exe)
            args = [scriptURL.path]
        }
        proc.arguments = args + [inputPath.path, outDir.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let status = proc.terminationStatus
        if status != 0 {
            throw PyError.failed(status: status, stderr: stderr)
        }

        let outputs = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        return Result(stdout: stdout, stderr: stderr, status: status, outputFiles: outputs)
    }
}