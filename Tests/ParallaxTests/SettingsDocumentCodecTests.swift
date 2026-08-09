import Foundation
import XCTest
@testable import Parallax

final class SettingsDocumentCodecTests: XCTestCase {
    private let codec = SettingsDocumentCodec()

    func testFullRoundTripPreservesAllSettingsAndTemplateOrder()
        throws
    {
        for appearance in ["system", "light", "dark"] {
            let document = makeDocument(appearance: appearance)
            let encoded = try codec.encode(document)

            guard case let .current(decoded) = codec.decode(encoded) else {
                return XCTFail("Expected a current settings document.")
            }

            XCTAssertEqual(decoded, document)
            XCTAssertEqual(
                decoded.profileTemplates.map(\.name),
                ["Café 🧪", "Cafe\u{301}"]
            )
        }
    }

    func testHistoricalTemplateNameScalarsRemainExactWithoutMutationValidation()
        throws
    {
        let historicalNames = [
            "Cafe\u{301}",
            "..",
            "\u{202E}hidden",
            "line\nseparator",
            " \u{200D} ",
        ]
        let templates = historicalNames.enumerated().map { index, name in
            SettingsDocument.Template(
                id: uuid(index + 100),
                name: name,
                argumentsText: "",
                environmentText: "",
                notes: ""
            )
        }
        let document = replacing(
            makeDocument(),
            templates: templates,
            visuals: []
        )

        let data = try codec.encode(document)
        guard case let .current(decoded) = codec.decode(data) else {
            return XCTFail("Expected historical names to remain decodable.")
        }

        XCTAssertEqual(decoded.profileTemplates.map(\.name), historicalNames)
        for index in historicalNames.indices {
            XCTAssertEqual(
                Array(decoded.profileTemplates[index].name.unicodeScalars),
                Array(historicalNames[index].unicodeScalars)
            )
        }
    }

    func testGoldenEncodingIsCompactSortedAndRepeatable() throws {
        let document = SettingsDocument(
            revision: SettingsRevision(rawValue: 7),
            profileTemplates: [
                .init(
                    id: "00000000-0000-4000-8000-000000000002",
                    name: "Work",
                    argumentsText: "--label=\"a/b\"\nnext",
                    environmentText: #"PATH=C:\bin"#,
                    notes: "emoji 🧪"
                )
            ],
            defaultBaseStoragePath: "/Managed/Root",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: "dark",
            profileVisualIdentities: [
                .init(
                    profileID:
                        "00000000-0000-4000-8000-000000000002",
                    symbol: "briefcase.fill",
                    color: "blue"
                )
            ]
        )
        let expected = Data(
            #"{"appearance":"dark","automaticallyRecoverCrashedApps":false,"confirmBeforeLaunch":true,"defaultBaseStoragePath":"/Managed/Root","profileTemplates":[{"argumentsText":"--label=\"a/b\"\nnext","environmentText":"PATH=C:\\bin","id":"00000000-0000-4000-8000-000000000002","name":"Work","notes":"emoji 🧪"}],"profileVisualIdentities":[{"color":"blue","profileID":"00000000-0000-4000-8000-000000000002","symbol":"briefcase.fill"}],"revision":7,"schemaVersion":1}"#.utf8
        )

        let first = try codec.encode(document)
        let second = try codec.encode(document)

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertFalse(first.contains(0x0A))
    }

    func testVisualsCanonicalizeByLowercaseUUIDAndSort()
        throws
    {
        let document = replacing(
            makeDocument(),
            visuals: [
                .init(
                    profileID:
                        "AAAAAAAA-0000-4000-8000-000000000002",
                    symbol: "globe",
                    color: "cyan"
                ),
                .init(
                    profileID:
                        "11111111-0000-4000-8000-000000000001",
                    symbol: "terminal.fill",
                    color: "green"
                ),
            ]
        )

        let data = try codec.encode(document)
        guard case let .current(decoded) = codec.decode(data) else {
            return XCTFail("Expected a current settings document.")
        }

        XCTAssertEqual(
            decoded.profileVisualIdentities.map(\.profileID),
            [
                "11111111-0000-4000-8000-000000000001",
                "aaaaaaaa-0000-4000-8000-000000000002",
            ]
        )
    }

    func testFutureSchemaIsIdentifiedWithoutCurrentDecodeAndKeepsBytes() {
        let data = Data(
            #" { "schemaVersion" : 2, "newShape" : {"value":true} } "#
                .utf8
        )

        XCTAssertEqual(
            codec.decode(data),
            .future(schemaVersion: 2, originalBytes: data)
        )
    }

