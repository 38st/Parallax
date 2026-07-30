import Foundation
import XCTest
@testable import Parallax

final class LaunchHistoryStoreTests: XCTestCase {
    @MainActor
    func testLifecyclePersistsAsCompletedHistory() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let process = ProcessStartIdentity(
            processIdentifier: 4_242,
            startTimeSeconds: 1_800_000_000,
            startTimeMicroseconds: 250_000
        )
        let inspector = FakeHistoryProcessInspector()
        inspector.inspections[process.processIdentifier] = .live(process)
        let store = try LaunchHistoryStore(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let fixture = makeFixture()
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let startedAt = requestedAt.addingTimeInterval(2)
        let endedAt = startedAt.addingTimeInterval(65)

        store.record(
            fixture.snapshot(state: .requested),
            application: fixture.application,
            profile: fixture.profile,
            fallbackProfileName: fixture.profile.name,
            at: requestedAt
        )
        store.record(
            fixture.snapshot(
                state: .running(
                    processIdentifier: process.processIdentifier
                )
            ),
            application: fixture.application,
            profile: fixture.profile,
            fallbackProfileName: fixture.profile.name,
            at: startedAt
        )
        store.record(
            fixture.snapshot(
                state: .terminated(
                    processIdentifier: process.processIdentifier
                )
            ),
            application: fixture.application,
            profile: fixture.profile,
            fallbackProfileName: fixture.profile.name,
            at: endedAt
        )

        let reloaded = try LaunchHistoryStore(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let entry = try XCTUnwrap(reloaded.entries.first)

        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(entry.requestID, fixture.requestID)
        XCTAssertEqual(entry.applicationName, "ChatGPT")
        XCTAssertEqual(entry.profileName, "Work")
        XCTAssertEqual(entry.state, .closed)
        XCTAssertEqual(entry.process, process)
        XCTAssertEqual(
            entry.observedProcessIdentifier,
            process.processIdentifier
        )
        XCTAssertEqual(entry.requestedAt, requestedAt)
        XCTAssertEqual(entry.startedAt, startedAt)
        XCTAssertEqual(entry.endedAt, endedAt)
    }

    @MainActor
    func testHistoryIsBoundedToNewestEntries() {
        let store = LaunchHistoryStore(maximumEntryCount: 2)
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var requestIDs: [UUID] = []

        for offset in 0..<3 {
            let requestID = UUID()
            requestIDs.append(requestID)
            store.record(
                ProfileLaunchLifecycleSnapshot(
                    requestID: requestID,
                    identity: fixture.identity,
                    state: .requested
                ),
                application: fixture.application,
                profile: fixture.profile,
                fallbackProfileName: fixture.profile.name,
                at: base.addingTimeInterval(
                    TimeInterval(offset)
                )
            )
        }

        XCTAssertEqual(
            store.entries.map(\.requestID),
            [requestIDs[2], requestIDs[1]]
        )
    }

    @MainActor
    func testStaleStoreMergesAnotherProcessEntriesByRequestID()
        throws
    {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let firstStore = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        let staleSecondStore = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        let first = makeFixture()
        let second = makeFixture()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        firstStore.record(
            first.snapshot(state: .requested),
            application: first.application,
            profile: first.profile,
            fallbackProfileName: first.profile.name,
            at: base
        )
        staleSecondStore.record(
            second.snapshot(state: .requested),
            application: second.application,
            profile: second.profile,
            fallbackProfileName: second.profile.name,
            at: base.addingTimeInterval(1)
        )

        let reloaded = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        XCTAssertEqual(
            Set(reloaded.entries.map(\.requestID)),
            Set([first.requestID, second.requestID])
        )
    }

    @MainActor
    func testStaleClearRemovesAllPersistedEntriesForApplication()
        throws
    {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let fixture = makeFixture()
        let firstStore = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        let staleClearingStore = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        firstStore.record(
            fixture.snapshot(state: .requested),
            application: fixture.application,
            profile: fixture.profile,
            fallbackProfileName: fixture.profile.name
        )

        staleClearingStore.clearHistory(
            for: fixture.application
        )

        let reloaded = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        XCTAssertTrue(
            reloaded.entries(
                for: fixture.application
            ).isEmpty
        )
    }

    @MainActor
    func testCorruptHistoryIsQuarantinedBeforeStartingEmpty() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(
            to: directory.appendingPathComponent(
                "launch-history.json"
            )
        )

        let store = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertFalse(names.contains("launch-history.json"))
        XCTAssertTrue(
            names.contains {
                $0.hasPrefix("launch-history.corrupt.")
                    && $0.hasSuffix(".json")
            }
        )
    }

