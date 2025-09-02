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

        let body: [String: Any] = [
            "model": config.model,
            "input": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": userText]
            ],
            "tools": tools,
            "stream": true,
            "temperature": 0.2
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
        if !(200..<300).contains(http.statusCode) {
            // Try to fetch error body for better diagnostics
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let text = String(data: data, encoding: .utf8) ?? ""
                throw OpenAIClient.ClientError.http(http.statusCode, text.isEmpty ? "Non-200 streaming response" : text)
            } catch {
                throw OpenAIClient.ClientError.http(http.statusCode, "Non-200 streaming response")
            }
        }

        var buffer = Data()
        for try await chunk in bytes {
            buffer.append(chunk)
            // Split on double newlines (end of SSE event)
            while let range = buffer.range(of: Data("\n\n".utf8)) {
                let eventData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let line = String(data: eventData, encoding: .utf8) {
                    // Parse SSE fields (we care about "data:" lines)
                    for s in line.split(separator: "\n") {
                        if s.hasPrefix("data:") {
                            let payload = s.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { onEvent(.completed); return }
                            if payload.isEmpty { continue }
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
                                            if let fn = c["function"] as? [String: Any],
                                               let name = fn["name"] as? String,
                                               let args = fn["arguments"] as? String {
                                                return (id, name, args)
                                            }
                                            return nil
                                        }
                                        onEvent(.requiresAction(responseId: responseId, toolCalls: tuples))
                                        continue
                                    }
                                }

                                // Extract text delta possibilities
                                if let t = obj["type"] as? String, t.contains("delta") {
                                    if let delta = obj["delta"] as? [String: Any] {
                                        if let text = delta["output_text"] as? String {
                                            onEvent(.textDelta(text))
                                            continue
                                        }
                                        if let content = delta["content"] as? [[String: Any]] {
                                            for item in content {
                                                if let itemType = item["type"] as? String,
                                                   (itemType.contains("output_text") || itemType == "text"),
                                                   let txt = item["text"] as? String {
                                                    onEvent(.textDelta(txt))
                                                }
                                            }
                                            continue
                                        }
                                    }
                                }

                                // Non-delta but direct text output
                                if let text = obj["output_text"] as? String, !text.isEmpty {
                                    onEvent(.textDelta(text))
                                    continue
                                }
                                if let output = obj["output"] as? [[String: Any]] {
                                    for seg in output {
                                        if let segType = seg["type"] as? String,
                                           (segType == "output_text" || segType == "text"),
                                           let txt = seg["text"] as? String {
                                            onEvent(.textDelta(txt))
                                        }
                                    }
                                    continue
                                }

                                // Completed?
                                if let status = obj["status"] as? String, status == "completed" {
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