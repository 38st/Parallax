import Foundation
import XCTest
@testable import Parallax

final class LibraryFixtureTests: XCTestCase {
    func testFixtureManifestNamesEveryBASE002Scenario() {
        let fixtureNames = Set(LibraryFixtureCase.matrix.map(\.fileName))

        XCTAssertEqual(
            fixtureNames,
            [
                "valid-v1-library.json",
                "legacy-raw-array.json",
                "corrupt-truncated.json",
                "unsupported-future-version.json",
                "negative-version.json",
                "zero-version.json",
                "duplicate-application-ids.json",
                "duplicate-profile-ids.json",
                "duplicate-storage-names.json",
                "legacy-missing-null-storage-name.json",
                "empty-storage-name.json",
                "reserved-archives-storage-name.json",
                "case-variant-storage-names.json",
                "slash-containing-storage-name.json",
                "traversing-storage-name.json",
                "conflicting-import-profiles.json",
                "conflicting-import-profiles-incoming.json",
                "moved-application-record.json",
                "external-isolation-paths.json"
            ]
        )
    }

    func testConflictingImportFixturePairSharesIdentityAndDiffersInConfiguration() throws {
        let existing = try applications(in: "conflicting-import-profiles.json")
        let incoming = try applications(in: "conflicting-import-profiles-incoming.json")

        guard
            let existingApplication = existing.first,
            let incomingApplication = incoming.first,
            let existingProfile = existingApplication.profiles.first,
            let incomingProfile = incomingApplication.profiles.first
        else {
            XCTFail("Expected one application and profile on each side of the conflict fixture")
            return
        }

        XCTAssertEqual(existingApplication.id, incomingApplication.id)
        XCTAssertEqual(existingApplication.bundleIdentifier, incomingApplication.bundleIdentifier)
        XCTAssertEqual(existingProfile.id, incomingProfile.id)
        XCTAssertEqual(existingProfile.name, incomingProfile.name)
        XCTAssertEqual(existingProfile.storageName, incomingProfile.storageName)
        XCTAssertNotEqual(existingProfile.argumentsText, incomingProfile.argumentsText)
        XCTAssertNotEqual(existingProfile.environmentText, incomingProfile.environmentText)
        XCTAssertNotEqual(existingProfile.notes, incomingProfile.notes)
    }

    func testFixtureMigrationMatrixCapturesCurrentDecodeBehavior() throws {
        for fixture in LibraryFixtureCase.matrix {
            let data = try fixture.data()

            switch fixture.expectedDecode {
            case let .migrationRequired(expectedCount):
                let result = try LibraryPersistence.decodeLibrary(from: data)
                guard case let .migrationRequired(legacy) = result else {
                    XCTFail("Expected legacy migration result for \(fixture.fileName)")
                    continue
                }
                let applications = legacy.applications
                XCTAssertEqual(
                    applications.count,
                    expectedCount,
                    "Unexpected application count for \(fixture.fileName)"
                )
                try assertConditions(fixture.conditions, data: data, applications: applications)
                XCTAssertThrowsError(
                    try LibraryPersistence.decodeApplications(from: data)
                ) { error in
                    guard case .migrationRequired = error as? LibraryPersistenceError else {
                        XCTFail("Expected typed migration-required error for \(fixture.fileName)")
                        return
                    }
                }

            case .malformedJSON:
                XCTAssertThrowsError(
                    try LibraryPersistence.decodeApplications(from: data),
                    "Expected malformed fixture \(fixture.fileName) to fail"
                )
                XCTAssertThrowsError(
                    try JSONSerialization.jsonObject(with: data),
                    "Expected malformed fixture \(fixture.fileName) to be invalid JSON"
                )

            case let .unsupportedVersion(expectedVersion):
                XCTAssertNoThrow(
                    try JSONSerialization.jsonObject(with: data),
                    "Future-version fixture itself must remain valid JSON"
                )
                XCTAssertThrowsError(try LibraryPersistence.decodeApplications(from: data)) { error in
                    guard case let LibraryPersistenceError.unsupportedVersion(found, supported) = error else {
                        XCTFail("Unexpected error for \(fixture.fileName): \(error)")
                        return
                    }
                    XCTAssertEqual(found, expectedVersion)
                    XCTAssertEqual(supported, LibraryDocument.currentVersion)
                }

            case let .invalidVersion(expectedVersion):
                XCTAssertThrowsError(
                    try LibraryPersistence.decodeLibrary(from: data)
                ) { error in
                    guard case let .invalidVersion(found) = error as? LibraryPersistenceError else {
                        XCTFail("Unexpected error for \(fixture.fileName): \(error)")
                        return
                    }
                    XCTAssertEqual(found, expectedVersion)
                }
            }
        }
    }

