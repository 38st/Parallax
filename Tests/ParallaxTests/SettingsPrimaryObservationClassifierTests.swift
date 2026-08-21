import Foundation
@testable import Parallax
import XCTest

final class SettingsPrimaryObservationClassifierTests: XCTestCase {
    typealias ReadResult = Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >

    func testPreparedObservationClassificationMatrix() {
        let priorBytes = Data("prior".utf8)
        let targetBytes = Data("target".utf8)
        let otherBytes = Data("other".utf8)
        let missingPrior = prepared(
            prior: .missing,
            targetBytes: targetBytes
        )
        let currentPrior = prepared(
            prior: .current(
                bytes: priorBytes,
                token: token(revision: 1, bytes: priorBytes)
            ),
            targetBytes: targetBytes
        )
        let cases: [
            (
                name: String,
                result: ReadResult,
                prepared: SettingsPrimaryPreparedPublication,
                expected: SettingsPrimaryMutationClassification
            )
        ] = [
            (
                "failed read",
                .failure(.expiredAuthority),
                missingPrior,
                .indeterminate
            ),
            (
                "missing prior remains missing",
                .success(.missing),
                missingPrior,
                .prior
            ),
            (
                "current prior becomes missing",
                .success(.missing),
                currentPrior,
                .neither
            ),
            (
                "target bytes",
                .success(.bytes(targetBytes)),
                currentPrior,
                .target
            ),
            (
                "prior bytes",
                .success(.bytes(priorBytes)),
                currentPrior,
                .prior
            ),
            (
                "unrelated bytes",
                .success(.bytes(otherBytes)),
                currentPrior,
                .neither
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                SettingsPrimaryObservationClassifier.classify(
                    testCase.result,
                    prepared: testCase.prepared
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testInitialObservationClassificationMatrix() {
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        let cases: [
            (
                name: String,
                initial: SettingsPrimaryInitialObservation,
                result: ReadResult,
                expected: SettingsPrimaryMutationClassification
            )
        ] = [
            (
                "unreadable initial remains indeterminate",
                .unreadable(.expiredAuthority),
                .success(.missing),
                .indeterminate
            ),
            (
                "missing remains missing",
                .missing,
                .success(.missing),
                .prior
            ),
            (
                "missing becomes bytes",
                .missing,
                .success(.bytes(original)),
                .neither
            ),
            (
                "bytes remain exact",
                .bytes(original),
                .success(.bytes(original)),
                .prior
            ),
            (
                "bytes change",
                .bytes(original),
                .success(.bytes(replacement)),
                .neither
            ),
            (
                "reclassification read fails",
                .bytes(original),
                .failure(.expiredAuthority),
                .indeterminate
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                SettingsPrimaryObservationClassifier.classify(
                    testCase.result,
                    initial: testCase.initial
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testInitialObservationPreservesExactReadEvidence() {
        let bytes = Data("bytes".utf8)
        XCTAssertEqual(
            SettingsPrimaryObservationClassifier.initialObservation(
                .success(.missing)
            ),
            .missing
        )
        XCTAssertEqual(
            SettingsPrimaryObservationClassifier.initialObservation(
                .success(.bytes(bytes))
            ),
            .bytes(bytes)
        )
        XCTAssertEqual(
            SettingsPrimaryObservationClassifier.initialObservation(
                .failure(.reentrantAuthorityOperation)
            ),
            .unreadable(.reentrantAuthorityOperation)
        )
    }

    func testCleanupClassificationMatrixAndLazyReclassification() {
        let cases: [
            (
                name: String,
                original: SettingsPrimaryMutationClassification,
                targetProofEligible: Bool?,
                fresh: SettingsPrimaryMutationClassification,
                expected: SettingsPrimaryMutationClassification,
                expectedCalls: Int
            )
        ] = [
            ("settled prior", .prior, false, .target, .prior, 0),
            ("fresh prior", .indeterminate, false, .prior, .prior, 1),
            ("fresh neither", .indeterminate, false, .neither, .neither, 1),
            (
                "fresh indeterminate",
                .indeterminate,
                false,
                .indeterminate,
                .indeterminate,
                1
            ),
            ("eligible target", .indeterminate, true, .target, .target, 1),
            ("ineligible target", .indeterminate, false, .target, .neither, 1),
            (
                "target without publication",
                .indeterminate,
                nil,
                .target,
                .target,
                1
            ),
        ]

        for testCase in cases {
            var calls = 0
            let actual = SettingsPrimaryObservationClassifier
                .cleanupClassification(
                    testCase.original,
                    targetProofEligible: testCase.targetProofEligible
                ) {
                    calls += 1
                    return testCase.fresh
                }
            XCTAssertEqual(actual, testCase.expected, testCase.name)
            XCTAssertEqual(calls, testCase.expectedCalls, testCase.name)
        }
    }

    private func prepared(
        prior: SettingsPrimaryPreparedPrior,
        targetBytes: Data
    ) -> SettingsPrimaryPreparedPublication {
        let targetToken = token(revision: 2, bytes: targetBytes)
        return SettingsPrimaryPreparedPublication(
            prior: prior,
            targetDocument: SettingsDocument(
                revision: targetToken.revision,
                profileTemplates: [],
                defaultBaseStoragePath: "",
                confirmBeforeLaunch: false,
                automaticallyRecoverCrashedApps: true,
                appearance: "system",
                profileVisualIdentities: []
            ),
            targetBytes: targetBytes,
            targetToken: targetToken
        )
    }

    private func token(
        revision: UInt64,
        bytes: Data
    ) -> SettingsVersionToken {
        SettingsVersionToken(
            revision: SettingsRevision(rawValue: revision),
            sourceSHA256: SettingsSourceSHA256(bytes)
        )
    }
}
