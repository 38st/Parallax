import Foundation
import XCTest
@testable import Parallax

final class StrictJSONLexicalParityTests: XCTestCase {
    func testSharedMalformedCorpusRejectsIdenticallyBeforeFutureDispatch() {
        let textualCorpus = [
            #"{"schemaVersion":2,"future":"\uD800"}"#,
            #"{"schemaVersion":2,"future":"\uDC00"}"#,
            #"{"schemaVersion":2,"future":"\uD800\u0041"}"#,
            #"{"schemaVersion":2,"future":"\q"}"#,
            #"{"schemaVersion":2,"future":01}"#,
            #"{"schemaVersion":2,"future":1.}"#,
            #"{"schemaVersion":2,"future":1e+}"#,
            #"{"schemaVersion":2,"future":tru}"#,
            #"{"schemaVersion":2,"future":[0,]}"#,
            #"{"schemaVersion":2,"future":{"x":0,}}"#,
            #"{"schemaVersion":2} trailing"#,
        ]
        var corpus = textualCorpus.map { Data($0.utf8) }
        var invalidUTF8 = Data(
            #"{"schemaVersion":2,"future":""#.utf8
        )
        invalidUTF8.append(0xFF)
        invalidUTF8.append(contentsOf: #""}"#.utf8)
        corpus.append(invalidUTF8)

        for data in corpus {
            XCTAssertEqual(
                preflight.scan(data),
                .failure(.malformedJSON),
                "Preflight accepted: \(data as NSData)"
            )
            XCTAssertEqual(
                codecIssue(codec.decode(data)),
                .malformedJSON,
                "Codec accepted: \(data as NSData)"
            )
        }
    }

    func testSharedNumberLexerPreservesExactProbeSpelling() {
        for spelling in ["-0", "1.0", "1E-2", "-1.20e+03"] {
            let source = Data(
                #"{"schemaVersion":2,"probe":\#(spelling)}"#.utf8
            )
            let scanner = StrictJSONPreflight(
                limits: limits,
                rootRequirement: .object,
                topLevelProbe: .init(key: "probe")
            )
            XCTAssertEqual(
                scanner.scan(source),
                .success(
                    .init(
                        root: .object,
                        probe: .numberToken(spelling),
                        rootItemCount: 2
                    )
                )
            )
            XCTAssertEqual(
                codec.decode(source),
                .future(schemaVersion: 2, originalBytes: source)
            )
        }
    }

    func testSharedExactKeyUsesScalarIdentityWithoutNormalization() {
        let nfc = StrictJSONExactKey("\u{00E9}")
        let escapedNFC = StrictJSONExactKey(
            String(Unicode.Scalar(0x00E9)!)
        )
        let nfd = StrictJSONExactKey("e\u{0301}")

        XCTAssertEqual(nfc, escapedNFC)
        XCTAssertNotEqual(nfc, nfd)
        XCTAssertEqual(Set([nfc, escapedNFC, nfd]).count, 2)
    }

    private let codec = SettingsDocumentCodec()

    private var limits: StrictJSONPreflight.Limits {
        .init(
            maximumBytes: 1_024 * 1_024,
            maximumArrayItems: 4_096,
            maximumObjectMembers: 256,
            maximumKeyUTF8Bytes: 256,
            maximumStringUTF8Bytes: 64 * 1_024,
            maximumNumberBytes: 128,
            maximumNestingDepth: 32,
            maximumTokenCount: 200_000
        )
    }

    private var preflight: StrictJSONPreflight {
        .init(
            limits: limits,
            rootRequirement: .object,
            topLevelProbe: .init(key: "schemaVersion")
        )
    }

    private func codecIssue(
        _ result: SettingsDocumentDecodeResult
    ) -> SettingsDocumentCodecIssue? {
        guard case let .invalid(failure) = result else {
            return nil
        }
        return failure.issue
    }
}
