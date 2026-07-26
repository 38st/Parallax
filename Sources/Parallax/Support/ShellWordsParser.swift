import Foundation

enum ShellWordsParser {
    struct ParseResult: Sendable, Equatable {
        let words: [String]
        let isSyntacticallyValid: Bool
    }

    static func parse(_ text: String) -> [String] {
        LaunchArgumentParser.parse(text).words
    }

    static func parseResult(_ text: String) -> ParseResult {
        let parsed = LaunchArgumentParser.parse(text)
        return ParseResult(
            words: parsed.words,
            isSyntacticallyValid: !parsed.hasErrors
        )
    }

    static func quote(_ word: String) -> String {
        LaunchArgumentParser.quote(word)
    }
}