    @MainActor
    func testDuplicatePersistedRequestIDsAreMergedWithoutCrashing()
        throws
    {
        struct Document: Encodable {
            let schemaVersion: Int
            let entries: [LaunchHistoryEntry]
        }

        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fixture = makeFixture()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var older = LaunchHistoryEntry(
            requestID: fixture.requestID,
            applicationID: fixture.application.id,
            applicationStorageID:
                fixture.application.storageID,
            profileID: fixture.profile.id,
            profileStorageID: fixture.profile.storageID,
            applicationName: fixture.application.displayName,
            applicationBundleIdentifier:
                fixture.application.bundleIdentifier,
            profileName: fixture.profile.name,
            requestedAt: base,
            startedAt: base,
            endedAt: base,
            state: .closed,
            process: nil,
            updatedAt: base
        )
        var newer = older
        older.profileName = "Older"
        newer.profileName = "Newer"
        newer.updatedAt = base.addingTimeInterval(1)
        try JSONEncoder().encode(
            Document(
                schemaVersion: 1,
                entries: [older, newer]
            )
        ).write(
            to: directory.appendingPathComponent(
                "launch-history.json"
            )
        )
        let store = try LaunchHistoryStore(
            applicationSupportURL: support
        )
        let another = makeFixture()
        store.record(
            another.snapshot(state: .requested),
            application: another.application,
            profile: another.profile,
            fallbackProfileName: another.profile.name,
            at: base.addingTimeInterval(2)
        )

        XCTAssertEqual(
            store.entries.filter {
                $0.requestID == fixture.requestID
            }.count,
            1
        )
        XCTAssertEqual(
            store.entries.first {
                $0.requestID == fixture.requestID
            }?.profileName,
            "Newer"
        )
    }

    @MainActor
    func testPresentationUsesPlainLanguageAndDuration() {
        let fixture = makeFixture()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = LaunchHistoryEntry(
            requestID: fixture.requestID,
            applicationID: fixture.application.id,
            applicationStorageID: fixture.application.storageID,
            profileID: fixture.profile.id,
            profileStorageID: fixture.profile.storageID,
            applicationName: fixture.application.displayName,
            applicationBundleIdentifier:
                fixture.application.bundleIdentifier,
            profileName: fixture.profile.name,
            requestedAt: startedAt.addingTimeInterval(-2),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_900),
            state: .closed,
            process: nil
        )

        let presentation = LaunchHistoryEntryPresentation(
            entry: entry,
            now: startedAt.addingTimeInterval(4_000),
            locale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(presentation.statusLabel, "Closed")
        XCTAssertEqual(presentation.durationLabel, "1h 5m")
        XCTAssertEqual(presentation.tone, .neutral)

        var unexpectedEntry = entry
        unexpectedEntry.terminationDisposition = .unexpected
        let unexpectedPresentation =
            LaunchHistoryEntryPresentation(
                entry: unexpectedEntry,
                now: startedAt.addingTimeInterval(4_000),
                locale: Locale(identifier: "en_US")
            )
        XCTAssertEqual(
            unexpectedPresentation.statusLabel,
            "Ended Unexpectedly"
        )
        XCTAssertEqual(unexpectedPresentation.tone, .failure)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-launch-history-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func makeFixture() -> HistoryFixture {
        let profile = LaunchProfile(name: "Work")
        let application = ManagedApplication(
            displayName: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/ChatGPT.app",
            profiles: [profile]
        )
        return HistoryFixture(
            requestID: UUID(),
            application: application,
            profile: profile
        )
    }
}

private struct HistoryFixture {
    let requestID: UUID
    let application: ManagedApplication
    let profile: LaunchProfile

    var identity: ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID
        )
    }

    func snapshot(
        state: ProfileLaunchLifecycleState
    ) -> ProfileLaunchLifecycleSnapshot {
        ProfileLaunchLifecycleSnapshot(
            requestID: requestID,
            identity: identity,
            state: state
        )
    }
}

private final class FakeHistoryProcessInspector:
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    var inspections: [pid_t: ProcessIdentityInspection] = [:]

    func inspect(
        processIdentifier: pid_t
    ) -> ProcessIdentityInspection {
        inspections[processIdentifier] ?? .dead
    }
}
