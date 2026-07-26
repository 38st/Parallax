import Foundation

enum LaunchEnvironmentOperation: Sendable, Equatable {
    case set(String)
    case unset
}

struct LaunchEnvironmentEntry: Sendable, Equatable {
    let name: String
    let operation: LaunchEnvironmentOperation
    let range: LaunchSourceRange
    let nameRange: LaunchSourceRange
    let valueRange: LaunchSourceRange?
}

struct LaunchEnvironmentParseResult: Sendable, Equatable {
    let entries: [LaunchEnvironmentEntry]
    let diagnostics: [LaunchParsingDiagnostic]

    var effectiveOperations: [String: LaunchEnvironmentOperation] {
        entries.reduce(into: [:]) { result, entry in
            result[entry.name] = entry.operation
        }
    }

    var effectiveValues: [String: String] {
        effectiveOperations.reduce(into: [:]) { result, item in
            if case let .set(value) = item.value {
                result[item.key] = value
            }
        }
    }

    var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

enum LaunchEnvironmentParser {
    static func parse(_ text: String) -> LaunchEnvironmentParseResult {
        var entries: [LaunchEnvironmentEntry] = []
        var diagnostics: [LaunchParsingDiagnostic] = []
        var firstRanges: [String: LaunchSourceRange] = [:]
        let source = text as NSString
        let sourceLength = source.length
        var lineStartOffset = 0
        var lineNumber = 1

        while lineStartOffset <= sourceLength {
            let remainingRange = NSRange(
                location: lineStartOffset,
                length: sourceLength - lineStartOffset
            )
            let newlineRange = source.range(
                of: "\n",
                options: [],
                range: remainingRange
            )
            let hasNewline = newlineRange.location != NSNotFound
            let rawLineEnd = hasNewline ? newlineRange.location : sourceLength
            let contentEnd: Int
            if rawLineEnd > lineStartOffset,
               source.character(at: rawLineEnd - 1) == 0x0d
            {
                contentEnd = rawLineEnd - 1
            } else {
                contentEnd = rawLineEnd
            }
            let content = source.substring(
                with: NSRange(
                    location: lineStartOffset,
                    length: contentEnd - lineStartOffset
                )
            )

            let parsed = parseLine(
                content,
                lineNumber: lineNumber,
                lineStartOffset: lineStartOffset
            )
            diagnostics.append(contentsOf: parsed.diagnostics)

            if let entry = parsed.entry {
                if let firstRange = firstRanges[entry.name] {
                    diagnostics.append(
                        LaunchParsingDiagnostic(
                            code: .duplicateEnvironmentName,
                            severity: .warning,
                            source: .environment,
                            range: entry.nameRange,
                            relatedRange: firstRange
                        )
                    )
                } else {
                    firstRanges[entry.name] = entry.nameRange
                }
                entries.append(entry)
            }

            guard hasNewline else { break }
            lineStartOffset = newlineRange.location + newlineRange.length
            lineNumber += 1
        }

        return LaunchEnvironmentParseResult(
            entries: entries,
            diagnostics: diagnostics
        )
    }

