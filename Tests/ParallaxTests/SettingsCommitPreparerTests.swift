import Foundation
@testable import Parallax
import XCTest

final class SettingsCommitPreparerTests: XCTestCase {
    func testMissingPreparationProducesExactRevisionOneBytesAndToken()
        throws
    {
        let content = content(appearance: "dark")
        let result = SettingsCommitPreparer().prepare(
            content,
            expectation: .missing,
            inspection: .missing
        )

        guard case .prepared(let prepared) = result else {
            return XCTFail("Expected prepared target, got \(result)")
        }
        XCTAssertEqual(prepared.prior, .missing)
        XCTAssertEqual(prepared.targetDocument.revision.rawValue, 1)
        XCTAssertEqual(
            prepared.targetDocument.schemaVersion,
            SettingsDocument.currentSchemaVersion
        )
        XCTAssertEqual(prepared.targetDocument.appearance, "dark")
        XCTAssertEqual(
            prepared.targetBytes,
            try SettingsDocumentCodec().encode(prepared.targetDocument)
        )
        XCTAssertEqual(
            prepared.targetToken,
            SettingsVersionToken(
                revision: .init(rawValue: 1),
                sourceSHA256: .init(prepared.targetBytes)
            )
        )
    }

    func testCurrentPreparationPreservesExactPriorAndAdvancesRevision()
        throws
    {
        for revision in [UInt64(0), 9] {
            let sourceDocument = document(
                revision: revision,
                appearance: "system"
            )
            let sourceBytes = try SettingsDocumentCodec().encode(
                sourceDocument
            )
            let source = snapshot(
                document: sourceDocument,
                bytes: sourceBytes
            )

            guard case .prepared(let prepared) = SettingsCommitPreparer()
                .prepare(
                    content(appearance: "light"),
                    expectation: .version(source.versionToken),
                    inspection: .current(source)
                )
            else {
                return XCTFail("Expected current preparation.")
            }
            XCTAssertEqual(
                prepared.prior,
                .current(
                    bytes: sourceBytes,
                    token: source.versionToken
                )
            )
            XCTAssertEqual(
                prepared.targetDocument.revision.rawValue,
                revision + 1
            )
            XCTAssertEqual(prepared.targetDocument.appearance, "light")
            XCTAssertEqual(
                prepared.targetToken.sourceSHA256,
                SettingsSourceSHA256(prepared.targetBytes)
            )
        }
    }

    func testExpectationMismatchMatrixPreservesCompleteEvidence() throws {
        let currentDocument = document(revision: 4)
        let currentBytes = try SettingsDocumentCodec().encode(
            currentDocument
        )
        let current = snapshot(
            document: currentDocument,
            bytes: currentBytes
        )
        let wrongToken = SettingsVersionToken(
            revision: current.versionToken.revision,
            sourceSHA256: .init(Data("wrong".utf8))
        )
        let cases: [
            (
                SettingsCommitExpectation,
                SettingsRepositoryInspection,
                SettingsVersionToken?
            )
        ] = [
            (.version(current.versionToken), .missing, nil),
            (.missing, .current(current), current.versionToken),
            (.version(wrongToken), .current(current), current.versionToken),
        ]

        for (expectation, inspection, priorToken) in cases {
            XCTAssertEqual(
                SettingsCommitPreparer().prepare(
                    content(),
                    expectation: expectation,
                    inspection: inspection
                ),
                .terminal(
                    .rejected(
                        .init(
                            classification: .prior,
                            failure: .expectationMismatch,
                            priorToken: priorToken,
                            targetToken: nil,
                            residual: nil
                        )
                    )
                )
            )
        }
    }

    func testRevisionOverflowWinsBeforeTargetValidation() throws {
        let maximumDocument = document(revision: .max)
        let bytes = try SettingsDocumentCodec().encode(maximumDocument)
        let current = snapshot(document: maximumDocument, bytes: bytes)

        XCTAssertEqual(
            SettingsCommitPreparer().prepare(
                content(appearance: "unsupported"),
                expectation: .version(current.versionToken),
                inspection: .current(current)
            ),
            .terminal(
                .rejected(
                    .init(
                        classification: .prior,
                        failure: .revisionOverflow,
                        priorToken: current.versionToken,
                        targetToken: nil,
                        residual: nil
                    )
                )
            )
        )
    }

