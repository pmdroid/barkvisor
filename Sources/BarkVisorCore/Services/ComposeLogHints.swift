import Foundation

public enum ComposeLogHints {
    public static func firstPassword(in text: String) -> String? {
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let value = firstPassword(inLine: String(line)) {
                return value
            }
        }
        return nil
    }

    public static func firstPassword(inLine line: String) -> String? {
        let lower = line.lowercased()
        guard lower.contains("temporary password is provided for this session")
            || lower.contains("webui administrator password was not set")
        else { return nil }
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let raw = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if token.isEmpty { return nil }
        return token
    }

    public static func isFirstPasswordLine(_ line: String) -> Bool {
        firstPassword(inLine: line) != nil
    }

    public static func lines(from text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty }
    }
}
