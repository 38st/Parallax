import XCTest
@testable import Parallax

final class ManagedAppWorkaroundStoreTests: XCTestCase {
    @MainActor
    func testRecordsRoundTripWithRestrictivePermissionsAndIsolation()
        throws
    {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let applicationStorageID = UUID()
        let firstProfileStorageID = UUID()
        let secondProfileStorageID = UUID()
        let store = try ManagedAppWorkaroundStore(
            applicationSupportURL: support
        )

        XCTAssertTrue(
            store.upsert(
                record(
                    applicationStorageID: applicationStorageID,
                    profileStorageID: firstProfileStorageID,
                    workaroundID: "future.workaround.v7"
                )
            )
        )
        XCTAssertTrue(
            store.upsert(
                record(
                    applicationStorageID: applicationStorageID,
                    profileStorageID: secondProfileStorageID,
                    workaroundID: "other.workaround"
                )
            )
        )

        let reloaded = try ManagedAppWorkaroundStore(
            applicationSupportURL: support
        )
        XCTAssertEqual(
            reloaded.records(
                applicationStorageID: applicationStorageID,
                profileStorageID: firstProfileStorageID
            ).map(\.workaroundID),
            ["future.workaround.v7"]
        )
        let file = support.appendingPathComponent(
            "Parallax/managed-app-workarounds.json"
        )
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: file.path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    @MainActor
    func testCorruptStateIsQuarantinedAndRemovalPersists() throws {
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
        try Data("{invalid".utf8).write(
            to: directory.appendingPathComponent(
                "managed-app-workarounds.json"
            )
        )

        let store = try ManagedAppWorkaroundStore(
            applicationSupportURL: support
        )
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            ).contains {
                $0.hasPrefix("managed-app-workarounds.corrupt.")
            }
        )

        let applicationStorageID = UUID()
        let profileStorageID = UUID()
        let workaroundID = "known.workaround"
        XCTAssertTrue(
            store.upsert(
                record(
                    applicationStorageID: applicationStorageID,
                    profileStorageID: profileStorageID,
                    workaroundID: workaroundID
                )
            )
        )
        XCTAssertTrue(
            store.remove(
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID,
                workaroundID: workaroundID
            )
        )
        let reloaded = try ManagedAppWorkaroundStore(
            applicationSupportURL: support
        )
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    private func record(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        workaroundID: String
    ) -> ManagedAppWorkaroundRecord {
        ManagedAppWorkaroundRecord(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            workaroundID: workaroundID,
            displayName: "Future-compatible workaround",
            definitionVersion: 7,
            configurationReference: "vendor.setting.path",
            state: .verified,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            operatorNote: "No secret values."
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-workarounds-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
