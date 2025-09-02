import Foundation

struct OpenAIClient {
    struct ToolCall {
        let id: String
        let name: String
        let argumentsJSON: String
    }

    struct ToolOutput {
        let toolCallId: String
        let output: String
    }

    struct Config {
        let apiKey: String
        let model: String
        let systemPrompt: String
    }

    enum ClientError: Error, LocalizedError {
        case missingAPIKey
        case badResponse
        case http(Int, String)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "OpenAI API key not configured"
            case .badResponse: return "Unexpected API response"
            case .http(let code, let body): return "OpenAI HTTP \(code): \(body)"
            case .decoding: return "Failed to decode OpenAI response"
            }
        }
    }

    // MARK: - Public

    static func loadAPIKeyFromDefaultsOrEnv() -> String? {
        if let key = UserDefaults.standard.string(forKey: "openai_api_key"), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    static func createResponse(config: Config, userText: String, tools: [[String: Any]]) async throws -> [String: Any] {
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
            "temperature": 0.2
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(http.statusCode, text)
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        return obj ?? [:]
    }

    static func submitToolOutputs(apiKey: String, model: String, responseId: String, toolOutputs: [ToolOutput]) async throws -> [String: Any] {
        // Submit tool outputs by POSTing to /v1/responses with previous_response_id and model
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "previous_response_id": responseId,
            "tool_outputs": toolOutputs.map { ["tool_call_id": $0.toolCallId, "output": $0.output] },
            // Responses API requires the 'input' param even when only submitting tool outputs.
            "input": []
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(http.statusCode, text)
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        return obj ?? [:]
    }

    // MARK: - Helpers

    static func extractToolCalls(_ response: [String: Any]) -> (responseId: String, calls: [ToolCall])? {
        // Expected shapes (approx):
        // Old: { required_action: { tool_calls: [ { id, function: { name, arguments } } ] } }
        // New: { required_action: { tool_calls: [ { id, name, arguments } ] } }
        guard let responseId = response["id"] as? String else { return nil }
        guard let required = response["required_action"] as? [String: Any] else { return nil }
        guard let toolCalls = required["tool_calls"] as? [[String: Any]] ?? (required["submit_tool_outputs"] as? [String: Any])?["tool_calls"] as? [[String: Any]] else {
            return nil
        }
        let calls: [ToolCall] = toolCalls.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            // New shape: name/arguments at top level
            if let name = c["name"] as? String {
                if let a = c["arguments"] as? String {
                    return ToolCall(id: id, name: name, argumentsJSON: a)
                } else if let aObj = c["arguments"] as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: aObj),
                          let a = String(data: data, encoding: .utf8) {
                    return ToolCall(id: id, name: name, argumentsJSON: a)
                }
            }
            // Old shape: nested under "function"
            if let function = c["function"] as? [String: Any],
               let name = function["name"] as? String,
               let args = function["arguments"] as? String {
                return ToolCall(id: id, name: name, argumentsJSON: args)
            }
            return nil
        }
        return (responseId, calls)
    }

    static func extractText(_ response: [String: Any]) -> String? {
        // Expected possible shapes: "output_text" or nested in "output" array segments
        if let text = response["output_text"] as? String { return text }
        if let output = response["output"] as? [[String: Any]] {
            var buffer = ""
            for seg in output {
                if let type = seg["type"] as? String, type == "output_text",
                   let text = seg["text"] as? String {
                    buffer += text
                } else if let type = seg["type"] as? String, type == "message",
                          let content = seg["content"] as? [[String: Any]] {
                    for item in content {
                        if let t = item["type"] as? String, t == "text",
                           let val = item["text"] as? String {
                            buffer += val
                        }
                    }
                }
            }
            if !buffer.isEmpty { return buffer }
        }
        return nil
    }
}