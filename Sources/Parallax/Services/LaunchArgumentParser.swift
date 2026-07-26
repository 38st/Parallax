import Foundation

struct LaunchArgumentToken: Sendable, Equatable {
    let value: String
    let range: LaunchSourceRange
}

struct LaunchArgumentParseResult: Sendable, Equatable {
    let tokens: [LaunchArgumentToken]
    let diagnostics: [LaunchParsingDiagnostic]

    var words: [String] {
        tokens.map(\.value)
    }

    var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

enum LaunchArgumentParser {
    static func parse(_ text: String) -> LaunchArgumentParseResult {
        var tokens: [LaunchArgumentToken] = []
        var diagnostics: [LaunchParsingDiagnostic] = []
        var current = ""
        var tokenStart: LaunchSourceLocation?
        var activeQuote: Character?
        var quoteStart: LaunchSourceLocation?
        var isEscaped = false
        var escapeStart: LaunchSourceLocation?
        var location = LaunchSourceLocation(utf16Offset: 0, line: 1, column: 1)

        for character in text {
            let characterStart = location
            let characterEnd = advanced(location, by: character)
            location = characterEnd

            if isUnsupportedControlCharacter(character) {
                diagnostics.append(
                    LaunchParsingDiagnostic(
                        code: .unsupportedControlCharacter,
                        source: .arguments,
                        range: LaunchSourceRange(
                            start: characterStart,
                            end: characterEnd
                        )
                    )
                )
                continue
            }

            if let quote = activeQuote {
                if quote == "'" {
                    if character == quote {
                        activeQuote = nil
                        quoteStart = nil
                    } else {
                        current.append(character)
                    }
                } else if isEscaped {
                    current.append(character)
                    isEscaped = false
                    escapeStart = nil
                } else if character == "\\" {
                    isEscaped = true
                    escapeStart = characterStart
                } else if character == quote {
                    activeQuote = nil
                    quoteStart = nil
                } else {
                    current.append(character)
                }
                if tokenStart == nil {
                    tokenStart = characterStart
                }
                continue
            }

            if isEscaped {
                current.append(character)
                isEscaped = false
                escapeStart = nil
                continue
            }

            if character == "\\" {
                tokenStart = tokenStart ?? characterStart
                isEscaped = true
                escapeStart = characterStart
            } else if character == "\"" || character == "'" {
                tokenStart = tokenStart ?? characterStart
                activeQuote = character
                quoteStart = characterStart
            } else if character.isWhitespace {
                if let start = tokenStart {
                    tokens.append(
                        LaunchArgumentToken(
                            value: current,
                            range: LaunchSourceRange(
                                start: start,
                                end: characterStart
                            )
                        )
                    )
                    current.removeAll(keepingCapacity: true)
                    tokenStart = nil
                }
            } else {
                tokenStart = tokenStart ?? characterStart
                current.append(character)
            }
        }

        if isEscaped {
            // Preserve the legacy partial-token value for editing previews while
            // the blocking diagnostic prevents it from being launched.
            current.append("\\")
            diagnostics.append(
                LaunchParsingDiagnostic(
                    code: .trailingEscape,
                    source: .arguments,
                    range: LaunchSourceRange(
                        start: escapeStart ?? location,
                        end: location
                    )
                )
            )
        }

        if let activeQuote, let quoteStart {
            diagnostics.append(
                LaunchParsingDiagnostic(
                    code: activeQuote == "'"
                        ? .unmatchedSingleQuote
                        : .unmatchedDoubleQuote,
                    source: .arguments,
                    range: LaunchSourceRange(
                        start: quoteStart,
                        end: location
                    )
                )
            )
        }

        if let tokenStart {
            tokens.append(
                LaunchArgumentToken(
                    value: current,
                    range: LaunchSourceRange(start: tokenStart, end: location)
                )
            )
        }

        return LaunchArgumentParseResult(
            tokens: tokens,
            diagnostics: diagnostics
        )
    }

    static func serialize(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }

        let unquotedScalars = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_+-./:=,@%"))
        guard word.unicodeScalars.allSatisfy({ unquotedScalars.contains($0) }) else {
            return "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return word
    }

    private static func advanced(
        _ location: LaunchSourceLocation,
        by character: Character
    ) -> LaunchSourceLocation {
        let width = String(character).utf16.count
        if character == "\n" {
            return LaunchSourceLocation(
                utf16Offset: location.utf16Offset + width,
                line: location.line + 1,
                column: 1
            )
        }
        return LaunchSourceLocation(
            utf16Offset: location.utf16Offset + width,
            line: location.line,
            column: location.column + width
        )
    }

    private static func isUnsupportedControlCharacter(_ character: Character) -> Bool {
        guard !character.isWhitespace else { return false }
        return character.unicodeScalars.contains {
            $0.value == 0 || $0.value == 0x7f || $0.value < 0x20
        }
    }
}
