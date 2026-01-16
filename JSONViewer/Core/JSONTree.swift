import Foundation

enum JSONScalar: Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

struct JSONTreeNode: Identifiable, Hashable {
    let id = UUID()
    let key: String?
    let path: String   // full path from root (e.g., user.name or [0].id)
    let scalar: JSONScalar?
    var children: [JSONTreeNode]? = nil

    var isLeaf: Bool { children == nil }
}

enum JSONTreeBuilderError: Error {
    case invalid
}

struct JSONTreeBuilder {
    static func build(from data: Data) throws -> JSONTreeNode {
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        return build(from: any, key: nil, parentPath: "")
    }

    static func build(from text: String) throws -> JSONTreeNode {
        guard let data = text.data(using: .utf8) else { throw JSONTreeBuilderError.invalid }
        return try build(from: data)
    }

    static func build(from any: Any, key: String?, parentPath: String) -> JSONTreeNode {
        let path: String
        if let k = key {
            if k.hasPrefix("[") {
                path = parentPath.isEmpty ? k : parentPath + k
            } else {
                path = parentPath.isEmpty ? k : parentPath + "." + k
            }
        } else {
            path = ""
        }

        if let dict = any as? [String: Any] {
            let children = dict.keys.sorted().map { k in
                build(from: dict[k] as Any, key: k, parentPath: path)
            }
            return JSONTreeNode(key: key, path: path, scalar: nil, children: children)
        } else if let array = any as? [Any] {
            let children = array.enumerated().map { (idx, el) in
                build(from: el, key: "[\(idx)]", parentPath: path)
            }
            return JSONTreeNode(key: key, path: path, scalar: nil, children: children)
        } else if let s = any as? String {
            return JSONTreeNode(key: key, path: path, scalar: .string(s))
        } else if let n = any as? NSNumber {
            if n === kCFBooleanTrue || n === kCFBooleanFalse {
                return JSONTreeNode(key: key, path: path, scalar: .bool(n.boolValue))
            } else {
                return JSONTreeNode(key: key, path: path, scalar: .number(n.doubleValue))
            }
        } else if any is NSNull {
            return JSONTreeNode(key: key, path: path, scalar: .null)
        } else {
            return JSONTreeNode(key: key, path: path, scalar: .null)
        }
    }
}

extension JSONTreeNode {
    var displayKey: String {
        key ?? "root"
    }

    var previewValue: String {
        guard let scalar else { return children != nil ? "…" : "" }
        switch scalar {
        case .string(let s): return "\"\(s)\""
        case .number(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// Full JSON string for this node.
    func asJSONString() -> String {
        return asJSONString(limit: nil)
    }

    /// JSON string for this node, optionally truncated to a maximum number of characters.
    /// When truncated, the returned string will end with "… (truncated)" and may not be valid JSON.
    func asJSONString(limit: Int?) -> String {
        var output = ""
        var remaining = limit ?? Int.max
        var truncated = false

        writeJSON(into: &output, remaining: &remaining, truncated: &truncated)

        if truncated, limit != nil {
            output.append("… (truncated)")
        }
        return output
    }

    private func writeJSON(into output: inout String, remaining: inout Int, truncated: inout Bool) {
        if truncated || remaining <= 0 {
            truncated = true
            return
        }

        if let scalar {
            switch scalar {
            case .string(let s):
                append("\"\(s)\"", to: &output, remaining: &remaining, truncated: &truncated)
            case .number(let d):
                append(String(d), to: &output, remaining: &remaining, truncated: &truncated)
            case .bool(let b):
                append(b ? "true" : "false", to: &output, remaining: &remaining, truncated: &truncated)
            case .null:
                append("null", to: &output, remaining: &remaining, truncated: &truncated)
            }
            return
        }

        if let children {
            let isArray = children.first?.key?.hasPrefix("[") == true
            if isArray {
                append("[", to: &output, remaining: &remaining, truncated: &truncated)
                for (index, child) in children.enumerated() {
                    if truncated || remaining <= 0 { break }
                    if index > 0 {
                        append(", ", to: &output, remaining: &remaining, truncated: &truncated)
                    }
                    child.writeJSON(into: &output, remaining: &remaining, truncated: &truncated)
                }
                append("]", to: &output, remaining: &remaining, truncated: &truncated)
            } else {
                append("{", to: &output, remaining: &remaining, truncated: &truncated)
                for (index, child) in children.enumerated() {
                    if truncated || remaining <= 0 { break }
                    if index > 0 {
                        append(", ", to: &output, remaining: &remaining, truncated: &truncated)
                    }
                    let key = child.key ?? ""
                    append("\"\(key)\": ", to: &output, remaining: &remaining, truncated: &truncated)
                    child.writeJSON(into: &output, remaining: &remaining, truncated: &truncated)
                }
                append("}", to: &output, remaining: &remaining, truncated: &truncated)
            }
        } else {
            append("null", to: &output, remaining: &remaining, truncated: &truncated)
        }
    }

    private func append(_ string: String, to output: inout String, remaining: inout Int, truncated: inout Bool) {
        if truncated || remaining <= 0 {
            truncated = true
            return
        }
        if string.count <= remaining {
            output.append(string)
            remaining -= string.count
        } else {
            let index = string.index(string.startIndex, offsetBy: remaining)
            output.append(contentsOf: string[string.startIndex..<index])
            remaining = 0
            truncated = true
        }
    }

    func find(byPath target: String) -> JSONTreeNode? {
        if self.path == target {
            return self
        }
        guard let children else { return nil }
        for child in children {
            if let found = child.find(byPath: target) {
                return found
            }
        }
        return nil
    }
}