    func testFutureSchemaSkipsEveryCurrentFieldLimit() {
        let appearance = String(repeating: "a", count: 17)
        let basePath = String(repeating: "p", count: 4_097)
        let identifier = String(repeating: "i", count: 37)
        let name = String(repeating: "n", count: 257)
        let text = String(repeating: "t", count: 64 * 1_024)
        let symbol = String(repeating: "s", count: 65)
        let color = String(repeating: "c", count: 17)
        let data = Data(
            """
            {"revision":184467440737095516160,\
            "profileTemplates":[{\
            "id":"\(identifier)",\
            "name":"\(name)",\
            "argumentsText":"\(text)",\
            "environmentText":"\(text)",\
            "notes":"\(text)"}],\
            "defaultBaseStoragePath":"\(basePath)",\
            "confirmBeforeLaunch":"future-value",\
            "automaticallyRecoverCrashedApps":null,\
            "appearance":"\(appearance)",\
            "profileVisualIdentities":[{\
            "profileID":"\(identifier)",\
            "symbol":"\(symbol)",\
            "color":"\(color)"}],\
            "schemaVersion":2}
            """.utf8
        )

        XCTAssertEqual(
            codec.decode(data),
            .future(schemaVersion: 2, originalBytes: data)
        )
    }

    func testRevisionWrapperEncodesZeroAndMaximumAsJSONNumbers()
        throws
    {
        for rawValue in [UInt64.zero, UInt64.max] {
            let document = replacing(
                makeDocument(),
                revision: SettingsRevision(rawValue: rawValue)
            )
            let data = try codec.encode(document)
            let json = try XCTUnwrap(
                String(data: data, encoding: .utf8)
            )

            XCTAssertTrue(
                json.contains(#""revision":\#(rawValue)"#)
            )
            guard case let .current(decoded) = codec.decode(data)
            else {
                return XCTFail("Expected current revision document.")
            }
            XCTAssertEqual(decoded.revision.rawValue, rawValue)
        }
    }

    func testInvalidFailuresKeepExactOriginalBytes() {
        let data = replacingJSON(
            validJSON(),
            #""revision":0"#,
            with: #""revision":null"#
        )

        guard case let .invalid(failure) = codec.decode(data) else {
            return XCTFail("Expected invalid input.")
        }

        XCTAssertEqual(failure.originalBytes, data)
        XCTAssertEqual(
            failure.issue,
            .invalidType(path: "$.revision")
        )
    }

    func testInputLimitAllowsExactMaximumAndRejectsPlusOne() {
        let base = validJSON()
        let exact = base + Data(
            repeating: 0x20,
            count: 4 * 1_024 * 1_024 - base.count
        )
        let over = exact + Data([0x20])

        guard case .current = codec.decode(exact) else {
            return XCTFail("Exact input maximum must decode.")
        }
        XCTAssertEqual(
            issue(for: over),
            .inputTooLarge(
                actual: 4 * 1_024 * 1_024 + 1,
                maximum: 4 * 1_024 * 1_024
            )
        )
    }

    func testStringLimitsAllowBoundaryAndRejectPlusOne()
        throws
    {
        let base = makeDocument()
        let name = String(repeating: "n", count: 256)
        let path = String(repeating: "p", count: 4_096)
        let text = String(repeating: "t", count: 64 * 1_024)
        let boundaryTemplate = SettingsDocument.Template(
            id: base.profileTemplates[0].id,
            name: name,
            argumentsText: text,
            environmentText: text,
            notes: text
        )
        let boundary = SettingsDocument(
            revision: base.revision,
            profileTemplates: [boundaryTemplate],
            defaultBaseStoragePath: path,
            confirmBeforeLaunch: base.confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                base.automaticallyRecoverCrashedApps,
            appearance: base.appearance,
            profileVisualIdentities: []
        )

        let boundaryData = try codec.encode(boundary)
        guard case .current = codec.decode(boundaryData) else {
            return XCTFail("String boundaries must decode.")
        }

        let cases: [(SettingsDocument, String, Int)] = [
            (
                replacing(
                    boundary,
                    templates: [
                        .init(
                            id: boundaryTemplate.id,
                            name: name + "n",
                            argumentsText: "",
                            environmentText: "",
                            notes: ""
                        )
                    ]
                ),
                "$.profileTemplates[0].name",
                256
            ),
            (
                replacing(boundary, basePath: path + "p"),
                "$.defaultBaseStoragePath",
                4_096
            ),
            (
                replacing(
                    boundary,
                    templates: [
                        template(
                            boundaryTemplate,
                            argumentsText: text + "t"
                        )
                    ]
                ),
                "$.profileTemplates[0].argumentsText",
                64 * 1_024
            ),
            (
                replacing(
                    boundary,
                    templates: [
                        template(
                            boundaryTemplate,
                            environmentText: text + "t"
                        )
                    ]
                ),
                "$.profileTemplates[0].environmentText",
                64 * 1_024
            ),
            (
                replacing(
                    boundary,
                    templates: [
                        template(
                            boundaryTemplate,
                            notes: text + "t"
                        )
                    ]
                ),
                "$.profileTemplates[0].notes",
                64 * 1_024
            ),
        ]

        for (document, path, maximum) in cases {
            XCTAssertThrowsError(try codec.encode(document)) {
                XCTAssertEqual(
                    $0 as? SettingsDocumentCodecIssue,
                    .stringTooLong(path: path, maximum: maximum)
                )
            }
            XCTAssertEqual(
                issue(for: try rawEncode(document)),
                .stringTooLong(path: path, maximum: maximum)
            )
        }
    }

    func testMultibyteUTF8LimitsAllowExactBytesAndRejectPlusOne()
        throws
    {
        let base = makeDocument()
        let exactName = String(repeating: "é", count: 127) + "aa"
        let overName = String(repeating: "é", count: 127) + "aé"
        let exactPath = String(repeating: "é", count: 2_048)
        let overPath =
            String(repeating: "é", count: 2_047) + "aé"
        let exactText =
            String(repeating: "é", count: 32_768)
        let overText =
            String(repeating: "é", count: 32_767) + "aé"
        XCTAssertEqual(exactName.utf8.count, 256)
        XCTAssertEqual(overName.utf8.count, 257)
        XCTAssertEqual(exactPath.utf8.count, 4_096)
        XCTAssertEqual(overPath.utf8.count, 4_097)
        XCTAssertEqual(exactText.utf8.count, 64 * 1_024)
        XCTAssertEqual(overText.utf8.count, 64 * 1_024 + 1)

        let exactTemplate = SettingsDocument.Template(
            id: uuid(50),
            name: exactName,
            argumentsText: exactText,
            environmentText: exactText,
            notes: exactText
        )
        let exact = replacing(
            base,
            templates: [exactTemplate],
            basePath: exactPath,
            visuals: []
        )
        let exactData = try codec.encode(exact)
        guard case .current = codec.decode(exactData) else {
            return XCTFail("Exact multibyte boundaries must decode.")
        }

        let cases: [(SettingsDocument, String, Int)] = [
            (
                replacing(
                    exact,
                    templates: [
                        template(exactTemplate, name: overName)
                    ]
                ),
                "$.profileTemplates[0].name",
                256
            ),
            (
                replacing(exact, basePath: overPath),
                "$.defaultBaseStoragePath",
                4_096
            ),
            (
                replacing(
                    exact,
                    templates: [
                        template(
                            exactTemplate,
                            argumentsText: overText
                        )
                    ]
                ),
                "$.profileTemplates[0].argumentsText",
                64 * 1_024
            ),
        ]
        for (document, path, maximum) in cases {
            let expected = SettingsDocumentCodecIssue.stringTooLong(
                path: path,
                maximum: maximum
            )
            XCTAssertThrowsError(try codec.encode(document)) {
                XCTAssertEqual(
                    $0 as? SettingsDocumentCodecIssue,
                    expected
                )
            }
            XCTAssertEqual(
                issue(for: try rawEncode(document)),
                expected
            )
        }
    }

    func testCollectionLimitsAllow4096AndReject4097()
        throws
    {
        let templates = (0..<4_096).map {
            SettingsDocument.Template(
                id: uuid($0),
                name: "T\($0)",
                argumentsText: "",
                environmentText: "",
                notes: ""
            )
        }
        let visuals = (0..<4_096).map {
            SettingsDocument.VisualIdentity(
                profileID: uuid($0),
                symbol: "globe",
                color: "blue"
            )
        }
        let boundary = replacing(
            makeDocument(),
            templates: templates,
            visuals: visuals
        )

        let boundaryData = try codec.encode(boundary)
        guard case .current = codec.decode(boundaryData) else {
            return XCTFail("Collection boundaries must decode.")
        }

        let excessTemplates = replacing(
            boundary,
            templates: templates + [
                .init(
                    id: uuid(4_096),
                    name: "Overflow",
                    argumentsText: "",
                    environmentText: "",
                    notes: ""
                )
            ]
        )
        XCTAssertThrowsError(
            try codec.encode(excessTemplates)
        ) {
            XCTAssertEqual(
                $0 as? SettingsDocumentCodecIssue,
                .tooManyItems(
                    path: "$.profileTemplates",
                    maximum: 4_096
                )
            )
        }
        XCTAssertEqual(
            issue(for: try rawEncode(excessTemplates)),
            .tooManyItems(
                path: "$.profileTemplates",
                maximum: 4_096
            )
        )
        let excessVisuals = replacing(
            boundary,
            visuals: visuals + [
                .init(
                    profileID: uuid(4_096),
                    symbol: "globe",
                    color: "blue"
                )
            ]
        )
        XCTAssertThrowsError(
            try codec.encode(excessVisuals)
        ) {
            XCTAssertEqual(
                $0 as? SettingsDocumentCodecIssue,
                .tooManyItems(
                    path: "$.profileVisualIdentities",
                    maximum: 4_096
                )
            )
        }
        XCTAssertEqual(
            issue(for: try rawEncode(excessVisuals)),
            .tooManyItems(
                path: "$.profileVisualIdentities",
                maximum: 4_096
            )
        )
    }

    func testMalformedUTF8TrailingTopLevelDeepAndTokenHeavyInput() {
        XCTAssertEqual(
            issue(for: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])),
            .malformedJSON
        )
        XCTAssertEqual(
            issue(for: Data(#"{"schemaVersion":1}{}"#.utf8)),
            .malformedJSON
        )
        XCTAssertEqual(
            issue(for: Data(#"[{"schemaVersion":1}]"#.utf8)),
            .invalidTopLevel
        )
        let exactDepth = Data(
            (
                String(repeating: "[", count: 32)
                    + "0"
                    + String(repeating: "]", count: 32)
            ).utf8
        )
        XCTAssertEqual(issue(for: exactDepth), .invalidTopLevel)
        let deep = Data(
            (
                String(repeating: "[", count: 33)
                    + "0"
                    + String(repeating: "]", count: 33)
            ).utf8
        )
        XCTAssertEqual(
            issue(for: deep),
            .excessiveNesting(maximum: 32)
        )

        var exactTokenLimits = SettingsDocumentCodec.Limits()
        exactTokenLimits.maximumTokenCount = 3
        let exactTokenCodec = SettingsDocumentCodec(
            limits: exactTokenLimits
        )
        let future = Data(#"{"schemaVersion":2}"#.utf8)
        XCTAssertEqual(
            exactTokenCodec.decode(future),
            .future(schemaVersion: 2, originalBytes: future)
        )

        var lowTokenLimits = SettingsDocumentCodec.Limits()
        lowTokenLimits.maximumTokenCount = 2
        let lowTokenCodec = SettingsDocumentCodec(
            limits: lowTokenLimits
        )
        guard case let .invalid(failure) =
            lowTokenCodec.decode(future)
        else {
            return XCTFail("Expected token limit rejection.")
        }
        XCTAssertEqual(
            failure.issue,
            .tooManyTokens(maximum: 2)
        )

        var tokenHeavyLimits = SettingsDocumentCodec.Limits()
        tokenHeavyLimits.maximumTokenCount = 5
        let tokenHeavyCodec = SettingsDocumentCodec(
            limits: tokenHeavyLimits
        )
        guard case let .invalid(tokenHeavyFailure) =
            tokenHeavyCodec.decode(
                Data(#"{"a":[1,2,3,4,5,6]}"#.utf8)
            )
        else {
            return XCTFail("Expected token-heavy rejection.")
        }
        XCTAssertEqual(
            tokenHeavyFailure.issue,
            .tooManyTokens(maximum: 5)
        )
    }

    func testParserCapsFutureUnknownArraysObjectsKeysAndStrings() {
        let array = (0...4_096)
            .map(String.init)
            .joined(separator: ",")
        XCTAssertEqual(
            issue(
                for: Data(
                    #"{"schemaVersion":2,"items":[\#(array)]}"#
                        .utf8
                )
            ),
            .tooManyItems(path: "$.items", maximum: 4_096)
        )

        let members = (0..<256)
            .map { #""k\#($0)":0"# }
            .joined(separator: ",")
        XCTAssertEqual(
            issue(
                for: Data(
                    #"{"schemaVersion":2,\#(members)}"#.utf8
                )
            ),
            .tooManyItems(path: "$", maximum: 256)
        )

        let longKey = String(repeating: "k", count: 257)
        XCTAssertEqual(
            issue(
                for: Data(
                    #"{"schemaVersion":2,"\#(longKey)":0}"#.utf8
                )
            ),
            .stringTooLong(path: "$.<key>", maximum: 256)
        )

        let longString = String(
            repeating: "s",
            count: 64 * 1_024 + 1
        )
        XCTAssertEqual(
            issue(
                for: Data(
                    #"{"schemaVersion":2,"payload":"\#(longString)"}"#
                        .utf8
                )
            ),
            .stringTooLong(
                path: "$.payload",
                maximum: 64 * 1_024
            )
        )

        let longNumber = String(repeating: "1", count: 129)
        XCTAssertEqual(
            issue(
                for: Data(
                    #"{"schemaVersion":2,"payload":\#(longNumber)}"#
                        .utf8
                )
            ),
            .numericTokenTooLong(
                path: "$.payload",
                maximum: 128
            )
        )
    }

    func testParserRejectsCurrentOverflowBeforeParsingNextValue() {
        let first =
            #"{"id":"00000000-0000-4000-8000-000000000001","name":"A","argumentsText":"","environmentText":"","notes":""}"#
        let overflow = Data(
            #"{"schemaVersion":1,"revision":0,"profileTemplates":[\#(first),null]}"#
                .utf8
        )
        var limits = SettingsDocumentCodec.Limits()
        limits.maximumTemplates = 1
        let limited = SettingsDocumentCodec(limits: limits)

        guard case let .invalid(failure) =
            limited.decode(overflow)
        else {
            return XCTFail("Expected parser-level collection rejection.")
        }
        XCTAssertEqual(
            failure.issue,
            .tooManyItems(
                path: "$.profileTemplates",
                maximum: 1
            )
        )
        XCTAssertEqual(failure.originalBytes, overflow)
    }

    func testMissingNullMistypedAndUnknownKeysAreRejected() {
        let missing = Data(
            #"{"schemaVersion":1,"revision":0,"profileTemplates":[],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system"}"#
                .utf8
        )
        XCTAssertEqual(
            issue(for: missing),
            .missingKey(path: "$.profileVisualIdentities")
        )

        let null = replacingJSON(
            validJSON(),
            #""appearance":"system""#,
            with: #""appearance":null"#
        )
        XCTAssertEqual(
            issue(for: null),
            .invalidType(path: "$.appearance")
        )

        let mistyped = replacingJSON(
            validJSON(),
            #""confirmBeforeLaunch":true"#,
            with: #""confirmBeforeLaunch":"true""#
        )
        XCTAssertEqual(
            issue(for: mistyped),
            .invalidType(path: "$.confirmBeforeLaunch")
        )

        for data in [
            insertingJSON(
                validJSON(),
                before: #""revision""#,
                text: #""unknown":1,"#
            ),
            Data(
                #"{"schemaVersion":1,"revision":0,"profileTemplates":[{"id":"00000000-0000-4000-8000-000000000001","name":"A","argumentsText":"","environmentText":"","notes":"","unknown":true}],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[]}"#
                    .utf8
            ),
            Data(
                #"{"schemaVersion":1,"revision":0,"profileTemplates":[],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[{"profileID":"00000000-0000-4000-8000-000000000001","symbol":"globe","color":"blue","unknown":true}]}"#
                    .utf8
            ),
        ] {
            guard case .unknownKey = issue(for: data) else {
                return XCTFail("Expected unknown key rejection.")
            }
        }
    }

    func testDuplicateKeysAtEveryObjectLevelAreRejected() {
        let inputs = [
            Data(
                #"{"schemaVersion":1,"schemaVersion":1}"#.utf8
            ),
            Data(
                #"{"schemaVersion":1,"schema\u0056ersion":1}"#
                    .utf8
            ),
            Data(
                #"{"schemaVersion":1,"revision":0,"profileTemplates":[{"id":"00000000-0000-4000-8000-000000000001","id":"00000000-0000-4000-8000-000000000002","name":"A","argumentsText":"","environmentText":"","notes":""}],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[]}"#
                    .utf8
            ),
            Data(
                #"{"schemaVersion":1,"revision":0,"profileTemplates":[],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[{"profileID":"00000000-0000-4000-8000-000000000001","symbol":"globe","symbol":"leaf.fill","color":"blue"}]}"#
                    .utf8
            ),
            Data(
                #"{"schemaVersion":2,"future":{"nested":1,"nested":2}}"#
                    .utf8
            ),
        ]

        for input in inputs {
            guard case .duplicateKey = issue(for: input) else {
                return XCTFail("Expected duplicate key rejection.")
            }
        }
    }

    func testObjectKeyIdentityIsScalarExactForFutureDocuments() {
        let distinct = Data(
            #"{"schemaVersion":2,"é":1,"e\u0301":2}"#.utf8
        )
        XCTAssertEqual(
            codec.decode(distinct),
            .future(schemaVersion: 2, originalBytes: distinct)
        )

        let duplicate = Data(
            #"{"schemaVersion":2,"é":1,"\u00e9":2}"#.utf8
        )
        guard case .duplicateKey = issue(for: duplicate) else {
            return XCTFail(
                "Literal and escaped identical scalars must collide."
            )
        }
    }

    func testNumericShapeAndOverflowAreRejected() {
        for version in [
            "0", "-1", "1.0", "1e0",
            "18446744073709551616",
        ] {
            let data = Data(
                #"{"schemaVersion":\#(version)}"#.utf8
            )
            XCTAssertEqual(
                issue(for: data),
                .invalidValue(path: "$.schemaVersion")
            )
        }

        for revision in [
            "-1", "1.0", "1e0", "18446744073709551616",
        ] {
            let data = replacingJSON(
                validJSON(),
                #""revision":0"#,
                with: #""revision":\#(revision)"#
            )
            XCTAssertEqual(
                issue(for: data),
                .invalidValue(path: "$.revision")
            )
        }
    }

    func testInvalidUUIDDuplicatesAndUnknownRawValuesRejectDecode() {
        let invalidUUID = replacingJSON(
            validJSON(templateID: "not-a-uuid"),
            #""id":"not-a-uuid""#,
            with: #""id":"not-a-uuid""#
        )
        XCTAssertEqual(
            issue(for: invalidUUID),
            .invalidValue(path: "$.profileTemplates[0].id")
        )
        let invalidVisualUUID = replacingJSON(
            validJSON(includeVisual: true),
            #""profileID":"00000000-0000-4000-8000-000000000001""#,
            with: #""profileID":"not-a-uuid""#
        )
        XCTAssertEqual(
            issue(for: invalidVisualUUID),
            .invalidValue(
                path: "$.profileVisualIdentities[0].profileID"
            )
        )

        let duplicateTemplates = Data(
            #"{"schemaVersion":1,"revision":0,"profileTemplates":[{"id":"AAAAAAAA-0000-4000-8000-000000000001","name":"A","argumentsText":"","environmentText":"","notes":""},{"id":"aaaaaaaa-0000-4000-8000-000000000001","name":"B","argumentsText":"","environmentText":"","notes":""}],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[]}"#
                .utf8
        )
        guard case .duplicateTemplateID =
            issue(for: duplicateTemplates)
        else {
            return XCTFail("Expected duplicate template IDs.")
        }

        let duplicateVisuals = Data(
            #"{"schemaVersion":1,"revision":0,"profileTemplates":[],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":[{"profileID":"AAAAAAAA-0000-4000-8000-000000000001","symbol":"globe","color":"blue"},{"profileID":"aaaaaaaa-0000-4000-8000-000000000001","symbol":"leaf.fill","color":"green"}]}"#
                .utf8
        )
        guard case .duplicateVisualProfileID =
            issue(for: duplicateVisuals)
        else {
            return XCTFail("Expected duplicate visual IDs.")
        }

        for (needle, replacement, path) in [
            (
                #""appearance":"system""#,
                #""appearance":"neon""#,
                "$.appearance"
            ),
            (
                #""symbol":"globe""#,
                #""symbol":"unknown""#,
                "$.profileVisualIdentities[0].symbol"
            ),
            (
                #""color":"blue""#,
                #""color":"ultraviolet""#,
                "$.profileVisualIdentities[0].color"
            ),
        ] {
            XCTAssertEqual(
                issue(
                    for: replacingJSON(
                        validJSON(includeVisual: true),
                        needle,
                        with: replacement
                    )
                ),
                .invalidValue(path: path)
            )
        }
    }

    func testEncodeRejectsInvalidCandidates() {
        let base = makeDocument()
        let invalid: [SettingsDocument] = [
            SettingsDocument(
                schemaVersion: 0,
                revision: .zero,
                profileTemplates: [],
                defaultBaseStoragePath: "",
                confirmBeforeLaunch: true,
                automaticallyRecoverCrashedApps: true,
                appearance: "system",
                profileVisualIdentities: []
            ),
            replacing(base, appearance: "neon"),
            replacing(
                base,
                templates: [
                    .init(
                        id: "invalid",
                        name: "A",
                        argumentsText: "",
                        environmentText: "",
                        notes: ""
                    )
                ]
            ),
            replacing(
                base,
                visuals: [
                    .init(
                        profileID: uuid(1),
                        symbol: "unknown",
                        color: "blue"
                    )
                ]
            ),
            replacing(
                base,
                templates: [
                    .init(
                        id: uuid(1),
                        name: "A",
                        argumentsText: "",
                        environmentText: "",
                        notes: ""
                    ),
                    .init(
                        id: uuid(1).uppercased(),
                        name: "B",
                        argumentsText: "",
                        environmentText: "",
                        notes: ""
                    ),
                ]
            ),
            replacing(
                base,
                visuals: [
                    .init(
                        profileID: uuid(1),
                        symbol: "globe",
                        color: "blue"
                    ),
                    .init(
                        profileID: uuid(1).uppercased(),
                        symbol: "leaf.fill",
                        color: "green"
                    ),
                ]
            ),
        ]

        for document in invalid {
            XCTAssertThrowsError(try codec.encode(document))
        }
    }

    func testEncodePreflightsAggregateContentBeforeJSONAllocation() {
        let text = String(repeating: "x", count: 64 * 1_024)
        let templates = (0..<65).map {
            SettingsDocument.Template(
                id: uuid($0),
                name: "T\($0)",
                argumentsText: text,
                environmentText: "",
                notes: ""
            )
        }
        let document = replacing(
            makeDocument(),
            templates: templates,
            visuals: []
        )

        XCTAssertThrowsError(try codec.encode(document)) {
            guard case let .encodedOutputTooLarge(actual, maximum) =
                $0 as? SettingsDocumentCodecIssue
            else {
                return XCTFail("Expected aggregate size rejection.")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 4 * 1_024 * 1_024)
        }
    }

    func testUnicodeScalarsEscapesEmojiAndMultilineRoundTrip()
        throws
    {
        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"
        let document = replacing(
            makeDocument(),
            templates: [
                .init(
                    id: uuid(10),
                    name: "NFC \(nfc) 🧪",
                    argumentsText:
                        "quote \" slash / backslash \\\nline\u{2028}two",
                    environmentText: "EMOJI=🧪",
                    notes: "NFD \(nfd)"
                ),
                .init(
                    id: uuid(11),
                    name: "NFD \(nfd)",
                    argumentsText: "",
                    environmentText: "",
                    notes: ""
                ),
            ]
        )

        let encoded = try codec.encode(document)
        guard case let .current(decoded) = codec.decode(encoded) else {
            return XCTFail("Expected a current settings document.")
        }

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(
            Array(decoded.defaultBaseStoragePath.unicodeScalars),
            Array(document.defaultBaseStoragePath.unicodeScalars)
        )
        XCTAssertEqual(
            Array(decoded.appearance.unicodeScalars),
            Array(document.appearance.unicodeScalars)
        )
        for index in document.profileTemplates.indices {
            let source = document.profileTemplates[index]
            let result = decoded.profileTemplates[index]
            XCTAssertEqual(
                Array(result.id.unicodeScalars),
                Array(source.id.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.name.unicodeScalars),
                Array(source.name.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.argumentsText.unicodeScalars),
                Array(source.argumentsText.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.environmentText.unicodeScalars),
                Array(source.environmentText.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.notes.unicodeScalars),
                Array(source.notes.unicodeScalars)
            )
        }
        for index in document.profileVisualIdentities.indices {
            let source = document.profileVisualIdentities[index]
            let result = decoded.profileVisualIdentities[index]
            XCTAssertEqual(
                Array(result.profileID.unicodeScalars),
                Array(source.profileID.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.symbol.unicodeScalars),
                Array(source.symbol.unicodeScalars)
            )
            XCTAssertEqual(
                Array(result.color.unicodeScalars),
                Array(source.color.unicodeScalars)
            )
        }
        let json = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )
        XCTAssertTrue(json.contains(#"\""#))
        XCTAssertTrue(json.contains(#"\\"#))
        XCTAssertTrue(json.contains(#"\n"#))
        XCTAssertTrue(json.contains("slash /"))
    }

    func testMaximumValidDocumentCompletesWithinBudget()
        throws
    {
        let templates = (0..<4_096).map {
            SettingsDocument.Template(
                id: uuid($0),
                name: "Template \($0)",
                argumentsText: "",
                environmentText: "",
                notes: ""
            )
        }
        let visuals = (0..<4_096).map {
            SettingsDocument.VisualIdentity(
                profileID: uuid($0),
                symbol: "globe",
                color: "blue"
            )
        }
        let document = replacing(
            makeDocument(),
            templates: templates,
            visuals: visuals
        )

        let start = ContinuousClock.now
        let data = try codec.encode(document)
        guard case .current = codec.decode(data) else {
            return XCTFail("Maximum valid document must decode.")
        }
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(data.count, 4 * 1_024 * 1_024)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    private func makeDocument(
        appearance: String = "system"
    ) -> SettingsDocument {
        SettingsDocument(
            revision: SettingsRevision(rawValue: .max),
            profileTemplates: [
                .init(
                    id: uuid(1),
                    name: "Café 🧪",
                    argumentsText: "--first\n--second",
                    environmentText: "A=1\nB=two",
                    notes: "NFC"
                ),
                .init(
                    id: uuid(2),
                    name: "Cafe\u{301}",
                    argumentsText: #""quoted value""#,
                    environmentText: #"PATH=C:\bin"#,
                    notes: "NFD"
                ),
            ],
            defaultBaseStoragePath: "/Managed/Parallax Data",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: appearance,
            profileVisualIdentities: [
                .init(
                    profileID: uuid(1),
                    symbol: "terminal.fill",
                    color: "green"
                ),
                .init(
                    profileID: uuid(2),
                    symbol: "globe",
                    color: "blue"
                ),
            ]
        )
    }

    private func replacing(
        _ source: SettingsDocument,
        revision: SettingsRevision? = nil,
        templates: [SettingsDocument.Template]? = nil,
        basePath: String? = nil,
        appearance: String? = nil,
        visuals: [SettingsDocument.VisualIdentity]? = nil
    ) -> SettingsDocument {
        SettingsDocument(
            schemaVersion: source.schemaVersion,
            revision: revision ?? source.revision,
            profileTemplates: templates ?? source.profileTemplates,
            defaultBaseStoragePath:
                basePath ?? source.defaultBaseStoragePath,
            confirmBeforeLaunch: source.confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                source.automaticallyRecoverCrashedApps,
            appearance: appearance ?? source.appearance,
            profileVisualIdentities:
                visuals ?? source.profileVisualIdentities
        )
    }

    private func template(
        _ source: SettingsDocument.Template,
        name: String? = nil,
        argumentsText: String? = nil,
        environmentText: String? = nil,
        notes: String? = nil
    ) -> SettingsDocument.Template {
        SettingsDocument.Template(
            id: source.id,
            name: name ?? source.name,
            argumentsText: argumentsText ?? source.argumentsText,
            environmentText:
                environmentText ?? source.environmentText,
            notes: notes ?? source.notes
        )
    }

    private func validJSON(
        templateID: String =
            "00000000-0000-4000-8000-000000000001",
        includeVisual: Bool = false
    ) -> Data {
        let visual = includeVisual
            ? #"[{"profileID":"00000000-0000-4000-8000-000000000001","symbol":"globe","color":"blue"}]"#
            : "[]"
        return Data(
            #"{"schemaVersion":1,"revision":0,"profileTemplates":[{"id":"\#(templateID)","name":"A","argumentsText":"","environmentText":"","notes":""}],"defaultBaseStoragePath":"","confirmBeforeLaunch":true,"automaticallyRecoverCrashedApps":true,"appearance":"system","profileVisualIdentities":\#(visual)}"#
                .utf8
        )
    }

    private func issue(
        for data: Data
    ) -> SettingsDocumentCodecIssue {
        guard case let .invalid(failure) = codec.decode(data) else {
            XCTFail("Expected invalid settings data.")
            return .malformedJSON
        }
        return failure.issue
    }

    private func replacingJSON(
        _ data: Data,
        _ needle: String,
        with replacement: String
    ) -> Data {
        let source = String(decoding: data, as: UTF8.self)
        return Data(
            source.replacingOccurrences(
                of: needle,
                with: replacement
            ).utf8
        )
    }

    private func rawEncode(
        _ document: SettingsDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(document)
    }

    private func insertingJSON(
        _ data: Data,
        before needle: String,
        text: String
    ) -> Data {
        replacingJSON(data, needle, with: text + needle)
    }

    private func uuid(_ index: Int) -> String {
        String(
            format:
                "00000000-0000-4000-8000-%012llx",
            Int64(index + 1)
        )
    }
}
