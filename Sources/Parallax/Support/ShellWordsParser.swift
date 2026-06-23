import Foundation

enum ShellWordsParser {
    static func parse(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false
        var didStartWord = false

        for character in text {
            if let activeQuote = quote {
                if activeQuote == "'" {
                    if character == activeQuote {
                        quote = nil
                    } else {
                        current.append(character)
                    }
                } else {
                    if isEscaped {
                        current.append(character)
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == activeQuote {
                        quote = nil
                    } else {
                        current.append(character)
                    }
                }
                didStartWord = true
                continue
            }

            if isEscaped {
                current.append(character)
                isEscaped = false
                didStartWord = true
                continue
            }

            if character == "\\" {
                isEscaped = true
                didStartWord = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                didStartWord = true
            } else if character.isWhitespace {
                if didStartWord {
                    words.append(current)
                    current.removeAll()
                    didStartWord = false
                }
            } else {
                current.append(character)
                didStartWord = true
            }
        }

        if isEscaped {
            current.append("\\")
        }

        if didStartWord {
            words.append(current)
        }

        return words
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
}
