import Foundation
@testable import Parallax
import XCTest

final class SettingsLegacySnapshotDecoderTests: XCTestCase {
    private let id = UUID(
        uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF"
    )!

    func testGoldenLiteralsDecodeWithoutNormalizingLegacyValues() {
        let templates = data(
            """
            [
              {
                "id":"00112233-4455-4677-8899-aabbccddeeff",
                "name":"",
                "argumentsText":"  --flag  ",
                "environmentText":"CAFE=é",
                "notes":" café "
              },
              {
                "id":"00112233-4455-4677-8899-AABBCCDDEEFF",
                "name":"",
                "argumentsText":"",
                "environmentText":"",
                "notes":""
              }
            ]
            """
        )
        let visuals = data(
            """
            {
              "z-Key":{"symbol":"app.dashed","color":"gray"},
              "A-key":{"symbol":"briefcase.fill","color":"blue"}
            }
            """
        )

        let result = decode(templates: .retained(templates), visuals: .retained(visuals))

        XCTAssertEqual(
            result.profileTemplates,
            .decoded([
                .init(
                    id: id,
                    name: "",
                    argumentsText: "  --flag  ",
                    environmentText: "CAFE=e\u{301}",
                    notes: " café ",
                    materializedIgnoredMemberCount: 0
                ),
                .init(
                    id: id,
                    name: "",
                    argumentsText: "",
                    environmentText: "",
                    notes: "",
                    materializedIgnoredMemberCount: 0
                ),
            ])
        )
        XCTAssertEqual(
            result.profileVisualIdentities,
            .decoded([
                .init(
                    key: "A-key",
                    symbol: .briefcase,
                    color: .blue,
                    materializedIgnoredMemberCount: 0
                ),
                .init(
                    key: "z-Key",
                    symbol: .unmanaged,
                    color: .gray,
                    materializedIgnoredMemberCount: 0
                ),
            ])
        )
    }

    func testCurrentJSONEncoderOutputForBothHistoricalShapesDecodes() throws {
        let templates = [
            ProfileTemplate(
                id: id,
                name: "Current",
                argumentsText: "--one",
                environmentText: "A=B",
                notes: "note"
            ),
        ]
        let visuals = [
            "not-a-uuid": ProfileInstanceVisualIdentity(
                symbol: .music,
                color: .cyan
            ),
        ]
        let encoder = JSONEncoder()

        let result = decode(
            templates: .retained(try encoder.encode(templates)),
            visuals: .retained(try encoder.encode(visuals))
        )

        XCTAssertEqual(
            result.profileTemplates,
            .decoded([
                .init(
                    id: id,
                    name: "Current",
                    argumentsText: "--one",
                    environmentText: "A=B",
                    notes: "note",
                    materializedIgnoredMemberCount: 0
                ),
            ])
        )
        XCTAssertEqual(
            result.profileVisualIdentities,
            .decoded([
                .init(
                    key: "not-a-uuid",
                    symbol: .music,
                    color: .cyan,
                    materializedIgnoredMemberCount: 0
                ),
            ])
        )
    }

    func testFrozenVisualVocabularyAcceptsEveryHistoricalRawValue() {
        let symbols: [SettingsLegacyVisualSymbol] = [
            .briefcase, .person, .flask, .terminal, .book, .palette,
            .globe, .lightbulb, .hammer, .camera, .music, .leaf,
            .unmanaged,
        ]
        let colors: [SettingsLegacyVisualColor] = [
            .blue, .purple, .orange, .pink, .teal, .green, .indigo,
            .cyan, .brown, .gray,
        ]
        var members: [String] = []
        var expected: [SettingsLegacyVisualIdentityWireRecord] = []
        for (index, symbol) in symbols.enumerated() {
            let color = colors[index % colors.count]
            let key = String(format: "key-%02d", index)
            members.append(
                "\"\(key)\":{\"symbol\":\"\(symbol.rawValue)\","
                    + "\"color\":\"\(color.rawValue)\"}"
            )
            expected.append(
                .init(
                    key: key,
                    symbol: symbol,
                    color: color,
                    materializedIgnoredMemberCount: 0
                )
            )
        }

        XCTAssertEqual(
            decode(visuals: .retained(data("{\(members.joined(separator: ","))}")))
                .profileVisualIdentities,
            .decoded(expected)
        )
    }

