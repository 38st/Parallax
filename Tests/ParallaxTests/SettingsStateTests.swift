import Foundation
import XCTest
@testable import Parallax

final class SettingsStateTests: XCTestCase {
    func testTypedStateRoundTripsCurrentDocumentDeterministically() throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000002")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")
        )
        let state = SettingsState(
            profileTemplates: [
                ProfileTemplate(
                    id: firstID,
                    name: "Work",
                    argumentsText: "--isolated",
                    environmentText: "A=1",
                    notes: "Keep order"
                )
            ],
            defaultBaseStoragePath: "/tmp/profiles",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: .dark,
            profileVisualIdentities: [
                firstID: .init(symbol: .briefcase, color: .blue),
                secondID: .init(symbol: .flask, color: .purple),
            ]
        )

        let document = state.document(
            revision: SettingsRevision(rawValue: 7)
        )

        XCTAssertEqual(
            document.profileVisualIdentities.map(\.profileID),
            [
                secondID.uuidString.lowercased(),
                firstID.uuidString.lowercased(),
            ]
        )
        XCTAssertEqual(try SettingsState(document: document), state)
        XCTAssertEqual(document.revision, SettingsRevision(rawValue: 7))
    }

    func testDefaultsMatchCurrentRuntimeDefaults() {
        XCTAssertEqual(SettingsState.defaults.profileTemplates, ProfileTemplate.defaults)
        XCTAssertEqual(SettingsState.defaults.defaultBaseStoragePath, "")
        XCTAssertFalse(SettingsState.defaults.confirmBeforeLaunch)
        XCTAssertTrue(SettingsState.defaults.automaticallyRecoverCrashedApps)
        XCTAssertEqual(SettingsState.defaults.appearance, .system)
        XCTAssertTrue(SettingsState.defaults.profileVisualIdentities.isEmpty)
    }

    func testMappingRejectsInvalidAndDuplicateWireIdentity() throws {
        let duplicate = "abcdefab-cdef-4abc-8def-abcdefabcdef"
        guard let duplicateID = UUID(uuidString: duplicate) else {
            return XCTFail("Fixture UUID must remain valid.")
        }
        let document = SettingsDocument(
            revision: SettingsRevision(rawValue: 1),
            profileTemplates: [
                .init(
                    id: duplicate,
                    name: "One",
                    argumentsText: "",
                    environmentText: "",
                    notes: ""
                ),
                .init(
                    id: duplicate.uppercased(),
                    name: "Two",
                    argumentsText: "",
                    environmentText: "",
                    notes: ""
                ),
            ],
            defaultBaseStoragePath: "",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true,
            appearance: "system",
            profileVisualIdentities: []
        )

        XCTAssertThrowsError(try SettingsState(document: document)) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .duplicateTemplateID(duplicateID)
            )
        }
    }

    func testMappingRejectsUnsupportedSchemaAndInvalidTemplateID() {
        XCTAssertThrowsError(
            try SettingsState(
                document: document(schemaVersion: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .unsupportedSchema(2)
            )
        }

        XCTAssertThrowsError(
            try SettingsState(
                document: document(templateID: "not-a-uuid")
            )
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .invalidTemplateID("not-a-uuid")
            )
        }
    }

    func testMappingRejectsInvalidAndDuplicateVisualIdentity() throws {
        XCTAssertThrowsError(
            try SettingsState(
                document: document(visualProfileID: "not-a-uuid")
            )
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .invalidVisualProfileID("not-a-uuid")
            )
        }

        let duplicate = "abcdefab-cdef-4abc-8def-abcdefabcdef"
        let duplicateID = try XCTUnwrap(UUID(uuidString: duplicate))
        let duplicateDocument = document(
            visualProfileID: duplicate,
            additionalVisualProfileID: duplicate.uppercased()
        )
        XCTAssertThrowsError(
            try SettingsState(document: duplicateDocument)
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .duplicateVisualProfileID(duplicateID)
            )
        }
    }

    func testMappingRejectsUnknownAppearanceAndVisualVocabulary() {
        XCTAssertThrowsError(
            try SettingsState(document: document(appearance: "sepia"))
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .invalidAppearance("sepia")
            )
        }

        XCTAssertThrowsError(
            try SettingsState(document: document(symbol: "unknown"))
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .invalidVisualSymbol("unknown")
            )
        }

        XCTAssertThrowsError(
            try SettingsState(document: document(color: "ultraviolet"))
        ) { error in
            XCTAssertEqual(
                error as? SettingsState.MappingError,
                .invalidVisualColor("ultraviolet")
            )
        }
    }

    func testMixedCaseWireUUIDsEncodeAsCanonicalLowercase() throws {
        let raw = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        let state = try SettingsState(
            document: document(
                templateID: raw,
                visualProfileID: raw
            )
        )

        let encoded = state.document(revision: .zero)

        XCTAssertEqual(encoded.profileTemplates.map(\.id), [raw.lowercased()])
        XCTAssertEqual(
            encoded.profileVisualIdentities.map(\.profileID),
            [raw.lowercased()]
        )
    }

    private func document(
        schemaVersion: UInt64 = SettingsDocument.currentSchemaVersion,
        templateID: String? = nil,
        appearance: String = "system",
        visualProfileID: String =
            "10000000-0000-4000-8000-000000000001",
        additionalVisualProfileID: String? = nil,
        symbol: String = "globe",
        color: String = "blue"
    ) -> SettingsDocument {
        let templates = templateID.map { id in
            [
                SettingsDocument.Template(
                    id: id,
                    name: "Template",
                    argumentsText: "",
                    environmentText: "",
                    notes: ""
                )
            ]
        } ?? []
        var visuals = [
            SettingsDocument.VisualIdentity(
                profileID: visualProfileID,
                symbol: symbol,
                color: color
            )
        ]
        if let additionalVisualProfileID {
            visuals.append(
                .init(
                    profileID: additionalVisualProfileID,
                    symbol: symbol,
                    color: color
                )
            )
        }
        return SettingsDocument(
            schemaVersion: schemaVersion,
            revision: SettingsRevision(rawValue: 1),
            profileTemplates: templates,
            defaultBaseStoragePath: "",
            confirmBeforeLaunch: false,
            automaticallyRecoverCrashedApps: true,
            appearance: appearance,
            profileVisualIdentities: visuals
        )
    }
}
