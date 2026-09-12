import Foundation

/// Turns free text typed by the student into a safe FTS5 MATCH expression.
/// Every whitespace-separated token becomes a quoted phrase (double quotes
/// inside are doubled), so operators, parentheses, colons and `NEAR` lose
/// their meaning; the last token is prefix-matched so results appear while
/// typing. Tokens are implicitly ANDed by FTS5.
public enum FTSQuery {
    /// - Returns: the MATCH expression, or nil when the query has no tokens.
    public static func sanitize(_ query: String) -> String? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var phrases: [String] = []
        for (index, token) in tokens.enumerated() {
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            var phrase = "\"" + escaped + "\""
            if index == tokens.count - 1 { phrase += "*" }
            phrases.append(phrase)
        }
        return phrases.joined(separator: " ")
    }
}