    func testEmptyFormsCoexistenceAndExactSourceAttachment() {
        let templates = data("[]")
        let visuals = data("{}")
        let source = snapshot(
            templates: .retained(templates),
            names: .retained(["legacy", "legacy"]),
            path: .retained("  /tmp/../raw  "),
            confirm: .retained(false),
            automatic: .retained(true),
            appearance: .retained("future"),
            visuals: .retained(visuals),
            completion: .partial([.unexpectedKeyCount(3)])
        )

        let result = SettingsLegacySnapshotDecoder(source: source).decode()

        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.profileTemplates, .decoded([]))
        XCTAssertEqual(result.profileVisualIdentities, .decoded([]))
        XCTAssertEqual(
            Mirror(reflecting: result).children.map(\.label),
            ["source", "profileTemplates", "profileVisualIdentities"]
        )
    }

    func testEveryNonRetainedStatePassesThroughIndependently() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 17)
        let violations = [
            SettingsLegacyLimitViolation.byteCount(actual: 9, maximum: 8),
        ]
        let cases: [
            (
                SettingsLegacyField<Data>,
                SettingsLegacyDecodedField<
                    [SettingsLegacyTemplateWireRecord]
                >
            )
        ] = [
            (.unavailable(failure), .unavailable(failure)),
            (.absent, .absent),
            (.wrongType(.date), .wrongType(.date)),
            (.oversized(violations), .oversized(violations)),
        ]
        for (field, expected) in cases {
            let result = decode(
                templates: field,
                visuals: .retained(data("{}")),
                completion: .partial([.source(failure)])
            )
            XCTAssertEqual(result.profileTemplates, expected)
            XCTAssertEqual(result.profileVisualIdentities, .decoded([]))
            XCTAssertEqual(
                result.source.completion,
                .partial([.source(failure)])
            )
        }

        let visualCases: [
            (
                SettingsLegacyField<Data>,
                SettingsLegacyDecodedField<
                    [SettingsLegacyVisualIdentityWireRecord]
                >
            )
        ] = [
            (.unavailable(failure), .unavailable(failure)),
            (.absent, .absent),
            (.wrongType(.array), .wrongType(.array)),
            (.oversized(violations), .oversized(violations)),
        ]
        for (field, expected) in visualCases {
            let result = decode(
                templates: .retained(data("[]")),
                visuals: field
            )
            XCTAssertEqual(result.profileTemplates, .decoded([]))
            XCTAssertEqual(result.profileVisualIdentities, expected)
        }
    }

    func testUnknownMembersAreIgnoredWithQualifiedMaterializedCounts() {
        let templates = data(
            """
            [{
              "id":"00112233-4455-4677-8899-AABBCCDDEEFF",
              "name":"n",
              "argumentsText":"",
              "environmentText":"",
              "notes":"",
              "unknown":42,
              "nested":{"anything":[1,2,3]}
            }]
            """
        )
        let visuals = data(
            """
            {"raw":{"symbol":"globe","color":"teal","future":true}}
            """
        )

        let result = decode(
            templates: .retained(templates),
            visuals: .retained(visuals)
        )

        guard case .decoded(let decodedTemplates) = result.profileTemplates,
              case .decoded(let decodedVisuals) =
                result.profileVisualIdentities
        else {
            return XCTFail("Expected both retained fields to decode.")
        }
        XCTAssertEqual(
            decodedTemplates.first?.materializedIgnoredMemberCount,
            2
        )
        XCTAssertEqual(
            decodedVisuals.first?.materializedIgnoredMemberCount,
            1
        )
    }

    func testVisualKeysRemainRawCaseDistinctAndSortByUTF8Bytes() {
        let input = data(
            """
            {
              "é":{"symbol":"leaf.fill","color":"green"},
              "a":{"symbol":"camera.fill","color":"pink"},
              "A":{"symbol":"hammer.fill","color":"brown"},
              "not-a-UUID":{"symbol":"flask.fill","color":"orange"},
              "NOT-A-UUID":{"symbol":"terminal.fill","color":"indigo"}
            }
            """
        )
        let expectedKeys = ["A", "NOT-A-UUID", "a", "not-a-UUID", "é"]

        guard case .decoded(let records) =
                decode(visuals: .retained(input)).profileVisualIdentities
        else {
            return XCTFail("Expected visual identities to decode.")
        }
        XCTAssertEqual(records.map(\.key), expectedKeys)
    }

    func testCanonicalEquivalentVisualRootKeysFailAsIdentityAmbiguity() {
        let input = data(
            """
            {
              "é":{"symbol":"globe","color":"blue"},
              "é":{"symbol":"app.dashed","color":"gray"}
            }
            """
        )

        XCTAssertEqual(
            decode(visuals: .retained(input)).profileVisualIdentities,
            .invalid(
                .visualKeyIdentityAmbiguity(
                    sourceCount: 2,
                    materializedCount: 1
                )
            )
        )
    }

    func testTemplateRequiredFieldsReportMissingNullWrongAndInvalidUUID() {
        let fields: [(String, SettingsLegacyWireField)] = [
            ("id", .id),
            ("name", .name),
            ("argumentsText", .argumentsText),
            ("environmentText", .environmentText),
            ("notes", .notes),
        ]
        for (name, field) in fields {
            let missing = templateObject(omitting: name)
            assertTemplateShape(
                missing,
                field: field,
                problem: .missing
            )
            let null = templateObject(replacing: name, with: "null")
            assertTemplateShape(null, field: field, problem: .null)
            let wrong = templateObject(replacing: name, with: "42")
            assertTemplateShape(wrong, field: field, problem: .wrongType)
        }
        assertTemplateShape(
            templateObject(replacing: "id", with: "\"not-a-uuid\""),
            field: .id,
            problem: .invalidValue
        )
    }

    func testVisualRequiredFieldsReportMissingNullWrongAndUnknownEnum() {
        for (name, field) in [
            ("symbol", SettingsLegacyWireField.symbol),
            ("color", SettingsLegacyWireField.color),
        ] {
            assertVisualShape(
                visualObject(omitting: name),
                field: field,
                problem: .missing
            )
            assertVisualShape(
                visualObject(replacing: name, with: "null"),
                field: field,
                problem: .null
            )
            assertVisualShape(
                visualObject(replacing: name, with: "false"),
                field: field,
                problem: .wrongType
            )
            assertVisualShape(
                visualObject(replacing: name, with: "\"future\""),
                field: field,
                problem: .invalidValue
            )
        }
    }

    func testWrongItemsAndRootsHaveTypedShapeOrPreflightFailures() {
        assertTemplateShape(
            "null",
            location: .template(index: 0),
            field: .templateItem,
            problem: .null
        )
        assertTemplateShape(
            "7",
            location: .template(index: 0),
            field: .templateItem,
            problem: .wrongType
        )
        assertVisualShape(
            "null",
            field: .visualValue,
            problem: .null
        )
        assertVisualShape(
            "[]",
            field: .visualValue,
            problem: .wrongType
        )
        XCTAssertEqual(
            decode(templates: .retained(data("{}"))).profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .invalidRoot(required: .array, actual: .object)
                )
            )
        )
        XCTAssertEqual(
            decode(visuals: .retained(data("[]")))
                .profileVisualIdentities,
            .invalid(
                .preflight(
                    payload: .profileVisualIdentities,
                    issue: .invalidRoot(required: .object, actual: .array)
                )
            )
        )
    }

    func testMalformedTrailingInvalidUTF8AndDuplicateKeysFailPreflight() {
        let invalidInputs = [
            Data("{".utf8),
            Data("[] trailing".utf8),
            Data([0x5B, 0x22, 0xFF, 0x22, 0x5D]),
        ]
        for input in invalidInputs {
            assertPreflightFailure(
                decode(templates: .retained(input)).profileTemplates
            )
        }
        let duplicateInputs = [
            """
            [{"id":"00112233-4455-4677-8899-AABBCCDDEEFF",
            "id":"00112233-4455-4677-8899-AABBCCDDEEFF",
            "name":"","argumentsText":"","environmentText":"","notes":""}]
            """,
            """
            {"key":{"symbol":"globe","symbol":"leaf.fill","color":"blue"}}
            """,
            """
            {"key":{"symbol":"globe","color":"blue"},
             "key":{"symbol":"leaf.fill","color":"green"}}
            """,
        ]
        assertPreflightFailure(
            decode(templates: .retained(data(duplicateInputs[0])))
                .profileTemplates
        )
        for source in duplicateInputs.dropFirst() {
            assertPreflightFailure(
                decode(visuals: .retained(data(source)))
                    .profileVisualIdentities
            )
        }
    }

    func testFieldFailuresAreLocalAndFixedValidationOrderWins() {
        let templates = data(
            """
            [{"id":"bad","name":7}]
            """
        )
        let visuals = data(
            """
            {"key":{"symbol":"future"}}
            """
        )

        let result = decode(
            templates: .retained(templates),
            visuals: .retained(visuals)
        )

        XCTAssertEqual(
            result.profileTemplates,
            .invalid(
                .shape(
                    payload: .profileTemplates,
                    location: .template(index: 0),
                    field: .id,
                    problem: .invalidValue
                )
            )
        )
        XCTAssertEqual(
            result.profileVisualIdentities,
            .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "key"),
                    field: .symbol,
                    problem: .invalidValue
                )
            )
        )

        let sibling = decode(
            templates: .retained(data("[null]")),
            visuals: .retained(data("{}"))
        )
        XCTAssertEqual(sibling.profileVisualIdentities, .decoded([]))
    }

    func testPostMaterializationStringBoundsAreExactAndPlusOne() {
        let name = String(repeating: "n", count: 256)
        let text = String(repeating: "t", count: 65_536)
        let valid = """
        [{"id":"00112233-4455-4677-8899-AABBCCDDEEFF",
        "name":"\(name)","argumentsText":"\(text)",
        "environmentText":"","notes":""}]
        """
        XCTAssertNotInvalid(
            decode(templates: .retained(data(valid))).profileTemplates
        )

        let oversizedName = templateObject(
            replacing: "name",
            with: "\"\(name)n\""
        )
        XCTAssertEqual(
            decode(templates: .retained(data("[\(oversizedName)]")))
                .profileTemplates,
            .invalid(
                .resource(
                    payload: .profileTemplates,
                    location: .template(index: 0),
                    resource: .nameUTF8Bytes,
                    actual: 257,
                    maximum: 256
                )
            )
        )
        let oversizedText = templateObject(
            replacing: "notes",
            with: "\"\(text)t\""
        )
        XCTAssertEqual(
            decode(templates: .retained(data("[\(oversizedText)]")))
                .profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .stringTooLong(path: "$[0].notes", maximum: 65_536)
                )
            )
        )
    }

    func testItemAndInputBoundsAreExactAndPlusOne() {
        let item = templateObject()
        let exact = "[" + Array(
            repeating: item,
            count: SettingsLegacySnapshotDecoder.maximumItems
        ).joined(separator: ",") + "]"
        guard case .decoded(let values) =
                decode(templates: .retained(data(exact))).profileTemplates
        else {
            return XCTFail("Expected maximum item count to decode.")
        }
        XCTAssertEqual(values.count, 4_096)

        let plusOne = "[" + Array(
            repeating: item,
            count: SettingsLegacySnapshotDecoder.maximumItems + 1
        ).joined(separator: ",") + "]"
        XCTAssertEqual(
            decode(templates: .retained(data(plusOne))).profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .tooManyItems(path: "$", maximum: 4_096)
                )
            )
        )

        let exactBytes = Data(
            ("[" + String(
                repeating: " ",
                count: SettingsLegacySnapshotDecoder.maximumInputBytes - 2
            ) + "]").utf8
        )
        XCTAssertEqual(
            decode(templates: .retained(exactBytes)).profileTemplates,
            .decoded([])
        )
        let plusOneBytes = exactBytes + Data(" ".utf8)
        XCTAssertEqual(
            decode(templates: .retained(plusOneBytes)).profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .inputTooLarge(
                        actual:
                            SettingsLegacySnapshotDecoder.maximumInputBytes
                                + 1,
                        maximum:
                            SettingsLegacySnapshotDecoder.maximumInputBytes
                    )
                )
            )
        )
    }

    func testKeySymbolAndColorBoundsAndEnumPrecedence() {
        let exactKey = String(repeating: "k", count: 256)
        XCTAssertNotInvalid(
            decode(
                visuals: .retained(
                    data(
                        "{\"" + exactKey
                            + "\":{\"symbol\":\"globe\","
                            + "\"color\":\"gray\"}}"
                    )
                )
            ).profileVisualIdentities
        )
        let longKey = String(repeating: "k", count: 257)
        XCTAssertEqual(
            decode(
                visuals: .retained(
                    data(
                        "{\"" + longKey
                            + "\":{\"symbol\":\"globe\","
                            + "\"color\":\"gray\"}}"
                    )
                )
            ).profileVisualIdentities,
            .invalid(
                .preflight(
                    payload: .profileVisualIdentities,
                    issue: .stringTooLong(path: "$.<key>", maximum: 256)
                )
            )
        )

        let exactSymbol = String(repeating: "s", count: 64)
        XCTAssertEqual(
            decode(
                visuals: .retained(
                    data(
                        "{\"k\":{\"symbol\":\"\(exactSymbol)\","
                            + "\"color\":\"blue\"}}"
                    )
                )
            ).profileVisualIdentities,
            .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "k"),
                    field: .symbol,
                    problem: .invalidValue
                )
            )
        )
        let longSymbol = exactSymbol + "s"
        XCTAssertEqual(
            decode(
                visuals: .retained(
                    data(
                        "{\"k\":{\"symbol\":\"\(longSymbol)\","
                            + "\"color\":\"future\"}}"
                    )
                )
            ).profileVisualIdentities,
            .invalid(
                .resource(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "k"),
                    resource: .symbolUTF8Bytes,
                    actual: 65,
                    maximum: 64
                )
            )
        )
        let exactColor = String(repeating: "c", count: 16)
        XCTAssertEqual(
            decode(
                visuals: .retained(
                    data(
                        "{\"k\":{\"symbol\":\"globe\","
                            + "\"color\":\"\(exactColor)\"}}"
                    )
                )
            ).profileVisualIdentities,
            .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "k"),
                    field: .color,
                    problem: .invalidValue
                )
            )
        )
        let longColor = exactColor + "c"
        XCTAssertEqual(
            decode(
                visuals: .retained(
                    data(
                        "{\"k\":{\"symbol\":\"globe\","
                            + "\"color\":\"\(longColor)\"}}"
                    )
                )
            ).profileVisualIdentities,
            .invalid(
                .resource(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "k"),
                    resource: .colorUTF8Bytes,
                    actual: 17,
                    maximum: 16
                )
            )
        )
    }

    func testSourceBytesArePreservedOnSuccessAndFailure() {
        let templateBytes = data(" [ ] \n")
        let visualBytes = data("{\"key\":{\"symbol\":\"future\"}}")
        let source = snapshot(
            templates: .retained(templateBytes),
            visuals: .retained(visualBytes)
        )

        let result = SettingsLegacySnapshotDecoder(source: source).decode()

        XCTAssertEqual(result.source.profileTemplates, .retained(templateBytes))
        XCTAssertEqual(
            result.source.profileVisualIdentities,
            .retained(visualBytes)
        )
        XCTAssertEqual(result.profileTemplates, .decoded([]))
        XCTAssertNotEqual(result.profileVisualIdentities, .decoded([]))
    }

    func testCanonicalEquivalentUnknownNestedNamesHaveQualifiedCounts() {
        let templates = data(
            """
            [{
              "id":"00112233-4455-4677-8899-AABBCCDDEEFF",
              "name":"","argumentsText":"","environmentText":"","notes":"",
              "é":1,"é":2
            }]
            """
        )
        let visuals = data(
            """
            {"key":{"symbol":"globe","color":"blue","é":1,"é":2}}
            """
        )

        let result = decode(
            templates: .retained(templates),
            visuals: .retained(visuals)
        )

        guard case .decoded(let decodedTemplates) = result.profileTemplates,
              case .decoded(let decodedVisuals) =
                result.profileVisualIdentities
        else {
            return XCTFail("Expected compatibility-ignored members.")
        }
        XCTAssertEqual(
            decodedTemplates[0].materializedIgnoredMemberCount,
            1,
            "This is Foundation's materialized count, not a source count."
        )
        XCTAssertEqual(
            decodedVisuals[0].materializedIgnoredMemberCount,
            1,
            "This is Foundation's materialized count, not a source count."
        )
    }

    func testDepthBoundIsExactAndPlusOne() {
        func payload(nestedArrayCount: Int) -> Data {
            let nested = String(repeating: "[", count: nestedArrayCount)
                + "0"
                + String(repeating: "]", count: nestedArrayCount)
            return data(
                "[\(templateObject().dropLast()),\"future\":\(nested)}]"
            )
        }

        XCTAssertNotInvalid(
            decode(
                templates: .retained(payload(nestedArrayCount: 30))
            ).profileTemplates
        )
        XCTAssertEqual(
            decode(
                templates: .retained(payload(nestedArrayCount: 31))
            ).profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .excessiveNesting(maximum: 32)
                )
            )
        )
    }

    func testTokenBoundIsExactAndPlusOne() {
        func payload(extraToken: Bool) -> Data {
            var arrays: [String] = []
            arrays.reserveCapacity(4_096)
            for index in 0..<4_096 {
                let count = index < 3_378 ? 48 : 47
                let adjusted = count + (extraToken && index == 0 ? 1 : 0)
                arrays.append(
                    "[" + Array(repeating: "0", count: adjusted)
                        .joined(separator: ",") + "]"
                )
            }
            return data(
                "[\(templateObject().dropLast()),\"future\":["
                    + arrays.joined(separator: ",") + "]}]"
            )
        }

        XCTAssertNotInvalid(
            decode(
                templates: .retained(payload(extraToken: false))
            ).profileTemplates
        )
        XCTAssertEqual(
            decode(
                templates: .retained(payload(extraToken: true))
            ).profileTemplates,
            .invalid(
                .preflight(
                    payload: .profileTemplates,
                    issue: .tooManyTokens(maximum: 200_000)
                )
            )
        )
    }

    func testCheckedSendabilityAndConcurrentReplayAreDeterministic() async {
        assertSendable(SettingsLegacySnapshotDecoder.self)
        assertSendable(SettingsLegacyDecodedSnapshot.self)
        let decoder = SettingsLegacySnapshotDecoder(
            source: snapshot(
                templates: .retained(data("[]")),
                visuals: .retained(
                    data(
                        """
                        {"b":{"symbol":"globe","color":"blue"},
                         "a":{"symbol":"leaf.fill","color":"green"}}
                        """
                    )
                )
            )
        )
        let expected = decoder.decode()

        let results = await withTaskGroup(
            of: SettingsLegacyDecodedSnapshot.self,
            returning: [SettingsLegacyDecodedSnapshot].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    decoder.decode()
                }
            }
            var values: [SettingsLegacyDecodedSnapshot] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    func testMaximumValidAndFourMiBInputsHaveBoundedPerformance() {
        let item = templateObject()
        let maximumValid = "[" + Array(
            repeating: item,
            count: SettingsLegacySnapshotDecoder.maximumItems
        ).joined(separator: ",") + "]"
        let fourMiB = Data(
            ("[" + String(
                repeating: " ",
                count: SettingsLegacySnapshotDecoder.maximumInputBytes - 2
            ) + "]").utf8
        )

        measure {
            _ = decode(
                templates: .retained(data(maximumValid)),
                visuals: .retained(fourMiB)
            )
        }
    }

    private func decode(
        templates: SettingsLegacyField<Data> = .absent,
        visuals: SettingsLegacyField<Data> = .absent,
        completion: SettingsLegacySnapshotCompletion = .complete
    ) -> SettingsLegacyDecodedSnapshot {
        SettingsLegacySnapshotDecoder(
            source: snapshot(
                templates: templates,
                visuals: visuals,
                completion: completion
            )
        ).decode()
    }

    private func snapshot(
        templates: SettingsLegacyField<Data> = .absent,
        names: SettingsLegacyField<[String]> = .absent,
        path: SettingsLegacyField<String> = .absent,
        confirm: SettingsLegacyField<Bool> = .absent,
        automatic: SettingsLegacyField<Bool> = .absent,
        appearance: SettingsLegacyField<String> = .absent,
        visuals: SettingsLegacyField<Data> = .absent,
        completion: SettingsLegacySnapshotCompletion = .complete
    ) -> SettingsLegacySnapshot {
        .init(
            profileTemplates: templates,
            legacyProfileTemplateNames: names,
            defaultBaseStoragePath: path,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: automatic,
            appearance: appearance,
            profileVisualIdentities: visuals,
            completion: completion
        )
    }

    private func data(_ source: String) -> Data {
        Data(source.utf8)
    }

    private func templateObject(
        omitting omitted: String? = nil,
        replacing replacement: String? = nil,
        with rawValue: String = ""
    ) -> String {
        let fields = [
            ("id", "\"00112233-4455-4677-8899-AABBCCDDEEFF\""),
            ("name", "\"name\""),
            ("argumentsText", "\"arguments\""),
            ("environmentText", "\"environment\""),
            ("notes", "\"notes\""),
        ]
        return "{" + fields.compactMap { name, value in
            guard name != omitted else {
                return nil
            }
            return "\"\(name)\":"
                + (name == replacement ? rawValue : value)
        }.joined(separator: ",") + "}"
    }

    private func visualObject(
        omitting omitted: String? = nil,
        replacing replacement: String? = nil,
        with rawValue: String = ""
    ) -> String {
        let fields = [
            ("symbol", "\"globe\""),
            ("color", "\"blue\""),
        ]
        return "{" + fields.compactMap { name, value in
            guard name != omitted else {
                return nil
            }
            return "\"\(name)\":"
                + (name == replacement ? rawValue : value)
        }.joined(separator: ",") + "}"
    }

    private func assertTemplateShape(
        _ source: String,
        location: SettingsLegacyWireLocation = .template(index: 0),
        field: SettingsLegacyWireField,
        problem: SettingsLegacyWireValueProblem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = "[\(source)]"
        XCTAssertEqual(
            decode(templates: .retained(data(payload))).profileTemplates,
            .invalid(
                .shape(
                    payload: .profileTemplates,
                    location: location,
                    field: field,
                    problem: problem
                )
            ),
            file: file,
            line: line
        )
    }

    private func assertVisualShape(
        _ source: String,
        field: SettingsLegacyWireField,
        problem: SettingsLegacyWireValueProblem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            decode(
                visuals: .retained(data("{\"key\":\(source)}"))
            ).profileVisualIdentities,
            .invalid(
                .shape(
                    payload: .profileVisualIdentities,
                    location: .visual(key: "key"),
                    field: field,
                    problem: problem
                )
            ),
            file: file,
            line: line
        )
    }

    private func assertPreflightFailure<Value>(
        _ field: SettingsLegacyDecodedField<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .invalid(.preflight) = field else {
            return XCTFail(
                "Expected a typed preflight failure, got \(field).",
                file: file,
                line: line
            )
        }
    }

    private func XCTAssertNotInvalid<Value>(
        _ field: SettingsLegacyDecodedField<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .invalid(let issue) = field {
            XCTFail(
                "Unexpected invalid field: \(issue)",
                file: file,
                line: line
            )
        }
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
