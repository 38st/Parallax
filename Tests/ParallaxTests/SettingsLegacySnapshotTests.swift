import CoreFoundation
import Foundation
import XCTest
@testable import Parallax

final class SettingsLegacySnapshotTests: XCTestCase {
    func testFixedCatalogAndAllAbsentEvidenceAreDeterministic() {
        let first = SettingsLegacySnapshotClassifier.classify([:])
        let second = SettingsLegacySnapshotClassifier.classify([:])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.completion, .complete)
        XCTAssertEqual(first.profileTemplates, .absent)
        XCTAssertEqual(first.legacyProfileTemplateNames, .absent)
        XCTAssertEqual(first.defaultBaseStoragePath, .absent)
        XCTAssertEqual(first.confirmBeforeLaunch, .absent)
        XCTAssertEqual(first.automaticallyRecoverCrashedApps, .absent)
        XCTAssertEqual(first.appearance, .absent)
        XCTAssertEqual(first.profileVisualIdentities, .absent)
        XCTAssertEqual(
            SettingsLegacyKey.ordered,
            [
                .profileTemplates,
                .legacyProfileTemplateNames,
                .defaultBaseStoragePath,
                .confirmBeforeLaunch,
                .automaticallyRecoverCrashedApps,
                .appearance,
                .profileVisualIdentities,
            ]
        )
        XCTAssertEqual(SettingsLegacyKey.ordered.count, 7)
        XCTAssertTrue(SettingsLegacyKey.ordered.allSatisfy {
            !$0.rawValue.isEmpty
                && $0.rawValue.utf8.count
                    <= SettingsLegacySnapshotReader
                        .maximumRequestedKeyUTF8Bytes
        })
    }

    func testAllSevenExactValuesAndIntentionalEmptiesArePreserved()
        throws
    {
        let templates = Data([0xff, 0x00, 0x41])
        let identities = Data("{not-json".utf8)
        let names = ["", "é", "é", "Z\u{301}"]
        let snapshot = capture([
            key(.profileTemplates): templates,
            key(.legacyProfileTemplateNames): names,
            key(.defaultBaseStoragePath): "",
            key(.confirmBeforeLaunch): false,
            key(.automaticallyRecoverCrashedApps): true,
            key(.appearance): "",
            key(.profileVisualIdentities): identities,
        ])

        XCTAssertEqual(snapshot.profileTemplates, .retained(templates))
        XCTAssertEqual(
            snapshot.legacyProfileTemplateNames,
            .retained(names)
        )
        guard case .retained(let retainedNames) =
            snapshot.legacyProfileTemplateNames
        else {
            return XCTFail("Expected exact legacy names.")
        }
        XCTAssertEqual(
            retainedNames.last?.unicodeScalars.map(\.value),
            [90, 769]
        )
        XCTAssertEqual(snapshot.defaultBaseStoragePath, .retained(""))
        XCTAssertEqual(snapshot.confirmBeforeLaunch, .retained(false))
        XCTAssertEqual(
            snapshot.automaticallyRecoverCrashedApps,
            .retained(true)
        )
        XCTAssertEqual(snapshot.appearance, .retained(""))
        XCTAssertEqual(
            snapshot.profileVisualIdentities,
            .retained(identities)
        )
        XCTAssertEqual(snapshot.completion, .complete)

        let emptyNames = capture([
            key(.legacyProfileTemplateNames): [String](),
        ])
        XCTAssertEqual(
            emptyNames.legacyProfileTemplateNames,
            .retained([])
        )
    }

    func testSourceFailureAndInvalidApplicationIDAreTyped()
        throws
    {
        let failure = SettingsLegacySourceFailure.unavailable(code: EIO)
        let failed = SettingsLegacySnapshotClassifier.unavailable(failure)

        XCTAssertEqual(failed.profileTemplates, .unavailable(failure))
        XCTAssertEqual(
            failed.automaticallyRecoverCrashedApps,
            .unavailable(failure)
        )
        XCTAssertEqual(
            failed.completion,
            .partial([.source(failure)])
        )
        let invalidID = String(
            repeating: "a",
            count:
                SettingsLegacySnapshotReader
                    .maximumApplicationIdentifierUTF8Bytes + 1
        )
        let invalid = SettingsLegacySnapshotReader(
            applicationIdentifier: invalidID
        ).capture()
        let invalidFailure =
            SettingsLegacySourceFailure.invalidApplicationIdentifier(
                actualUTF8Bytes: invalidID.utf8.count,
                maximum:
                    SettingsLegacySnapshotReader
                        .maximumApplicationIdentifierUTF8Bytes
            )
        XCTAssertEqual(invalid.appearance, .unavailable(invalidFailure))
        XCTAssertEqual(
            invalid.completion,
            .partial([.source(invalidFailure)])
        )

        let exactID = String(
            repeating: "a",
            count:
                SettingsLegacySnapshotReader
                    .maximumApplicationIdentifierUTF8Bytes
        )
        XCTAssertEqual(
            SettingsLegacySnapshotReader(
                applicationIdentifier: exactID
            ).capture().completion,
            .complete
        )
    }

    func testReservedApplicationIdentifiersFailBeforeSourceRead() {
        let cases: [
            (String, SettingsLegacyReservedApplicationIdentifier)
        ] = [
            (
                kCFPreferencesAnyApplication as String,
                .anyApplication
            ),
            (
                kCFPreferencesCurrentApplication as String,
                .currentApplication
            ),
        ]

        for (identifier, reserved) in cases {
            let expected =
                SettingsLegacySourceFailure.reservedApplicationIdentifier(
                    reserved
                )
            XCTAssertEqual(
                SettingsLegacySnapshotReader
                    .applicationIdentifierFailure(identifier),
                expected
            )
            let snapshot = SettingsLegacySnapshotReader(
                applicationIdentifier: identifier
            ).capture()
            XCTAssertEqual(
                snapshot.completion,
                .partial([.source(expected)])
            )
            XCTAssertEqual(
                snapshot.profileVisualIdentities,
                .unavailable(expected)
            )
        }
    }

    func testStrictTypesKeepValidSiblingsAndIssueOrderIsFixed()
        throws
    {
        let snapshot = capture([
            key(.profileTemplates): "data",
            key(.legacyProfileTemplateNames): ["valid", 7],
            key(.defaultBaseStoragePath): Data(),
            key(.confirmBeforeLaunch): NSNumber(value: 1),
            key(.automaticallyRecoverCrashedApps): false,
            key(.appearance): ["dark"],
            key(.profileVisualIdentities): Data([1]),
            "settings.profileTemplates.corrupt.z": Data([2]),
            "aaa.unexpected": true,
        ])

        XCTAssertEqual(snapshot.profileTemplates, .wrongType(.string))
        XCTAssertEqual(
            snapshot.legacyProfileTemplateNames,
            .wrongType(.array)
        )
        XCTAssertEqual(snapshot.defaultBaseStoragePath, .wrongType(.data))
        XCTAssertEqual(snapshot.confirmBeforeLaunch, .wrongType(.number))
        XCTAssertEqual(
            snapshot.automaticallyRecoverCrashedApps,
            .retained(false)
        )
        XCTAssertEqual(snapshot.appearance, .wrongType(.array))
        XCTAssertEqual(
            snapshot.profileVisualIdentities,
            .retained(Data([1]))
        )
        XCTAssertEqual(
            snapshot.completion,
            .partial([
                .field(
                    key: .profileTemplates,
                    issue: .wrongType(.string)
                ),
                .field(
                    key: .legacyProfileTemplateNames,
                    issue: .wrongType(.array)
                ),
                .field(
                    key: .defaultBaseStoragePath,
                    issue: .wrongType(.data)
                ),
                .field(
                    key: .confirmBeforeLaunch,
                    issue: .wrongType(.number)
                ),
                .field(
                    key: .appearance,
                    issue: .wrongType(.array)
                ),
                .unexpectedKeyCount(2),
            ])
        )
    }

    func testUnexpectedKeyEvidenceIsBoundedCountOnly() {
        XCTAssertEqual(
            capture([
                String(repeating: "x", count: 1_000_000): Data(),
            ]).completion,
            .partial([.unexpectedKeyCount(1)])
        )
        var many: [String: Any] = [:]
        for value in 0 ..< 10_001 {
            many["unexpected.\(value)"] = String(
                repeating: "z",
                count: 128
            )
        }
        XCTAssertEqual(
            capture(many).completion,
            .partial([.unexpectedKeyCount(10_001)])
        )
        many[key(.appearance)] = "dark"
        let sibling = capture(many)
        XCTAssertEqual(sibling.appearance, .retained("dark"))
        XCTAssertEqual(
            sibling.completion,
            .partial([.unexpectedKeyCount(10_001)])
        )
    }

    func testDataIndividualAndAggregateBoundsAreExact() throws {
        let maximum = SettingsLegacySnapshotReader.maximumDataBytes
        let exact = Data(repeating: 0x41, count: maximum)
        let exactSnapshot = capture([
            key(.profileTemplates): exact,
            key(.profileVisualIdentities): exact,
        ])
        XCTAssertEqual(exactSnapshot.profileTemplates, .retained(exact))
        XCTAssertEqual(
            exactSnapshot.profileVisualIdentities,
            .retained(exact)
        )
        XCTAssertEqual(exactSnapshot.completion, .complete)

        let plusOne = Data(repeating: 0x42, count: maximum + 1)
        let oversized = capture([
            key(.profileTemplates): exact,
            key(.profileVisualIdentities): plusOne,
        ])
        XCTAssertEqual(
            oversized.profileVisualIdentities,
            .oversized([
                .byteCount(
                    actual: UInt64(maximum + 1),
                    maximum: maximum
                ),
            ])
        )
        XCTAssertEqual(
            oversized.completion,
            .partial([
                .field(
                    key: .profileVisualIdentities,
                    issue: .oversized([
                        .byteCount(
                            actual: UInt64(maximum + 1),
                            maximum: maximum
                        ),
                    ])
                ),
                .aggregateDataBytes(
                    actual: UInt64((maximum * 2) + 1),
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumAggregateDataBytes
                ),
            ])
        )
    }

    func testEveryRawTypeIsClassifiedWithoutCoercion() {
        let cases: [
            (
                key: SettingsLegacyKey,
                value: Any,
                type: SettingsLegacyRawType
            )
        ] = [
            (.defaultBaseStoragePath, true, .boolean),
            (.defaultBaseStoragePath, Data(), .data),
            (.profileTemplates, "text", .string),
            (.profileTemplates, NSArray(), .array),
            (.confirmBeforeLaunch, NSNumber(value: 1), .number),
            (.profileTemplates, NSDictionary(), .dictionary),
            (.profileTemplates, NSDate(timeIntervalSince1970: 0), .date),
            (.profileTemplates, NSNull(), .other),
        ]

        for item in cases {
            let snapshot = capture([key(item.key): item.value])
            let issue: SettingsLegacySnapshotIssue
            guard case .partial(let issues) = snapshot.completion,
                  let first = issues.first
            else {
                XCTFail("Expected wrong-type evidence for \(item.type).")
                continue
            }
            issue = first
            XCTAssertEqual(
                issue,
                .field(
                    key: item.key,
                    issue: .wrongType(item.type)
                )
            )
        }
    }

    func testAcceptedReferenceValuesAreCopiedIntoOwnedEvidence() {
        let mutableData = NSMutableData(data: Data([1, 2, 3]))
        let mutableName = NSMutableString(string: "Original")
        let mutablePath = NSMutableString(string: "/Original")
        let mutableNames = NSMutableArray(object: mutableName)

        let snapshot = capture([
            key(.profileTemplates): mutableData,
            key(.legacyProfileTemplateNames): mutableNames,
            key(.defaultBaseStoragePath): mutablePath,
        ])
        mutableData.replaceBytes(
            in: NSRange(location: 0, length: mutableData.length),
            withBytes: [UInt8(9), 9, 9]
        )
        mutableName.setString("Changed")
        mutablePath.setString("/Changed")
        mutableNames.add("Later")

        XCTAssertEqual(
            snapshot.profileTemplates,
            .retained(Data([1, 2, 3]))
        )
        XCTAssertEqual(
            snapshot.legacyProfileTemplateNames,
            .retained(["Original"])
        )
        XCTAssertEqual(
            snapshot.defaultBaseStoragePath,
            .retained("/Original")
        )
    }

    func testLegacyNameBoundsPreserveOrderDuplicatesAndUnicode()
        throws
    {
        let exactName = String(repeating: "é", count: 128)
        XCTAssertEqual(exactName.utf8.count, 256)
        let exactNames = Array(
            repeating: "",
            count: SettingsLegacySnapshotReader.maximumLegacyNames - 2
        ) + [exactName, exactName]
        XCTAssertEqual(
            capture([
                key(.legacyProfileTemplateNames): exactNames,
            ]).legacyProfileTemplateNames,
            .retained(exactNames)
        )

        let tooMany = Array(
            repeating: "",
            count: SettingsLegacySnapshotReader.maximumLegacyNames + 1
        )
        XCTAssertEqual(
            capture([
                key(.legacyProfileTemplateNames): tooMany,
            ]).legacyProfileTemplateNames,
            .oversized([
                .elementCount(
                    actual: tooMany.count,
                    maximum:
                        SettingsLegacySnapshotReader.maximumLegacyNames
                ),
            ])
        )

        let longName = exactName + "a"
        XCTAssertEqual(longName.utf8.count, 257)
        XCTAssertEqual(
            capture([
                key(.legacyProfileTemplateNames): [longName],
            ]).legacyProfileTemplateNames,
            .oversized([
                .stringElementUTF8Bytes(
                    firstIndex: 0,
                    firstActual: 257,
                    violationCount: 1,
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumLegacyNameUTF8Bytes
                ),
            ])
        )
    }

    func testLegacyNameAggregatePlusOneIsReportedWithoutRetention()
        throws
    {
        let chunk = String(repeating: "a", count: 256)
        let chunkCount =
            SettingsLegacySnapshotReader
                .maximumLegacyNamesAggregateUTF8Bytes / 256
        let exactNames = Array(repeating: chunk, count: chunkCount)
        let exact = capture([
            key(.legacyProfileTemplateNames): exactNames,
        ])
        XCTAssertEqual(
            exact.legacyProfileTemplateNames,
            .oversized([
                .elementCount(
                    actual: exactNames.count,
                    maximum:
                        SettingsLegacySnapshotReader.maximumLegacyNames
                ),
            ])
        )
        let names = Array(repeating: chunk, count: chunkCount) + ["b"]
        let snapshot = capture([
            key(.legacyProfileTemplateNames): names,
        ])

        XCTAssertEqual(
            snapshot.legacyProfileTemplateNames,
            .oversized([
                .elementCount(
                    actual: names.count,
                    maximum:
                        SettingsLegacySnapshotReader.maximumLegacyNames
                ),
                .aggregateUTF8Bytes(
                    actual: UInt64(
                        SettingsLegacySnapshotReader
                            .maximumLegacyNamesAggregateUTF8Bytes + 1
                    ),
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumLegacyNamesAggregateUTF8Bytes
                ),
            ])
        )
    }

    func testPathAndAppearanceMultibyteBoundsAreExact() throws {
        let path = String(repeating: "é", count: 2_048)
        let appearance = String(repeating: "é", count: 8)
        let exact = capture([
            key(.defaultBaseStoragePath): path,
            key(.appearance): appearance,
        ])
        XCTAssertEqual(exact.defaultBaseStoragePath, .retained(path))
        XCTAssertEqual(exact.appearance, .retained(appearance))

        let pathPlusOne = path + "a"
        let appearancePlusOne = appearance + "a"
        let oversized = capture([
            key(.defaultBaseStoragePath): pathPlusOne,
            key(.appearance): appearancePlusOne,
        ])
        XCTAssertEqual(
            oversized.defaultBaseStoragePath,
            .oversized([
                .byteCount(
                    actual: 4_097,
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumBasePathUTF8Bytes
                ),
            ])
        )
        XCTAssertEqual(
            oversized.appearance,
            .oversized([
                .byteCount(
                    actual: 17,
                    maximum:
                        SettingsLegacySnapshotReader
                            .maximumAppearanceUTF8Bytes
                ),
            ])
        )
    }

    func testEmptyAndMissingRealApplicationDomainsMatchAndIgnoreRegistration()
        throws
    {
        let firstID = "parallax.legacy.snapshot.\(UUID().uuidString)"
        let secondID = "parallax.legacy.snapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: secondID))
        defaults.register(defaults: [
            key(.appearance): "registered-only",
        ])

        let missing = SettingsLegacySnapshotReader(
            applicationIdentifier: firstID
        ).capture()
        let registeredOnly = SettingsLegacySnapshotReader(
            applicationIdentifier: secondID
        ).capture()

        XCTAssertEqual(missing, registeredOnly)
        XCTAssertEqual(registeredOnly.appearance, .absent)
        XCTAssertEqual(
            defaults.string(forKey: key(.appearance)),
            "registered-only"
        )
    }

    func testFixedProductionReaderReadsOnlyPersistedRandomizedDomain()
        throws
    {
        let identifier = "parallax.legacy.snapshot.\(UUID().uuidString)"
        let persisted: [SettingsLegacyKey: Any] = [
            .profileTemplates: Data([0xff, 0x00]),
            .legacyProfileTemplateNames: ["", "Client", "Client"],
            .defaultBaseStoragePath: "/Volumes/Profile Data",
            .confirmBeforeLaunch: false,
            .appearance: "dark",
            .profileVisualIdentities: Data("{opaque".utf8),
        ]
        let unrelatedKey = "settings.unrelated.\(UUID().uuidString)"
        defer {
            for key in persisted.keys {
                CFPreferencesSetValue(
                    key.rawValue as CFString,
                    nil,
                    identifier as CFString,
                    kCFPreferencesCurrentUser,
                    kCFPreferencesAnyHost
                )
            }
            CFPreferencesSetValue(
                unrelatedKey as CFString,
                nil,
                identifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            _ = CFPreferencesSynchronize(
                identifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        for (key, value) in persisted {
            CFPreferencesSetValue(
                key.rawValue as CFString,
                value as CFPropertyList,
                identifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesSetValue(
            unrelatedKey as CFString,
            "ignored" as CFString,
            identifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        XCTAssertTrue(
            CFPreferencesSynchronize(
                identifier as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defaults.register(defaults: [
            key(.automaticallyRecoverCrashedApps): true,
        ])

        let snapshot = SettingsLegacySnapshotReader(
            applicationIdentifier: identifier
        ).capture()

        XCTAssertEqual(
            snapshot.profileTemplates,
            .retained(Data([0xff, 0x00]))
        )
        XCTAssertEqual(
            snapshot.legacyProfileTemplateNames,
            .retained(["", "Client", "Client"])
        )
        XCTAssertEqual(
            snapshot.defaultBaseStoragePath,
            .retained("/Volumes/Profile Data")
        )
        XCTAssertEqual(snapshot.confirmBeforeLaunch, .retained(false))
        XCTAssertEqual(
            snapshot.automaticallyRecoverCrashedApps,
            .absent
        )
        XCTAssertEqual(snapshot.appearance, .retained("dark"))
        XCTAssertEqual(
            snapshot.profileVisualIdentities,
            .retained(Data("{opaque".utf8))
        )
        XCTAssertEqual(snapshot.completion, .complete)
    }

    func testConcurrentCapturesAreImmutableAndDeterministic() {
        let reader = SettingsLegacySnapshotReader(
            applicationIdentifier:
                "parallax.legacy.concurrent.\(UUID().uuidString)"
        )
        let results = SnapshotResults()
        let group = DispatchGroup()
        for _ in 0 ..< 24 {
            group.enter()
            DispatchQueue.global().async {
                results.append(reader.capture())
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values.count, 24)
        let first = results.values.first
        XCTAssertTrue(results.values.allSatisfy { $0 == first })
    }

    func testMaximumValidCapturePerformance() {
        let data = Data(
            repeating: 0x41,
            count: SettingsLegacySnapshotReader.maximumDataBytes
        )
        let name = String(
            repeating: "a",
            count: SettingsLegacySnapshotReader.maximumLegacyNameUTF8Bytes
        )
        let values: [String: Any] = [
            key(.profileTemplates): data,
            key(.legacyProfileTemplateNames): Array(
                repeating: name,
                count: SettingsLegacySnapshotReader.maximumLegacyNames
            ),
            key(.defaultBaseStoragePath): String(
                repeating: "p",
                count:
                    SettingsLegacySnapshotReader.maximumBasePathUTF8Bytes
            ),
            key(.confirmBeforeLaunch): false,
            key(.automaticallyRecoverCrashedApps): true,
            key(.appearance): String(
                repeating: "a",
                count: SettingsLegacySnapshotReader.maximumAppearanceUTF8Bytes
            ),
            key(.profileVisualIdentities): data,
        ]

        measure {
            XCTAssertEqual(
                SettingsLegacySnapshotClassifier
                    .classify(values).completion,
                .complete
            )
        }
    }

    private func capture(
        _ values: [String: Any]
    ) -> SettingsLegacySnapshot {
        SettingsLegacySnapshotClassifier.classify(values)
    }

    private func key(_ key: SettingsLegacyKey) -> String {
        key.rawValue
    }
}

private final class SnapshotResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsLegacySnapshot] = []

    func append(_ snapshot: SettingsLegacySnapshot) {
        lock.withLock {
            stored.append(snapshot)
        }
    }

    var values: [SettingsLegacySnapshot] {
        lock.withLock { stored }
    }
}
