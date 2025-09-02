import Foundation

enum JSONPrettyPrinterError: Error {
    case invalidEncoding
}

struct JSONPrettyPrinter {
    static func pretty(data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: prettyData, encoding: .utf8) else {
            throw JSONPrettyPrinterError.invalidEncoding
        }
        return string
    }

    static func pretty(text: String) throws -> String {
        guard let data = text.data(using: .utf8) else {
            throw JSONPrettyPrinterError.invalidEncoding
        }
        return try pretty(data: data)
    }
}