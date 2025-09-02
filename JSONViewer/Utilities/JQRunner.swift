import Foundation

enum JQInputKind {
    case json
    case jsonlSlurped // JSON Lines; will be slurped into an array with -s
}

struct JQRunner {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    enum JQError: Error, LocalizedError {
        case jqNotFound
        case failed(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .jqNotFound:
                return "jq executable not found. Install with Homebrew: brew install jq"
            case .failed(let status, let stderr):
                return "jq failed (\(status)): \(stderr)"
            }
        }
    }

    static func findExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/jq",
            "/usr/local/bin/jq",
            "/usr/bin/jq"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback to env
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/env") {
            return "/usr/bin/env"
        }
        return nil
    }

    static func run(filter: String, input: Data, kind: JQInputKind) throws -> Result {
        guard let exe = findExecutable() else { throw JQError.jqNotFound }

        let proc = Process()
        var args: [String]
        if exe.hasSuffix("/env") {
            args = ["jq"]
        } else {
            args = []
        }

        // -c compact output; -s slurp for JSONL
        var jqArgs: [String] = ["-c"]
        if kind == .jsonlSlurped {
            jqArgs.append("-s")
        }
        jqArgs.append(filter)

        if exe.hasSuffix("/env") {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = args + jqArgs
        } else {
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = jqArgs
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Ensure we capture output concurrently to avoid pipe deadlocks on large output
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        // Start readers BEFORE running the process to avoid race where output fills buffer
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            // Copy to avoid mutation races (single writer here)
            stdoutData = data
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData = data
            group.leave()
        }

        try proc.run()

        // Feed input (write then close stdin)
        try inPipe.fileHandleForWriting.write(contentsOf: input)
        try inPipe.fileHandleForWriting.close()

        // Wait for process to finish and for pipes to drain
        proc.waitUntilExit()
        group.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let status = proc.terminationStatus
        if status != 0 {
            throw JQError.failed(status: status, stderr: stderr)
        }
        return Result(stdout: stdout, stderr: stderr, status: status)
    }
}