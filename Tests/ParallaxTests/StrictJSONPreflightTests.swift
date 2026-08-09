import Foundation
import XCTest
@testable import Parallax

final class StrictJSONPreflightTests: XCTestCase {
    func testFormatNeutralRootEvidenceAndRequirements() {
        XCTAssertEqual(scan(#"{}"#), success(.object))
        XCTAssertEqual(scan(#"[]"#), success(.array))
        for source in [#""text""#, "true", "false", "null", "-1.5e+2"] {
            XCTAssertEqual(scan(source), success(.scalar))
        }
        XCTAssertEqual(
            scan(" [ ] ", requirement: .array),
            success(.array)
        )
        XCTAssertEqual(
            scan(" { } ", requirement: .object),
            success(.object)
        )
        XCTAssertEqual(
            scan("42", requirement: .object),
            .failure(
                .invalidRoot(required: .object, actual: .scalar)
            )
        )
        XCTAssertEqual(
            scan("{} trailing", requirement: .array),
            .failure(.malformedJSON),
            "Malformed/trailing input must precede a root-shape issue."
        )
        XCTAssertEqual(scan(""), .failure(.malformedJSON))
        XCTAssertEqual(scan(" \n\t"), .failure(.malformedJSON))
    }

    func testNonSettingsJSONEscapesSurrogatesAndRawUTF8() {
        XCTAssertEqual(
            scan(
                #"{"free":"é","escaped":"\u00e9","emoji":"\uD83D\uDE00"}"#
            ),
            success(.object)
        )
        for source in [
            #"{"x":"\uD800"}"#,
            #"{"x":"\uDC00"}"#,
            #"{"x":"\uD800\u0041"}"#,
            #"{"x":"\q"}"#,
            "{\"x\":\"line\nbreak\"}",
        ] {
            XCTAssertEqual(scan(source), .failure(.malformedJSON))
        }
        XCTAssertEqual(
            preflight().scan(Data([0x22, 0xff, 0x22])),
            .failure(.malformedJSON)
        )
    }

    func testExactNumberGrammarAndProbeTokenPreservation() {
        for number in [
            "0", "-0", "1", "-12", "1.0", "1e2", "1E-2", "-1.20e+03",
        ] {
            XCTAssertEqual(scan(number), success(.scalar))
        }
        for number in [
            "-", "01", "-01", "1.", ".1", "1e", "1e+", "+1", "NaN",
        ] {
            XCTAssertEqual(scan(number), .failure(.malformedJSON))
        }
        XCTAssertEqual(
            scan(
                #"{"version":-1.20e+03}"#,
                probe: "version"
            ),
            .success(
                .init(
                    root: .object,
                    probe: .numberToken("-1.20e+03")
                )
            )
        )
    }

    func testProbeMissingOtherDuplicateAndScalarExactIdentity() {
        XCTAssertEqual(
            scan("{}", probe: "schemaVersion"),
            .success(.init(root: .object, probe: .missing))
        )
        XCTAssertEqual(
            scan(#"{"schemaVersion":"1"}"#, probe: "schemaVersion"),
            .success(.init(root: .object, probe: .other))
        )
        XCTAssertEqual(
            scan(#"{"sch\u0065maVersion":2}"#, probe: "schemaVersion"),
            .success(
                .init(root: .object, probe: .numberToken("2"))
            )
        )
        XCTAssertEqual(
            scan(
                #"{"schemaVersion":1,"sch\u0065maVersion":2}"#,
                probe: "schemaVersion"
            ),
            .failure(
                .duplicateKey(path: "$", key: "schemaVersion")
            )
        )

        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"
        XCTAssertNotEqual(
            nfc.unicodeScalars.map(\.value),
            nfd.unicodeScalars.map(\.value)
        )
        XCTAssertEqual(
            scan(
                "{\"\\u00e9\":1,\"e\\u0301\":2}",
                probe: nfc
            ),
            .success(
                .init(root: .object, probe: .numberToken("1"))
            )
        )
    }

    func testInputByteLimitIsExactAndPrecedesAllocation() {
        var exactLimits = limits()
        exactLimits = replacing(exactLimits, maximumBytes: 2)
        XCTAssertEqual(
            preflight(limits: exactLimits).scan(Data("[]".utf8)),
            success(.array)
        )
        XCTAssertEqual(
            preflight(limits: exactLimits).scan(Data("[ ]".utf8)),
            .failure(.inputTooLarge(actual: 3, maximum: 2))
        )
    }

    func testDepthTokenAndCollectionLimitsAreExact() {
        var depth = limits()
        depth = replacing(depth, maximumNestingDepth: 2)
        XCTAssertEqual(
            preflight(limits: depth).scan(Data("[[]]".utf8)),
            success(.array)
        )
        XCTAssertEqual(
            preflight(limits: depth).scan(Data("[[[]]]".utf8)),
            .failure(.excessiveNesting(maximum: 2))
        )

        var tokens = limits()
        tokens = replacing(tokens, maximumTokenCount: 2)
        XCTAssertEqual(
            preflight(limits: tokens).scan(Data("[0]".utf8)),
            success(.array)
        )
        tokens = replacing(tokens, maximumTokenCount: 1)
        XCTAssertEqual(
            preflight(limits: tokens).scan(Data("[0]".utf8)),
            .failure(.tooManyTokens(maximum: 1))
        )

        var collections = limits()
        collections = replacing(
            collections,
            maximumArrayItems: 2,
            maximumObjectMembers: 2
        )
        XCTAssertEqual(
            preflight(limits: collections).scan(Data("[0,1]".utf8)),
            success(.array)
        )
        XCTAssertEqual(
            preflight(limits: collections).scan(Data("[0,1,2]".utf8)),
            .failure(.tooManyItems(path: "$", maximum: 2))
        )
        XCTAssertEqual(
            preflight(limits: collections).scan(
                Data(#"{"a":0,"b":1}"#.utf8)
            ),
            success(.object)
        )
        XCTAssertEqual(
            preflight(limits: collections).scan(
                Data(#"{"a":0,"b":1,"c":2}"#.utf8)
            ),
            .failure(.tooManyItems(path: "$", maximum: 2))
        )
    }

    func testMultibyteKeyStringAndNumberLimitsAreExact() {
        var bounded = limits()
        bounded = replacing(
            bounded,
            maximumKeyUTF8Bytes: 2,
            maximumStringUTF8Bytes: 2,
            maximumNumberBytes: 2
        )
        XCTAssertEqual(
            preflight(limits: bounded).scan(Data(#"{"é":"é"}"#.utf8)),
            success(.object)
        )
        XCTAssertEqual(
            preflight(limits: bounded).scan(Data(#"{"éa":0}"#.utf8)),
            .failure(.stringTooLong(path: "$.<key>", maximum: 2))
        )
        XCTAssertEqual(
            preflight(limits: bounded).scan(Data(#"{"a":"éa"}"#.utf8)),
            .failure(.stringTooLong(path: "$.a", maximum: 2))
        )
        XCTAssertEqual(
            preflight(limits: bounded).scan(Data(#"{"a":12}"#.utf8)),
            success(.object)
        )
        XCTAssertEqual(
            preflight(limits: bounded).scan(Data(#"{"a":123}"#.utf8)),
            .failure(
                .numericTokenTooLong(path: "$.a", maximum: 2)
            )
        )
    }

    func testProbeHasIndependentFixedImplementationBound() {
        let maximum =
            StrictJSONPreflight.implementationMaximumProbeKeyUTF8Bytes
        let exact = String(repeating: "é", count: maximum / 2)
        XCTAssertEqual(exact.utf8.count, maximum)
        XCTAssertEqual(
            scan("{}", probe: exact),
            .success(.init(root: .object, probe: .missing))
        )
        let over = exact + "p"
        XCTAssertEqual(
            scan("{}", probe: over),
            .failure(
                .probeKeyTooLong(
                    actual: maximum + 1,
                    maximum: maximum
                )
            )
        )
    }

    func testInputKeyLimitDoesNotPreflightProbeConfiguration() {
        for maximum in [12, 0, -1] {
            let bounded = replacing(
                limits(),
                maximumKeyUTF8Bytes: maximum
            )
            let scanner = preflight(
                limits: bounded,
                requirement: .object,
                probe: "schemaVersion"
            )
            XCTAssertEqual(
                scanner.scan(Data()),
                .failure(.malformedJSON)
            )
            XCTAssertEqual(
                scanner.scan(Data("{".utf8)),
                .failure(.malformedJSON)
            )
            XCTAssertEqual(
                scanner.scan(Data("{}".utf8)),
                .success(.init(root: .object, probe: .missing))
            )
            XCTAssertEqual(
                scanner.scan(Data("[]".utf8)),
                .failure(
                    .invalidRoot(required: .object, actual: .array)
                )
            )
            XCTAssertEqual(
                scanner.scan(
                    Data(#"{"schemaVersion":1}"#.utf8)
                ),
                .failure(
                    .stringTooLong(
                        path: "$.<key>",
                        maximum: maximum
                    )
                )
            )
        }
    }

    func testCodecKeyLimitPreservesInputFailurePrecedence() {
        for maximum in [12, 0, -1] {
            var codecLimits = SettingsDocumentCodec.Limits()
            codecLimits.maximumKeyUTF8Bytes = maximum
            let codec = SettingsDocumentCodec(limits: codecLimits)

            XCTAssertEqual(
                codecIssue(codec.decode(Data())),
                .malformedJSON
            )
            XCTAssertEqual(
                codecIssue(codec.decode(Data("{".utf8))),
                .malformedJSON
            )
            XCTAssertEqual(
                codecIssue(codec.decode(Data("{}".utf8))),
                .missingKey(path: "$.schemaVersion")
            )
            XCTAssertEqual(
                codecIssue(codec.decode(Data("[]".utf8))),
                .invalidTopLevel
            )
            XCTAssertEqual(
                codecIssue(
                    codec.decode(
                        Data(#"{"schemaVersion":1}"#.utf8)
                    )
                ),
                .stringTooLong(
                    path: "$.<key>",
                    maximum: maximum
                )
            )
        }
    }

    func testImplementationNestingCeilingAtExactAndPlusOne() {
        let maximum =
            StrictJSONPreflight.implementationMaximumNestingDepth
        let unlimited = replacing(
            limits(),
            maximumNestingDepth: .max
        )
        let scanner = preflight(limits: unlimited)
        XCTAssertEqual(
            scanner.scan(nestedArrays(depth: maximum)),
            success(.array)
        )
        XCTAssertEqual(
            scanner.scan(nestedArrays(depth: maximum + 1)),
            .failure(.excessiveNesting(maximum: maximum))
        )
    }

    func testLimitsAreTotalForZeroNegativeAndIntMax() {
        var zero = limits()
        zero = replacing(zero, maximumBytes: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data()),
            .failure(.malformedJSON)
        )
        XCTAssertEqual(
            preflight(limits: zero).scan(Data("0".utf8)),
            .failure(.inputTooLarge(actual: 1, maximum: 0))
        )

        zero = replacing(limits(), maximumTokenCount: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data("0".utf8)),
            .failure(.tooManyTokens(maximum: 0))
        )

        zero = replacing(limits(), maximumNestingDepth: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data("[]".utf8)),
            .failure(.excessiveNesting(maximum: 0))
        )

        zero = replacing(limits(), maximumArrayItems: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data("[0]".utf8)),
            .failure(.tooManyItems(path: "$", maximum: 0))
        )

        zero = replacing(limits(), maximumObjectMembers: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data(#"{"a":0}"#.utf8)),
            .failure(.tooManyItems(path: "$", maximum: 0))
        )

        zero = replacing(limits(), maximumKeyUTF8Bytes: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data(#"{"":0}"#.utf8)),
            success(.object)
        )
        XCTAssertEqual(
            preflight(limits: zero).scan(Data(#"{"a":0}"#.utf8)),
            .failure(.stringTooLong(path: "$.<key>", maximum: 0))
        )

        zero = replacing(limits(), maximumStringUTF8Bytes: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data(#"{"a":""}"#.utf8)),
            success(.object)
        )
        XCTAssertEqual(
            preflight(limits: zero).scan(Data(#"{"a":"x"}"#.utf8)),
            .failure(.stringTooLong(path: "$.a", maximum: 0))
        )

        zero = replacing(limits(), maximumNumberBytes: 0)
        XCTAssertEqual(
            preflight(limits: zero).scan(Data("0".utf8)),
            .failure(.numericTokenTooLong(path: "$", maximum: 0))
        )

        var negative = limits()
        negative = replacing(negative, maximumBytes: -1)
        XCTAssertEqual(
            preflight(limits: negative).scan(Data()),
            .failure(.inputTooLarge(actual: 0, maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumTokenCount: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data("0".utf8)),
            .failure(.tooManyTokens(maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumNestingDepth: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data("[]".utf8)),
            .failure(.excessiveNesting(maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumObjectMembers: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data("{}".utf8)),
            .failure(.tooManyItems(path: "$", maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumArrayItems: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data("[]".utf8)),
            .failure(.tooManyItems(path: "$", maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumKeyUTF8Bytes: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data(#"{"":0}"#.utf8)),
            .failure(.stringTooLong(path: "$.<key>", maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumStringUTF8Bytes: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data(#""""#.utf8)),
            .failure(.stringTooLong(path: "$", maximum: -1))
        )

        negative = replacing(
            limits(),
            maximumNumberBytes: -1
        )
        XCTAssertEqual(
            preflight(limits: negative).scan(Data("0".utf8)),
            .failure(.numericTokenTooLong(path: "$", maximum: -1))
        )

        let unlimited = StrictJSONPreflight.Limits(
            maximumBytes: .max,
            maximumArrayItems: .max,
            maximumObjectMembers: .max,
            maximumKeyUTF8Bytes: .max,
            maximumStringUTF8Bytes: .max,
            maximumNumberBytes: .max,
            maximumNestingDepth: .max,
            maximumTokenCount: .max
        )
        XCTAssertEqual(
            preflight(limits: unlimited).scan(
                Data(#"{"a":[true,null,-1.5e2]}"#.utf8)
            ),
            success(.object)
        )
    }

    func testCheckedSendableConcurrentScansAreDeterministic() {
        assertSendable(StrictJSONPreflight.self)
        assertSendable(StrictJSONPreflightEvidence.self)
        assertSendable(StrictJSONPreflightIssue.self)
        let scanner = preflight(
            requirement: .object,
            probe: "v"
        )
        let data = Data(#"{"v":42,"items":[1,2,3]}"#.utf8)
        let results = PreflightResults()
        let group = DispatchGroup()
        for _ in 0 ..< 32 {
            group.enter()
            DispatchQueue.global().async {
                results.append(scanner.scan(data))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values.count, 32)
        XCTAssertTrue(results.values.allSatisfy {
            $0 == .success(
                .init(root: .object, probe: .numberToken("42"))
            )
        })
    }

    func testEvidenceContainsOnlyRootAndProbe() {
        let evidence = StrictJSONPreflightEvidence(
            root: .object,
            probe: .numberToken("1")
        )
        XCTAssertEqual(
            Mirror(reflecting: evidence).children.compactMap(\.label),
            ["root", "probe"]
        )
    }

    func testMaximumFourMiBInputPerformance() {
        let maximum = 4 * 1_024 * 1_024
        var data = Data(repeating: 0x20, count: maximum - 2)
        data.append(contentsOf: [0x5B, 0x5D])
        var maximumLimits = limits()
        maximumLimits = replacing(
            maximumLimits,
            maximumBytes: maximum
        )
        let scanner = preflight(limits: maximumLimits)

        measure {
            XCTAssertEqual(scanner.scan(data), success(.array))
        }
    }

    private func scan(
        _ source: String,
        requirement: StrictJSONRootRequirement = .any,
        probe: String? = nil
    ) -> Result<StrictJSONPreflightEvidence, StrictJSONPreflightIssue> {
        preflight(
            requirement: requirement,
            probe: probe
        ).scan(Data(source.utf8))
    }

    private func success(
        _ root: StrictJSONRootKind
    ) -> Result<StrictJSONPreflightEvidence, StrictJSONPreflightIssue> {
        .success(.init(root: root, probe: .notRequested))
    }

    private func nestedArrays(depth: Int) -> Data {
        Data(
            (
                String(repeating: "[", count: depth)
                    + String(repeating: "]", count: depth)
            ).utf8
        )
    }

    private func codecIssue(
        _ result: SettingsDocumentDecodeResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SettingsDocumentCodecIssue {
        guard case .invalid(let failure) = result else {
            XCTFail("Expected invalid codec input.", file: file, line: line)
            return .malformedJSON
        }
        return failure.issue
    }

    private func preflight(
        limits: StrictJSONPreflight.Limits? = nil,
        requirement: StrictJSONRootRequirement = .any,
        probe: String? = nil
    ) -> StrictJSONPreflight {
        .init(
            limits: limits ?? self.limits(),
            rootRequirement: requirement,
            topLevelProbe: probe.map {
                .init(key: $0)
            }
        )
    }

    private func limits() -> StrictJSONPreflight.Limits {
        .init(
            maximumBytes: 4 * 1_024 * 1_024,
            maximumArrayItems: 4_096,
            maximumObjectMembers: 256,
            maximumKeyUTF8Bytes: 256,
            maximumStringUTF8Bytes: 64 * 1_024,
            maximumNumberBytes: 128,
            maximumNestingDepth: 32,
            maximumTokenCount: 200_000
        )
    }

    private func replacing(
        _ limits: StrictJSONPreflight.Limits,
        maximumBytes: Int? = nil,
        maximumArrayItems: Int? = nil,
        maximumObjectMembers: Int? = nil,
        maximumKeyUTF8Bytes: Int? = nil,
        maximumStringUTF8Bytes: Int? = nil,
        maximumNumberBytes: Int? = nil,
        maximumNestingDepth: Int? = nil,
        maximumTokenCount: Int? = nil
    ) -> StrictJSONPreflight.Limits {
        .init(
            maximumBytes: maximumBytes ?? limits.maximumBytes,
            maximumArrayItems:
                maximumArrayItems ?? limits.maximumArrayItems,
            maximumObjectMembers:
                maximumObjectMembers ?? limits.maximumObjectMembers,
            maximumKeyUTF8Bytes:
                maximumKeyUTF8Bytes ?? limits.maximumKeyUTF8Bytes,
            maximumStringUTF8Bytes:
                maximumStringUTF8Bytes ?? limits.maximumStringUTF8Bytes,
            maximumNumberBytes:
                maximumNumberBytes ?? limits.maximumNumberBytes,
            maximumNestingDepth:
                maximumNestingDepth ?? limits.maximumNestingDepth,
            maximumTokenCount:
                maximumTokenCount ?? limits.maximumTokenCount
        )
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}

private final class PreflightResults: @unchecked Sendable {
    typealias Value = Result<
        StrictJSONPreflightEvidence,
        StrictJSONPreflightIssue
    >

    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.withLock {
            stored.append(value)
        }
    }

    var values: [Value] {
        lock.withLock { stored }
    }
}
