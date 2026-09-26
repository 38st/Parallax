import Foundation
import XCTest

@testable import Parallax

final class CrashAttributionAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (URL, LaunchHistoryEntry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = LaunchHistoryEntry(
            requestID: UUID(), applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID(), applicationName: "Audit",
            applicationBundleIdentifier: "com.example.audit", profileName: "Work",
            requestedAt: start, startedAt: start, endedAt: start.addingTimeInterval(60),
            state: .closed,
            process: ProcessStartIdentity(
                processIdentifier: 77, startTimeSeconds: 1_800_000_000, startTimeMicroseconds: 0))
        return (root, entry)
    }

    private func write(
        _ root: URL, name: String, processName: String = "Audit", launch: String? = nil,
        bugType: String = "309", corpse: Bool = false, nonFatal: Bool? = nil
    ) throws {
        let header: [String: Any] = ["bug_type": bugType, "bundleID": "com.example.audit"]
        var body: [String: Any] = [
            "pid": 77, "procName": processName, "captureTime": "2027-01-15 08:01:00.0000 +0000",
            "isCorpse": corpse, "isNonFatal": nonFatal ?? corpse,
            "exception": ["type": corpse ? "EXC_CRASH" : "EXC_BAD_ACCESS"],
        ]
        if let launch { body["procLaunch"] = launch }
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(0x0a)
        data.append(try JSONSerialization.data(withJSONObject: body))
        try data.write(to: root.appendingPathComponent(name + ".ips"))
    }

    func testNonfatalCorpseAndNonCrashReportsCannotConfirmCrash() throws {
        for (bug, corpse) in [("309", true), ("298", false)] {
            let (root, entry) = try fixture()
            try write(root, name: "report", bugType: bug, corpse: corpse)
            XCTAssertTrue(
                ApplicationCrashReportLocator(diagnosticReportsURL: root).reports(matching: [entry])
                    .isEmpty)
        }
    }

    func testFatalCorpseReportRemainsValidCrashEvidence() throws {
        let (root, entry) = try fixture()
        try write(root, name: "fatal", corpse: true, nonFatal: false)
        XCTAssertNotNil(
            ApplicationCrashReportLocator(diagnosticReportsURL: root).reports(matching: [entry])[
                entry.requestID])
    }

    func testMissingLaunchTimeRequiresUniqueCompatibleReportEvenWithSavedIdentity() throws {
        let (root, entry) = try fixture()
        try write(root, name: "first")
        try write(root, name: "second")
        XCTAssertTrue(
            ApplicationCrashReportLocator(diagnosticReportsURL: root).reports(matching: [entry])
                .isEmpty)
    }

    func testFallbackProcessNameMustMatchExactly() throws {
        let (root, original) = try fixture()
        var entry = original
        entry.applicationBundleIdentifier = nil
        try write(root, name: "report", processName: "áudit")
        XCTAssertTrue(
            ApplicationCrashReportLocator(diagnosticReportsURL: root).reports(matching: [entry])
                .isEmpty)
    }
}
