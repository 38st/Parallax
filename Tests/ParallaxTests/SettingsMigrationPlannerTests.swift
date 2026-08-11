import Foundation
@testable import Parallax
import XCTest

final class SettingsMigrationPlannerTests: XCTestCase {
    private let templateID = UUID(
        uuid: (
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x46, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
        )
    )
    private let visualID = UUID(
        uuid: (
            0xaa, 0xaa, 0xaa, 0xaa, 0xbb, 0xbb, 0x4c, 0xcc,
            0x8d, 0xdd, 0xee, 0xee, 0xee, 0xee, 0xee, 0xee
        )
    )

    func testMissingPrimaryAndAbsentLegacyPublishesExactDefaults() {
        let legacy = assessment(snapshot())
        let result = planner(legacy: legacy).plan()

        guard case .publishDefaults(let ready) = result else {
            return XCTFail("Expected defaults publication, got \(result)")
        }
        XCTAssertEqual(ready.state, .defaults)
        XCTAssertEqual(ready.evidence.current.source, .missing)
        XCTAssertEqual(ready.evidence.legacy, legacy)
    }

    func testFullyRepresentableLegacyMaterializesWithoutChangingValues() {
        let templateJSON = Data(
            """
            [{"id":"00112233-4455-4677-8899-AABBCCDDEEFF",\
            "name":" Raw  Name ","argumentsText":"--x",\
            "environmentText":"A=1","notes":" note "}]
            """.utf8
        )
        let visualJSON = Data(
            """
            {"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee":{
            "symbol":"globe","color":"brown"}}
            """.utf8
        )
        let legacy = assessment(
            snapshot(
                templates: .retained(templateJSON),
                path: .retained("/raw/../path"),
                confirm: .retained(true),
                automatic: .retained(false),
                appearance: .retained("dark"),
                visuals: .retained(visualJSON)
            )
        )

        guard case .publishLegacy(let ready) =
            planner(legacy: legacy).plan()
        else {
            return XCTFail("Expected a legacy publication.")
        }
        XCTAssertEqual(
            ready.state.profileTemplates,
            [
                ProfileTemplate(
                    id: templateID,
                    name: " Raw  Name ",
                    argumentsText: "--x",
                    environmentText: "A=1",
                    notes: " note "
                ),
            ]
        )
        XCTAssertEqual(ready.state.defaultBaseStoragePath, "/raw/../path")
        XCTAssertTrue(ready.state.confirmBeforeLaunch)
        XCTAssertFalse(ready.state.automaticallyRecoverCrashedApps)
        XCTAssertEqual(ready.state.appearance, .dark)
        XCTAssertEqual(
            ready.state.profileVisualIdentities,
            [
                visualID: ProfileInstanceVisualIdentity(
                    symbol: .globe,
                    color: .brown
                ),
            ]
        )
        XCTAssertEqual(ready.evidence.legacy, legacy)
    }

    func testNamesOnlyPreserveBlankSpacingDuplicatesAndUnicodeScalars() {
        let nfc = "\u{00e9}"
        let nfd = "e\u{0301}"
        let names = ["", " A  B ", nfc, nfd, nfc]
        let legacy = assessment(snapshot(names: .retained(names)))

        guard case .publishLegacy(let first) =
            planner(legacy: legacy).plan(),
            case .publishLegacy(let second) =
            planner(legacy: legacy).plan()
        else {
            return XCTFail("Expected a names-only migration.")
        }
        XCTAssertEqual(first.state.profileTemplates.map(\.name), names)
        XCTAssertEqual(first.state.profileTemplates, second.state.profileTemplates)
        XCTAssertEqual(
            Set(first.state.profileTemplates.map(\.id)).count,
            names.count
        )
        XCTAssertEqual(
            first.state.profileTemplates[2].name.unicodeScalars.map(\.value),
            nfc.unicodeScalars.map(\.value)
        )
        XCTAssertEqual(
            first.state.profileTemplates[3].name.unicodeScalars.map(\.value),
            nfd.unicodeScalars.map(\.value)
        )
        guard case .publishLegacy(let different) = planner(
            legacy: assessment(snapshot(names: .retained(["Different"])))
        ).plan() else {
            return XCTFail("Expected a second names-only migration.")
        }
        XCTAssertNotEqual(
            first.state.profileTemplates[0].id,
            different.state.profileTemplates[0].id
        )
    }

