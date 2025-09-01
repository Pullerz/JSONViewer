import Foundation

enum JSONScalar: Equatable {
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

    func asJSONString() -> String {
        if let scalar {
            switch scalar {
            case .string(let s): return "\"\(s)\""
            case .number(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            }
        } else if let children {
            if children.first?.key?.hasPrefix("[") == true {
                // array
                let inner = children.map { $0.asJSONString() }.joined(separator: ", ")
                return "[\(inner)]"
            } else {
                let inner = children.map { child in
                    let key = child.key ?? ""
                    return "\"\(key)\": \(child.asJSONString())"
                }.joined(separator: ", ")
                return "{\(inner)}"
            }
        } else {
            return "null"
        }
    }
}