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
        guard let marker = lower.range(of: "this session:") else { return nil }
        let start = line.index(line.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: marker.upperBound))
        let raw = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
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