    func testEmptyStructuredTemplatesRemainEmptyButEmptyNamesUseDefaults() {
        let structured = assessment(
            snapshot(templates: .retained(Data("[]".utf8)))
        )
        let names = assessment(snapshot(names: .retained([])))

        guard case .publishLegacy(let structuredReady) =
            planner(legacy: structured).plan(),
            case .publishLegacy(let namesReady) =
            planner(legacy: names).plan()
        else {
            return XCTFail("Expected valid legacy publications.")
        }
        XCTAssertEqual(structuredReady.state.profileTemplates, [])
        XCTAssertEqual(
            namesReady.state.profileTemplates,
            ProfileTemplate.defaults
        )
    }

    func testEquivalentCoexistingTemplateFormsUseStructuredIdentity() {
        let data = templateData(id: templateID, name: "Same")
        let legacy = assessment(
            snapshot(
                templates: .retained(data),
                names: .retained(["Same"])
            )
        )

        guard case .publishLegacy(let ready) =
            planner(legacy: legacy).plan()
        else {
            return XCTFail("Expected exact redundant forms to migrate.")
        }
        XCTAssertEqual(ready.state.profileTemplates.map(\.id), [templateID])
        XCTAssertEqual(ready.state.profileTemplates.map(\.name), ["Same"])
    }

    func testScalarDistinctCoexistingFormsRequireRecovery() {
        let nfc = "\u{00e9}"
        let nfd = "e\u{0301}"
        let legacy = assessment(
            snapshot(
                templates: .retained(
                    templateData(id: templateID, name: nfc)
                ),
                names: .retained([nfd])
            )
        )

        XCTAssertEqual(
            recoveryReasons(planner(legacy: legacy).plan()),
            [.conflictingTemplateForms]
        )
    }

    func testCurrentPrimaryIsAuthoritativeAndDoesNotEvaluateCorruptLegacy() {
        let current = currentSnapshot(
            document: document(
                templates: [
                    .init(
                        id: templateID.uuidString,
                        name: "Current",
                        argumentsText: "",
                        environmentText: "",
                        notes: ""
                    ),
                ]
            )
        )
        let legacy = assessment(
            snapshot(
                path: .wrongType(.number),
                appearance: .retained("future")
            )
        )

        guard case .useCurrent(let ready) = planner(
            current: current,
            legacy: legacy
        ).plan() else {
            return XCTFail("Expected the current primary.")
        }
        XCTAssertEqual(ready.state.profileTemplates.map(\.name), ["Current"])
        XCTAssertEqual(ready.evidence.current.source, current)
        XCTAssertEqual(ready.evidence.legacy, legacy)
    }

    func testFutureCorruptAndUnavailableCurrentPrimaryNeverFallBack() {
        let validLegacy = assessment(snapshot(confirm: .retained(true)))
        let bytes = Data("evidence".utf8)
        let corruptFailure = SettingsDocumentCodecFailure(
            issue: .malformedJSON,
            originalBytes: bytes
        )
        let unavailable = SettingsRepositoryUnavailable.primaryFile(
            .changedDuringRead
        )
        let cases: [
            (SettingsRepositoryInspection, SettingsMigrationRecoveryReason)
        ] = [
            (
                .future(
                    schemaVersion: 99,
                    evidence: .init(
                        originalBytes: bytes,
                        sourceSHA256: .init(bytes)
                    )
                ),
                .currentPrimaryFutureSchema(99)
            ),
            (
                .recoveryRequired(
                    failure: corruptFailure,
                    sourceSHA256: .init(bytes)
                ),
                .currentPrimaryCorrupt(corruptFailure)
            ),
            (
                .unavailable(unavailable),
                .currentPrimaryUnavailable(unavailable)
            ),
        ]

        for (current, expected) in cases {
            let result = planner(
                current: current,
                legacy: validLegacy
            ).plan()
            XCTAssertEqual(recoveryReasons(result), [expected])
            XCTAssertEqual(recoveryEvidence(result)?.current.source, current)
            XCTAssertEqual(recoveryEvidence(result)?.legacy, validLegacy)
        }
    }

    func testInvalidCurrentStateNeverFallsBackToLegacy() {
        let duplicate = SettingsDocument.Template(
            id: templateID.uuidString,
            name: "Duplicate",
            argumentsText: "",
            environmentText: "",
            notes: ""
        )
        let source = currentSnapshot(
            document: document(templates: [duplicate, duplicate])
        )

        XCTAssertEqual(
            recoveryReasons(
                planner(
                    current: source,
                    legacy: assessment(snapshot(confirm: .retained(true)))
                ).plan()
            ),
            [.currentPrimaryInvalidState(.duplicateTemplateID(templateID))]
        )
    }

