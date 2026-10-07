import Foundation

struct ProviderStatus: Sendable, Equatable {
    var email: String?
    var plan: String?
    var windows: [UsageWindow]
    /// Set when sign-in is confirmed but the usage numbers couldn't be read.
    var usageError: String?
}

/// Reads Claude usage through the `claude` CLI, signed in to a private config folder.
enum ClaudeProvider {
    private static func environment(_ configFolder: URL) -> [String: String] {
        ["CLAUDE_CONFIG_DIR": configFolder.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TZ": "UTC"]
    }

    static func signIn(configFolder: URL) async throws -> ProviderStatus {
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await ProviderCLI.run(
            "claude", ["auth", "login", "--claudeai"], environment: environment(configFolder), timeout: 300
        )
        guard result.status == 0 else { throw ProviderError.failed("Claude sign-in didn't finish.") }
        return try await status(configFolder: configFolder)
    }

    static func status(configFolder: URL) async throws -> ProviderStatus {
        let auth = try await ProviderCLI.run(
            "claude", ["auth", "status", "--json"], environment: environment(configFolder), timeout: 15
        )
        var status = try parseAuthStatus(auth.stdout)
        do {
            let usage = try await ProviderCLI.run(
                "claude",
                ["-p", "/usage", "--output-format", "json", "--tools", "", "--safe-mode",
                 "--no-session-persistence", "--max-budget-usd", "0.000001"],
                environment: environment(configFolder),
                timeout: 30
            )
            guard usage.status == 0 else { throw ProviderError.failed("Claude didn't report usage.") }
            status.windows = try parseUsage(usage.stdout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            status.usageError = error.localizedDescription
        }
        return status
    }

    static func parseAuthStatus(_ data: Data) throws -> ProviderStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.failed("Claude's sign-in status couldn't be read.")
        }
        let signedIn = (object["loggedIn"] as? Bool) ?? (object["isAuthenticated"] as? Bool)
        guard let signedIn else { throw ProviderError.failed("Claude's sign-in status couldn't be read.") }
        guard signedIn else { throw ProviderError.signedOut }
        let account = object["account"] as? [String: Any]
        let email = (object["email"] as? String) ?? (account?["email"] as? String)
        let plan = (object["subscriptionType"] as? String) ?? (object["plan"] as? String)
        return ProviderStatus(email: email, plan: plan?.capitalized, windows: [])
    }

    /// Parses `claude -p /usage --output-format json`. Rejects output that cost tokens.
    static func parseUsage(_ data: Data, now: Date = Date()) throws -> [UsageWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["result"] as? String
        else { throw ProviderError.failed("Claude's usage report couldn't be read.") }
        let cost = (object["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0
        let usage = object["usage"] as? [String: Any]
        let tokens = ((usage?["input_tokens"] as? NSNumber)?.intValue ?? 0) + ((usage?["output_tokens"] as? NSNumber)?.intValue ?? 0)
        guard cost == 0, tokens == 0 else {
            throw ProviderError.failed("Claude answered the usage request with the model instead of a report.")
        }

        var windows: [String: (order: Int, window: UsageWindow)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let parsed = parseLine(String(line), now: now) else { continue }
            windows[parsed.window.title] = parsed
        }
        guard !windows.isEmpty else { throw ProviderError.failed("Claude didn't report any usage limits.") }
        return windows.values.sorted { ($0.order, $0.window.title) < ($1.order, $1.window.title) }.map(\.window)
    }

    private static func parseLine(_ line: String, now: Date) -> (order: Int, window: UsageWindow)? {
        guard let colon = line.firstIndex(of: ":"), let used = line.range(of: "% used") else { return nil }
        let title = line[..<colon].trimmingCharacters(in: .whitespaces)
        let number = line[line.index(after: colon)..<used.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }

        let order: Int
        let name: String
        if title == "Current session" {
            order = 0
            name = "Session"
        } else if title.hasPrefix("Current week (") && title.hasSuffix(")") {
            let scope = String(title.dropFirst("Current week (".count).dropLast())
            if scope.lowercased() == "all models" {
                order = 1
                name = "Week"
            } else {
                order = 2
                name = "Week · \(scope)"
            }
        } else {
            return nil
        }

        var resetsAt: Date?
        let rest = line[used.upperBound...]
        if let marker = rest.range(of: "· resets ") {
            var reset = String(rest[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            if reset.hasSuffix("(UTC)") { reset = String(reset.dropLast(5)).trimmingCharacters(in: .whitespaces) }
            resetsAt = parseReset(reset, now: now)
        }
        var percent = Int(min(value, 100).rounded())
        if let resetsAt, resetsAt <= now { percent = 0 }
        return (order, UsageWindow(title: name, percent: percent, resetsAt: resetsAt))
    }

    /// Understands "in 4 hr 36 min", "4:36pm", and "Aug 20 at 4:36pm", all in UTC.
    static func parseReset(_ text: String, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let lowered = text.lowercased()

        if lowered.hasPrefix("in ") {
            let parts = lowered.dropFirst(3).split(separator: " ")
            var seconds = 0.0
            var index = 0
            while index + 1 < parts.count {
                guard let amount = Double(parts[index]) else { return nil }
                let unit = parts[index + 1]
                if unit.hasPrefix("d") { seconds += amount * 86_400 }
                else if unit.hasPrefix("h") { seconds += amount * 3_600 }
                else if unit.hasPrefix("m") { seconds += amount * 60 }
                else if unit.hasPrefix("s") { seconds += amount }
                else { return nil }
                index += 2
            }
            guard index == parts.count, seconds <= 366 * 86_400 else { return nil }
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.isLenient = false
        let compact = text.replacingOccurrences(of: " ", with: "").uppercased()

        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: compact) {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                guard var date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { return nil }
                if date < now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
                return date
            }
        }

        let pieces = text.components(separatedBy: " at ")
        guard pieces.count == 2 else { return nil }
        formatter.dateFormat = "MMM d"
        guard let day = formatter.date(from: pieces[0]) else { return nil }
        var time: Date?
        for format in ["h:mma", "ha"] where time == nil {
            formatter.dateFormat = format
            time = formatter.date(from: pieces[1].replacingOccurrences(of: " ", with: "").uppercased())
        }
        guard let time else { return nil }
        let dayParts = calendar.dateComponents([.month, .day], from: day)
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        let year = calendar.component(.year, from: now)
        var components = DateComponents(year: year, month: dayParts.month, day: dayParts.day, hour: timeParts.hour, minute: timeParts.minute)
        guard var date = calendar.date(from: components) else { return nil }
        if date.timeIntervalSince(now) < -180 * 86_400 {
            components.year = year + 1
            date = calendar.date(from: components) ?? date
        } else if date.timeIntervalSince(now) > 180 * 86_400 {
            components.year = year - 1
            date = calendar.date(from: components) ?? date
        }
        return date
    }
}
