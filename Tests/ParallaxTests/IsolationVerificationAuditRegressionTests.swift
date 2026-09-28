import Foundation
import XCTest
@testable import Parallax

final class IsolationVerificationAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory
    private var scanner: IsolationActivityScanner {
        let instant = ContinuousClock.now
        return IsolationActivityScanner(monotonicNow: { instant })
    }
    private let began = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(-10)], ofItemAtPath: root.path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testOldDataDoesNotVerifyIsolationButModifiedNestedFileDoes() throws {
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = nested.appendingPathComponent("state")
        try Data("fixture".utf8).write(to: file)
        for url in [root, nested, file] {
            try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(-1)], ofItemAtPath: url.path)
        }
        XCTAssertEqual(scanner.activity(in: root, since: began), .inactive)
        try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(1)], ofItemAtPath: file.path)
        XCTAssertEqual(scanner.activity(in: root, since: began), .active)
    }

    func testScanDoesNotFollowSymlinksOrClaimAbsenceWhenBoundIsReached() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(-1)], ofItemAtPath: managed.path)
        XCTAssertEqual(scanner.activity(in: managed, since: began), .inactive)
        XCTAssertEqual(IsolationActivityScanner(maximumEntries: 0, monotonicNow: scanner.monotonicNow).activity(in: managed, since: began), .unknown)
        XCTAssertEqual(scanner.activity(in: managed.appendingPathComponent("link"), since: began), .unknown)
    }

    func testActivityScanNeverRepairsProviderFolderPermissions() throws {
        let provider = root.appendingPathComponent(".parallax/FirefoxProfile")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o770])
        _ = scanner.activity(in: provider, since: .distantFuture)
        XCTAssertEqual(try LocalFileSystem().attributesOfItem(at: provider).posixPermissions, 0o770)
    }

    func testScanStopsWhenInjectedTimeBudgetExpires() {
        let clock = ScanBudgetTestClock()
        let scanner = IsolationActivityScanner(monotonicNow: { clock.next() })
        XCTAssertEqual(scanner.activity(in: root, since: began), .unknown)
    }

    func testFakeClockRechecksPrimaryFolderAndClearsNotice() async throws {
        let first = root.appendingPathComponent("UserData")
        for url in [first] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(-1)], ofItemAtPath: url.path)
        }
        let clock = VerificationTestClock(began: began, writeOnSecondSleep: [first])
        let reports = VerificationReports()
        let verifier = IsolationActivityVerifier(clock: clock, scanner: scanner)
        await verifier.verify(paths: [.managed(first), .external(ExternalIsolationPath(requestedURL: root, canonicalURL: root))], since: began) {
            await reports.append($0)
        }
        let values = await reports.values
        XCTAssertEqual(values, [.inactive, .active])
        let sleeps = await clock.delays
        XCTAssertEqual(sleeps, [30, 30])
    }

    func testPrimaryFolderActivityDoesNotWaitForOptionalFolders() async throws {
        let primary = root.appendingPathComponent("UserData")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(1)], ofItemAtPath: primary.path)
        let isolation = PreparedLaunchIsolation(userDataURL: primary,
            codexHomeURL: root.appendingPathComponent("CodexHome"), managesUserData: true, managesCodexHome: true)
        XCTAssertEqual(isolation.managedVerificationPaths, [.managed(primary)])
        let reports = VerificationReports()
        await IsolationActivityVerifier(clock: VerificationTestClock(began: began, writeOnSecondSleep: []), scanner: scanner).verify(
            paths: isolation.managedVerificationPaths, since: began
        ) { await reports.append($0) }
        let values = await reports.values
        XCTAssertEqual(values, [.active])
    }

    func testCancelledClockDoesNotPublishNotice() async {
        let reports = VerificationReports()
        await IsolationActivityVerifier(clock: CancelledVerificationClock()).verify(paths: [.managed(root)], since: began) {
            await reports.append($0)
        }
        let values = await reports.values
        XCTAssertTrue(values.isEmpty)
    }

    func testExplicitPathsAreNeverInspected() async {
        let clock = VerificationTestClock(began: began, writeOnSecondSleep: [])
        let reports = VerificationReports()
        await IsolationActivityVerifier(clock: clock, scanner: scanner).verify(
            paths: [.external(ExternalIsolationPath(requestedURL: root, canonicalURL: root))], since: began
        ) { await reports.append($0) }
        let values = await reports.values
        let sleeps = await clock.delays
        XCTAssertTrue(values.isEmpty)
        XCTAssertTrue(sleeps.isEmpty)
    }
}

private actor VerificationReports {
    var values: [IsolationFolderActivity] = []
    func append(_ value: IsolationFolderActivity) { values.append(value) }
}

private actor VerificationTestClock: IsolationVerificationClock {
    let began: Date
    let writeOnSecondSleep: [URL]
    var delays: [TimeInterval] = []

    init(began: Date, writeOnSecondSleep: [URL]) {
        self.began = began
        self.writeOnSecondSleep = writeOnSecondSleep
    }

    func sleep(seconds: TimeInterval) async throws {
        delays.append(seconds)
        if delays.count == 2 {
            for url in writeOnSecondSleep {
                try FileManager.default.setAttributes([.modificationDate: began.addingTimeInterval(40)], ofItemAtPath: url.path)
            }
        }
    }
}

private struct CancelledVerificationClock: IsolationVerificationClock {
    func sleep(seconds: TimeInterval) async throws { throw CancellationError() }
}

private final class ScanBudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    func next() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        let value = instant
        instant = instant.advanced(by: .seconds(1))
        return value
    }
}
