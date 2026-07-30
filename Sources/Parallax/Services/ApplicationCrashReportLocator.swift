import Foundation

struct ApplicationCrashReport:
    Identifiable,
    Equatable,
    Sendable
{
    var id: URL { fileURL }

    let fileURL: URL
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let processName: String
    let launchedAt: Date?
    let capturedAt: Date
    let incidentIdentifier: String?
    let exceptionType: String?
    let signal: String?
    let reason: String?
}

struct ApplicationCrashReportLocator: Sendable {
    private struct Header: Decodable {
        let appName: String?
        let timestamp: String?
        let bundleIdentifier: String?
        let incidentIdentifier: String?

        private enum CodingKeys: String, CodingKey {
            case appName = "app_name"
            case timestamp
            case bundleIdentifier = "bundleID"
            case incidentIdentifier = "incident_id"
        }
    }

    private struct Body: Decodable {
        struct BundleInfo: Decodable {
            let bundleIdentifier: String?

            private enum CodingKeys: String, CodingKey {
                case bundleIdentifier = "CFBundleIdentifier"
            }
        }

        struct Exception: Decodable {
            let type: String?
            let signal: String?
        }

        struct Termination: Decodable {
            let indicator: String?
        }

        let processIdentifier: pid_t?
        let processName: String?
        let launchedAt: String?
        let capturedAt: String?
        let incidentIdentifier: String?
        let bundleInfo: BundleInfo?
        let exception: Exception?
        let termination: Termination?

        private enum CodingKeys: String, CodingKey {
            case processIdentifier = "pid"
            case processName = "procName"
            case launchedAt = "procLaunch"
            case capturedAt = "captureTime"
            case incidentIdentifier = "incident"
            case bundleInfo
            case exception
            case termination
        }
    }

    private static let maximumReportBytes = 16 * 1_024 * 1_024
    private static let maximumReportsToInspect = 500

    let diagnosticReportsURL: URL

    init(
        diagnosticReportsURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(
                "DiagnosticReports",
                isDirectory: true
            )
    ) {
        self.diagnosticReportsURL = diagnosticReportsURL
    }

    func reports(
        matching entries: [LaunchHistoryEntry]
    ) -> [UUID: ApplicationCrashReport] {
        let candidates = reportURLs()
            .compactMap(parseReport)
        var matches: [UUID: ApplicationCrashReport] = [:]

        for entry in entries where entry.state.isTerminal {
            guard
                let processIdentifier = entry.processIdentifier
            else {
                continue
            }
            let compatible = candidates.filter { report in
                guard
                    report.processIdentifier
                        == processIdentifier
                else {
                    return false
                }

                if let expected = entry.applicationBundleIdentifier {
                    guard report.bundleIdentifier == expected else {
                        return false
                    }
                } else if report.processName.compare(
                    entry.applicationName,
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive,
                    ]
                ) != .orderedSame {
                    return false
                }

                if let process = entry.process,
                   let launchedAt = report.launchedAt
                {
                    let recordedStart = Date(
                        timeIntervalSince1970:
                            TimeInterval(process.startTimeSeconds)
                                + TimeInterval(
                                    process.startTimeMicroseconds
                                ) / 1_000_000
                    )
                    return abs(
                        launchedAt.timeIntervalSince(recordedStart)
                    ) < 5
                }

                let earliest = entry.requestedAt.addingTimeInterval(-10)
                let latest = (entry.endedAt ?? Date())
                    .addingTimeInterval(300)
                guard
                    report.capturedAt >= earliest,
                    report.capturedAt <= latest
                else {
                    return false
                }
                if let launchedAt = report.launchedAt {
                    return launchedAt >= earliest
                        && launchedAt
                            <= (entry.endedAt ?? report.capturedAt)
                                .addingTimeInterval(10)
                }
                return true
            }

            let match: ApplicationCrashReport?
            if entry.process == nil, compatible.count != 1 {
                // A PID without a start identity can be reused. Only a unique
                // bundle/name- and time-compatible report is safe to link.
                match = nil
            } else {
                match = compatible.min(by: {
                distance(from: $0, to: entry)
                    < distance(from: $1, to: entry)
                })
            }
            if let match {
                matches[entry.requestID] = match
            }
        }
        return matches
    }

    func recentReports(
        bundleIdentifier: String?,
        processName: String,
        limit: Int = 20
    ) -> [ApplicationCrashReport] {
        reportURLs()
            .compactMap(parseReport)
            .filter { report in
                if let bundleIdentifier,
                   let reportBundleIdentifier =
                    report.bundleIdentifier
                {
                    return reportBundleIdentifier
                        == bundleIdentifier
                }
                return report.processName.compare(
                    processName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private func reportURLs() -> [URL] {
        let directories = [
            diagnosticReportsURL,
            diagnosticReportsURL.appendingPathComponent(
                "Retired",
                isDirectory: true
            ),
        ]
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        var reports: [(url: URL, modifiedAt: Date)] = []

        for directory in directories {
            guard
                let urls = try? FileManager.default
                    .contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                    )
            else {
                continue
            }

            for url in urls where url.pathExtension == "ips" {
                guard
                    let values = try? url.resourceValues(
                        forKeys: keys
                    ),
                    values.isRegularFile == true,
                    let size = values.fileSize,
                    size > 0,
                    size <= Self.maximumReportBytes
                else {
                    continue
                }
                reports.append(
                    (
                        url,
                        values.contentModificationDate
                            ?? Date.distantPast
                    )
                )
            }
        }

        return reports
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(Self.maximumReportsToInspect)
            .map(\.url)
    }

    private func parseReport(_ url: URL) -> ApplicationCrashReport? {
        guard
            let data = try? Data(
                contentsOf: url,
                options: [.mappedIfSafe]
            ),
            data.count <= Self.maximumReportBytes,
            let newline = data.firstIndex(of: 0x0A)
        else {
            return nil
        }

        let headerData = data[..<newline]
        let bodyStart = data.index(after: newline)
        let bodyData = data[bodyStart...]
        let decoder = JSONDecoder()

        guard
            let header = try? decoder.decode(
                Header.self,
                from: Data(headerData)
            ),
            let body = try? decoder.decode(
                Body.self,
                from: Data(bodyData)
            ),
            let processIdentifier = body.processIdentifier,
            let capturedAt = parseDate(
                body.capturedAt ?? header.timestamp
            )
        else {
            return nil
        }

        return ApplicationCrashReport(
            fileURL: url,
            processIdentifier: processIdentifier,
            bundleIdentifier:
                body.bundleInfo?.bundleIdentifier
                    ?? header.bundleIdentifier,
            processName: body.processName
                ?? header.appName
                ?? url.deletingPathExtension().lastPathComponent,
            launchedAt: parseDate(body.launchedAt),
            capturedAt: capturedAt,
            incidentIdentifier:
                body.incidentIdentifier
                    ?? header.incidentIdentifier,
            exceptionType: body.exception?.type,
            signal: body.exception?.signal,
            reason: body.termination?.indicator
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSS Z",
            "yyyy-MM-dd HH:mm:ss.SSS Z",
            "yyyy-MM-dd HH:mm:ss.SS Z",
            "yyyy-MM-dd HH:mm:ss Z",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private func distance(
        from report: ApplicationCrashReport,
        to entry: LaunchHistoryEntry
    ) -> TimeInterval {
        abs(
            report.capturedAt.timeIntervalSince(
                entry.endedAt ?? entry.requestedAt
            )
        )
    }
}
