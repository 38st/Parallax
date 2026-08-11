import Foundation
@testable import Parallax
import XCTest

final class SettingsLegacyMigrationAssessmentTests: XCTestCase {
    private let id = UUID(
        uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF"
    )!

    func testJSONAndNameStatesPreserveEmptyAndNonemptyCounts() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 7)
        let violations = [
            SettingsLegacyLimitViolation.byteCount(actual: 2, maximum: 1),
        ]
        let invalid = SettingsLegacySnapshotDecodeIssue.shape(
            payload: .profileTemplates,
            location: .root,
            field: .root,
            problem: .wrongType
        )
        let jsonCases: [
            (
                SettingsLegacyDecodedField<
                    [SettingsLegacyTemplateWireRecord]
                >,
                SettingsLegacyMigrationJSONFieldState
            )
        ] = [
            (.unavailable(failure), .unavailable),
            (.absent, .absent),
            (.wrongType(.array), .wrongType),
            (.oversized(violations), .oversized),
            (.invalid(invalid), .invalid),
            (.decoded([]), .decoded(count: 0)),
            (.decoded([template(id: id, name: "A")]), .decoded(count: 1)),
        ]
        for (field, expected) in jsonCases {
            XCTAssertEqual(
                assess(templates: field).structuredTemplates,
                expected
            )
        }

        let nameCases: [
            (
                SettingsLegacyField<[String]>,
                SettingsLegacyMigrationNamesState
            )
        ] = [
            (.unavailable(failure), .unavailable),
            (.absent, .absent),
            (.wrongType(.dictionary), .wrongType),
            (.oversized(violations), .oversized),
            (.retained([]), .retained(count: 0)),
            (.retained(["", "A"]), .retained(count: 2)),
        ]
        for (field, expected) in nameCases {
            XCTAssertEqual(
                assess(names: field).legacyNames,
                expected
            )
        }
    }

    func testPairingRequiresExactAssociatedStateAndRetainedMaterialization() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 9)
        let otherFailure = SettingsLegacySourceFailure.unavailable(code: 10)
        let violation = SettingsLegacyLimitViolation.byteCount(
            actual: 3,
            maximum: 2
        )
        let otherViolation = SettingsLegacyLimitViolation.elementCount(
            actual: 3,
            maximum: 2
        )
        let invalid = SettingsLegacySnapshotDecodeIssue.shape(
            payload: .profileTemplates,
            location: .root,
            field: .root,
            problem: .wrongType
        )
        let paired: [
            (
                SettingsLegacyField<Data>,
                SettingsLegacyDecodedField<
                    [SettingsLegacyTemplateWireRecord]
                >
            )
        ] = [
            (.unavailable(failure), .unavailable(failure)),
            (.absent, .absent),
            (.wrongType(.data), .wrongType(.data)),
            (.oversized([violation]), .oversized([violation])),
            (.retained(Data("[]".utf8)), .decoded([])),
            (.retained(Data("bad".utf8)), .invalid(invalid)),
        ]
        for (raw, decoded) in paired {
            XCTAssertEqual(
                assess(rawTemplates: raw, templates: decoded)
                    .structuredTemplatePairing,
                .paired
            )
        }

        let inconsistent: [
            (
                SettingsLegacyField<Data>,
                SettingsLegacyDecodedField<
                    [SettingsLegacyTemplateWireRecord]
                >
            )
        ] = [
            (.unavailable(failure), .unavailable(otherFailure)),
            (.absent, .decoded([])),
            (.wrongType(.data), .wrongType(.array)),
            (.oversized([violation]), .oversized([otherViolation])),
            (.retained(Data("[]".utf8)), .absent),
        ]
        for (raw, decoded) in inconsistent {
            XCTAssertEqual(
                assess(rawTemplates: raw, templates: decoded)
                    .structuredTemplatePairing,
                .inconsistent
            )
        }

        let visual = assess(
            rawVisuals: .retained(Data("{}".utf8)),
            visuals: .decoded([])
        )
        XCTAssertEqual(visual.visualPairing, .paired)
    }

    func testTemplateFormPresenceCoversEveryPermutation() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 1)
        let structured: [
            (SettingsLegacyField<Data>, SettingsLegacyMigrationPresence)
        ] = [
            (.unavailable(failure), .unknown),
            (.absent, .absent),
            (.retained(Data()), .present),
            (.wrongType(.string), .present),
            (
                .oversized([.byteCount(actual: 2, maximum: 1)]),
                .present
            ),
        ]
        let names: [
            (
                SettingsLegacyField<[String]>,
                SettingsLegacyMigrationPresence
            )
        ] = [
            (.unavailable(failure), .unknown),
            (.absent, .absent),
            (.retained([]), .present),
            (.wrongType(.string), .present),
            (
                .oversized([.elementCount(actual: 2, maximum: 1)]),
                .present
            ),
        ]

        for (rawTemplates, expectedTemplates) in structured {
            for (rawNames, expectedNames) in names {
                XCTAssertEqual(
                    assess(
                        rawTemplates: rawTemplates,
                        names: rawNames
                    ).templateForms,
                    .init(
                        structured: expectedTemplates,
                        names: expectedNames
                    )
                )
            }
        }
    }

    func testNameCompatibilityAndScalarExactCanonicalRelations() {
        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"
        let names = [
            nfc,
            nfd,
            nfc,
            "Name",
            "name",
            " Internal  Space ",
            "Internal  Space",
            "\u{00A0}\u{2003}\u{2028}",
        ]

        let assessment = assess(names: .retained(names))
        let facts = assessment.legacyNameFacts

        XCTAssertEqual(facts.map(\.sourceIndex), Array(names.indices))
        XCTAssertEqual(facts[0].compatibility, .accepted)
        XCTAssertNil(facts[0].firstPriorScalarExactIndex)
        XCTAssertNil(
            facts[0].firstPriorCanonicalEquivalentButScalarDistinctIndex
        )
        XCTAssertNil(facts[1].firstPriorScalarExactIndex)
        XCTAssertEqual(
            facts[1].firstPriorCanonicalEquivalentButScalarDistinctIndex,
            0
        )
        XCTAssertEqual(facts[2].firstPriorScalarExactIndex, 0)
        XCTAssertEqual(
            facts[2].firstPriorCanonicalEquivalentButScalarDistinctIndex,
            1
        )
        XCTAssertNil(facts[4].firstPriorScalarExactIndex)
        XCTAssertNil(
            facts[4].firstPriorCanonicalEquivalentButScalarDistinctIndex
        )
        XCTAssertEqual(facts[5].compatibility, .requiresNormalization)
        XCTAssertEqual(facts[6].compatibility, .accepted)
        XCTAssertEqual(facts[7].compatibility, .blank)
    }

    func testStructuredTemplateFactsKeepOrderIgnoredCountsAndEarliestUUID() {
        let other = UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        )!
        let records = [
            template(id: id, name: "A", ignored: 2),
            template(id: other, name: " A ", ignored: 0),
            template(id: id, name: "", ignored: 1),
            template(id: id, name: "A", ignored: 3),
        ]

        let facts = assess(templates: .decoded(records))
            .structuredTemplateFacts

        XCTAssertEqual(facts.map(\.sourceIndex), [0, 1, 2, 3])
        XCTAssertEqual(facts.map(\.id), [id, other, id, id])
        XCTAssertEqual(
            facts.map(\.materializedIgnoredMemberCount),
            [2, 0, 1, 3]
        )
        XCTAssertEqual(
            facts.map(\.firstPriorEqualUUIDIndex),
            [nil, nil, 0, 0]
        )
        XCTAssertEqual(facts[1].name.compatibility, .requiresNormalization)
        XCTAssertEqual(facts[2].name.compatibility, .blank)
        XCTAssertEqual(facts[3].name.firstPriorScalarExactIndex, 0)
    }

    func testEveryScalarStateAndAppearanceClassification() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 3)
        let violations = [
            SettingsLegacyLimitViolation.byteCount(actual: 2, maximum: 1),
        ]
        let strings: [
            (SettingsLegacyField<String>, SettingsLegacyMigrationStringState)
        ] = [
            (.unavailable(failure), .unavailable),
            (.absent, .absent),
            (.wrongType(.number), .wrongType),
            (.oversized(violations), .oversized),
            (.retained(""), .retainedEmpty),
            (.retained("/raw/../path"), .retainedNonempty),
        ]
        for (field, expected) in strings {
            XCTAssertEqual(assess(path: field).basePath, expected)
        }

        let booleans: [
            (SettingsLegacyField<Bool>, SettingsLegacyMigrationBooleanState)
        ] = [
            (.unavailable(failure), .unavailable),
            (.absent, .absent),
            (.wrongType(.number), .wrongType),
            (.oversized(violations), .oversized),
            (.retained(false), .retainedFalse),
            (.retained(true), .retainedTrue),
        ]
        for (field, expected) in booleans {
            let result = assess(confirm: field, automatic: field)
            XCTAssertEqual(result.confirmBeforeLaunch, expected)
            XCTAssertEqual(result.automaticallyRecoverCrashedApps, expected)
        }

        let appearances: [
            (
                SettingsLegacyField<String>,
                SettingsLegacyMigrationAppearanceState
            )
        ] = [
            (.unavailable(failure), .unavailable),
            (.absent, .absent),
            (.wrongType(.boolean), .wrongType),
            (.oversized(violations), .oversized),
            (.retained("system"), .supported(.system)),
            (.retained("light"), .supported(.light)),
            (.retained("dark"), .supported(.dark)),
            (.retained(""), .unsupportedEmpty),
            (.retained("System"), .unsupportedNonempty),
            (.retained("bounded-future"), .unsupportedNonempty),
        ]
        for (field, expected) in appearances {
            XCTAssertEqual(assess(appearance: field).appearance, expected)
        }
    }

    func testVisualKeyClassesCollisionsAndEntryOrder() {
        let raw = id.uuidString.lowercased()
        let other = UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        )!
        let mixedCaseIdentifier =
            "00112233-4455-4677-8899-AAbbCCDDeeFF"
        let records = [
            visual(key: raw, ignored: 1),
            visual(key: id.uuidString.uppercased(), ignored: 2),
            visual(
                key: mixedCaseIdentifier,
                ignored: 3
            ),
            visual(key: "not-a-uuid", ignored: 4),
            visual(key: other.uuidString, ignored: 5),
            visual(key: raw, ignored: 6),
        ]

        let facts = assess(visuals: .decoded(records)).visualFacts

        XCTAssertEqual(facts.map(\.entryIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(
            facts.map(\.materializedIgnoredMemberCount),
            [1, 2, 3, 4, 5, 6]
        )
        XCTAssertEqual(facts[0].rawKeyClass, .canonicalLowercaseUUID(id))
        XCTAssertEqual(facts[1].rawKeyClass, .noncanonicalUUID(id))
        XCTAssertEqual(facts[2].rawKeyClass, .noncanonicalUUID(id))
        XCTAssertEqual(facts[3].rawKeyClass, .nonUUID)
        XCTAssertEqual(facts[4].rawKeyClass, .noncanonicalUUID(other))
        XCTAssertEqual(facts[5].rawKeyClass, .canonicalLowercaseUUID(id))
        XCTAssertEqual(
            facts.map(\.firstPriorEqualUUIDIndex),
            [nil, 0, 0, nil, nil, 0]
        )
    }

    func testEveryHistoricalVisualValueContributesExactRawBytes() {
        let symbols: [SettingsLegacyVisualSymbol] = [
            .briefcase, .person, .flask, .terminal, .book, .palette,
            .globe, .lightbulb, .hammer, .camera, .music, .leaf,
            .unmanaged,
        ]
        let colors: [SettingsLegacyVisualColor] = [
            .blue, .purple, .orange, .pink, .teal, .green, .indigo,
            .cyan, .brown, .gray,
        ]
        let records = symbols.enumerated().map { index, symbol in
            visual(
                key: "raw-\(index)",
                symbol: symbol,
                color: colors[index % colors.count]
            )
        }
        let expected = records.reduce(UInt64(0)) { total, record in
            total
                + UInt64(record.key.utf8.count)
                + UInt64(record.symbol.rawValue.utf8.count)
                + UInt64(record.color.rawValue.utf8.count)
        }

        XCTAssertEqual(
            assess(visuals: .decoded(records)).byteTotals.visuals,
            expected
        )
    }

    func testInvalidD1BEvidenceRemainsInvalidWithoutDerivedFacts() {
        let issue = SettingsLegacySnapshotDecodeIssue
            .visualKeyIdentityAmbiguity(
                sourceCount: 2,
                materializedCount: 1
            )
        let result = assess(
            rawVisuals: .retained(Data("{}".utf8)),
            visuals: .invalid(issue)
        )

        XCTAssertEqual(result.visuals, .invalid)
        XCTAssertEqual(result.visualPairing, .paired)
        XCTAssertTrue(result.visualFacts.isEmpty)
        XCTAssertEqual(result.byteTotals.visuals, 0)
    }

    func testExactByteTotalsExcludeIgnoredMembersAndBooleanValues() {
        let record = template(
            id: id,
            name: "é",
            arguments: "a",
            environment: "🧪",
            notes: "",
            ignored: 99
        )
        let identity = visual(
            key: id.uuidString.lowercased(),
            symbol: .globe,
            color: .gray,
            ignored: 88
        )

        let result = assess(
            names: .retained(["é", "a"]),
            path: .retained("/é"),
            confirm: .retained(true),
            automatic: .retained(false),
            appearance: .retained("dark"),
            templates: .decoded([record]),
            visuals: .decoded([identity])
        )

        XCTAssertEqual(
            result.byteTotals,
            .init(
                structuredTemplates: 43,
                legacyNames: 3,
                retainedScalars: 7,
                visuals: 45,
                nameOnlyIdentifierDemand: 72
            )
        )
    }

    func testDecoderOrderAndPartialSourceAreAttachedWithoutSelection() {
        let rawTemplates = Data("[]".utf8)
        let rawVisuals = Data(
            """
            {"z":{"symbol":"globe","color":"blue"},
             "a":{"symbol":"leaf.fill","color":"green"}}
            """.utf8
        )
        let source = snapshot(
            rawTemplates: .retained(rawTemplates),
            names: .retained(["coexisting"]),
            rawVisuals: .retained(rawVisuals),
            completion: .partial([
                .unexpectedKeyCount(2),
                .aggregateDataBytes(actual: 9, maximum: 8),
            ])
        )
        let decoded = SettingsLegacySnapshotDecoder(source: source).decode()

        let result = SettingsLegacyMigrationAssessor(
            source: decoded
        ).assess()

        XCTAssertEqual(result.source, decoded)
        XCTAssertEqual(result.structuredTemplatePairing, .paired)
        XCTAssertEqual(result.visualPairing, .paired)
        XCTAssertEqual(
            result.templateForms,
            .init(structured: .present, names: .present)
        )
        XCTAssertEqual(result.visualFacts.map(\.entryIndex), [0, 1])
        guard case .partial(let issues) = result.source.source.completion else {
            return XCTFail("Expected attached partial source evidence.")
        }
        XCTAssertEqual(
            issues,
            [
                .unexpectedKeyCount(2),
                .aggregateDataBytes(actual: 9, maximum: 8),
            ]
        )
    }

    func testMaximumBoundTotalsAreExactAndAssessmentIsBounded() {
        let text = String(repeating: "t", count: 64 * 1_024)
        let name = String(repeating: "n", count: 256)
        let rawVisualIdentifier = String(repeating: "k", count: 256)
        let templateRecord = template(
            id: id,
            name: name,
            arguments: text,
            environment: text,
            notes: text
        )
        let visualRecord = visual(
            key: rawVisualIdentifier,
            symbol: .person,
            color: .purple
        )
        let templates = Array(repeating: templateRecord, count: 4_096)
        let names = Array(repeating: name, count: 4_096)
        let visuals = Array(repeating: visualRecord, count: 4_096)

        let result = assess(
            names: .retained(names),
            path: .retained(String(repeating: "p", count: 4_096)),
            appearance: .retained(String(repeating: "a", count: 16)),
            templates: .decoded(templates),
            visuals: .decoded(visuals)
        )

        let templateBytes = UInt64(
            36 + 256 + 3 * 64 * 1_024
        ) * 4_096
        let visualBytes = UInt64(
            rawVisualIdentifier.utf8.count
                + SettingsLegacyVisualSymbol.person.rawValue.utf8.count
                + SettingsLegacyVisualColor.purple.rawValue.utf8.count
        ) * 4_096
        XCTAssertEqual(result.byteTotals.structuredTemplates, templateBytes)
        XCTAssertEqual(result.byteTotals.legacyNames, 256 * 4_096)
        XCTAssertEqual(result.byteTotals.retainedScalars, 4_112)
        XCTAssertEqual(result.byteTotals.visuals, visualBytes)
        XCTAssertEqual(
            result.byteTotals.nameOnlyIdentifierDemand,
            36 * 4_096
        )
        XCTAssertEqual(result.structuredTemplateFacts.count, 4_096)
        XCTAssertEqual(result.legacyNameFacts.count, 4_096)
        XCTAssertEqual(result.visualFacts.count, 4_096)
    }

    func testMaximum4096ItemAssessmentPerformance() {
        let templates = (0..<4_096).map { index in
            template(
                id: UUID(
                    uuid: (
                        UInt8(truncatingIfNeeded: index),
                        UInt8(truncatingIfNeeded: index >> 8),
                        0, 0, 0, 0, 0x40, 0,
                        0x80, 0, 0, 0, 0, 0, 0, 1
                    )
                ),
                name: "Name \(index)"
            )
        }
        let visuals = templates.map {
            visual(key: $0.id.uuidString.lowercased())
        }
        let decoded = decodedSnapshot(
            names: .retained(templates.map(\.name)),
            templates: .decoded(templates),
            visuals: .decoded(visuals)
        )
        let assessor = SettingsLegacyMigrationAssessor(source: decoded)

        measure {
            _ = assessor.assess()
        }
    }

    func testCheckedSendabilitySourceAttachmentAndConcurrentReplay() async {
        assertSendable(SettingsLegacyMigrationAssessor.self)
        assertSendable(SettingsLegacyMigrationAssessment.self)
        let decoded = decodedSnapshot(
            names: .retained(["é", "e\u{301}", "é"]),
            templates: .decoded([
                template(id: id, name: "A"),
            ]),
            visuals: .decoded([
                visual(key: id.uuidString.lowercased()),
            ]),
            completion: .partial([.unexpectedKeyCount(1)])
        )
        let assessor = SettingsLegacyMigrationAssessor(source: decoded)
        let expected = assessor.assess()

        let labels = Mirror(reflecting: expected).children
            .compactMap(\.label)
        XCTAssertEqual(labels.filter { $0 == "source" }.count, 1)
        XCTAssertFalse(labels.contains("candidate"))
        XCTAssertFalse(labels.contains("plan"))

        let results = await withTaskGroup(
            of: SettingsLegacyMigrationAssessment.self,
            returning: [SettingsLegacyMigrationAssessment].self
        ) { group in
            for _ in 0..<32 {
                group.addTask { assessor.assess() }
            }
            var values: [SettingsLegacyMigrationAssessment] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    private func assess(
        rawTemplates: SettingsLegacyField<Data> = .absent,
        names: SettingsLegacyField<[String]> = .absent,
        path: SettingsLegacyField<String> = .absent,
        confirm: SettingsLegacyField<Bool> = .absent,
        automatic: SettingsLegacyField<Bool> = .absent,
        appearance: SettingsLegacyField<String> = .absent,
        rawVisuals: SettingsLegacyField<Data> = .absent,
        templates: SettingsLegacyDecodedField<
            [SettingsLegacyTemplateWireRecord]
        > = .absent,
        visuals: SettingsLegacyDecodedField<
            [SettingsLegacyVisualIdentityWireRecord]
        > = .absent,
        completion: SettingsLegacySnapshotCompletion = .complete
    ) -> SettingsLegacyMigrationAssessment {
        SettingsLegacyMigrationAssessor(
            source: decodedSnapshot(
                rawTemplates: rawTemplates,
                names: names,
                path: path,
                confirm: confirm,
                automatic: automatic,
                appearance: appearance,
                rawVisuals: rawVisuals,
                templates: templates,
                visuals: visuals,
                completion: completion
            )
        ).assess()
    }

    private func decodedSnapshot(
        rawTemplates: SettingsLegacyField<Data> = .absent,
        names: SettingsLegacyField<[String]> = .absent,
        path: SettingsLegacyField<String> = .absent,
        confirm: SettingsLegacyField<Bool> = .absent,
        automatic: SettingsLegacyField<Bool> = .absent,
        appearance: SettingsLegacyField<String> = .absent,
        rawVisuals: SettingsLegacyField<Data> = .absent,
        templates: SettingsLegacyDecodedField<
            [SettingsLegacyTemplateWireRecord]
        > = .absent,
        visuals: SettingsLegacyDecodedField<
            [SettingsLegacyVisualIdentityWireRecord]
        > = .absent,
        completion: SettingsLegacySnapshotCompletion = .complete
    ) -> SettingsLegacyDecodedSnapshot {
        .init(
            source: snapshot(
                rawTemplates: rawTemplates,
                names: names,
                path: path,
                confirm: confirm,
                automatic: automatic,
                appearance: appearance,
                rawVisuals: rawVisuals,
                completion: completion
            ),
            profileTemplates: templates,
            profileVisualIdentities: visuals
        )
    }

    private func snapshot(
        rawTemplates: SettingsLegacyField<Data> = .absent,
        names: SettingsLegacyField<[String]> = .absent,
        path: SettingsLegacyField<String> = .absent,
        confirm: SettingsLegacyField<Bool> = .absent,
        automatic: SettingsLegacyField<Bool> = .absent,
        appearance: SettingsLegacyField<String> = .absent,
        rawVisuals: SettingsLegacyField<Data> = .absent,
        completion: SettingsLegacySnapshotCompletion = .complete
    ) -> SettingsLegacySnapshot {
        .init(
            profileTemplates: rawTemplates,
            legacyProfileTemplateNames: names,
            defaultBaseStoragePath: path,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: automatic,
            appearance: appearance,
            profileVisualIdentities: rawVisuals,
            completion: completion
        )
    }

    private func template(
        id: UUID,
        name: String,
        arguments: String = "",
        environment: String = "",
        notes: String = "",
        ignored: Int = 0
    ) -> SettingsLegacyTemplateWireRecord {
        .init(
            id: id,
            name: name,
            argumentsText: arguments,
            environmentText: environment,
            notes: notes,
            materializedIgnoredMemberCount: ignored
        )
    }

    private func visual(
        key: String,
        symbol: SettingsLegacyVisualSymbol = .globe,
        color: SettingsLegacyVisualColor = .blue,
        ignored: Int = 0
    ) -> SettingsLegacyVisualIdentityWireRecord {
        .init(
            key: key,
            symbol: symbol,
            color: color,
            materializedIgnoredMemberCount: ignored
        )
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
