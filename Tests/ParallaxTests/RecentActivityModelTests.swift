import Foundation
import XCTest
@testable import Parallax

@MainActor
final class RecentActivityModelTests: XCTestCase {
    func testLaterApplicationLoadWinsWhenEarlierLoadFinishesLast()
        async
    {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let firstID = UUID()
        let secondID = UUID()
        let firstRequest = request(applicationID: firstID)
        let secondRequest = request(applicationID: secondID)
        let firstSnapshot = snapshot(label: "first")
        let secondSnapshot = snapshot(label: "second")

        let firstTask = Task {
            await model.reload(for: firstRequest)
        }
        await loader.waitForRequest(applicationID: firstID)

        let secondTask = Task {
            await model.reload(for: secondRequest)
        }
        await loader.waitForRequest(applicationID: secondID)

        await loader.resume(
            applicationID: secondID,
            with: secondSnapshot
        )
        await secondTask.value
        await loader.resume(
            applicationID: firstID,
            with: firstSnapshot
        )
        await firstTask.value

        XCTAssertEqual(model.recentCrashReports, secondSnapshot.recent)
        XCTAssertEqual(model.crashReports, secondSnapshot.matched)
    }

    func testCancelledApplicationSwitchDoesNotExposePriorSnapshot() async {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let initialID = UUID()
        let cancelledID = UUID()
        let initialSnapshot = snapshot(label: "initial")
        let cancelledSnapshot = snapshot(label: "cancelled")

        let initialTask = Task {
            await model.reload(for: request(applicationID: initialID))
        }
        await loader.waitForRequest(applicationID: initialID)
        await loader.resume(
            applicationID: initialID,
            with: initialSnapshot
        )
        await initialTask.value

        let cancelledTask = Task {
            await model.reload(
                for: request(applicationID: cancelledID)
            )
        }
        await loader.waitForRequest(applicationID: cancelledID)
        cancelledTask.cancel()
        await loader.resume(
            applicationID: cancelledID,
            with: cancelledSnapshot
        )
        await cancelledTask.value

        XCTAssertTrue(model.recentCrashReports.isEmpty)
        XCTAssertTrue(model.crashReports.isEmpty)
    }

    func testApplicationSwitchClearsPriorSnapshotWhileLoading() async {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let firstID = UUID()
        let secondID = UUID()
        let firstSnapshot = snapshot(label: "first")

        let firstTask = Task {
            await model.reload(for: request(applicationID: firstID))
        }
        await loader.waitForRequest(applicationID: firstID)
        await loader.resume(applicationID: firstID, with: firstSnapshot)
        await firstTask.value

        let secondTask = Task {
            await model.reload(for: request(applicationID: secondID))
        }
        await loader.waitForRequest(applicationID: secondID)

        XCTAssertTrue(model.recentCrashReports.isEmpty)
        XCTAssertTrue(model.crashReports.isEmpty)

        secondTask.cancel()
        await loader.fail(
            applicationID: secondID,
            with: CancellationError()
        )
        await secondTask.value
    }

    func testApplicationSwitchFailureDoesNotRestorePriorSnapshot() async {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let firstID = UUID()
        let secondID = UUID()
        let firstSnapshot = snapshot(label: "first")

        let firstTask = Task {
            await model.reload(for: request(applicationID: firstID))
        }
        await loader.waitForRequest(applicationID: firstID)
        await loader.resume(applicationID: firstID, with: firstSnapshot)
        await firstTask.value

        let secondTask = Task {
            await model.reload(for: request(applicationID: secondID))
        }
        await loader.waitForRequest(applicationID: secondID)
        await loader.fail(
            applicationID: secondID,
            with: RecentActivityLoaderTestError.failed
        )
        await secondTask.value

        XCTAssertTrue(model.recentCrashReports.isEmpty)
        XCTAssertTrue(model.crashReports.isEmpty)
    }

    func testSameApplicationRefreshFailureRetainsCoherentSnapshot() async {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let applicationID = UUID()
        let initialSnapshot = snapshot(label: "initial")

        let initialTask = Task {
            await model.reload(for: request(applicationID: applicationID))
        }
        await loader.waitForRequest(applicationID: applicationID)
        await loader.resume(
            applicationID: applicationID,
            with: initialSnapshot
        )
        await initialTask.value

        let refreshTask = Task {
            await model.reload(for: request(applicationID: applicationID))
        }
        await loader.waitForRequest(
            applicationID: applicationID,
            count: 2
        )
        await loader.fail(
            applicationID: applicationID,
            with: RecentActivityLoaderTestError.failed
        )
        await refreshTask.value

        XCTAssertEqual(model.recentCrashReports, initialSnapshot.recent)
        XCTAssertEqual(model.crashReports, initialSnapshot.matched)
    }

    func testClearInvalidatesInFlightMatchedReportLoad() async {
        let loader = ControlledRecentActivityLoader()
        let model = RecentActivityModel(loader: loader)
        let applicationID = UUID()
        let loadedSnapshot = snapshot(label: "late")

        let task = Task {
            await model.reload(for: request(applicationID: applicationID))
        }
        await loader.waitForRequest(applicationID: applicationID)

        model.clearParallaxActivity()
        await loader.resume(
            applicationID: applicationID,
            with: loadedSnapshot
        )
        await task.value

        XCTAssertTrue(model.crashReports.isEmpty)
        XCTAssertTrue(model.recentCrashReports.isEmpty)
    }

    func testApplicationSwitchRequestIncludesApplicationIdentity() {
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertNotEqual(
            request(applicationID: firstID),
            request(applicationID: secondID)
        )
    }

    private func request(
        applicationID: UUID
    ) -> RecentActivityLoadRequest {
        RecentActivityLoadRequest(
            applicationID: applicationID,
            bundleIdentifier: "com.example.app",
            processName: "Example",
            entries: []
        )
    }

    private func snapshot(
        label: String
    ) -> RecentActivityCrashReportSnapshot {
        let requestID = UUID()
        let report = ApplicationCrashReport(
            fileURL: URL(fileURLWithPath: "/tmp/\(label).ips"),
            processIdentifier: 42,
            bundleIdentifier: "com.example.app",
            processName: "Example",
            launchedAt: nil,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            incidentIdentifier: label,
            exceptionType: nil,
            signal: nil,
            reason: nil
        )
        return RecentActivityCrashReportSnapshot(
            matched: [requestID: report],
            recent: [report]
        )
    }
}

private actor ControlledRecentActivityLoader:
    RecentActivityCrashReportLoading
{
    private var requestCounts: [UUID: Int] = [:]
    private var continuations:
        [
            UUID:
                CheckedContinuation<
                    RecentActivityCrashReportSnapshot,
                    any Error
                >
        ] = [:]

    func load(
        for request: RecentActivityLoadRequest
    ) async throws -> RecentActivityCrashReportSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            requestCounts[request.applicationID, default: 0] += 1
            continuations[request.applicationID] = continuation
        }
    }

    func waitForRequest(
        applicationID: UUID,
        count: Int = 1
    ) async {
        while requestCounts[applicationID, default: 0] < count {
            await Task.yield()
        }
    }

    func resume(
        applicationID: UUID,
        with snapshot: RecentActivityCrashReportSnapshot
    ) {
        continuations.removeValue(forKey: applicationID)?
            .resume(returning: snapshot)
    }

    func fail(applicationID: UUID, with error: any Error) {
        continuations.removeValue(forKey: applicationID)?
            .resume(throwing: error)
    }
}

private enum RecentActivityLoaderTestError: Error {
    case failed
}