    private static func parseLine(
        _ line: String,
        lineNumber: Int,
        lineStartOffset: Int
    ) -> (
        entry: LaunchEnvironmentEntry?,
        diagnostics: [LaunchParsingDiagnostic]
    ) {
        let contentStart = line.firstIndex(where: { !isHorizontalWhitespace($0) })
            ?? line.endIndex
        guard contentStart != line.endIndex else { return (nil, []) }
        guard line[contentStart] != "#" else { return (nil, []) }

        if let controlRange = unsupportedControlRange(
            in: line,
            lineNumber: lineNumber,
            lineStartOffset: lineStartOffset
        ) {
            return (
                nil,
                [
                    LaunchParsingDiagnostic(
                        code: .unsupportedControlCharacter,
                        source: .environment,
                        range: controlRange
                    )
                ]
            )
        }

        let meaningful = line[contentStart...]
        if meaningful.hasPrefix("unset"),
           let afterUnset = line.index(
               contentStart,
               offsetBy: "unset".count,
               limitedBy: line.endIndex
           ),
           afterUnset < line.endIndex,
           isHorizontalWhitespace(line[afterUnset])
        {
            return parseUnset(
                line,
                contentStart: contentStart,
                afterUnset: afterUnset,
                lineNumber: lineNumber,
                lineStartOffset: lineStartOffset
            )
        }

        guard let separator = line[contentStart...].firstIndex(of: "=") else {
            let range = sourceRange(
                in: line,
                from: contentStart,
                to: line.endIndex,
                lineNumber: lineNumber,
                lineStartOffset: lineStartOffset
            )
            return (
                nil,
                [
                    LaunchParsingDiagnostic(
                        code: .malformedEnvironmentLine,
                        source: .environment,
                        range: range
                    )
                ]
            )
        }

        let rawName = line[contentStart..<separator]
        let nameStart = rawName.firstIndex(where: { !isHorizontalWhitespace($0) })
            ?? rawName.endIndex
        let nameEnd = rawName.lastIndex(where: { !isHorizontalWhitespace($0) })
            .map { line.index(after: $0) }
            ?? rawName.endIndex
        let name = String(line[nameStart..<nameEnd])
        let nameRange = sourceRange(
            in: line,
            from: nameStart,
            to: nameEnd,
            lineNumber: lineNumber,
            lineStartOffset: lineStartOffset
        )
        guard isValidEnvironmentName(name) else {
            return (
                nil,
                [
                    LaunchParsingDiagnostic(
                        code: .invalidEnvironmentName,
                        source: .environment,
                        range: nameRange
                    )
                ]
            )
        }

        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...])
        return (
            LaunchEnvironmentEntry(
                name: name,
                operation: .set(value),
                range: sourceRange(
                    in: line,
                    from: contentStart,
                    to: line.endIndex,
                    lineNumber: lineNumber,
                    lineStartOffset: lineStartOffset
                ),
                nameRange: nameRange,
                valueRange: sourceRange(
                    in: line,
                    from: valueStart,
                    to: line.endIndex,
                    lineNumber: lineNumber,
                    lineStartOffset: lineStartOffset
                )
            ),
            []
        )
    }

    private static func parseUnset(
        _ line: String,
        contentStart: String.Index,
        afterUnset: String.Index,
        lineNumber: Int,
        lineStartOffset: Int
    ) -> (
        entry: LaunchEnvironmentEntry?,
        diagnostics: [LaunchParsingDiagnostic]
    ) {
        let remainder = line[afterUnset...]
        let nameStart = remainder.firstIndex(where: { !isHorizontalWhitespace($0) })
            ?? line.endIndex
        let nameEnd = line[nameStart...]
            .lastIndex(where: { !isHorizontalWhitespace($0) })
            .map { line.index(after: $0) }
            ?? nameStart
        let name = String(line[nameStart..<nameEnd])
        let nameRange = sourceRange(
            in: line,
            from: nameStart,
            to: nameEnd,
            lineNumber: lineNumber,
            lineStartOffset: lineStartOffset
        )
        guard isValidEnvironmentName(name) else {
            return (
                nil,
                [
                    LaunchParsingDiagnostic(
                        code: .invalidEnvironmentName,
                        source: .environment,
                        range: nameRange
                    )
                ]
            )
        }
        return (
            LaunchEnvironmentEntry(
                name: name,
                operation: .unset,
                range: sourceRange(
                    in: line,
                    from: contentStart,
                    to: line.endIndex,
                    lineNumber: lineNumber,
                    lineStartOffset: lineStartOffset
                ),
                nameRange: nameRange,
                valueRange: nil
            ),
            []
        )
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard isASCIILetter(first) || first == "_" else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            isASCIILetter($0) || isASCIIDigit($0) || $0 == "_"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func unsupportedControlRange(
        in line: String,
        lineNumber: Int,
        lineStartOffset: Int
    ) -> LaunchSourceRange? {
        for index in line.indices {
            let character = line[index]
            if character != "\t",
               character.unicodeScalars.contains(where: {
                   $0.value == 0 || $0.value == 0x7f || $0.value < 0x20
               })
            {
                return sourceRange(
                    in: line,
                    from: index,
                    to: line.index(after: index),
                    lineNumber: lineNumber,
                    lineStartOffset: lineStartOffset
                )
            }
        }
        return nil
    }

    private static func sourceRange(
        in line: String,
        from start: String.Index,
        to end: String.Index,
        lineNumber: Int,
        lineStartOffset: Int
    ) -> LaunchSourceRange {
        let startOffset = line[..<start].utf16.count
        let endOffset = line[..<end].utf16.count
        return LaunchSourceRange(
            start: LaunchSourceLocation(
                utf16Offset: lineStartOffset + startOffset,
                line: lineNumber,
                column: startOffset + 1
            ),
            end: LaunchSourceLocation(
                utf16Offset: lineStartOffset + endOffset,
                line: lineNumber,
                column: endOffset + 1
            )
        )
    }
}
