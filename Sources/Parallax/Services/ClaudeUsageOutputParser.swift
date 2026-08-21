import Foundation

enum ClaudeUsageOutputParserError: Error, Equatable {
    case invalidEnvelope
    case inferenceDetected
    case usageUnavailable
}

struct ClaudeUsageOutputParser {
    static func parse(
        _ output: String,
        now: Date = Date()
    ) throws -> [AIUsageWindow] {
        guard
            output.utf8.count <= 128 * 1_024,
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any],
            let result = envelope["result"] as? String,
            result.utf8.count <= 96 * 1_024,
            let totalCost = envelope["total_cost_usd"] as? NSNumber,
            CFGetTypeID(totalCost) != CFBooleanGetTypeID(),
            let usage = envelope["usage"] as? [String: Any],
            let inputTokens = numericValue(usage["input_tokens"]),
            let outputTokens = numericValue(usage["output_tokens"])
        else {
            throw ClaudeUsageOutputParserError.invalidEnvelope
        }
        guard
            totalCost.doubleValue == 0,
            inputTokens == 0,
            outputTokens == 0
        else {
            throw ClaudeUsageOutputParserError.inferenceDetected
        }

        var windowsByKey: [String: AIUsageWindow] = [:]
        for line in result.split(whereSeparator: \Character.isNewline) {
            guard let parsed = parseLine(String(line), now: now) else {
                continue
            }
            let key = parsed.kind.rawValue + ":"
                + (parsed.modelName?.lowercased() ?? "")
            windowsByKey[key] = parsed
            if windowsByKey.count >= 8 { break }
        }

        let windows = windowsByKey.values.sorted { lhs, rhs in
            let lhsOrder = order(lhs.kind)
            let rhsOrder = order(rhs.kind)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.modelName ?? "").localizedCaseInsensitiveCompare(
                rhs.modelName ?? ""
            ) == .orderedAscending
        }
        guard !windows.isEmpty else {
            throw ClaudeUsageOutputParserError.usageUnavailable
        }
        return windows
    }

    private static func parseLine(
        _ line: String,
        now: Date
    ) -> AIUsageWindow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let separator = trimmed.firstIndex(of: ":"),
            let usedRange = trimmed.range(of: "% used", range: separator..<trimmed.endIndex)
        else {
            return nil
        }

        let title = String(trimmed[..<separator])
        let percentageStart = trimmed.index(after: separator)
        let percentageText = trimmed[percentageStart..<usedRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let percentage = ProviderNumericDecoder.percentage(percentageText)
        else {
            return nil
        }

        let kind: AIUsageWindowKind
        let modelName: String?
        if title == "Current session" {
            kind = .session
            modelName = nil
        } else if
            title.hasPrefix("Current week ("),
            title.hasSuffix(")")
        {
            let start = title.index(
                title.startIndex,
                offsetBy: "Current week (".count
            )
            let end = title.index(before: title.endIndex)
            let scope = String(title[start..<end])
            if scope.caseInsensitiveCompare("all models") == .orderedSame {
                kind = .weeklyAllModels
                modelName = nil
            } else {
                guard let safeName = validatedModelName(scope) else {
                    return nil
                }
                kind = .weeklyModel
                modelName = safeName
            }
        } else {
            return nil
        }

        let remainder = trimmed[usedRange.upperBound...]
        let resetMarker = "· resets "
        let resetsAt: Date?
        if let markerRange = remainder.range(of: resetMarker) {
            resetsAt = parseReset(
                String(remainder[markerRange.upperBound...]),
                now: now
            )
        } else {
            resetsAt = nil
        }
        return AIUsageWindow(
            kind: kind,
            modelName: modelName,
            usagePercent: percentage,
            resetsAt: resetsAt
        )
    }

    private static func validatedModelName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= 64,
            !trimmed.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            return nil
        }
        return trimmed
    }

    private static func parseReset(_ value: String, now: Date) -> Date? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(" (UTC)") {
            normalized.removeLast(" (UTC)".count)
        }
        if normalized.hasPrefix("in "),
            let interval = relativeInterval(String(normalized.dropFirst(3)))
        {
            return now.addingTimeInterval(interval)
        }

        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        for format in [
            "MMM d 'at' h:mma yyyy",
            "MMM d 'at' h:mm a yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            guard var candidate = formatter.date(from: "\(normalized) \(year)")
            else {
                continue
            }
            if candidate < now.addingTimeInterval(-60) {
                candidate = calendar.date(
                    byAdding: .year,
                    value: 1,
                    to: candidate
                ) ?? candidate
            }
            return candidate
        }
        return nil
    }

    private static func relativeInterval(_ value: String) -> TimeInterval? {
        let pieces = value.split(whereSeparator: \Character.isWhitespace)
        guard pieces.count >= 2 else { return nil }
        var seconds: TimeInterval = 0
        var index = 0
        var matched = false
        while index + 1 < pieces.count {
            guard let amount = Double(pieces[index]) else {
                index += 1
                continue
            }
            let unit = pieces[index + 1].lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            let multiplier: TimeInterval?
            if unit.hasPrefix("day") || unit == "d" {
                multiplier = 86_400
            } else if unit.hasPrefix("hour") || unit.hasPrefix("hr")
                || unit == "h"
            {
                multiplier = 3_600
            } else if unit.hasPrefix("min") || unit == "m" {
                multiplier = 60
            } else if unit.hasPrefix("sec") || unit == "s" {
                multiplier = 1
            } else {
                multiplier = nil
            }
            if let multiplier {
                seconds += amount * multiplier
                matched = true
                index += 2
            } else {
                index += 1
            }
        }
        return matched && seconds >= 0 ? seconds : nil
    }

    private static func order(_ kind: AIUsageWindowKind) -> Int {
        switch kind {
        case .session: 0
        case .weeklyAllModels: 1
        case .weeklyModel: 2
        }
    }

    private static func numericValue(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else {
            return nil
        }
        return number.doubleValue
    }
}
