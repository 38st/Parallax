import Foundation

/// Parses launch arguments written like a shell command line, and environment lines.
enum LaunchText {
    enum ParseError: LocalizedError {
        case unterminatedQuote

        var errorDescription: String? { "An argument has an unmatched quote." }
    }

    /// Splits words the way a POSIX shell would, without expansions.
    static func words(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "'":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "'" { closed = true; break }
                    current.unicodeScalars.append(next)
                }
                if !closed { throw ParseError.unterminatedQuote }
            case "\"":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "\"" { closed = true; break }
                    if next == "\\" {
                        guard let escaped = iterator.next() else { throw ParseError.unterminatedQuote }
                        if !["$", "`", "\"", "\\", "\n"].contains(escaped) { current.unicodeScalars.append("\\") }
                        if escaped != "\n" { current.unicodeScalars.append(escaped) }
                        continue
                    }
                    current.unicodeScalars.append(next)
                }
                if !closed { throw ParseError.unterminatedQuote }
            case "\\":
                inWord = true
                if let escaped = iterator.next(), escaped != "\n" { current.unicodeScalars.append(escaped) }
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = ""; inWord = false }
            default:
                inWord = true
                current.unicodeScalars.append(scalar)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=,@%")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    struct Environment: Equatable {
        var values: [String: String] = [:]
        var unset: Set<String> = []
    }

    /// `KEY=VALUE` sets, `unset KEY` removes, `#` lines are comments. Later lines win.
    static func environment(_ text: String) -> Environment {
        var result = Environment()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("unset ") {
                let key = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if isValidKey(key) { result.values[key] = nil; result.unset.insert(key) }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard isValidKey(key) else { continue }
            result.values[key] = String(line[line.index(after: equals)...])
            result.unset.remove(key)
        }
        return result
    }

    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) } && key.allSatisfy(\.isASCII)
    }

    /// Removes every assignment and `unset` line for the given keys.
    static func removingEnvironment(_ keys: Set<String>, from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("unset ") { return !keys.contains(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
            guard let equals = line.firstIndex(of: "=") else { return true }
            return !keys.contains(String(line[..<equals]))
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element == String {
    /// True when an option is present as `--name`, `--name=value`, or `-name` variants given.
    func containsOption(_ names: [String]) -> Bool {
        contains { word in names.contains { word == $0 || word.hasPrefix($0 + "=") } }
    }

    /// Removes an option written as `--name=value` or `--name value`.
    func removingOption(_ names: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for word in self {
            if skipNext { skipNext = false; continue }
            if names.contains(word) { skipNext = true; continue }
            if names.contains(where: { word.hasPrefix($0 + "=") }) { continue }
            result.append(word)
        }
        return result
    }
}
