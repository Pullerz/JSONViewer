import Foundation
import SwiftUI

struct JSONSyntaxHighlighter {
    struct Theme {
        let key = Color(.sRGB, red: 0.75, green: 0.75, blue: 0.78, opacity: 1)
        let string = Color(.sRGB, red: 0.79, green: 0.95, blue: 0.83, opacity: 1)
        let number = Color(.sRGB, red: 0.65, green: 0.84, blue: 1.0, opacity: 1)
        let boolNull = Color(.sRGB, red: 0.89, green: 0.80, blue: 1.0, opacity: 1)
        let punctuation = Color(.sRGB, red: 0.60, green: 0.63, blue: 0.66, opacity: 1)
        let base = Color.primary
    }

    static func highlight(_ text: String, limit: Int = 1_000_000) -> AttributedString? {
        guard text.utf8.count <= limit else { return nil }

        var attr = AttributedString(text)
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let theme = Theme()

        func setColor(_ color: Color, range: NSRange) {
            if let r = Range(range, in: text) {
                attr[r].foregroundColor = color
            }
        }

        // Keys: "key":
        if let keyRegex = try? NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:", options: []) {
            keyRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match, match.numberOfRanges > 1 {
                    let r = match.range(at: 1)
                    setColor(theme.key, range: r)
                }
            }
        }

        // Strings (values)
        if let stringRegex = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", options: []) {
            stringRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match {
                    setColor(theme.string, range: match.range)
                }
            }
        }

        // Numbers
        if let numberRegex = try? NSRegularExpression(pattern: "(?<![\\w\"])[-+]?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?", options: []) {
            numberRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match {
                    setColor(theme.number, range: match.range)
                }
            }
        }

        // Booleans and null
        if let boolNullRegex = try? NSRegularExpression(pattern: "\\b(true|false|null)\\b", options: []) {
            boolNullRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match {
                    setColor(theme.boolNull, range: match.range)
                }
            }
        }

        // Punctuation
        if let punctRegex = try? NSRegularExpression(pattern: "[\\{\\}\\[\\],:]", options: []) {
            punctRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match {
                    setColor(theme.punctuation, range: match.range)
                }
            }
        }

        return attr
    }
}