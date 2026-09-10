import Foundation

/// UI language is shared with non-UI error and diagnostic producers. Access is synchronized;
/// speech and message defaults take an explicit language from their settings snapshot instead.
public enum L10n {
    private static let lock = NSLock()
    private static var selectedLanguage = AppLanguage.system
    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selectedLanguage }
        set { lock.lock(); defer { lock.unlock() }; selectedLanguage = newValue }
    }

    public static func key(_ key: String, language: AppLanguage? = nil) -> String {
        (language ?? self.language) == .english ? english[key] ?? key : key
    }

    public static func text(_ message: Message, language: AppLanguage? = nil) -> String {
        let template = key(message.key, language: language)
        // Substitute once: user text that contains {0} must never become another placeholder.
        let pattern = #/\{(\d+)\}/#
        return template.replacing(pattern) { match in
            guard let index = Int(match.output.1), message.arguments.indices.contains(index) else { return String(match.output.0) }
            return message.arguments[index]
        }
    }

    /// Refresh an already-rendered app status when switching languages. This is used only
    /// for app-owned status fields, never for transcripts, replies, templates, or recordings.
    public static func relocalizeStatus(_ value: String, from previous: AppLanguage) -> String {
        guard previous != language else { return value }
        for (japanese, english) in english {
            let source = previous == .japanese ? japanese : english
            let target = previous == .japanese ? english : japanese
            if source == value { return target }
            let placeholders = source.matches(of: #/\{\d+\}/#)
            guard !placeholders.isEmpty else { continue }
            var pattern = "", start = source.startIndex
            for placeholder in placeholders {
                pattern += NSRegularExpression.escapedPattern(for: String(source[start..<placeholder.range.lowerBound])) + "(.*?)"
                start = placeholder.range.upperBound
            }
            pattern += NSRegularExpression.escapedPattern(for: String(source[start...]))
            guard let regex = try? NSRegularExpression(pattern: "\\A" + pattern + "\\z", options: .dotMatchesLineSeparators),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            var arguments: [String: String] = [:]
            for (index, placeholder) in placeholders.enumerated() {
                if let range = Range(match.range(at: index + 1), in: value) {
                    arguments[String(placeholder.output)] = String(value[range])
                }
            }
            return target.replacing(#/\{\d+\}/#) { arguments[String($0.output)] ?? String($0.output) }
        }
        return value
    }

    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]
        public init(stringLiteral value: String) { key = value; arguments = [] }
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }
        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            public init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
            public mutating func appendLiteral(_ literal: String) { key += literal }
            public mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }
}
