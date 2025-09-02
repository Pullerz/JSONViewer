import Foundation

enum SSEEvent {
    case textDelta(String)
    case requiresAction(responseId: String, toolCalls: [(id: String, name: String, argumentsJSON: String)])
    case completed
}

struct OpenAIStreamClient {
    struct Config {
        let apiKey: String
        let model: String
        let systemPrompt: String
    }

    // Stream a Responses create call. If the model requires tools, we will surface requiresAction and stop text streaming.
    static func streamCreateResponse(
        config: Config,
        userText: String,
        tools: [[String: Any]],
        onEvent: @escaping (SSEEvent) -> Void
    ) async throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": config.model,
            "input": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": userText]
            ],
            "tools": tools,
            "stream": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await streamSSE(request: req, onEvent: onEvent)
    }

    // Stream a submit_tool_outputs continuation
    static func streamSubmitToolOutputs(
        apiKey: String,
        responseId: String,
        toolOutputs: [OpenAIClient.ToolOutput],
        onEvent: @escaping (SSEEvent) -> Void
    ) async throws {
        let url = URL(string: "https://api.openai.com/v1/responses/\(responseId)/submit_tool_outputs")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "tool_outputs": toolOutputs.map { ["tool_call_id": $0.toolCallId, "output": $0.output] },
            "stream": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        try await streamSSE(request: req, onEvent: onEvent)
    }

    // Generic SSE reader for OpenAI Responses
    private static func streamSSE(request: URLRequest, onEvent: @escaping (SSEEvent) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIClient.ClientError.badResponse
        }
        #if DEBUG
        print("[SSE] HTTP status:", http.statusCode)
        #endif
        if !(200..<300).contains(http.statusCode) {
            // Consume the error body from the same streaming response for full details.
            var errData = Data()
            for try await chunk in bytes {
                errData.append(chunk)
            }
            let text = String(data: errData, encoding: .utf8) ?? "Non-200 streaming response"
            #if DEBUG
            print("[SSE] Error body:", text)
            #endif
            throw OpenAIClient.ClientError.http(http.statusCode, text)
        }

        var buffer = Data()
        for try await chunk in bytes {
            buffer.append(chunk)
            // Split on double newlines (end of SSE event). Handle both LF and CRLF.
            while true {
                let lf2 = Data("\n\n".utf8)
                let crlf2 = Data("\r\n\r\n".utf8)
                let useRange = buffer.range(of: lf2) ?? buffer.range(of: crlf2)
                guard let range = useRange else { break }
                let eventData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let raw = String(data: eventData, encoding: .utf8) {
                    // Normalize line endings
                    let line = raw.replacingOccurrences(of: "\r\n", with: "\n")
                    #if DEBUG
                    let preview = line.count > 500 ? String(line.prefix(500)) + "…" : line
                    if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        print("[SSE] event chunk:", preview)
                    }
                    #endif
                    // Parse SSE fields (we care about "data:" lines)
                    for s in line.split(separator: "\n") {
                        if s.hasPrefix("data:") {
                            let payload = s.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { onEvent(.completed); return }
                            if payload.isEmpty { continue }
                            #if DEBUG
                            let dp = payload.count > 500 ? String(payload.prefix(500)) + "…" : payload
                            print("[SSE] data:", dp)
                            #endif
                            if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                                // Heuristics to find deltas, required actions, or completion
                                if let required = obj["required_action"] as? [String: Any] {
                                    var responseId = obj["id"] as? String ?? ""
                                    // Responses API sometimes wraps tool calls under submit_tool_outputs key
                                    var toolCalls: [[String: Any]] = []
                                    if let calls = required["tool_calls"] as? [[String: Any]] {
                                        toolCalls = calls
                                    } else if let sto = required["submit_tool_outputs"] as? [String: Any],
                                              let calls = sto["tool_calls"] as? [[String: Any]] {
                                        toolCalls = calls
                                    }
                                    if !toolCalls.isEmpty {
                                        let tuples: [(String, String, String)] = toolCalls.compactMap { c in
                                            guard let id = c["id"] as? String else { return nil }
                                            // New Responses shape: name/arguments at top level
                                            if let name = c["name"] as? String {
                                                if let a = c["arguments"] as? String {
                                                    return (id, name, a)
                                                } else if let aObj = c["arguments"] as? [String: Any],
                                                          let data = try? JSONSerialization.data(withJSONObject: aObj),
                                                          let a = String(data: data, encoding: .utf8) {
                                                    return (id, name, a)
                                                }
                                            }
                                            // Legacy shape: nested function object
                                            if let fn = c["function"] as? [String: Any],
                                               let name = fn["name"] as? String,
                                               let args = fn["arguments"] as? String {
                                                return (id, name, args)
                                            }
                                            return nil
                                        }
                                        #if DEBUG
                                        print("[SSE] requiresAction tool calls:", tuples.map { $0.1 })
                                        #endif
                                        onEvent(.requiresAction(responseId: responseId, toolCalls: tuples))
                                        continue
                                    }
                                }

                                // Extract text delta possibilities
                                if let t = obj["type"] as? String, t.contains("delta") {
                                    if let delta = obj["delta"] as? [String: Any] {
                                        if let text = delta["output_text"] as? String {
                                            #if DEBUG
                                            print("[SSE] textDelta (direct) len:", text.count)
                                            #endif
                                            onEvent(.textDelta(text))
                                            continue
                                        }
                                        if let content = delta["content"] as? [[String: Any]] {
                                            for item in content {
                                                if let itemType = item["type"] as? String,
                                                   (itemType.contains("output_text") || itemType == "text"),
                                                   let txt = item["text"] as? String {
                                                    #if DEBUG
                                                    print("[SSE] textDelta (content) len:", txt.count)
                                                    #endif
                                                    onEvent(.textDelta(txt))
                                                }
                                            }
                                            continue
                                        }
                                    }
                                }

                                // Non-delta but direct text output
                                if let text = obj["output_text"] as? String, !text.isEmpty {
                                    #if DEBUG
                                    print("[SSE] text (output_text) len:", text.count)
                                    #endif
                                    onEvent(.textDelta(text))
                                    continue
                                }
                                if let output = obj["output"] as? [[String: Any]] {
                                    for seg in output {
                                        if let segType = seg["type"] as? String,
                                           (segType == "output_text" || segType == "text"),
                                           let txt = seg["text"] as? String {
                                            #if DEBUG
                                            print("[SSE] text (output) len:", txt.count)
                                            #endif
                                            onEvent(.textDelta(txt))
                                        }
                                    }
                                    continue
                                }

                                // Completed?
                                if let status = obj["status"] as? String, status == "completed" {
                                    #if DEBUG
                                    print("[SSE] completed (status)")
                                    #endif
                                    onEvent(.completed)
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        // Stream ended without [DONE]
        onEvent(.completed)
    }
}
