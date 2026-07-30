import Foundation
import XCTest
@testable import Parallax

final class ApplicationCrashReportLocatorTests: XCTestCase {
    func testMatchesReportByProcessStartIdentityAndBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-crash-reports-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchedAt = try date(
            "2027-01-15 10:00:00.2500 -0500"
        )
        let capturedAt = try date(
            "2027-01-15 10:05:00.0000 -0500"
        )
        let process = ProcessStartIdentity(
            processIdentifier: 8_161,
            startTimeSeconds: UInt64(
                launchedAt.timeIntervalSince1970
            ),
            startTimeMicroseconds: 250_000
        )
        let entry = makeEntry(
            process: process,
            requestedAt: launchedAt,
            endedAt: capturedAt
        )
        try writeReport(
            to: directory.appendingPathComponent(
                "ChatGPT-2027-01-15-100500.ips"
            ),
            processIdentifier: process.processIdentifier
        )

        let locator = ApplicationCrashReportLocator(
            diagnosticReportsURL: directory
        )
        let report = try XCTUnwrap(
            locator.reports(matching: [entry])[entry.requestID]
        )

        XCTAssertEqual(report.processIdentifier, 8_161)
        XCTAssertEqual(report.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(report.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(report.signal, "SIGSEGV")
        XCTAssertEqual(report.reason, "Segmentation fault: 11")
        XCTAssertEqual(
            locator.recentReports(
                bundleIdentifier: "com.openai.codex",
                processName: "ChatGPT"
            ).map(\.fileURL),
            [report.fileURL]
        )
    }

    func testRejectsSamePIDFromDifferentBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-crash-reports-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchedAt = try date(
            "2027-01-15 10:00:00.2500 -0500"
        )
        let process = ProcessStartIdentity(
            processIdentifier: 8_161,
            startTimeSeconds: UInt64(
                launchedAt.timeIntervalSince1970
            ),
            startTimeMicroseconds: 250_000
        )
        var entry = makeEntry(
            process: process,
            requestedAt: launchedAt,
            endedAt: launchedAt.addingTimeInterval(300)
        )
        entry.applicationBundleIdentifier = "com.example.other"
        try writeReport(
            to: directory.appendingPathComponent(
                "ChatGPT-2027-01-15-100500.ips"
            ),
            processIdentifier: process.processIdentifier
        )

        let matches = ApplicationCrashReportLocator(
            diagnosticReportsURL: directory
        ).reports(matching: [entry])

        XCTAssertTrue(matches.isEmpty)
    }

    func testUniquelyLinksImmediateExitWithoutProcessStartIdentity()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-crash-reports-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let requestedAt = try date(
            "2027-01-15 10:00:00.2500 -0500"
        )
        var entry = makeEntry(
            process: ProcessStartIdentity(
                processIdentifier: 8_161,
                startTimeSeconds: UInt64(
                    requestedAt.timeIntervalSince1970
                ),
                startTimeMicroseconds: 250_000
            ),
            requestedAt: requestedAt,
            endedAt: requestedAt.addingTimeInterval(300)
        )
        entry.process = nil
        entry.observedProcessIdentifier = 8_161
        entry.terminationDisposition = .unexpected
        try writeReport(
            to: directory.appendingPathComponent(
                "ChatGPT-2027-01-15-100500.ips"
            ),
            processIdentifier: 8_161
        )

        let match = ApplicationCrashReportLocator(
            diagnosticReportsURL: directory
        ).reports(matching: [entry])[entry.requestID]

        XCTAssertNotNil(match)
    }

    private func makeEntry(
        process: ProcessStartIdentity,
        requestedAt: Date,
        endedAt: Date
    ) -> LaunchHistoryEntry {
        LaunchHistoryEntry(
            requestID: UUID(),
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID(),
            applicationName: "ChatGPT",
            applicationBundleIdentifier: "com.openai.codex",
            profileName: "Work",
            requestedAt: requestedAt,
            startedAt: requestedAt,
            endedAt: endedAt,
            state: .closed,
            process: process
        )
    }

    private func writeReport(
        to url: URL,
        processIdentifier: pid_t
    ) throws {
        let header: [String: Any] = [
            "app_name": "ChatGPT",
            "timestamp": "2027-01-15 10:05:00.0000 -0500",
            "bundleID": "com.openai.codex",
            "incident_id": "TEST-INCIDENT",
        ]
        let body: [String: Any] = [
            "pid": processIdentifier,
            "procName": "ChatGPT",
            "procLaunch": "2027-01-15 10:00:00.2500 -0500",
            "captureTime": "2027-01-15 10:05:00.0000 -0500",
            "incident": "TEST-INCIDENT",
            "bundleInfo": [
                "CFBundleIdentifier": "com.openai.codex"
            ],
            "exception": [
                "type": "EXC_BAD_ACCESS",
                "signal": "SIGSEGV",
            ],
            "termination": [
                "indicator": "Segmentation fault: 11"
            ],
        ]
        var data = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        )
        data.append(0x0A)
        data.append(
            try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]
            )
        )
        try data.write(to: url)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return try XCTUnwrap(formatter.date(from: value))
    }
}
