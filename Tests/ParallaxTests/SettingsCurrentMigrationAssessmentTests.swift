import Foundation
@testable import Parallax
import XCTest

final class SettingsCurrentMigrationAssessmentTests: XCTestCase {
    func testEveryInspectionCaseMapsAndAttachesExactSource() {
        let currentBytes = Data("current-source".utf8)
        let current = SettingsRepositoryInspection.current(
            .init(
                document: document(revision: .max),
                versionToken: .init(
                    revision: .init(rawValue: .max),
                    sourceSHA256: .init(currentBytes)
                ),
                originalBytes: currentBytes
            )
        )
        let futureBytes = Data("future-source".utf8)
        let future = SettingsRepositoryInspection.future(
            schemaVersion: .max,
            evidence: .init(
                originalBytes: futureBytes,
                sourceSHA256: .init(futureBytes)
            )
        )
        let recoveryBytes = Data("recovery-source".utf8)
        let recovery = SettingsRepositoryInspection.recoveryRequired(
            failure: .init(
                issue: .duplicateKey(path: "$", key: "schemaVersion"),
                originalBytes: recoveryBytes
            ),
            sourceSHA256: .init(recoveryBytes)
        )
        let unavailable = SettingsRepositoryInspection.unavailable(
            .primaryFile(.systemCall(operation: "fixture", code: 5))
        )
        let cases: [
            (SettingsRepositoryInspection, SettingsCurrentMigrationPresence)
        ] = [
            (.missing, .absent),
            (current, .present),
            (future, .present),
            (recovery, .present),
            (unavailable, .unknown),
        ]

        for (source, expected) in cases {
            let result = assessor(source).assess()
            XCTAssertEqual(result.source, source)
            XCTAssertEqual(result.presence, expected)
            XCTAssertEqual(assessor(source).assess(), result)
            XCTAssertEqual(
                Mirror(reflecting: result).children.compactMap(\.label),
                ["source", "presence"]
            )
        }
    }

    func testPresenceDoesNotDependOnObservedContent() {
        let currentCases = [
            Data(),
            Data([0]),
            Data("different-current-content".utf8),
        ].map { bytes in
            SettingsRepositoryInspection.current(
                .init(
                    document: document(revision: UInt64(bytes.count)),
                    versionToken: .init(
                        revision: .init(rawValue: UInt64(bytes.count)),
                        sourceSHA256: .init(bytes)
                    ),
                    originalBytes: bytes
                )
            )
        }
        let futureCases = [Data(), Data([0xff])].map { bytes in
            SettingsRepositoryInspection.future(
                schemaVersion: bytes.isEmpty ? 2 : .max,
                evidence: .init(
                    originalBytes: bytes,
                    sourceSHA256: .init(bytes)
                )
            )
        }
        let recoveryIssues: [SettingsDocumentCodecIssue] = [
            .inputTooLarge(actual: 2, maximum: 1),
            .malformedJSON,
            .excessiveNesting(maximum: 32),
            .tooManyTokens(maximum: 200_000),
            .duplicateKey(path: "$", key: "a"),
            .invalidTopLevel,
            .missingKey(path: "$.schemaVersion"),
            .unknownKey(path: "$.unknown"),
            .invalidType(path: "$.revision"),
            .invalidValue(path: "$.appearance"),
        ]
        let recoveryCases = recoveryIssues.enumerated().map { index, issue in
            let bytes = Data(repeating: UInt8(index), count: index)
            return SettingsRepositoryInspection.recoveryRequired(
                failure: .init(issue: issue, originalBytes: bytes),
                sourceSHA256: .init(bytes)
            )
        }

        for source in currentCases + futureCases + recoveryCases {
            XCTAssertEqual(assessor(source).assess().presence, .present)
        }
    }

    func testEveryUnavailableErrorFamilyRemainsUnknown() {
        let errors: [SettingsPrimaryFileAccessError] = [
            .unsafeItem(item: .parent, reason: .symbolicLink),
            .unsafeItem(item: .primary, reason: .multipleHardLinks),
            .invalidMaximumBytes(-1),
            .inputTooLarge(actual: .max, maximum: 4 * 1_024 * 1_024),
            .changedDuringRead,
            .systemCall(operation: "fixture", code: 24),
        ]

        for error in errors {
            let source = SettingsRepositoryInspection.unavailable(
                .primaryFile(error)
            )
            let result = assessor(source).assess()
            XCTAssertEqual(result.presence, .unknown)
            XCTAssertEqual(result.source, source)
        }
    }

    func testMaximumEvidenceIsAttachedWithoutInterpretation() {
        let bytes = Data(
            repeating: 0xa5,
            count: SettingsRepository.maximumPrimaryBytes
        )
        let source = SettingsRepositoryInspection.future(
            schemaVersion: .max,
            evidence: .init(
                originalBytes: bytes,
                sourceSHA256: .init(bytes)
            )
        )
        let assessor = assessor(source)

        measure {
            let result = assessor.assess()
            XCTAssertEqual(result.presence, .present)
            XCTAssertEqual(result.source, source)
        }
    }

    func testCheckedSendabilityAndDeterministicConcurrentReplay() async {
        assertSendable(SettingsCurrentMigrationPresence.self)
        assertSendable(SettingsCurrentMigrationAssessment.self)
        assertSendable(SettingsCurrentMigrationAssessor.self)
        let futureBytes = Data("future".utf8)
        let recoveryBytes = Data("recovery".utf8)
        let sources: [SettingsRepositoryInspection] = [
            .unavailable(
                .primaryFile(.changedDuringRead)
            ),
            .missing,
            .future(
                schemaVersion: .max,
                evidence: .init(
                    originalBytes: futureBytes,
                    sourceSHA256: .init(futureBytes)
                )
            ),
            .current(
                .init(
                    document: document(revision: 9),
                    versionToken: .init(
                        revision: .init(rawValue: 9),
                        sourceSHA256: .init(Data())
                    ),
                    originalBytes: Data()
                )
            ),
            .recoveryRequired(
                failure: .init(
                    issue: .malformedJSON,
                    originalBytes: recoveryBytes
                ),
                sourceSHA256: .init(recoveryBytes)
            ),
        ]
        let expected = sources.map { assessor($0).assess() }

        let indexed = await withTaskGroup(
            of: (Int, SettingsCurrentMigrationAssessment).self,
            returning: [(Int, SettingsCurrentMigrationAssessment)].self
        ) { group in
            for repetition in 0..<16 {
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        (
                            repetition * sources.count + index,
                            SettingsCurrentMigrationAssessor(
                                source: source
                            ).assess()
                        )
                    }
                }
            }
            var results: [(Int, SettingsCurrentMigrationAssessment)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }
        let results = indexed.map(\.1)
        XCTAssertEqual(results.count, sources.count * 16)
        for repetition in 0..<16 {
            let start = repetition * sources.count
            XCTAssertEqual(
                Array(results[start..<(start + sources.count)]),
                expected
            )
        }
    }

    private func assessor(
        _ source: SettingsRepositoryInspection
    ) -> SettingsCurrentMigrationAssessor {
        .init(source: source)
    }

    private func document(revision: UInt64) -> SettingsDocument {
        .init(
            revision: .init(rawValue: revision),
            profileTemplates: [],
            defaultBaseStoragePath: "",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: false,
            appearance: "system",
            profileVisualIdentities: []
        )
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
