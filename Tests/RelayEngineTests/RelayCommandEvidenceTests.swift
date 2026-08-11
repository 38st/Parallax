import Foundation
import XCTest
@testable import RelayEngine

final class RelayCommandEvidenceTests: XCTestCase {
    func testMinimalEnvironmentDoesNotInheritAmbientValues() throws {
        let environment = try RelayMinimalEnvironment(
            explicitValues: ["TMPDIR": "/relay/tmp"]
        )

        XCTAssertEqual(
            environment.values,
            ["LANG": "C", "LC_ALL": "C", "TMPDIR": "/relay/tmp"]
        )
        XCTAssertNil(environment.values["HOME"])
        XCTAssertNil(environment.values["PATH"])
        XCTAssertNil(environment.values["SSH_AUTH_SOCK"])
    }

    func testMinimalEnvironmentRejectsUnapprovedAndMalformedNames() {
        XCTAssertThrowsError(
            try RelayMinimalEnvironment(
                explicitValues: ["PATH": "/malicious"]
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayMinimalEnvironmentError,
                .prohibitedName("PATH")
            )
        }
        XCTAssertThrowsError(
            try RelayMinimalEnvironment(
                explicitValues: ["BAD-NAME": "value"],
                allowedNames: ["BAD-NAME"]
            )
        )
    }

    func testBoundedCaptureDrainsAndDigestsAllBytesButRetainsPrefix() {
        let stream = RelayBoundedCommandStream(limit: 5)
        stream.append(Data("hello".utf8))
        stream.append(Data(" world".utf8))

        let result = stream.finalize(redactor: RelayEvidenceRedactor())

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.totalByteCount, 11)
        XCTAssertEqual(result.retainedByteCount, 5)
        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(
            result.rawSHA256,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        )
    }

    func testRedactorHandlesExplicitAndRecognizedTokenForms() {
        let redactor = RelayEvidenceRedactor(
            sensitiveLiterals: ["super-secret"]
        )
        let input = Data(
            "value=super-secret Authorization: Bearer abc.def-123 ghp_1234567890abcdefghijklmnop"
                .utf8
        )

        let result = redactor.redact(input)

        XCTAssertFalse(result.text.contains("super-secret"))
        XCTAssertFalse(result.text.contains("abc.def-123"))
        XCTAssertFalse(result.text.contains("ghp_"))
        XCTAssertEqual(result.replacementCount, 3)
    }

    func testTruncationDoesNotExposePrefixOfExplicitSecret() {
        let stream = RelayBoundedCommandStream(limit: 7)
        stream.append(Data("token=super-secret".utf8))

        let result = stream.finalize(
            redactor: RelayEvidenceRedactor(
                sensitiveLiterals: ["super-secret"]
            )
        )

        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.text, "token=<redacted-truncated>")
        XCTAssertFalse(result.text.contains("s"))
    }

    func testBudgetsRejectUnboundedOrNegativeValues() {
        XCTAssertThrowsError(try RelayCommandBudget(wallTime: .zero))
        XCTAssertThrowsError(
            try RelayCommandBudget(
                wallTime: .seconds(1),
                maximumStandardOutputBytes: -1
            )
        )
    }
}