    func testEveryLegacyFieldRejectsUnavailableWrongTypeAndOversize() {
        let failure = SettingsLegacySourceFailure.unavailable(code: 5)
        let violation = SettingsLegacyLimitViolation.byteCount(
            actual: 2,
            maximum: 1
        )
        let cases: [
            (
                SettingsLegacyKey,
                SettingsLegacySnapshot,
                SettingsMigrationRecoveryReason
            )
        ] = [
            (
                .profileTemplates,
                snapshot(templates: .unavailable(failure)),
                .legacyFieldUnavailable(
                    key: .profileTemplates,
                    failure: failure
                )
            ),
            (
                .legacyProfileTemplateNames,
                snapshot(names: .wrongType(.number)),
                .legacyFieldWrongType(
                    key: .legacyProfileTemplateNames,
                    actual: .number
                )
            ),
            (
                .defaultBaseStoragePath,
                snapshot(path: .oversized([violation])),
                .legacyFieldOversized(
                    key: .defaultBaseStoragePath,
                    violations: [violation]
                )
            ),
            (
                .confirmBeforeLaunch,
                snapshot(confirm: .wrongType(.string)),
                .legacyFieldWrongType(
                    key: .confirmBeforeLaunch,
                    actual: .string
                )
            ),
            (
                .automaticallyRecoverCrashedApps,
                snapshot(automatic: .wrongType(.number)),
                .legacyFieldWrongType(
                    key: .automaticallyRecoverCrashedApps,
                    actual: .number
                )
            ),
            (
                .appearance,
                snapshot(appearance: .wrongType(.boolean)),
                .legacyFieldWrongType(
                    key: .appearance,
                    actual: .boolean
                )
            ),
            (
                .profileVisualIdentities,
                snapshot(visuals: .oversized([violation])),
                .legacyFieldOversized(
                    key: .profileVisualIdentities,
                    violations: [violation]
                )
            ),
        ]

        for (key, source, expected) in cases {
            let reasons = recoveryReasons(
                planner(legacy: assessment(source)).plan()
            )
            XCTAssertTrue(
                reasons.contains(expected),
                "Missing exact recovery reason for \(key): \(reasons)"
            )
        }
    }

    func testPartialSnapshotPreservesAllIssuesInRecoveryEvidence() {
        let issues: [SettingsLegacySnapshotIssue] = [
            .unexpectedKeyCount(2),
            .aggregateDataBytes(actual: 9, maximum: 8),
        ]
        let legacy = assessment(
            snapshot(
                confirm: .retained(true),
                completion: .partial(issues)
            )
        )

        let result = planner(legacy: legacy).plan()
        XCTAssertEqual(
            recoveryReasons(result),
            [.legacySnapshotPartial(issues)]
        )
        XCTAssertEqual(recoveryEvidence(result)?.legacy, legacy)
    }

    func testMalformedTemplateAndVisualPayloadsPreserveDecodeIssue() {
        let templateLegacy = assessment(
            snapshot(templates: .retained(Data("{".utf8)))
        )
        let visualLegacy = assessment(
            snapshot(visuals: .retained(Data("[]".utf8)))
        )

        for (payload, legacy) in [
            (SettingsMigrationLegacyPayload.profileTemplates, templateLegacy),
            (.profileVisualIdentities, visualLegacy),
        ] {
            let reasons = recoveryReasons(planner(legacy: legacy).plan())
            guard let last = reasons.last,
                  case .legacyPayloadInvalid(let actual, _) = last else {
                return XCTFail("Expected exact invalid payload evidence.")
            }
            XCTAssertEqual(actual, payload)
            XCTAssertEqual(recoveryEvidence(
                planner(legacy: legacy).plan()
            )?.legacy, legacy)
        }
    }

    func testDuplicateTemplateIdentityRequiresRecoveryWithoutDedupe() {
        let array = templateData([
            (templateID, "First"),
            (templateID, "Second"),
        ])
        let legacy = assessment(snapshot(templates: .retained(array)))

        XCTAssertEqual(
            recoveryReasons(planner(legacy: legacy).plan()),
            [
                .duplicateTemplateID(
                    sourceIndex: 1,
                    firstIndex: 0,
                    id: templateID
                ),
            ]
        )
    }