    private func assertConditions(
        _ conditions: Set<FixtureStructuralCondition>,
        data: Data,
        applications: [LegacyManagedApplication]
    ) throws {
        for condition in conditions {
            switch condition {
            case .validVersionOneDocument:
                XCTAssertEqual(try documentVersion(in: data), 1)
                XCTAssertEqual(
                    applications.first?.profiles.first?.arguments,
                    [
                        "--user-data-dir=/FixtureData/ManagedProfiles/"
                            + "Fixture-Browser/Personal/UserData"
                    ]
                )

            case .legacyRawApplicationArray:
                XCTAssertTrue(try JSONSerialization.jsonObject(with: data) is [Any])

            case .negativeVersion:
                XCTAssertLessThan(try documentVersion(in: data), 0)

            case .zeroVersion:
                XCTAssertEqual(try documentVersion(in: data), 0)

            case .duplicateApplicationIDs:
                XCTAssertTrue(hasDuplicates(applications.map(\.id)))

            case .duplicateProfileIDs:
                XCTAssertTrue(hasDuplicates(applications.flatMap(\.profiles).map(\.id)))

            case .duplicateStorageNames:
                XCTAssertTrue(
                    applications.contains { application in
                        hasDuplicates(application.profiles.compactMap(\.storageName))
                    }
                )

            case .missingAndNullStorageNames:
                let storageNameStates = try rawStorageNameStates(in: data)
                XCTAssertTrue(storageNameStates.contains(.missing))
                XCTAssertTrue(storageNameStates.contains(.null))
                XCTAssertEqual(
                    Set(applications.flatMap(\.profiles).map(\.storageNameProvenance)),
                    [.missing, .null]
                )

            case .emptyStorageName:
                XCTAssertTrue(applications.flatMap(\.profiles).contains { $0.storageName == "" })

            case .reservedArchivesStorageName:
                XCTAssertTrue(
                    applications
                        .flatMap(\.profiles)
                        .compactMap(\.storageName)
                        .contains { $0.caseInsensitiveCompare("Archives") == .orderedSame }
                )

            case .caseVariantStorageNames:
                XCTAssertTrue(
                    applications.contains { application in
                        let names = application.profiles.compactMap(\.storageName)
                        return Set(names).count == names.count
                            && Set(names.map { $0.lowercased() }).count < names.count
                    }
                )

            case .slashContainingStorageName:
                XCTAssertTrue(
                    applications
                        .flatMap(\.profiles)
                        .compactMap(\.storageName)
                        .contains { $0.contains("/") }
                )

            case .traversingStorageName:
                XCTAssertTrue(
                    applications
                        .flatMap(\.profiles)
                        .compactMap(\.storageName)
                        .contains { $0.split(separator: "/", omittingEmptySubsequences: false).contains("..") }
                )

            case .conflictingImportExisting:
                XCTAssertEqual(
                    applications.first?.profiles.first?.environment["FIXTURE_MODE"],
                    "existing"
                )

            case .conflictingImportIncoming:
                XCTAssertEqual(
                    applications.first?.profiles.first?.environment["FIXTURE_MODE"],
                    "incoming"
                )

            case .movedApplicationRecord:
                XCTAssertTrue(
                    applications.contains {
                        $0.appPath == "/FixtureApplications/Old Location/Moved Fixture Browser.app"
                    }
                )

            case .externalCodexHome:
                XCTAssertTrue(
                    applications
                        .flatMap(\.profiles)
                        .contains {
                            $0.environment["CODEX_HOME"] == "/Volumes/ParallaxFixtureExternal/CodexHome"
                        }
                )

            case .externalUserData:
                XCTAssertTrue(
                    applications
                        .flatMap(\.profiles)
                        .contains {
                            $0.arguments.contains(
                                "--user-data-dir=/Volumes/ParallaxFixtureExternal/UserData"
                            )
                        }
                )
            }
        }
    }

    private func documentVersion(in data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let dictionary = object as? [String: Any],
            let version = dictionary["version"] as? Int
        else {
            throw FixtureAssertionError.missingIntegerVersion
        }
        return version
    }

    private func applications(in fixtureName: String) throws -> [LegacyManagedApplication] {
        guard let fixture = LibraryFixtureCase.matrix.first(where: { $0.fileName == fixtureName }) else {
            throw FixtureAssertionError.missingFixture(fixtureName)
        }
        let result = try LibraryPersistence.decodeLibrary(from: fixture.data())
        guard case let .migrationRequired(legacy) = result else {
            throw FixtureAssertionError.expectedLegacyLibrary(fixtureName)
        }
        return legacy.applications
    }

    private func rawStorageNameStates(in data: Data) throws -> Set<RawStorageNameState> {
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let document = object as? [String: Any],
            let applications = document["applications"] as? [[String: Any]]
        else {
            throw FixtureAssertionError.missingApplications
        }

        return Set(
            applications
                .flatMap { $0["profiles"] as? [[String: Any]] ?? [] }
                .map { profile in
                    guard let value = profile["storageName"] else { return .missing }
                    return value is NSNull ? .null : .value
                }
        )
    }

    private func hasDuplicates<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count < values.count
    }
}

private enum FixtureAssertionError: Error {
    case missingIntegerVersion
    case missingApplications
    case missingFixture(String)
    case expectedLegacyLibrary(String)
}

private enum RawStorageNameState: Hashable {
    case missing
    case null
    case value
}
