import Foundation
@testable import Parallax

enum FixtureDecodeExpectation: Equatable {
    case applications(Int)
    case malformedJSON
    case unsupportedVersion(Int)
}

enum FixtureStructuralCondition: String, Hashable {
    case validVersionOneDocument
    case legacyRawApplicationArray
    case negativeVersion
    case zeroVersion
    case duplicateApplicationIDs
    case duplicateProfileIDs
    case duplicateStorageNames
    case missingAndNullStorageNames
    case emptyStorageName
    case reservedArchivesStorageName
    case caseVariantStorageNames
    case slashContainingStorageName
    case traversingStorageName
    case conflictingImportExisting
    case conflictingImportIncoming
    case movedApplicationRecord
    case externalCodexHome
    case externalUserData
}

struct LibraryFixtureCase {
    let fileName: String
    let expectedDecode: FixtureDecodeExpectation
    let conditions: Set<FixtureStructuralCondition>

    func data() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: fileName,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureSupportError.missingResource(fileName)
        }
        return try Data(contentsOf: url)
    }

    static let matrix: [LibraryFixtureCase] = [
        LibraryFixtureCase(
            fileName: "valid-v1-library.json",
            expectedDecode: .applications(1),
            conditions: [.validVersionOneDocument]
        ),
        LibraryFixtureCase(
            fileName: "legacy-raw-array.json",
            expectedDecode: .applications(1),
            conditions: [.legacyRawApplicationArray]
        ),
        LibraryFixtureCase(
            fileName: "corrupt-truncated.json",
            expectedDecode: .malformedJSON,
            conditions: []
        ),
        LibraryFixtureCase(
            fileName: "unsupported-future-version.json",
            expectedDecode: .unsupportedVersion(999),
            conditions: []
        ),
        LibraryFixtureCase(
            fileName: "negative-version.json",
            expectedDecode: .applications(0),
            conditions: [.negativeVersion]
        ),
        LibraryFixtureCase(
            fileName: "zero-version.json",
            expectedDecode: .applications(0),
            conditions: [.zeroVersion]
        ),
        LibraryFixtureCase(
            fileName: "duplicate-application-ids.json",
            expectedDecode: .applications(2),
            conditions: [.duplicateApplicationIDs]
        ),
        LibraryFixtureCase(
            fileName: "duplicate-profile-ids.json",
            expectedDecode: .applications(1),
            conditions: [.duplicateProfileIDs]
        ),
        LibraryFixtureCase(
            fileName: "duplicate-storage-names.json",
            expectedDecode: .applications(1),
            conditions: [.duplicateStorageNames]
        ),
        LibraryFixtureCase(
            fileName: "legacy-missing-null-storage-name.json",
            expectedDecode: .applications(1),
            conditions: [.missingAndNullStorageNames]
        ),
        LibraryFixtureCase(
            fileName: "empty-storage-name.json",
            expectedDecode: .applications(1),
            conditions: [.emptyStorageName]
        ),
        LibraryFixtureCase(
            fileName: "reserved-archives-storage-name.json",
            expectedDecode: .applications(1),
            conditions: [.reservedArchivesStorageName]
        ),
        LibraryFixtureCase(
            fileName: "case-variant-storage-names.json",
            expectedDecode: .applications(1),
            conditions: [.caseVariantStorageNames]
        ),
        LibraryFixtureCase(
            fileName: "slash-containing-storage-name.json",
            expectedDecode: .applications(1),
            conditions: [.slashContainingStorageName]
        ),
        LibraryFixtureCase(
            fileName: "traversing-storage-name.json",
            expectedDecode: .applications(1),
            conditions: [.traversingStorageName]
        ),
        LibraryFixtureCase(
            fileName: "conflicting-import-profiles.json",
            expectedDecode: .applications(1),
            conditions: [.conflictingImportExisting]
        ),
        LibraryFixtureCase(
            fileName: "conflicting-import-profiles-incoming.json",
            expectedDecode: .applications(1),
            conditions: [.conflictingImportIncoming]
        ),
        LibraryFixtureCase(
            fileName: "moved-application-record.json",
            expectedDecode: .applications(1),
            conditions: [.movedApplicationRecord]
        ),
        LibraryFixtureCase(
            fileName: "external-isolation-paths.json",
            expectedDecode: .applications(1),
            conditions: [.externalCodexHome, .externalUserData]
        )
    ]
}

private enum FixtureSupportError: Error {
    case missingResource(String)
}