    func testUnknownTemplateAndVisualMembersRequireRecovery() {
        let template = Data(
            """
            [{"id":"00112233-4455-4677-8899-AABBCCDDEEFF",\
            "name":"A","argumentsText":"","environmentText":"",\
            "notes":"","future":true}]
            """.utf8
        )
        let visual = Data(
            """
            {"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee":{
            "symbol":"globe","color":"blue","future":true}}
            """.utf8
        )
        let legacy = assessment(
            snapshot(
                templates: .retained(template),
                visuals: .retained(visual)
            )
        )

        XCTAssertEqual(
            recoveryReasons(planner(legacy: legacy).plan()),
            [
                .templateUnknownMembers(sourceIndex: 0, count: 1),
                .visualUnknownMembers(entryIndex: 0, count: 1),
            ]
        )
    }

    func testNoncanonicalNonUUIDAndCanonicalEquivalentVisualKeysRecover() {
        let canonical = visualID.uuidString.lowercased()
        let upper = visualID.uuidString.uppercased()
        let visual = Data(
            """
            {"\(canonical)":{"symbol":"globe","color":"blue"},
             "\(upper)":{"symbol":"leaf.fill","color":"green"},
             "not-a-uuid":{"symbol":"camera.fill","color":"pink"}}
            """.utf8
        )
        let legacy = assessment(snapshot(visuals: .retained(visual)))

        XCTAssertEqual(
            recoveryReasons(planner(legacy: legacy).plan()),
            [
                .noncanonicalVisualKey(
                    entryIndex: 0,
                    key: upper,
                    id: visualID
                ),
                .duplicateVisualID(
                    entryIndex: 1,
                    firstIndex: 0,
                    id: visualID
                ),
                .nonUUIDVisualKey(entryIndex: 2, key: "not-a-uuid"),
            ]
        )
    }

    func testUnsupportedAppearanceValuesNeverCoerceToSystem() {
        for value in ["", "System", "future"] {
            let legacy = assessment(
                snapshot(appearance: .retained(value))
            )
            XCTAssertEqual(
                recoveryReasons(planner(legacy: legacy).plan()),
                [.unsupportedAppearance(value)]
            )
        }
    }

    func testCombinedLegacyPayloadThatExceedsTargetLimitRequiresRecovery()
        throws
    {
        let largeText = String(repeating: "x", count: 64 * 1_024)
        let templates = (0..<60).map { index in
            SettingsDocument.Template(
                id: deterministicUUID(index).uuidString,
                name: "T\(index)",
                argumentsText: largeText,
                environmentText: "",
                notes: ""
            )
        }
        let templateData = try JSONEncoder().encode(templates)
        XCTAssertLessThanOrEqual(
            templateData.count,
            SettingsLegacySnapshotDecoder.maximumInputBytes
        )

        let visualObject = Dictionary(
            uniqueKeysWithValues: (0..<4_096).map { index in
                (
                    deterministicUUID(10_000 + index)
                        .uuidString.lowercased(),
                    ["symbol": "globe", "color": "blue"]
                )
            }
        )
        let visualData = try JSONEncoder().encode(visualObject)
        XCTAssertLessThanOrEqual(
            visualData.count,
            SettingsLegacySnapshotDecoder.maximumInputBytes
        )
        XCTAssertLessThanOrEqual(
            templateData.count + visualData.count,
            SettingsLegacySnapshotReader.maximumAggregateDataBytes
        )

        let legacy = assessment(
            snapshot(
                templates: .retained(templateData),
                visuals: .retained(visualData)
            )
        )
        XCTAssertEqual(legacy.source.source.completion, .complete)
        let result = planner(legacy: legacy).plan()
        guard case .legacyTargetInvalid(
            .encodedOutputTooLarge(let actual, let maximum)
        ) = recoveryReasons(result).first else {
            return XCTFail("Expected target-size recovery, got \(result)")
        }
        XCTAssertEqual(
            recoveryReasons(result),
            [
                .legacyTargetInvalid(
                    .encodedOutputTooLarge(
                        actual: actual,
                        maximum: maximum
                    )
                ),
            ]
        )
        XCTAssertEqual(recoveryEvidence(result)?.legacy, legacy)
        XCTAssertGreaterThan(actual, maximum)
        XCTAssertEqual(maximum, 4 * 1_024 * 1_024)
    }

    func testUnsupportedVisualVocabularyRetainsExactDecoderEvidence() {
        let visual = Data(
            """
            {"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee":{
            "symbol":"future.symbol","color":"blue"}}
            """.utf8
        )
        let legacy = assessment(snapshot(visuals: .retained(visual)))
        let reasons = recoveryReasons(planner(legacy: legacy).plan())

        guard let last = reasons.last,
              case .legacyPayloadInvalid(
            payload: .profileVisualIdentities,
            issue: let issue
        ) = last else {
            return XCTFail("Expected unsupported vocabulary evidence.")
        }
        XCTAssertEqual(
            issue,
            .shape(
                payload: .profileVisualIdentities,
                location: .visual(key: visualID.uuidString.lowercased()),
                field: .symbol,
                problem: .invalidValue
            )
        )
    }