    func testFutureCorruptAndUnavailableInspectionsKeepExactEvidence() {
        let futureBytes = Data("future".utf8)
        XCTAssertEqual(
            SettingsCommitPreparer().prepare(
                content(appearance: "unsupported"),
                expectation: .missing,
                inspection: .future(
                    schemaVersion: 8,
                    evidence: .init(
                        originalBytes: futureBytes,
                        sourceSHA256: .init(futureBytes)
                    )
                )
            ),
            .terminal(
                .rejected(
                    .init(
                        classification: .prior,
                        failure: .futureSchema(8),
                        priorToken: nil,
                        targetToken: nil,
                        residual: nil
                    )
                )
            )
        )

        let corruptBytes = Data("corrupt".utf8)
        let corrupt = SettingsDocumentCodecFailure(
            issue: .malformedJSON,
            originalBytes: corruptBytes
        )
        XCTAssertEqual(
            SettingsCommitPreparer().prepare(
                content(appearance: "unsupported"),
                expectation: .missing,
                inspection: .recoveryRequired(
                    failure: corrupt,
                    sourceSHA256: .init(corruptBytes)
                )
            ),
            .terminal(
                .recoveryRequired(
                    .init(
                        classification: .prior,
                        failure: .corrupt(corrupt),
                        priorToken: nil,
                        targetToken: nil,
                        residual: nil
                    )
                )
            )
        )

        let unavailable = SettingsRepositoryUnavailable.primaryFile(
            .changedDuringRead
        )
        XCTAssertEqual(
            SettingsCommitPreparer().prepare(
                content(appearance: "unsupported"),
                expectation: .missing,
                inspection: .unavailable(unavailable)
            ),
            .terminal(
                .recoveryRequired(
                    .init(
                        classification: .indeterminate,
                        failure: .unavailable(unavailable),
                        priorToken: nil,
                        targetToken: nil,
                        residual: nil
                    )
                )
            )
        )
    }

    func testCodecFailuresRetainPriorTokenAndExactOutputLimit() throws {
        let invalid = SettingsCommitPreparer().prepare(
            content(appearance: "unsupported"),
            expectation: .missing,
            inspection: .missing
        )
        guard case .terminal(.rejected(let invalidEvidence)) = invalid else {
            return XCTFail("Expected invalid target.")
        }
        XCTAssertEqual(
            invalidEvidence.failure,
            .invalidTarget(.invalidValue(path: "$.appearance"))
        )

        let sourceContent = content()
        let revisionOne = sourceContent.document(
            revision: .init(rawValue: 1)
        )
        let canonical = try SettingsDocumentCodec().encode(revisionOne)
        var limits = SettingsDocumentCodec.Limits()
        limits.maximumBytes = canonical.count - 1
        let bounded = SettingsCommitPreparer(
            codec: SettingsDocumentCodec(limits: limits)
        ).prepare(
            sourceContent,
            expectation: .missing,
            inspection: .missing
        )
        guard case .terminal(.rejected(let boundedEvidence)) = bounded else {
            return XCTFail("Expected output bound rejection.")
        }
        XCTAssertEqual(
            boundedEvidence.failure,
            .invalidTarget(
                .encodedOutputTooLarge(
                    actual: canonical.count,
                    maximum: canonical.count - 1
                )
            )
        )
    }

    private func content(
        appearance: String = "system"
    ) -> SettingsContent {
        SettingsContent(
            document: document(revision: 99, appearance: appearance)
        )
    }

    private func document(
        revision: UInt64,
        appearance: String = "system"
    ) -> SettingsDocument {
        SettingsDocument(
            revision: .init(rawValue: revision),
            profileTemplates: [
                .init(
                    id: "00000000-0000-4000-8000-000000000001",
                    name: "Work",
                    argumentsText: "--safe",
                    environmentText: "A=1",
                    notes: "Fixture"
                ),
            ],
            defaultBaseStoragePath: "/Managed",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: appearance,
            profileVisualIdentities: []
        )
    }

    private func snapshot(
        document: SettingsDocument,
        bytes: Data
    ) -> SettingsRepositorySnapshot {
        .init(
            document: document,
            versionToken: .init(
                revision: document.revision,
                sourceSHA256: .init(bytes)
            ),
            originalBytes: bytes
        )
    }
}