    func testPairingMismatchFailsClosedWithAttachedAssessments() {
        let source = snapshot(templates: .retained(Data("[]".utf8)))
        let decoded = SettingsLegacyDecodedSnapshot(
            source: source,
            profileTemplates: .absent,
            profileVisualIdentities: .absent
        )
        let legacy = SettingsLegacyMigrationAssessor(source: decoded).assess()
        let result = planner(legacy: legacy).plan()

        XCTAssertEqual(
            recoveryReasons(result),
            [
                .legacyPayloadPairingInconsistent(.profileTemplates),
            ]
        )
        XCTAssertEqual(recoveryEvidence(result)?.legacy, legacy)
    }

    func testCheckedSendabilityAndDeterministicConcurrentReplay() async {
        assertSendable(SettingsMigrationLegacyPayload.self)
        assertSendable(SettingsMigrationRecoveryReason.self)
        assertSendable(SettingsMigrationEvidence.self)
        assertSendable(SettingsMigrationReadyPlan.self)
        assertSendable(SettingsMigrationRecoveryPlan.self)
        assertSendable(SettingsMigrationPlan.self)
        assertSendable(SettingsMigrationPlanner.self)
        let subject = planner(
            legacy: assessment(
                snapshot(
                    names: .retained(["A", " A ", ""]),
                    confirm: .retained(true)
                )
            )
        )
        let expected = subject.plan()

        let results = await withTaskGroup(
            of: SettingsMigrationPlan.self,
            returning: [SettingsMigrationPlan].self
        ) { group in
            for _ in 0..<32 {
                group.addTask { subject.plan() }
            }
            var values: [SettingsMigrationPlan] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    private func planner(
        current: SettingsRepositoryInspection = .missing,
        legacy: SettingsLegacyMigrationAssessment
    ) -> SettingsMigrationPlanner {
        SettingsMigrationPlanner(
            current: SettingsCurrentMigrationAssessor(
                source: current
            ).assess(),
            legacy: legacy
        )
    }

    private func assessment(
        _ source: SettingsLegacySnapshot
    ) -> SettingsLegacyMigrationAssessment {
        SettingsLegacyMigrationAssessor(
            source: SettingsLegacySnapshotDecoder(source: source).decode()
        ).assess()
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

    private func templateData(id: UUID, name: String) -> Data {
        templateData([(id, name)])
    }

    private func templateData(_ values: [(UUID, String)]) -> Data {
        let templates = values.map { id, name in
            SettingsDocument.Template(
                id: id.uuidString,
                name: name,
                argumentsText: "",
                environmentText: "",
                notes: ""
            )
        }
        do {
            return try JSONEncoder().encode(templates)
        } catch {
            XCTFail("Could not encode fixture: \(error)")
            return Data()
        }
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        let bits = UInt64(value)
        return UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0x40, 0,
            0x80, 0,
            UInt8(truncatingIfNeeded: bits >> 40),
            UInt8(truncatingIfNeeded: bits >> 32),
            UInt8(truncatingIfNeeded: bits >> 24),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits)
        ))
    }

    private func document(
        templates: [SettingsDocument.Template] = []
    ) -> SettingsDocument {
        .init(
            revision: .zero,
            profileTemplates: templates,
            defaultBaseStoragePath: "",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true,
            appearance: "system",
            profileVisualIdentities: []
        )
    }

    private func currentSnapshot(
        document: SettingsDocument
    ) -> SettingsRepositoryInspection {
        let bytes = Data("current".utf8)
        return .current(
            .init(
                document: document,
                versionToken: .init(
                    revision: document.revision,
                    sourceSHA256: .init(bytes)
                ),
                originalBytes: bytes
            )
        )
    }

    private func recoveryReasons(
        _ plan: SettingsMigrationPlan
    ) -> [SettingsMigrationRecoveryReason] {
        guard case .recoveryRequired(let recovery) = plan else {
            XCTFail("Expected recovery, got \(plan)")
            return []
        }
        return recovery.reasons
    }

    private func recoveryEvidence(
        _ plan: SettingsMigrationPlan
    ) -> SettingsMigrationEvidence? {
        guard case .recoveryRequired(let recovery) = plan else {
            XCTFail("Expected recovery, got \(plan)")
            return nil
        }
        return recovery.evidence
    }

    private func assertSendable<T: Sendable>(_: T.Type) {}
}
